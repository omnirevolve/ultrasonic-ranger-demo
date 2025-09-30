#pragma once
#include <cstdint>
#include <optional>
#include <chrono>

enum class Edge { Rising, Falling };

struct EdgeStamp {
  Edge edge;
  std::chrono::nanoseconds ts;
};

struct Pulse {
  std::chrono::nanoseconds width;
  double distance_m; // computed distance
};

class PulseTracker {
public:
  explicit PulseTracker(double sound_speed = 343.0); // m/s
  std::optional<Pulse> on_edge(const EdgeStamp& es);
private:
  std::optional<std::chrono::nanoseconds> t_rise_{};
  double c_;
};
