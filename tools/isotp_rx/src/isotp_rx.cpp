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
