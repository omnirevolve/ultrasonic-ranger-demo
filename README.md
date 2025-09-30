# Ultrasonic Ranger — PC Simulation + RPi5-ready

End-to-end demo: echo pulse → IRQ timestamp in kernel → distance export via `debugfs` → live TUI + simple decision logic.  
Runs fully on a developer PC using the upstream `gpio-sim` driver and is ready to be pointed at real GPIO on Raspberry Pi 5 later.

> Status: **demo** (PC simulation works); **RPi5 hookup next**.

---

## Repository layout

```
ranger-k/         # Kernel module: IRQ timestamps, /sys/kernel/debug/ranger_k/*
ranger-u/         # Userspace ranger (C++), optional
ranger-can/       # Minimal CAN/ISOTP sample (buildable)
ranger-k-test/    # Tiny userspace test for debugfs
tools/            # TUI visualizer, plotting, profiling helpers
scripts/          # Setup, pulse generator, demo wrappers
docker/           # Optional dev container (not required)
build/            # CMake build tree (generated)
```

Main data endpoints (from the kernel module):
- `/sys/kernel/debug/ranger_k/distances` — CSV, **meters** (5 values): `m.mmm,m.mmm,...`
- `/sys/kernel/debug/ranger_k/stats` — `seq=<n> pulses=a,b,c,d,e overruns=a,b,c,d,e`

---

## Quick start (PC simulation)

Requirements (Ubuntu 22.04/24.04 expected):
- Kernel headers (`linux-headers-$(uname -r)`)
- Build tools: `build-essential cmake`
- Python 3 with `curses` (usually present)
- Root access to load modules and write to `debugfs`

### 1) Enable gpio-sim and create a mock chip

```bash
sudo ./scripts/setup_sim.sh
```

This creates a `gpio-sim` device like:

```
/sys/class/gpio/gpiochip768   # label=gpio-sim.0-node0, ngpio=8 (base may differ)
```

### 2) Build + load the kernel module

```bash
cd ranger-k
./reload_k.sh
```

This compiles `ranger_k.ko` and loads it with five input lines mapped to
`gpio-sim` legacy numbers (e.g., 768..772). You should see in `dmesg`:

```
ranger_k: line[0]=GPIO768 -> irq 142 OK
...
ranger_k: loaded (threaded IRQ MVP)
```

### 3) Start the echo pulse generator

Run **as root** (it toggles `gpio-sim` sysfs):

```bash
sudo ./scripts/pulse_gen_multi.sh "0:1.0,1:1.6,2:0.8,3:2.2,4:0.35"
```

- Format: `"line:distance_m,..."`
- Uses 80 ms frames and emits one echo pulse per line each frame.
- Set `DEBUG=1` to log what is being pulsed.

### 4) Watch the values (sanity check)

```bash
watch -n 0.3 'sudo cat /sys/kernel/debug/ranger_k/stats; sudo cat /sys/kernel/debug/ranger_k/distances'
```

You should see `seq` and `pulses` increasing and non-zero distances.

### 5) Live TUI (decision + visualization)

Run with sudo (reading `debugfs` may require root depending on your system):

```bash
sudo python3 ./tools/demo_decider_viz.py --sysfs /sys/kernel/debug/ranger_k/distances
```

Controls:
- `q` — quit
- `r` — reload file
- `+ / -` — poll rate
- `space` — clear last error

The TUI shows the latest 5 distances and a simple decision string (e.g. `FORWARD`, `LEFT`, `STOP`). The decision rule is intentionally simple and kept in the Python for clarity.

---

## Raspberry Pi 5 notes (preview)

On RPi5 we will:
- Replace legacy numbers with proper descriptor lookup from Device Tree (`gpiod_get*`).
- Keep the same ISR math and `debugfs` layout so userland and TUI remain unchanged.
- Optionally move from `debugfs` to a character device if needed.

---

## Troubleshooting

**Module fails to insert (“File exists”)**
- A previous instance is still loaded. Run:
  ```bash
  sudo rmmod ranger_k || true
  sudo lsmod | grep ranger_k  # should be empty
  ./ranger-k/reload_k.sh
  ```

**No pulses / distances stay 0**
- Ensure the generator is running as root:
  ```bash
  sudo ./scripts/pulse_gen_multi.sh "0:1.0,1:1.6,2:0.8,3:2.2,4:0.35"
  ```
- Check that `gpio-sim` chip exists and the base matches what `reload_k.sh` prints.
- Confirm IRQ counters for the assigned IRQs increase:
  ```bash
  awk 'NR==1 || $1 ~ /^(142|143|144|145|146):/' /proc/interrupts
  ```

**TUI shows “Permission denied”**
- Run the TUI with `sudo`, or adjust file modes (not recommended for debugfs).

**gpiomon says “Device or resource busy”**
- That’s expected: the kernel module has already requested the IRQs.

---

## Design overview

- **Kernel (`ranger-k/`)**
  - Request 5 GPIO lines by legacy number (PC sim) or DT (RPi5 later).
  - Convert GPIO → IRQ, subscribe to both edges with a **threaded ISR**.
  - Rising edge timestamps start; falling edge timestamps stop → width (ns).
  - Convert width → distance (µm), publish last values via `debugfs`.

- **Userland**
  - **Pulse generator**: toggles `gpio-sim` line pulls to simulate echo widths derived from distances (d → t = 2d/c).
  - **TUI**: reads CSV, renders values, runs simple “decider” rule for clarity in demos.

---

## Build notes

### CMake targets (optional)
Top-level CMake builds `ranger-u`, `ranger-can`, and ISOTP demo tools:

```bash
mkdir -p build && cd build
cmake ..
make -j
```

The kernel module is built separately under `ranger-k/` via its `Makefile` or `reload_k.sh`.

---

## Roadmap

- RPi5 device-tree based GPIO descriptors
- Real cart (“nose” with 5 ultrasonic sensors)
- CAN publishing of distances/decisions
- Packaging the TUI as a standalone tool
- Optional char device instead of debugfs

---

## License

- Kernel module and userspace code: **GPLv2** where applicable for kernel code, and MIT/Apache-2.0 for userspace (see headers).  
  This demo currently marks the kernel module `MODULE_LICENSE("GPL")`.

---

## Acknowledgments

- Linux kernel `gpio-sim` and `isotp` protocol
- The broader Linux GPIO and CAN communities

---

## Contact

For collaboration and recruiting context (Rivian / OneSec):  
- Prepared by: **OmniRevolve** (suggested org for hosting)
- Tech focus: sensing, kernel-space timing, simple perception → decision loop
