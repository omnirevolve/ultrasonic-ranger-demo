#pragma once
#include <gpiod.h>
#include <string>
#include <optional>

struct GpioLineCfg {
  std::string chip;   // e.g. "/dev/gpiochip1"
  unsigned line;      // e.g. 0..n
  bool edge_rising = true;
  bool edge_falling = true;
  std::string consumer = "ranger-u";
};

class GpioLine {
public:
  explicit GpioLine(const GpioLineCfg& cfg);
  ~GpioLine();

  GpioLine(const GpioLine&) = delete;
  GpioLine& operator=(const GpioLine&) = delete;
  GpioLine(GpioLine&&) = delete;
  GpioLine& operator=(GpioLine&&) = delete;

  // event FD (for epoll)
  int fd() const;

  // non-blocking read; returns event or std::nullopt if no events
  std::optional<gpiod_line_event> read_event();

private:
  gpiod_chip* chip_{};
  gpiod_line* line_{};
  int evfd_{-1};
};
