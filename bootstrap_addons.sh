#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
echo "[+] Adding tools/isotp_rx (SocketCAN ISO-TP receiver) and tools/plotting helpers..."

mkdir -p tools/isotp_rx/src tools/isotp_rx/include tools

cat > tools/isotp_rx/CMakeLists.txt <<'CMAKE'
cmake_minimum_required(VERSION 3.13)
project(isotp_rx LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_executable(isotp_rx src/isotp_rx.cpp)
target_include_directories(isotp_rx PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
CMAKE

cat > tools/isotp_rx/src/isotp_rx.cpp <<'CPP'
#include <sys/types.h>
#include <sys/socket.h>
#include <linux/can.h>
#include <linux/can/isotp.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <iostream>

#pragma pack(push,1)
struct RangerMsg {
  uint32_t seq;
  float dist_m[5];
  uint32_t status;
};
#pragma pack(pop)

static int open_isotp(const std::string& ifname, uint32_t tx_id, uint32_t rx_id){
  int s = socket(PF_CAN, SOCK_DGRAM, CAN_ISOTP);
  if (s < 0) { perror("socket CAN_ISOTP"); return -1; }
  struct ifreq ifr{};
  std::snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", ifname.c_str());
  if (ioctl(s, SIOCGIFINDEX, &ifr) < 0){
    perror("ioctl SIOCGIFINDEX"); close(s); return -1;
  }
  struct sockaddr_can addr{};
  addr.can_family = AF_CAN;
  addr.can_ifindex = ifr.ifr_ifindex;
  addr.can_addr.tp.tx_id = tx_id;
  addr.can_addr.tp.rx_id = rx_id;
  if (bind(s, (struct sockaddr*)&addr, sizeof(addr)) < 0){
    perror("bind isotp"); close(s); return -1;
  }
  return s;
}

int main(int argc, char** argv){
  std::string ifname = (argc>1)? argv[1] : "vcan0";
  uint32_t tx = (argc>2)? std::strtoul(argv[2], nullptr, 0) : 0x700;
  uint32_t rx = (argc>3)? std::strtoul(argv[3], nullptr, 0) : 0x701;
  int s = open_isotp(ifname, tx, rx);
  if (s < 0) return 1;

  RangerMsg msg{};
  while (true){
    ssize_t n = recv(s, &msg, sizeof(msg), 0);
    if (n < 0){ perror("recv"); break; }
    if (n == (ssize_t)sizeof(msg)){
      std::cout << "seq=" << msg.seq
                << " d=[" << msg.dist_m[0] << "," << msg.dist_m[1] << ","
                << msg.dist_m[2] << "," << msg.dist_m[3] << "," << msg.dist_m[4]
                << "] status=0x" << std::hex << msg.status << std::dec << "\n";
    } else {
      std::cerr << "[warn] short frame: " << n << " bytes\n";
    }
  }
  close(s);
  return 0;
}
CPP

# Lightweight gnuplot helper for CSV from ranger-u
mkdir -p tools/plot
cat > tools/plot/plot_distances.gp <<'GP'
# Usage: gnuplot -persist -e "csv='data.csv'" tools/plot/plot_distances.gp
set datafile separator ","
if (!exists("csv")) csv="data.csv"
set key left top
set xlabel "sample"
set ylabel "distance (m)"
plot csv using 0:2 with lines title "d0", \
     csv using 0:3 with lines title "d1", \
     csv using 0:4 with lines title "d2", \
     csv using 0:5 with lines title "d3", \
     csv using 0:6 with lines title "d4"
GP

echo "[+] Done. Build receiver with:"
echo "    cmake -S tools/isotp_rx -B build/isotp_rx && cmake --build build/isotp_rx -- -j"
echo "[+] Run receiver (in another terminal) after demo_isotp.sh starts:"
echo "    ./build/isotp_rx/isotp_rx vcan0 0x700 0x701"
