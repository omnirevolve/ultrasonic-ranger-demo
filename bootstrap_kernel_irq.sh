#!/usr/bin/env bash
set -euo pipefail

echo "[+] Upgrading ranger-k to IRQ/timestamp MVP and adding profiling helpers..."

mkdir -p ranger-k tools/profile

############################################
# ranger-k/ranger_k.c (IRQ + timestamps MVP)
############################################
cat > ranger-k/ranger_k.c <<'KC'
// SPDX-License-Identifier: MIT
/*
 * ranger_k - IRQ/timestamp MVP
 * - Request GPIO lines by legacy GPIO numbers (module param line_gpios=...).
 * - Convert to IRQs, subscribe to both edges.
 * - ISR timestamps rising/falling, computes pulse width (ns) -> distance (m).
 * - Export distances via debugfs: /sys/kernel/debug/ranger_k/distances
 *
 * NOTE:
 * - Requires legacy GPIO numbers to be enabled in the kernel and available for gpio-sim.
 * - Use `sudo cat /sys/kernel/debug/gpio` to see ranges and pick numbers for gpio-sim lines.
 * - On Raspberry Pi 5 we will switch to descriptor-based lookup via DT (gpiod_get*).
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/gpio.h>           // legacy numbering helpers
#include <linux/gpio/consumer.h>  // for gpio_to_desc(), gpiod_to_irq()
#include <linux/ktime.h>
#include <linux/spinlock.h>
#include <linux/debugfs.h>
#include <linux/uaccess.h>
#include <linux/slab.h>

#define DRV_NAME "ranger_k"
#define MAX_SENSORS 5

static int line_gpios[MAX_SENSORS] = { -1, -1, -1, -1, -1 };
module_param_array(line_gpios, int, NULL, 0444);
MODULE_PARM_DESC(line_gpios, "Legacy GPIO numbers for ECHO lines (5 items)");

struct sensor_state {
	/* state machine: remember last rising ts */
	bool have_rise;
	ktime_t rise_ts;
	/* last computed distance (meters) */
	u32 dist_qmm; /* fixed-point: millimeters*1000 -> store as micrometers to avoid float in kernel */
	/* stats */
	u32 pulses;
	u32 overruns;
	int irq;
	struct gpio_desc *gdesc;
};

static struct {
	struct dentry *dbg_dir;
	struct dentry *dbg_stats;
	struct dentry *dbg_dist;
	spinlock_t lock; /* protects sensors[] updates */
	struct sensor_state s[MAX_SENSORS];
	u32 seq;
} g;

static inline u32 to_qmm_from_ns(s64 width_ns)
{
	/* HC-SR04: distance = (c * t) / 2
	 * c = 343.0 m/s -> 0.343 mm/us -> 0.000343 mm/ns
	 * distance_mm = 0.000343 * width_ns / 2 = 0.0001715 * width_ns
	 * We'll compute micrometers (um) to keep integers: 1 mm = 1000 um
	 * distance_um = 171.5 * width_ns / 1000  -> ~171 * ns / 1000 (approx)
	 * Use fixed-point: dist_qmm = distance_um (um).
	 */
	/* To keep it simple: dist_um = (343000.0 * width_ns) / (2*1e9) mm -> but stay integer: */
	/* dist_um = width_ns * 171500 / 1000000 */
	return (u32)div64_u64((u64)width_ns * 171500ULL, 1000000ULL);
}

static irqreturn_t echo_isr(int irq, void *dev_id)
{
	int idx = (long)dev_id;
	ktime_t now = ktime_get();
	unsigned long flags;
	struct sensor_state *s = &g.s[idx];

	/* Read level to classify edge (cheap but ok for demo) */
	int level = gpiod_get_value(s->gdesc);

	spin_lock_irqsave(&g.lock, flags);
	if (level) {
		/* rising */
		s->have_rise = true;
		s->rise_ts = now;
	} else {
		/* falling */
		if (s->have_rise) {
			s64 dt = ktime_to_ns(ktime_sub(now, s->rise_ts));
			s->have_rise = false;
			s->pulses++;
			s->dist_qmm = to_qmm_from_ns(dt);
		} else {
			s->overruns++;
		}
	}
	g.seq++;
	spin_unlock_irqrestore(&g.lock, flags);
	return IRQ_HANDLED;
}

static ssize_t distances_read(struct file *f, char __user *buf, size_t len, loff_t *ppos)
{
	char tmp[256];
	unsigned long flags;
	u32 um[MAX_SENSORS];
	int n;

	spin_lock_irqsave(&g.lock, flags);
	for (int i=0;i<MAX_SENSORS;i++) um[i] = g.s[i].dist_qmm;
	spin_unlock_irqrestore(&g.lock, flags);

	/* Print as meters with 3 decimals: (um / 1e6) */
	n = scnprintf(tmp, sizeof(tmp), "%.3f,%.3f,%.3f,%.3f,%.3f\n",
		um[0]/1000000.0, um[1]/1000000.0, um[2]/1000000.0, um[3]/1000000.0, um[4]/1000000.0);
	return simple_read_from_buffer(buf, len, ppos, tmp, n);
}

