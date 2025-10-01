// SPDX-License-Identifier: GPL-2.0
/*
 * ranger_k - IRQ/timestamp MVP (gpio-sim + threaded IRQ)
 *
 * Summary:
 * - Uses five ECHO lines specified by legacy GPIO numbers via module param
 *   line_gpios=..., or auto-selects 768..772 when a gpio-sim chip with
 *   label "gpio-sim.0-node0" is present.
 * - Explicitly requests lines as inputs (gpio_request_one).
 * - Attaches a threaded IRQ on both edges; the handler measures pulse width
 *   and converts it to distance (micrometers), exposing data via debugfs.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/gpio.h>           /* legacy GPIO API */
#include <linux/gpio/consumer.h>  /* gpio_to_desc(), gpiod_* */
#include <linux/ktime.h>
#include <linux/spinlock.h>
#include <linux/debugfs.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/errno.h>
#include <linux/types.h>
#include <linux/printk.h>
#include <linux/irq.h>

#define DRV_NAME    "ranger_k"
#define MAX_SENSORS 5

/* Module parameters:
 * Either provide all five legacy GPIO numbers or leave entries as -1
 * to auto-detect the gpio-sim base and use base..base+4 (typically 768..772).
 */
static int line_gpios[MAX_SENSORS] = { -1, -1, -1, -1, -1 };
module_param_array(line_gpios, int, NULL, 0444);
MODULE_PARM_DESC(line_gpios, "Legacy GPIO numbers for ECHO lines (5 items)");

struct sensor_state {
	bool have_rise;
	ktime_t rise_ts;
	u32 dist_um;   /* last measured distance (micrometers) */
	u32 pulses;    /* successfully measured pulses */
	u32 overruns;  /* falling edge without a prior rising edge */
	int irq;
	struct gpio_desc *gdesc;
};

static struct {
	struct dentry *dbg_dir;
	spinlock_t lock; /* protects s[] and seq */
	struct sensor_state s[MAX_SENSORS];
	u32 seq;
} g;

/* ns -> um: distance_um = t * 171500 / 1e6
 * (speed of sound ≈ 343 m/s, divide by 2 for round trip)
 */
static inline u32 width_ns_to_um(s64 width_ns)
{
	return (u32)div64_u64((u64)width_ns * 171500ULL, 1000000ULL);
}

/* === debugfs === */
static ssize_t distances_read(struct file *f, char __user *buf, size_t len, loff_t *ppos)
{
	char tmp[256];
	unsigned long flags;
	u32 um[MAX_SENSORS];
	int n;

	spin_lock_irqsave(&g.lock, flags);
	for (int i = 0; i < MAX_SENSORS; i++)
		um[i] = g.s[i].dist_um;
	spin_unlock_irqrestore(&g.lock, flags);

#define M_INT(u)   ((u) / 1000000U)
#define M_FRAC3(u) (((u) / 1000U) % 1000U)
	n = scnprintf(tmp, sizeof(tmp),
	              "%u.%03u,%u.%03u,%u.%03u,%u.%03u,%u.%03u\n",
	              M_INT(um[0]), M_FRAC3(um[0]),
	              M_INT(um[1]), M_FRAC3(um[1]),
	              M_INT(um[2]), M_FRAC3(um[2]),
	              M_INT(um[3]), M_FRAC3(um[3]),
	              M_INT(um[4]), M_FRAC3(um[4]));
#undef M_INT
#undef M_FRAC3
	return simple_read_from_buffer(buf, len, ppos, tmp, n);
}

static ssize_t stats_read(struct file *f, char __user *buf, size_t len, loff_t *ppos)
{
	char tmp[256];
	unsigned long flags;
	u32 seq, pulses[MAX_SENSORS], overr[MAX_SENSORS];
	int n;

	spin_lock_irqsave(&g.lock, flags);
	seq = g.seq;
	for (int i = 0; i < MAX_SENSORS; i++) {
		pulses[i] = g.s[i].pulses;
		overr[i]  = g.s[i].overruns;
	}
	spin_unlock_irqrestore(&g.lock, flags);

	n = scnprintf(tmp, sizeof(tmp),
	              "seq=%u pulses=%u,%u,%u,%u,%u overruns=%u,%u,%u,%u,%u\n",
	              seq, pulses[0], pulses[1], pulses[2], pulses[3], pulses[4],
	              overr[0], overr[1], overr[2], overr[3], overr[4]);

	return simple_read_from_buffer(buf, len, ppos, tmp, n);
}

