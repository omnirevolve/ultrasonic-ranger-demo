#include "gpio_line.hpp"
#include "pulse_measure.hpp"
#include "filter_median.hpp"
#include "telemetry.hpp"

#include <sys/epoll.h>
#include <memory>
#include <iostream>
#include <fstream>
#include <sstream>
#include <csignal>

struct SensorCtx {
  std::unique_ptr<GpioLine> gl;
  PulseTracker tracker;
  MedianFilter mf;
  explicit SensorCtx(const GpioLineCfg& cfg)
      : gl(std::make_unique<GpioLine>(cfg)), tracker(343.0), mf(5) {} // window=5
  SensorCtx(const SensorCtx&) = delete;
  SensorCtx& operator=(const SensorCtx&) = delete;
};

static volatile std::sig_atomic_t g_stop = 0;
static void on_sigint(int){ g_stop = 1; }

// v1 event -> our EdgeStamp
static EdgeStamp edge_from(const gpiod_line_event& ev){
  Edge e = (ev.event_type == GPIOD_LINE_EVENT_RISING_EDGE) ? Edge::Rising : Edge::Falling;
  timespec ts = ev.ts;
  auto ns = std::chrono::seconds(ts.tv_sec) + std::chrono::nanoseconds(ts.tv_nsec);
  return EdgeStamp{e, std::chrono::duration_cast<std::chrono::nanoseconds>(ns)};
}

static std::vector<unsigned> parse_lines(const std::string& s){
  std::vector<unsigned> v; std::stringstream ss(s); std::string tok;
  while (std::getline(ss, tok, ',')) v.push_back(static_cast<unsigned>(std::stoul(tok)));
  return v;
}

struct Args {
  std::string chip = "/dev/gpiochip1";
  std::vector<unsigned> lines = {0,1,2,3,4};
  int duration_sec = 0;           // 0 = run forever
  std::string jsonl_path;         // empty = stdout only
  std::string csv_path;           // optional
  double rate_hz = 10.0;          // periodic print rate
};

static Args parse_args(int argc, char** argv){
  Args a;
  for (int i=1;i<argc;i++){
    std::string k = argv[i];
    auto need = [&](const char* name){ if (i+1>=argc) { std::cerr<<"Missing value for "<<name<<"\n"; std::exit(2);} return std::string(argv[++i]); };
    if (k=="--chip") a.chip = need("--chip");
    else if (k=="--lines") a.lines = parse_lines(need("--lines"));
    else if (k=="--duration") a.duration_sec = std::stoi(need("--duration"));
    else if (k=="--jsonl") a.jsonl_path = need("--jsonl");
    else if (k=="--csv") a.csv_path = need("--csv");
    else if (k=="--rate-hz") a.rate_hz = std::stod(need("--rate-hz"));
    else if (k=="-h" || k=="--help"){
      std::cout <<
      "Usage: ranger-u [--chip /dev/gpiochipN] [--lines 0,1,...] [--duration SEC]\n"
      "                [--jsonl out.jsonl] [--csv out.csv] [--rate-hz N]\n";
      std::exit(0);
    }
  }
  return a;
}

int main(int argc, char** argv){
  std::signal(SIGINT, on_sigint);
  auto args = parse_args(argc, argv);

  // Build sensor set
  std::vector<std::unique_ptr<SensorCtx>> sensors;
  sensors.reserve(args.lines.size());

  int epfd = epoll_create1(0);
  if (epfd < 0){ perror("epoll_create1"); return 1; }

  for (size_t i=0;i<args.lines.size();++i){
    GpioLineCfg cfg{ args.chip, args.lines[i], true, true, "ranger-u" };
    sensors.emplace_back(std::make_unique<SensorCtx>(cfg));
    int fd = sensors.back()->gl->fd();
    epoll_event ev{}; ev.events = EPOLLIN; ev.data.fd = fd;
    if (epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev) < 0){ perror("epoll_ctl"); return 1; }
  }

  // Outputs
  std::ofstream jsonl_file, csv_file;
  if (!args.jsonl_path.empty()) jsonl_file.open(args.jsonl_path, std::ios::out | std::ios::trunc);
  if (!args.csv_path.empty()){
    csv_file.open(args.csv_path, std::ios::out | std::ios::trunc);
    csv_file << "ts_ns";
    for (size_t i=0;i<args.lines.size();++i) csv_file << ",d" << i;
    csv_file << "\n";
  }

  TelemetryFrame tf{}; // meters
  auto t0 = std::chrono::steady_clock::now();
  auto next_print = t0;
  using SteadyDur = std::chrono::steady_clock::duration;
  auto print_interval = std::chrono::duration_cast<SteadyDur>(std::chrono::duration<double>(1.0 / args.rate_hz));

  while(!g_stop){
    if (args.duration_sec > 0){
      auto now = std::chrono::steady_clock::now();
      if (std::chrono::duration_cast<std::chrono::seconds>(now - t0).count() >= args.duration_sec) break;
    }

    epoll_event events[16];
    int n = epoll_wait(epfd, events, 16, 10);
    if (n < 0){
      if (errno==EINTR) continue;
      perror("epoll_wait"); break;
    }

    // Drain events from ALL sensors (non-blocking read)
    for (size_t idx = 0; idx < sensors.size(); ++idx){
      while (true){
        auto evopt = sensors[idx]->gl->read_event();
        if (!evopt) break;
        EdgeStamp es = edge_from(*evopt);
        if (auto p = sensors[idx]->tracker.on_edge(es)){
          if (auto m = sensors[idx]->mf.push(p->distance_m)){
            tf.dist_m[idx] = static_cast<float>(*m);
          }
        }
      }
    }

    auto now = std::chrono::steady_clock::now();
    if (now >= next_print){
      auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(now - t0).count();

      std::string j = to_json(tf);
      if (jsonl_file.is_open()){
        jsonl_file << "{\"ts_ns\":" << ns << ",\"data\":" << j << "}\n";
      } else {
        std::cout << j << "\n";
        std::cout.flush();
      }

      if (csv_file.is_open()){
        csv_file << ns;
        for (size_t i=0;i<sensors.size();++i) csv_file << "," << tf.dist_m[i];
        csv_file << "\n";
      }

      next_print += print_interval;
    }
  }
  return 0;
}
