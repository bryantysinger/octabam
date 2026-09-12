#!/usr/bin/env python3
"""Stems for one part of a real project: each track's STATIC sample, at the
slot's gain, cut to --seconds -- what rig_render --project needs to render
the rig on the set (Stage D, 13 Sep 2026).

    python3 tools/harness/set_stems.py ~/octa/backups/OCTABAM_RIG --bank 1 --part 1 \\
        --audio ~/octa/backups/ChongBongolo26_20260904_preflash4 --out out/set/A1/stems

The part's per-track static slot is PART+0x2d3 + 5*track (ot_project.py's
map); the slot's PATH is resolved by BASENAME under --audio (the card's
AUDIO tree is not in the backups, the files are, flat). A track whose slot
has no file, or a machine that is not STATIC, gets no stem (silence). The
slot GAIN (48 = 0 dB, half-dB steps) is applied, as the unit applies it
before the AMP page. A sample shorter than --seconds is looped whole (the
unit's LOOP mode is not read; a loop is what the stems stand in for).
"""
import argparse, pathlib, re, sys, wave
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1])); import toolpath  # noqa: E402,F401
from hw import ot_project as otp  # noqa: E402

SR = 44100


def read_wav(path):
    from render_reverb import read_wav_channels, resample
    chans, sr = read_wav_channels(path)
    L = resample(chans[0], sr, SR)
    R = resample(chans[1], sr, SR) if len(chans) > 1 else L
    return L, R


def write_wav(path, L, R):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2); w.setsampwidth(3); w.setframerate(SR)
        w.writeframes(b"".join(int(max(-8388608, min(8388607, round(v * 8388607)))).to_bytes(3, "little", signed=True)
                               for pair in zip(L, R) for v in pair))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("project")
    ap.add_argument("--bank", type=int, required=True)
    ap.add_argument("--part", type=int, required=True)
    ap.add_argument("--audio", required=True, help="dir holding the sample files (matched by basename)")
    ap.add_argument("--seconds", type=float, default=8.0)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    pdir = pathlib.Path(a.project).expanduser()
    _, slots = otp.read_project(pdir)
    by_slot = {s["slot"]: s for s in slots if s["type"] == "STATIC" and s["path"]}
    audio = {p.name.lower(): p for p in pathlib.Path(a.audio).expanduser().rglob("*.wav")}
    data = (pdir / f"bank{a.bank:02d}.work").read_bytes()
    off = otp.PART_BASE + (a.part - 1) * otp.PART_STRIDE
    out = pathlib.Path(a.out); out.mkdir(parents=True, exist_ok=True)
    n = int(a.seconds * SR)
    for t in range(8):
        mtype = data[off + otp.MTYPE_OFF + t]
        slot = data[off + 0x2d3 + t * 5 + otp.SLOT_KIND["static"]] + 1
        s = by_slot.get(slot)
        name = pathlib.Path(s["path"]).name if s else None
        f = audio.get(name.lower()) if name else None
        if mtype != 0 or not f:
            print(f"  T{t+1}: {'machine type %d' % mtype if mtype else 'slot %d' % slot} -- no stem ({name or 'empty'})")
            continue
        L, R = read_wav(f)
        g = 10 ** (((s["gain"] - 48) / 2) / 20)
        reps = max(1, -(-n // len(L)))
        L = ([v * g for v in L] * reps)[:n]; R = ([v * g for v in R] * reps)[:n]
        write_wav(out / f"T{t+1}.wav", L, R)
        print(f"  T{t+1}: slot {slot:3d} {name}  gain {(s['gain']-48)/2:+.1f} dB  {len(L)/SR:.1f} s")
    print(f"-> {out}")


if __name__ == "__main__":
    main()
