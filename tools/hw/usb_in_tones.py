#!/usr/bin/env python3
"""USB IN on a unit: four tones into inputs A-D over USB, MAIN and CUE back
over USB, no interface or cable in the path. Bryan T, 21 Oct 2026, for the
29-word RX inject (modules/usb/rx_inject.asm).

    tools/hw/usb_in_tones.py --list
    tools/hw/usb_in_tones.py --label new --save
    tools/hw/usb_in_tones.py --label old --save

Needs numpy and sounddevice, and an image with USB IN = ABCD and MAIN, CUE
out (remix usb-io-main-cue-abcd). On the unit: inputs AB and CD at DIR up in
the mixer, nothing else playing.

Host channels 1-4 (inputs A-D) each get their own tone, all four at once,
for --seconds. The unit's channels come back full duplex. The first second
is dropped; every following whole second is analysed on its own (integer-Hz
tones, so each second holds whole cycles and the fit is exact):

  level   each tone's amplitude on each returned channel, in dBFS: shows
          which input reaches which side, and crosstalk where it should not;
  resid   what is left after removing the four tones and their harmonics up
          to the 5th, in dB relative to the channel's tone power: a wrong
          sample join, a torn block or a dropout raises it;
  worst   the worst second's resid, so one bad second is not averaged away;
  DC      the constant offset, in 24-bit LSBs (removed before resid).

Run it on two images built from the same remix (a change and main): an
inject change that is meant to be bit-identical should give the same
numbers. Results are written to usb_in_tones_<label>.txt; --save also keeps
the played and recorded audio as usb_in_tones_<label>.npz.

Measured (21 Oct 2026, Bryan T's MKII, usb-io-main-cue-abcd, macOS, the
29-word inject and the 39-word one before it, the same on both): every tone
at -18.1 dBFS on its own side (A, C on MAIN L; B, D on MAIN R), the
other side below -178 dB, resid -126 dB (within +-1.5 LSB: the path's
-0.137 dB gain, rounded). DC: MAIN R -409 to -410 LSB, MAIN L -6 to -9, present
while the host sends zeros, so added after the inject; its source is not
read. A wrong hi/lo join shows as resid tens of dB higher (errors up to 255
LSB, value-dependent), a slot error as a tone on the wrong side.
"""
import argparse
import sys

import numpy as np
import sounddevice as sd

FS = 44100
TONES = (433, 1009, 2017, 4001)          # host channels 1-4 = inputs A-D
NAMES = ("A", "B", "C", "D")
LEVEL = 10 ** (-18 / 20)                 # each tone at -18 dBFS


def find_device(name):
    for i, d in enumerate(sd.query_devices()):
        if name.lower() in d["name"].lower() and d["max_input_channels"] >= 2 and d["max_output_channels"] >= 4:
            return i
    sys.exit(f"no device matching '{name}' with 4 outputs (try --list, then --device)")


def fit(seg, freqs):
    """Least-squares amplitudes of sines at integer-Hz freqs over one whole second."""
    t = np.arange(len(seg)) / FS
    cols = []
    for f in freqs:
        cols += [np.sin(2 * np.pi * f * t), np.cos(2 * np.pi * f * t)]
    cols.append(np.ones_like(t))                      # DC, reported apart from the residual
    m = np.stack(cols, axis=1)
    coef, *_ = np.linalg.lstsq(m, seg, rcond=None)
    amps = np.hypot(coef[0:-1:2], coef[1:-1:2])
    return amps, seg - m @ coef, coef[-1]


def db(x):
    return 20 * np.log10(max(x, 1e-12))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--device", default="Octatrack")
    ap.add_argument("--seconds", type=int, default=12)
    ap.add_argument("--label", default="run")
    ap.add_argument("--save", action="store_true", help="also write the played and recorded audio to usb_in_tones_<label>.npz")
    a = ap.parse_args()
    if a.list:
        print(sd.query_devices())
        return
    dev = a.device if a.device.isdigit() else find_device(a.device)
    dev = int(dev)
    info = sd.query_devices(dev)
    n_in = int(info["max_input_channels"])
    print(f"device {dev}: {info['name']}, {n_in} in / {int(info['max_output_channels'])} out")

    n = FS * a.seconds
    t = np.arange(n) / FS
    out = np.zeros((n, 4), dtype=np.float32)
    for k, f in enumerate(TONES):
        out[:, k] = LEVEL * np.sin(2 * np.pi * f * t)
    ramp = np.minimum(1, np.arange(n) / (FS * 0.05))[:, None]
    out *= ramp
    rec = sd.playrec(out, samplerate=FS, device=dev, channels=n_in, dtype="float32", blocking=True)

    if a.save:
        np.savez_compressed(f"usb_in_tones_{a.label}.npz", played=out, recorded=rec, fs=FS)
    harm = [f * h for f in TONES for h in range(1, 6) if f * h < FS / 2]
    lines = [f"label {a.label}, device {info['name']}, {a.seconds - 1} seconds analysed",
             "tones: " + ", ".join(f"host ch {k + 1} -> input {NAMES[k]} {f} Hz" for k, f in enumerate(TONES))]
    for ch in range(n_in):
        amps_all, resid_all, dc_all = [], [], []
        for s in range(1, a.seconds):
            seg = rec[s * FS:(s + 1) * FS, ch].astype(np.float64)
            amps, r, dc = fit(seg, harm)
            dc_all.append(dc * 2 ** 23)
            tone_amps = amps[[harm.index(f) for f in TONES]]
            amps_all.append(tone_amps)
            tone_pow = np.sum(tone_amps ** 2) / 2
            resid_all.append(10 * np.log10(max(np.mean(r ** 2), 1e-24) / max(tone_pow, 1e-24)))
        amps_mean = np.mean(amps_all, axis=0)
        levels = "  ".join(f"{NAMES[k]} {db(amps_mean[k]):7.1f}" for k in range(4))
        lines.append(f"unit ch {ch + 1}:  {levels}   resid {np.median(resid_all):6.1f} dB   worst {max(resid_all):6.1f} dB   DC {np.median(dc_all):7.1f} LSB")
    print("\n".join(lines))
    with open(f"usb_in_tones_{a.label}.txt", "w") as fh:
        fh.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
