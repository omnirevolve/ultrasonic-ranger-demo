#!/usr/bin/env python3
import argparse
import curses
import time
import os

def parse_csv_line(s):
    # expects "m.mmm,m.mmm,m.mmm,m.mmm,m.mmm"
    parts = s.strip().split(",")
    vals = []
    for p in parts:
        p = p.strip()
        if not p:
            continue
        try:
            vals.append(float(p))
        except ValueError:
            # if malformed — keep old values by returning None
            return None
    return vals

def decide(vals, near=0.40, far=0.80):
    """
    Simple demo decision (tweak thresholds if needed):
      - if any < near: STOP
      - else if front (idx=2) < far: turn to side with more space
      - else FORWARD
    """
    if not vals or len(vals) < 3:
        return "NO DATA"

    if any(v < near for v in vals):
        return "STOP"

    front = vals[2]
    if front < far:
        left_space  = (vals[0] + vals[1]) / 2.0
        right_space = (vals[3] + vals[4]) / 2.0
        return "TURN LEFT" if left_space > right_space else "TURN RIGHT"

    return "FORWARD"

def draw(stdscr, src_path, hz=10):
    curses.curs_set(0)
    stdscr.nodelay(True)
    period = 1.0 / max(1, hz)
    last_vals = None
    err = ""

    title = "Ultrasonic Ranger — Live TUI (debugfs)"
    help1 = "q: quit    r: reload file    +/-: rate    space: clear error"

    while True:
        t0 = time.time()

        # input
        try:
            ch = stdscr.getch()
            if ch == ord('q'):
                return
            elif ch == ord('+'):
                period = max(0.02, period * 0.8)
            elif ch == ord('-'):
                period = min(1.0, period * 1.25)
            elif ch == ord('r'):
                # just re-open next iteration
                pass
            elif ch == ord(' '):
                err = ""
        except:
            pass

        # read sysfs
        vals = None
        try:
            with open(src_path, "r") as f:
                line = f.readline()
            parsed = parse_csv_line(line)
            if parsed is not None:
                vals = parsed
                last_vals = vals
            else:
                err = "Malformed CSV from sysfs"
        except PermissionError:
            err = "Permission denied. Try sudo or check file mode."
        except FileNotFoundError:
            err = f"Source not found: {src_path}"
        except Exception as e:
            err = f"Read error: {e}"

        # pick what to show
        show = last_vals if vals is None else vals
        decision = decide(show) if show else "NO DATA"

        # UI
        stdscr.erase()
        stdscr.addstr(0, 0, title)
        stdscr.addstr(1, 0, f"Source: {src_path}")
        stdscr.addstr(2, 0, help1)
        stdscr.addstr(3, 0, f"Rate: {1.0/period:.1f} Hz")

        stdscr.addstr(5, 0, "Distances (m):")
        if show:
            # Format with 3 decimals, keep indices for clarity
            for i, v in enumerate(show[:5]):
                stdscr.addstr(6 + i, 2, f"[{i}] {v:0.3f}")
        else:
            stdscr.addstr(6, 2, "(no data)")

        stdscr.addstr(12, 0, "Decision:")
        stdscr.addstr(13, 2, decision)

        if err:
            stdscr.addstr(15, 0, f"Warning: {err}")

        stdscr.refresh()

        # sleep to keep rate
        dt = time.time() - t0
        if dt < period:
            time.sleep(period - dt)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sysfs", default="/sys/kernel/debug/ranger_k/distances",
                    help="Path to /sys/kernel/debug/ranger_k/distances")
    ap.add_argument("--rate", type=int, default=10, help="UI refresh rate (Hz)")
    args = ap.parse_args()

    # Quick sanity info printed once (useful when launched from script)
    try:
        if os.path.exists(args.sysfs):
            with open(args.sysfs, "r") as f:
                sample = f.readline().strip()
            print(f"[i] initial sample: {sample}")
        else:
            print(f"[w] sysfs path not found: {args.sysfs}")
    except Exception as e:
        print(f"[w] pre-read failed: {e}")

    curses.wrapper(draw, args.sysfs, args.rate)

if __name__ == "__main__":
    main()
