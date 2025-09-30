#pragma once
#include <deque>
#include <algorithm>
#include <optional>
#include <vector>

class MedianFilter {
public:
  explicit MedianFilter(size_t win=5):win_(win){}
  std::optional<double> push(double v){
    buf_.push_back(v);
    if (buf_.size() > win_) buf_.pop_front();
    if (buf_.size() < win_) return std::nullopt;
    std::vector<double> tmp(buf_.begin(), buf_.end());
    std::sort(tmp.begin(), tmp.end());
    return tmp[tmp.size()/2];
  }
private:
  size_t win_;
  std::deque<double> buf_;
};
