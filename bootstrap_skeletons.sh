#!/usr/bin/env bash
set -euo pipefail

echo "[+] Creating skeletons for ranger-can (ISO-TP) and ranger-k (kernel module) ..."


ROOT="$(pwd)"

mkdir -p ranger-can/src ranger-can/include
mkdir -p ranger-k
mkdir -p ranger-k-test
mkdir -p scripts

############################################
# ranger-can/CMakeLists.txt
############################################
cat > ranger-can/CMakeLists.txt <<'CMAKE'
cmake_minimum_required(VERSION 3.13)
project(ranger-can LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(ranger-can
  src/ranger_can.cpp
)
target_include_directories(ranger-can PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
# socketcan is in glibc; just need headers. link to rt if needed.
# Some distros require linking with -lpthread for std::thread (if later used).
target_link_libraries(ranger-can PRIVATE)

install(TARGETS ranger-can RUNTIME DESTINATION bin)
CMAKE

############################################
# ranger-can/src/ranger_can.cpp
############################################
cat > ranger-can/src/ranger_can.cpp <<'CPP'
#include <sys/types.h>
#include <sys/socket.h>
#include <linux/can.h>
#include <linux/can/isotp.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

/*
 * ranger-can: ISO-TP bridge
 * - Reads JSONL from stdin: {"data":{"d":[x0,x1,x2,x3,x4]}}
 * - Packs into a simple binary frame and sends via SocketCAN ISO-TP.
 *   Payload layout (little-endian):
 *     uint32_t seq;
 *     float dist_m[5];
 *     uint32_t status; // reserved
 */

#pragma pack(push,1)
struct RangerMsg {
  uint32_t seq;
  float dist_m[5];
  uint32_t status;
};
#pragma pack(pop)

static volatile std::sig_atomic_t g_stop = 0;
static void on_sigint(int){ g_stop = 1; }

struct Args {
  std::string ifname = "vcan0";
  uint32_t tx_id = 0x701; // from us -> peer
  uint32_t rx_id = 0x700; // peer -> us
  double rate_hz = 20.0;  // minimum send interval if stdin is too fast; 0 => send asap
  bool verbose = false;
};

static void usage(const char* prog){
  std::cerr << "Usage: " << prog << " [--if vcan0] [--tx 0x701] [--rx 0x700] [--rate-hz 20] [--verbose]\n"
            << "Reads JSONL from stdin and sends ISO-TP frames.\n";
}

static Args parse_args(int argc, char** argv){
  Args a;
  for (int i=1;i<argc;i++){
    std::string k = argv[i];
    auto need = [&](const char* name){ if (i+1>=argc) { usage(argv[0]); std::exit(2);} return std::string(argv[++i]); };
    if (k=="--if") a.ifname = need("--if");
    else if (k=="--tx") a.tx_id = std::stoul(need("--tx"), nullptr, 0);
    else if (k=="--rx") a.rx_id = std::stoul(need("--rx"), nullptr, 0);
    else if (k=="--rate-hz") a.rate_hz = std::stod(need("--rate-hz"));
    else if (k=="--verbose" || k=="-v") a.verbose = true;
    else if (k=="-h" || k=="--help"){ usage(argv[0]); std::exit(0); }
    else { usage(argv[0]); std::exit(2); }
  }
  return a;
}

// very small JSON parser: find the "d":[...] array and parse 5 floats
static std::optional<std::array<float,5>> parse_jsonl_line(const std::string& line){
  auto pos = line.find("\"d\"");
  if (pos == std::string::npos) return std::nullopt;
  pos = line.find('[', pos);
  if (pos == std::string::npos) return std::nullopt;
  auto end = line.find(']', pos);
  if (end == std::string::npos) return std::nullopt;
  std::array<float,5> out{};
  size_t idx = 0;
  std::string arr = line.substr(pos+1, end-pos-1); // inside [ ... ]
  std::stringstream ss(arr);
  std::string tok;
  while (std::getline(ss, tok, ',') && idx < 5){
    try { out[idx++] = std::stof(tok); } catch(...) { return std::nullopt; }
  }
  if (idx != 5) return std::nullopt;
  return out;
}

static int open_isotp(const std::string& ifname, uint32_t tx_id, uint32_t rx_id){
  int s = socket(PF_CAN, SOCK_DGRAM, CAN_ISOTP);
  if (s < 0) { perror("socket CAN_ISOTP"); return -1; }

  // Configure default ISO-TP options
  struct can_isotp_options opts{};
  opts.flags = CAN_ISOTP_TX_PADDING | CAN_ISOTP_RX_PADDING;
  opts.txpad_content = 0x00;
  opts.rxpad_content = 0x00;
  if (setsockopt(s, SOL_CAN_ISOTP, CAN_ISOTP_OPTS, &opts, sizeof(opts)) < 0){
    perror("setsockopt CAN_ISOTP_OPTS");
    // not fatal
  }

  struct ifreq ifr{};
  std::snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", ifname.c_str());
  if (ioctl(s, SIOCGIFINDEX, &ifr) < 0){
    perror("ioctl SIOCGIFINDEX");
    close(s);
    return -1;
  }

  struct sockaddr_can addr{};
  addr.can_family = AF_CAN;
  addr.can_ifindex = ifr.ifr_ifindex;
  addr.can_addr.tp.tx_id = tx_id;
  addr.can_addr.tp.rx_id = rx_id;

  if (bind(s, (struct sockaddr*)&addr, sizeof(addr)) < 0){
    perror("bind isotp");
    close(s);
    return -1;
  }
  return s;
}

int main(int argc, char** argv){
  std::signal(SIGINT, on_sigint);
  auto args = parse_args(argc, argv);

  int s = open_isotp(args.ifname, args.tx_id, args.rx_id);
  if (s < 0) return 1;

  RangerMsg msg{};
  uint64_t last_sent_ns = 0;
  const bool rate_limit = (args.rate_hz > 0.0);
  const double min_interval_ns = rate_limit ? (1e9 / args.rate_hz) : 0.0;

  std::string line;
  while(!g_stop && std::getline(std::cin, line)){
    auto arr = parse_jsonl_line(line);
    if (!arr) continue;

    msg.seq++;
    for (size_t i=0;i<5;i++) msg.dist_m[i] = (*arr)[i];
    msg.status = 0;

    // Rate limiting (optional)
    uint64_t now_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    if (rate_limit && last_sent_ns != 0 && (now_ns - last_sent_ns) < min_interval_ns){
      // skip this packet; keep the latest
      continue;
    }
    last_sent_ns = now_ns;

    ssize_t n = send(s, &msg, sizeof(msg), 0);
    if (n < 0){
      perror("send isotp");
      break;
    }
    if (args.verbose){
      std::cerr << "[tx seq=" << msg.seq << "] "
                << msg.dist_m[0] << "," << msg.dist_m[1] << ","
                << msg.dist_m[2] << "," << msg.dist_m[3] << ","
                << msg.dist_m[4] << "\n";
    }
  }

  close(s);
  return 0;
}
CPP

############################################
# ranger-k/Makefile (out-of-tree module)
############################################
cat > ranger-k/Makefile <<'MK'
# Build with: make -C /lib/modules/$(uname -r)/build M=$(PWD) modules
obj-m += ranger_k.o

all:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

clean:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
MK

############################################
# ranger-k/ranger_k.c (kernel skeleton)
############################################
cat > ranger-k/ranger_k.c <<'KC'
// SPDX-License-Identifier: MIT
/*
 * ranger_k - minimal kernel skeleton for IRQ/timestamp-based ultrasonic reader.
 * This is a skeleton: no real GPIO yet. Exposes debugfs with dummy distances.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/debugfs.h>
#include <linux/uaccess.h>
#include <linux/jiffies.h>

#define DRV_NAME "ranger_k"

static struct dentry *dbg_dir;
static u32 dbg_seq;
static u32 dbg_status;
static float dbg_dist[5] = {0};

static ssize_t stats_read(struct file *f, char __user *buf, size_t len, loff_t *ppos)
{
	char tmp[128];
	int n = scnprintf(tmp, sizeof(tmp), "seq=%u status=0x%x jiffies=%lu\n",
	                  dbg_seq, dbg_status, jiffies);
	return simple_read_from_buffer(buf, len, ppos, tmp, n);
}

static const struct file_operations stats_fops = {
	.owner = THIS_MODULE,
	.read  = stats_read,
	.llseek = default_llseek,
};

static ssize_t distances_read(struct file *f, char __user *buf, size_t len, loff_t *ppos)
{
	char tmp[256];
	int n = scnprintf(tmp, sizeof(tmp), "%.3f,%.3f,%.3f,%.3f,%.3f\n",
	                  dbg_dist[0], dbg_dist[1], dbg_dist[2], dbg_dist[3], dbg_dist[4]);
	return simple_read_from_buffer(buf, len, ppos, tmp, n);
}

static const struct file_operations distances_fops = {
	.owner = THIS_MODULE,
	.read  = distances_read,
	.llseek = default_llseek,
};

static struct timer_list demo_timer;

static void demo_timer_fn(struct timer_list *t)
{
	/* update dummy distances with a simple waveform */
	unsigned long j = jiffies;
	dbg_seq++;
	for (int i=0;i<5;i++){
		dbg_dist[i] = 0.5f + 0.5f * ((j >> i) & 1); /* toggles 0.5 / 1.0 */
	}
	mod_timer(&demo_timer, jiffies + HZ/10);
}

static int __init ranger_k_init(void)
{
	dbg_dir = debugfs_create_dir(DRV_NAME, NULL);
	if (!dbg_dir){
		pr_err(DRV_NAME ": debugfs_create_dir failed\n");
		return -ENOMEM;
	}
	debugfs_create_file("stats", 0444, dbg_dir, NULL, &stats_fops);
	debugfs_create_file("distances", 0444, dbg_dir, NULL, &distances_fops);

	timer_setup(&demo_timer, demo_timer_fn, 0);
	mod_timer(&demo_timer, jiffies + HZ/10);

	pr_info(DRV_NAME ": loaded (skeleton)\n");
	return 0;
}

static void __exit ranger_k_exit(void)
{
	del_timer_sync(&demo_timer);
	debugfs_remove_recursive(dbg_dir);
	pr_info(DRV_NAME ": unloaded\n");
}

module_init(ranger_k_init);
module_exit(ranger_k_exit);

MODULE_LICENSE("MIT");
MODULE_AUTHOR("rpi5-ultrasonic demo");
MODULE_DESCRIPTION("Ultrasonic ranger kernel skeleton (debugfs)");

KC

############################################
# ranger-k/README.md
############################################
cat > ranger-k/README.md <<'MD'
# ranger-k (kernel skeleton)

Minimal out-of-tree module that exposes debugfs files:
- `/sys/kernel/debug/ranger_k/stats`
- `/sys/kernel/debug/ranger_k/distances`

> NOTE: this is a **skeleton** — GPIO/IRQ logic is not implemented yet.

## Build & run

```bash
cd ranger-k
make
sudo insmod ranger_k.ko
sudo ls /sys/kernel/debug/ranger_k
cat /sys/kernel/debug/ranger_k/stats
cat /sys/kernel/debug/ranger_k/distances
sudo rmmod ranger_k
```

If `debugfs` is not mounted:
```bash
sudo mount -t debugfs none /sys/kernel/debug
```
MD

############################################
# ranger-k-test (userspace reader of debugfs)
############################################
cat > ranger-k-test/README.md <<'MD'
# ranger-k-test

Tiny userspace helper that reads debugfs files exposed by `ranger_k` and prints them.
MD

cat > ranger-k-test/CMakeLists.txt <<'CMAKE'
cmake_minimum_required(VERSION 3.13)
project(ranger-k-test LANGUAGES C)
add_executable(ranger-k-test main.c)
CMAKE

cat > ranger-k-test/main.c <<'C'
#include <stdio.h>
#include <stdlib.h>

int main(void){
  FILE* f = fopen("/sys/kernel/debug/ranger_k/distances", "r");
  if (!f){ perror("open distances"); return 1; }
  char buf[256] = {0};
  if (fgets(buf, sizeof(buf), f)){
    printf("distances: %s", buf);
  }
  fclose(f);
  f = fopen("/sys/kernel/debug/ranger_k/stats", "r");
  if (f && fgets(buf, sizeof(buf), f)){
    printf("stats: %s", buf);
    fclose(f);
  }
  return 0;
}
C

############################################
# scripts/demo_isotp.sh (bridge demo)
############################################
cat > scripts/demo_isotp.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Demo: pipe ranger-u JSONL into ranger-can ISO-TP over vcan0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IFACE="${IFACE:-vcan0}"
TXID="${TXID:-0x701}"
RXID="${RXID:-0x700}"
DUR="${DUR_SEC:-10}"

# ensure vcan + isotp exist
sudo modprobe vcan can-isotp || true
ip link show "$IFACE" >/dev/null 2>&1 || { sudo ip link add dev "$IFACE" type vcan; sudo ip link set up "$IFACE"; }

# build tools
cmake -S "$ROOT" -B "$ROOT/build"
cmake --build "$ROOT/build" --target ranger-can ranger-u -- -j

# start receiver for demo
(isotprecv -s "$RXID" -d "$TXID" "$IFACE" | hexdump -C & echo $! > /tmp/isotprx.pid) || true
sleep 0.2

# run generator + ranger-u + pipe to ranger-can
sudo "$ROOT/scripts/pulse_gen_multi.sh" "0:1.0,1:1.6,2:0.8,3:2.2,4:0.35" & GEN_PID=$!
trap 'kill $GEN_PID 2>/dev/null || true; [ -f /tmp/isotprx.pid ] && kill $(cat /tmp/isotprx.pid) 2>/dev/null || true' EXIT

"$ROOT/build/ranger-u/ranger-u" \
  --chip /dev/$(gpiodetect | awk "/gpio-sim/ {print \$1}" | head -n1) \
  --lines 0,1,2,3,4 \
  --duration "$DUR" \
  --rate-hz 20 \
  --jsonl /proc/self/fd/1 --csv /dev/null \
| "$ROOT/build/ranger-can/ranger-can" --if "$IFACE" --tx "$TXID" --rx "$RXID" --rate-hz 20 --verbose

SH
chmod +x scripts/demo_isotp.sh

echo "[+] Done. Next steps:"
echo "    - Build ranger-can:    cmake -S . -B build && cmake --build build --target ranger-can"
echo "    - Kernel module:       cd ranger-k && make && sudo insmod ranger_k.ko"
echo "    - ISO-TP demo:         ./scripts/demo_isotp.sh  (watch isotprecv output)"
