#include "pulse_measure.hpp"

PulseTracker::PulseTracker(double sound_speed) : c_(sound_speed) {}

std::optional<Pulse> PulseTracker::on_edge(const EdgeStamp& es){
  if (es.edge == Edge::Rising){
    t_rise_ = es.ts;
    return std::nullopt;
  }
  if (es.edge == Edge::Falling && t_rise_){
    auto w = es.ts - *t_rise_;
    t_rise_.reset();
    // HC-SR04: pulse width equals round-trip time of sound
    double t_s = w.count() * 1e-9;
    double dist = (c_ * t_s) / 2.0; // meters
    return Pulse{w, dist};
  }
  return std::nullopt;
}
