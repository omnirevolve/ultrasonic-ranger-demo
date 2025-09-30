# ranger-k (IRQ/timestamp MVP)

This module subscribes to GPIO IRQs for 5 ECHO lines, timestamps rising/falling edges,
and exposes distances via debugfs:
- `/sys/kernel/debug/ranger_k/distances`  (CSV: d0..d4 in meters)

> NOTE: Uses **legacy GPIO numbers** for simplicity in PC emulation with `gpio-sim`.
> On RPi5 we will switch to GPIO descriptor lookup via Device Tree.

## Finding legacy GPIO numbers for gpio-sim

```bash
sudo cat /sys/kernel/debug/gpio
# Look for a gpiochip backing gpio-sim (label will reference gpio-sim). Note the base number.
# Legacy number = base + line_offset
# Example: base=768  -> line0=768, line1=769, ...
```

Alternatively, if your kernel exposes base via sysfs:
```bash
grep -R . /sys/class/gpio/ | head
```

## Build & Run

```bash
cd ranger-k
make
# Example: if gpio-sim base=768, pass 5 lines:
sudo insmod ranger_k.ko line_gpios=768,769,770,771,772

# See distances (update as pulses arrive):
sudo cat /sys/kernel/debug/ranger_k/distances

# Unload:
sudo rmmod ranger_k
```

If `debugfs` is not mounted:
```bash
sudo mount -t debugfs none /sys/kernel/debug
```
