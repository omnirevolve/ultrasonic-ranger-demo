#pragma once
#include <array>
#include <cstdint>
#include <string>

// Minimal format for ISO-TP: 5 float32 (meters)
struct TelemetryFrame {
  std::array<float,5> dist_m;
};

std::string to_json(const TelemetryFrame& tf);
