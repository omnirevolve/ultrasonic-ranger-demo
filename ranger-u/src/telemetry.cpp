#include "telemetry.hpp"
#include <sstream>

std::string to_json(const TelemetryFrame& tf){
  std::ostringstream os;
  os << "{";
  os << "\"d\":[";
  for (size_t i=0;i<tf.dist_m.size();++i){
    if (i) os << ",";
    os << tf.dist_m[i];
  }
  os << "]}";
  return os.str();
}
