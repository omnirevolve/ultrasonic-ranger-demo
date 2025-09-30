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
#include <array>

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