static const struct file_operations distances_fops = {
	.owner = THIS_MODULE,
	.read  = distances_read,
	.llseek = default_llseek,
};
static const struct file_operations stats_fops = {
	.owner = THIS_MODULE,
	.read  = stats_read,
	.llseek = default_llseek,
};

/* === threaded IRQ handler ===
 * Use a threaded-only handler (primary=NULL) so we can call *_cansleep()
 * and avoid touching the interrupt controller fast path.
 */
static irqreturn_t echo_irq_thread(int irq, void *dev_id)
{
	int idx = (long)dev_id;
	struct sensor_state *s = &g.s[idx];
	ktime_t now = ktime_get();
	int level = gpiod_get_value_cansleep(s->gdesc);
	unsigned long flags;

	spin_lock_irqsave(&g.lock, flags);
	if (level) {
		/* Rising edge */
		s->have_rise = true;
		s->rise_ts = now;
	} else {
		/* Falling edge */
		if (s->have_rise) {
			s64 dt = ktime_to_ns(ktime_sub(now, s->rise_ts));
			s->have_rise = false;
			s->pulses++;
			s->dist_um = width_ns_to_um(dt);
		} else {
			s->overruns++;
		}
	}
	g.seq++;
	spin_unlock_irqrestore(&g.lock, flags);

	return IRQ_HANDLED;
}

/* Auto-scan a gpio-sim chip: label == "gpio-sim.0-node0" → base */
static int autoscan_gpio_sim_base(int *base_out, int *ngpio_out)
{
	struct file *f;
	char path[128], lbl[64];
	int base, ngpio;

	*base_out = -1;
	*ngpio_out = 0;

	for (int chip = 0; chip < 4; chip++) {
		snprintf(path, sizeof(path), "/sys/class/gpio/gpiochip%d/label", 512 + chip*256);
		f = filp_open(path, O_RDONLY, 0);
		if (IS_ERR(f))
			continue;

		memset(lbl, 0, sizeof(lbl));
		kernel_read(f, lbl, sizeof(lbl)-1, &f->f_pos);
		filp_close(f, NULL);

		/* Read base */
		snprintf(path, sizeof(path), "/sys/class/gpio/gpiochip%d/base", 512 + chip*256);
		f = filp_open(path, O_RDONLY, 0);
		if (IS_ERR(f))
			continue;
		{
			char tmp[16]={0};
			kernel_read(f, tmp, sizeof(tmp)-1, &f->f_pos);
			base = simple_strtol(tmp, NULL, 10);
		}
		filp_close(f, NULL);

		/* Read ngpio */
		snprintf(path, sizeof(path), "/sys/class/gpio/gpiochip%d/ngpio", 512 + chip*256);
		f = filp_open(path, O_RDONLY, 0);
		if (IS_ERR(f))
			continue;
		{
			char tmp[16]={0};
			kernel_read(f, tmp, sizeof(tmp)-1, &f->f_pos);
			ngpio = simple_strtol(tmp, NULL, 10);
		}
		filp_close(f, NULL);

		if (strnstr(lbl, "gpio-sim.0-node0", sizeof(lbl))) {
			*base_out  = base;   /* typically 768 */
			*ngpio_out = ngpio;  /* typically 8   */
			return 0;
		}
	}
	return -ENODEV;
}

