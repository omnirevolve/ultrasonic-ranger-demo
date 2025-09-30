cmake_minimum_required(VERSION 3.13)
project(ranger-can LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(ranger-can
  src/ranger_can.cpp
)
target_include_directories(ranger-can PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
# socketcan is in glibc; just need headers. link to rt if needed.
# Some distros require linking with -lpthread for std::thread (if later used).
target_link_libraries(ranger-can PRIVATE)

install(TARGETS ranger-can RUNTIME DESTINATION bin)