static const struct file_operations distances_fops = {
	.owner = THIS_MODULE,
	.read  = distances_read,
	.llseek = default_llseek,
};

static int __init ranger_k_init(void)
{
	int ret = 0;

	spin_lock_init(&g.lock);
	g.dbg_dir = debugfs_create_dir(DRV_NAME, NULL);
	if (!g.dbg_dir) return -ENOMEM;
	debugfs_create_file("distances", 0444, g.dbg_dir, NULL, &distances_fops);

	for (int i=0;i<MAX_SENSORS;i++){
		int gpio = line_gpios[i];
		if (gpio < 0) continue; /* unused line */

		g.g.s[i].gdesc = gpio_to_desc(gpio);
		if (!g.g.s[i].gdesc){
			pr_err(DRV_NAME ": gpio_to_desc(%d) failed\n", gpio);
			ret = -EINVAL; goto fail;
		}
		/* Ensure as input */
		ret = gpiod_direction_input(g.g.s[i].gdesc);
		if (ret){
			pr_err(DRV_NAME ": gpiod_direction_input(%d) failed\n", gpio);
			goto fail;
		}
		/* Map to IRQ */
		g.g.s[i].irq = gpiod_to_irq(g.g.s[i].gdesc);
		if (g.g.s[i].irq < 0){
			pr_err(DRV_NAME ": gpiod_to_irq(%d) failed\n", gpio);
			ret = g.g.s[i].irq; goto fail;
		}
		/* Request both edges */
		ret = request_irq(g.g.s[i].irq, echo_isr,
		                  IRQF_TRIGGER_RISING | IRQF_TRIGGER_FALLING,
		                  DRV_NAME, (void*)(long)i);
		if (ret){
			pr_err(DRV_NAME ": request_irq(line %d -> irq %d) failed: %d\n", gpio, g.g.s[i].irq, ret);
			goto fail;
		}
		pr_info(DRV_NAME ": line[%d]=GPIO%d -> irq %d OK\n", i, gpio, g.g.s[i].irq);
	}
	pr_info(DRV_NAME ": loaded (IRQ MVP)\n");
	return 0;

fail:
	for (int i=0;i<MAX_SENSORS;i++){
		if (g.g.s[i].irq > 0) free_irq(g.g.s[i].irq, (void*)(long)i);
	}
	debugfs_remove_recursive(g.dbg_dir);
	return ret;
}

static void __exit ranger_k_exit(void)
{
	for (int i=0;i<MAX_SENSORS;i++){
		if (g.g.s[i].irq > 0) free_irq(g.g.s[i].irq, (void*)(long)i);
	}
	debugfs_remove_recursive(g.dbg_dir);
	pr_info(DRV_NAME ": unloaded\n");
}

module_init(ranger_k_init);
module_exit(ranger_k_exit);

MODULE_LICENSE("MIT");
MODULE_AUTHOR("rpi5-ultrasonic demo");
MODULE_DESCRIPTION("Ultrasonic ranger kernel IRQ/timestamp MVP");
KC

############################################
# ranger-k/README.md (update with how-to find GPIO numbers)
############################################
cat > ranger-k/README.md <<'MD'
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
MD

############################################
# Profiling helpers (perf / trace-cmd)
############################################
cat > tools/profile/perf_record.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Record perf for the user-space measurer (ranger-u).
DUR="${1:-10}"
BIN="${BIN:-./build/ranger-u/ranger-u}"
CHIP="${CHIP:-/dev/gpiochip1}"
LINES="${LINES:-0,1,2,3,4}"
PERF_OPTS="${PERF_OPTS:--F 999 -g}"

sudo perf record $PERF_OPTS -- \
  "$BIN" --chip "$CHIP" --lines "$LINES" --duration "$DUR" --rate-hz 20 --jsonl /dev/null --csv /dev/null
echo "[+] perf.data saved. View with: perf report"
SH
chmod +x tools/profile/perf_record.sh

cat > tools/profile/trace_irq.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Trace IRQ and scheduling for ranger_k.
DUR="${1:-5}"
EVENTS="${EVENTS:-irq:*,sched:*}"

sudo trace-cmd record -e "$EVENTS" -d "${DUR}s"
echo "[+] trace.dat saved. View with: trace-cmd report | less"
SH
chmod +x tools/profile/trace_irq.sh

echo "[+] Done. Next:"
echo "    - Find legacy GPIO numbers (see ranger-k/README.md)"
echo "    - Build & load module with line_gpios=..."
echo "    - Run tools/profile/*.sh to collect perf/trace data"