static int __init ranger_k_init(void)
{
	int ret = 0, base = -1, ngpio = 0;

	spin_lock_init(&g.lock);

	/* If no params are provided, try auto 768..772 via gpio-sim scan */
	bool need_auto = true;
	for (int i = 0; i < MAX_SENSORS; i++)
		if (line_gpios[i] >= 0) { need_auto = false; break; }

	if (need_auto && !autoscan_gpio_sim_base(&base, &ngpio)) {
		if (ngpio < MAX_SENSORS)
			pr_warn(DRV_NAME ": gpio-sim has only %d lines, will still use first %d\n",
			        ngpio, MAX_SENSORS);
		for (int i = 0; i < MAX_SENSORS; i++)
			line_gpios[i] = base + i;
	}

	/* debugfs */
	g.dbg_dir = debugfs_create_dir(DRV_NAME, NULL);
	if (!g.dbg_dir)
		return -ENOMEM;
	debugfs_create_file("distances", 0444, g.dbg_dir, NULL, &distances_fops);
	debugfs_create_file("stats",      0444, g.dbg_dir, NULL, &stats_fops);

	pr_info(DRV_NAME ": params line_gpios={%d,%d,%d,%d,%d}\n",
	        line_gpios[0], line_gpios[1], line_gpios[2], line_gpios[3], line_gpios[4]);

	/* Per-line initialization */
	for (int i = 0; i < MAX_SENSORS; i++) {
		int gpio = line_gpios[i];
		if (gpio < 0)
			continue;

		/* 1) Explicitly request the line as input */
		ret = gpio_request_one(gpio, GPIOF_IN, DRV_NAME);
		if (ret) {
			pr_err(DRV_NAME ": gpio_request_one(%d) failed: %d\n", gpio, ret);
			goto fail;
		}

		/* 2) Get descriptor and IRQ */
		g.s[i].gdesc = gpio_to_desc(gpio);
		if (!g.s[i].gdesc) {
			pr_err(DRV_NAME ": gpio_to_desc(%d) failed\n", gpio);
			ret = -EINVAL;
			goto fail;
		}

		/* Legacy API note: direction is already input; enforce for safety */
		ret = gpiod_direction_input(g.s[i].gdesc);
		if (ret) {
			pr_err(DRV_NAME ": gpiod_direction_input(%d) failed\n", gpio);
			goto fail;
		}

		g.s[i].irq = gpiod_to_irq(g.s[i].gdesc);
		if (g.s[i].irq < 0) {
			pr_err(DRV_NAME ": gpiod_to_irq(%d) failed: %d\n", gpio, g.s[i].irq);
			ret = g.s[i].irq;
			goto fail;
		}

		/* 3) Threaded IRQ on both edges */
		ret = request_threaded_irq(g.s[i].irq,
		                           /*primary*/NULL,
		                           /*thread */echo_irq_thread,
		                           IRQF_ONESHOT |
		                           IRQF_TRIGGER_RISING |
		                           IRQF_TRIGGER_FALLING,
		                           DRV_NAME,
		                           (void *)(long)i);
		if (ret) {
			pr_err(DRV_NAME ": request_threaded_irq(GPIO%d->irq %d) failed: %d\n",
			       gpio, g.s[i].irq, ret);
			goto fail;
		}

		pr_info(DRV_NAME ": line[%d]=GPIO%d -> irq %d OK\n", i, gpio, g.s[i].irq);
	}

	pr_info(DRV_NAME ": loaded (threaded IRQ MVP)\n");
	return 0;

fail:
	for (int i = 0; i < MAX_SENSORS; i++) {
		if (g.s[i].irq > 0) {
			free_irq(g.s[i].irq, (void *)(long)i);
			g.s[i].irq = 0;
		}
		if (line_gpios[i] >= 0)
			gpio_free(line_gpios[i]);
	}
	debugfs_remove_recursive(g.dbg_dir);
	return ret;
}

static void __exit ranger_k_exit(void)
{
	for (int i = 0; i < MAX_SENSORS; i++) {
		if (g.s[i].irq > 0)
			free_irq(g.s[i].irq, (void *)(long)i);
		if (line_gpios[i] >= 0)
			gpio_free(line_gpios[i]);
	}
	debugfs_remove_recursive(g.dbg_dir);
	pr_info(DRV_NAME ": unloaded\n");
}

module_init(ranger_k_init);
module_exit(ranger_k_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("rpi5-ultrasonic demo");
MODULE_DESCRIPTION("Ultrasonic ranger kernel IRQ/timestamp MVP (threaded)");
