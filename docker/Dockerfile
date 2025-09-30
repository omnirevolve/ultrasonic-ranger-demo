FROM debian:12
RUN apt-get update && apt-get install -y \
    build-essential cmake ninja-build pkg-config \
    libgpiod-dev can-utils trace-cmd linux-perf gnuplot \
    git gdb vim && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
