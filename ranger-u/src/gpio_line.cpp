#include "gpio_line.hpp"
#include <stdexcept>
#include <fcntl.h>
#include <cerrno>

GpioLine::GpioLine(const GpioLineCfg& cfg) {
  chip_ = gpiod_chip_open(cfg.chip.c_str());
  if (!chip_) throw std::runtime_error("gpiod_chip_open failed");

  line_ = gpiod_chip_get_line(chip_, cfg.line);
  if (!line_) throw std::runtime_error("gpiod_chip_get_line failed");

  int rc = -1;
  if (cfg.edge_rising && cfg.edge_falling) {
    rc = gpiod_line_request_both_edges_events(line_, cfg.consumer.c_str());
  } else if (cfg.edge_rising) {
    rc = gpiod_line_request_rising_edge_events(line_, cfg.consumer.c_str());
  } else {
    rc = gpiod_line_request_falling_edge_events(line_, cfg.consumer.c_str());
  }
  if (rc < 0) throw std::runtime_error("gpiod_line_request_*_events failed");

  evfd_ = gpiod_line_event_get_fd(line_);
  if (evfd_ < 0) throw std::runtime_error("gpiod_line_event_get_fd failed");

  // make non-blocking so we can drain after epoll without hangs
  int flags = fcntl(evfd_, F_GETFL, 0);
  if (flags >= 0) (void)fcntl(evfd_, F_SETFL, flags | O_NONBLOCK);
}

GpioLine::~GpioLine() {
  if (line_) gpiod_line_release(line_);
  if (chip_) gpiod_chip_close(chip_);
}

int GpioLine::fd() const { return evfd_; }

std::optional<gpiod_line_event> GpioLine::read_event() {
  gpiod_line_event ev{};
  int r = gpiod_line_event_read_fd(evfd_, &ev);
  if (r == 0) {
    // success (libgpiod v1 returns 0 on success for *_read_fd)
    return ev;
  }
  if (r < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      return std::nullopt; // no more events
    }
    throw std::runtime_error("gpiod_line_event_read_fd failed");
  }
  return std::nullopt;
}
