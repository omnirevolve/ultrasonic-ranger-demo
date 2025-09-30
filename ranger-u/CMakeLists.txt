cmake_minimum_required(VERSION 3.16)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GPIOD REQUIRED libgpiod)

add_executable(ranger-u
  src/main.cpp
  src/gpio_line.cpp
  src/pulse_measure.cpp
  src/filter_median.cpp
  src/telemetry.cpp)

target_include_directories(ranger-u PRIVATE include ${GPIOD_INCLUDE_DIRS})
target_link_libraries(ranger-u PRIVATE ${GPIOD_LIBRARIES})

# perf-friendly symbols
add_compile_options(-O2 -g)
