#!/usr/bin/env python3
"""Read USB AUDIO's counters from a unit over USB (the vendor request
0xc0/0x55 the module answers on EP0; modules/usbaudio/usbaudio.s).

  tools/hw/usb_counters.py            # once
  tools/hw/usb_counters.py --watch 1  # every second, deltas beside the values

Needs libusb and pyusb. On this Mac Homebrew is the Intel build under
/usr/local and the .venv python is arm64, so the x86_64 python takes the
package: `brew install libusb`, then
`/usr/local/bin/python3 -m pip install --user --break-system-packages pyusb`
and run this with `/usr/local/bin/python3` (25 Sep 2026).
A device-recipient control request needs no interface claim, so the
audio and MIDI drivers macOS attaches stay attached. The unit must be
running a `usb-audio` image; on any other image the request STALLs
(reported here, not an error).

Meaning (from usbaudio.s): produced/consumed are frame counts (the ring is
1,024 frames; fill = produced - consumed); underruns = polls the device
could not fill; overruns = the host stopped draining and the producer
lapped the ring; bankdup = blocks where the read-back ping-pong bank did
NOT alternate (the producer read a bank twice, or skipped one) -- the count
that decides whether the clicks are the producer's.

--out reads USB AUDIO OUT's counters (0xc0/0x56; modules/usbaudio-out/
usbaudio_out.s) instead: produced/consumed = frames into and out of the
OUT ring; minfill/maxfill = the ring's low and high water while consuming
since the stream came up (the cushion OUT_TARGET has to cover);
underruns = blocks the ring could not supply; overruns = ring laps;
reprimes = EP3 OUT self-heal primes; bad = odd-length or error packets;
frames/seconds = the two state-7 visits (equal while running).
bad = err + partial: err = completions with a dTD error bit, errmask =
which bits (0x40 halted, 0x20 data buffer, 0x08 transaction), partial =
lengths that were not whole frames; lasttok/lastslot = the last bad
completion's token (bytes left in bits 30:16) and dTD slot.
depth = dTDs still queued at the last bad one; badfr/badfr_prev = FRINDEX
(microframe count, wraps at 16384) at the last two bad ones; dry = times
the endpoint's dTD list had run empty; late/maxpass = retire passes that
found 3+ dTDs done, and the most in one pass.
good_nz/bad_nz = good/bad packets whose received data was not all zero,
bad_nzw = non-zero longs summed over the bad ones, last_nzw = in the
last (build 11; meaningful while the host sends digital silence).
"""
import argparse
import struct
import sys
import time

OUT_NAMES = ("produced", "consumed", "pkts", "lastn", "lastfill", "underruns", "overruns",
             "reprimes", "bad", "frames", "seconds", "minfill", "maxfill",
             "err", "partial", "errmask", "lasttok", "lastslot",
             "depth", "badfr", "badfr_prev", "dry", "late", "maxpass",
             "good_nz", "bad_nz", "bad_nzw", "last_nzw")
NAMES = ("consumed", "acc", "overruns", "underruns", "lastn", "lastfill", "lastbank",
         "bankdup", "lastsamp", "srcjump", "reprimes", "produced")


def read(dev, out=False):
    req, names = (0x56, OUT_NAMES) if out else (0x55, NAMES)
    n = 4 * len(names)
    raw = bytes(dev.ctrl_transfer(0xc0, req, 0, 0, n, timeout=1000))
    if len(raw) != n:
        raise RuntimeError(f"{len(raw)} bytes back, expected {n}")
    return dict(zip(names, struct.unpack(f">{len(names)}I" if out else f">{len(names)}i", raw)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--watch", type=float, default=0, help="seconds between reads; 0 = once")
    ap.add_argument("--out", action="store_true",
                    help="USB AUDIO OUT's counters (vendor request 0x56) instead of USB AUDIO's")
    a = ap.parse_args()
    try:
        import usb.core
    except ImportError:
        sys.exit("pyusb is not installed: brew install libusb && .venv/bin/pip install pyusb")
    # pyusb's default search misses a Homebrew libusb on this Mac (Intel
    # brew under /usr/local, 25 Sep 2026); name the library outright.
    import glob
    import usb.backend.libusb1
    libs = (glob.glob("/usr/local/opt/libusb/lib/libusb-1.0.dylib") + glob.glob("/opt/homebrew/opt/libusb/lib/libusb-1.0.dylib")
            + glob.glob("/usr/local/lib/libusb-1.0*.dylib") + glob.glob("/usr/local/Cellar/libusb/*/lib/libusb-1.0*.dylib")
            + glob.glob("/opt/homebrew/lib/libusb-1.0*.dylib") + glob.glob("/opt/homebrew/Cellar/libusb/*/lib/libusb-1.0*.dylib"))
    backend = usb.backend.libusb1.get_backend(find_library=lambda _: libs[0]) if libs else None
    dev = usb.core.find(idVendor=0x1935, idProduct=0x0002, backend=backend)
    if dev is None:
        sys.exit("no Octatrack on USB (1935:0002)")
    try:
        last = read(dev, a.out)
    except Exception as e:  # noqa: BLE001
        sys.exit(f"the request failed: {e} (a STALL means the image carries no USB AUDIO{' OUT' if a.out else ''})")
    print(" ".join(f"{k}={v:#x}" if k in ("errmask", "lasttok") else f"{k}={v}" for k, v in last.items()), flush=True)
    while a.watch > 0:
        time.sleep(a.watch)
        now = read(dev, a.out)
        print(" ".join(f"{k}={now[k]:#x}" if k in ("errmask", "lasttok") else
                       f"{k}={now[k]}{'(+%d)' % (now[k] - last[k]) if now[k] != last[k] else ''}" for k in now), flush=True)
        last = now


if __name__ == "__main__":
    main()
