#!/usr/bin/env python3
"""The sample analyzer's cost on a unit (TASK 98A5C, 0x40098a5c): one project, every condition, stepped over USB MIDI,
each ColdFire task's share read over USB (tools/hw/task_meter.py).

    python3 tools/hw/analyzer_sweep.py plan
    python3 tools/hw/analyzer_sweep.py proj TEMPLATE DEST            # TEMPLATE: a fresh project the unit (or ot_fresh.py) made
    python3 tools/hw/analyzer_sweep.py run DEST LABEL [--midi Octatrack] [--reps 3] [--secs 10] [--settle 3]
                                                      [--only FLEX,LOOP] [--seed 1]
    python3 tools/hw/analyzer_sweep.py report out/hw/analyzer/LABEL.csv [more.csv ...]
    python3 tools/hw/analyzer_sweep.py port-midi DEST OUT.midi [--secs 4]   # the same steps as a --midi script for the port

WHY. Under the ColdFire port the analyzer did no work for 8 FLEX or 8 STATIC tracks with loop off, and about 33 chunks a
second a track with loop on (the voice renderer's loop path at 0x40008666 raises 0x46104d04, which the frame interrupt
turns into the task's wake; 26 Oct 2026). The port counts instructions, not time; this measures time on the unit.

THE PROJECT. Three sample sets, eight files each (one per track), generated here beside the project files (noise hits
and a tone, a different tone per track): LONG OFF (4 s, loop off), SHORT ON (1 s, loop on, so it wraps twice a bar)
and LONG ON (4 s, loop on, a 2 s bar retriggers it before it reaches its end). FLEX slots 1-24 and STATIC slots 1-24
name them (set k, track t: slot 8k + t), TSTR off in every slot (TSMODE=0; the track's TSTR stays AUTO), 120 BPM,
trim records in markers.work. Bank A is FLEX, bank B STATIC: in each, part k plays set k on all eight tracks, and
pattern 4k + j (j = 0..3) is that part with a trig on step 1 of the first 1, 2, 4 or 8 tracks (LEN 16, 1X: a 2 s bar).
Pattern 13 of bank A has no trigs: BASE. A program change on --pc-channel (default 1) selects a pattern: 16 x bank +
pattern. The project's MIDI settings are ot_matrix.py's (clock, transport and program change receive on), so `run`
sends the clock itself.

A RUN. Per condition, in a shuffled order per repetition (--seed): STOP twice (the voices end), the program change,
START, --settle seconds, then --secs of task_meter polling; one CSV row per condition and repetition in
out/hw/analyzer/LABEL.csv (task shares, FRAME IRQ when LOAD METER is in the image, and the condition's fields).
`report` prints a table: per condition, the mean and spread of TASK 98A5C and IDLE over the repetitions. Run the same
sweep on the image without and with the stretch gate to get what the gate frees.

What it cannot see: interrupts other than the frame interrupt stay inside the task they hit (as on BRAIN's screen);
the FRAME IRQ correction assumes the interrupt is independent of task switches (brain.c, inferred).
"""
import argparse
import csv
import json
import math
import pathlib
import random
import shutil
import statistics
import struct
import sys
import time
import wave

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

BPM = 120
FS = 44100
SETS = (("LONG OFF", 4.0, 0), ("SHORT ON", 1.0, 1), ("LONG ON", 4.0, 1))    # name, seconds, LOOPMODE
NS = (1, 2, 4, 8)
MACHINES = (("FLEX", 1), ("STATIC", 0))          # name, machine type (ot_project.SLOT_KIND)
BASE_PATTERN = 12                                # bank A pattern 13
PLAN_FILE = "OCTABAM_ANALYZER.json"

# bank file layout (ot_project.py, ot_bank.py)
PTRN0, PTRN_FSTRIDE = 0x16, 0x8eec
PART_BASE, PART_STRIDE = 0x8eed6, 0x18bb
MTYPE_OFF, SLOT_OFF = 0x02b, 0x2d3
# markers.work (docs/firmware/STORAGE.md section 4): 22-byte header, 264 records of 784 B,
# FLEX 1..136 (129..136 the recorders), then STATIC 1..128; trim start, trim end, loop point first
MARK_HDR, MARK_REC, MARK_STATIC0 = 0x16, 784, 136


def slot_of(k, t):
    return 8 * k + t + 1


def wav_name(k, t):
    return f"AZ{k}{t + 1}.WAV"


def conditions():
    """[{name, machine, set, n, bank, pattern, program}], BASE first."""
    out = [{"name": "BASE", "machine": "-", "set": "-", "n": 0, "bank": 0, "pattern": BASE_PATTERN,
            "program": BASE_PATTERN}]
    for b, (mname, _) in enumerate(MACHINES):
        for k, (sname, _secs, _loop) in enumerate(SETS):
            for j, n in enumerate(NS):
                pat = 4 * k + j
                out.append({"name": f"{mname} {sname} x{n}", "machine": mname, "set": sname, "n": n,
                            "bank": b, "pattern": pat, "program": 16 * b + pat})
    return out


def trac_off(pattern, track):
    return PTRN0 + pattern * PTRN_FSTRIDE + 8 + track * 0x922 + 9


def sample(k, t, secs):
    """Decaying noise hits every 0.5 s and a tone (110 Hz x (t + 1)), 16-bit stereo; deterministic."""
    rnd = random.Random(100 * k + t)
    n = int(secs * FS)
    f0 = 110.0 * (t + 1)
    frames = bytearray()
    for i in range(n):
        x = i / FS
        v = 0.35 * math.exp(-(x % 0.5) * 12.0) * (rnd.random() * 2 - 1) + 0.3 * math.sin(2 * math.pi * f0 * x)
        s = int(max(-1.0, min(1.0, v)) * 30000)
        frames += struct.pack("<hh", s, s)
    return bytes(frames), n


def write_wav(path, frames):
    w = wave.open(str(path), "wb")
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(FS)
    w.writeframes(frames); w.close()


def sample_blocks(lengths):
    bpm24 = BPM * 24
    text = ""
    for mname, _ in MACHINES:
        for k, (_sname, _secs, loop) in enumerate(SETS):
            for t in range(8):
                bars = lengths[(k, t)] * 100 * BPM // (FS * 60 * 4)
                text += (f"[SAMPLE]\r\nTYPE={mname}\r\nSLOT={slot_of(k, t):03d}\r\nPATH={wav_name(k, t)}\r\n"
                         f"TRIM_BARSx100={bars}\r\nLOOP_BARSx100={bars}\r\nBPMx24={bpm24}\r\nTSMODE=0\r\n"
                         f"LOOPMODE={loop}\r\nGAIN=48\r\nTRIGQUANTIZATION=-1\r\n[/SAMPLE]\r\n\r\n")
    return text.encode("latin1")


def write_project_text(dest, lengths):
    import re
    for name in ("project.work", "project.strd"):
        path = dest / name
        if not path.exists():
            continue
        raw = path.read_bytes()
        if re.search(rb"\[SAMPLE\]\r?\nTYPE=(FLEX|STATIC)\r?\nSLOT=0*([1-9]|1\d|2[0-4])\r?\n", raw):
            sys.exit(f"{path}: the template already has a sample in slots 1-24; start from a fresh project")
        at = raw.find(b"[SAMPLE]")
        if at < 0:
            sys.exit(f"{path}: no [SAMPLE] section")
        path.write_bytes(raw[:at] + sample_blocks(lengths) + raw[at:])
    import ot_matrix as M
    settings = M.test_settings(1)
    settings["TEMPOx24"] = BPM * 24
    return M.stamp_text(dest, settings, M.TEST_STATES)


def write_markers(dest, lengths):
    for name in ("markers.work", "markers.strd"):
        path = dest / name
        if not path.exists():
            continue
        data = bytearray(path.read_bytes())
        if len(data) != MARK_HDR + 264 * MARK_REC + 2 and len(data) < MARK_HDR + 264 * MARK_REC:
            sys.exit(f"{path}: {len(data)} bytes, not the 264-record layout STORAGE.md describes")
        for k in range(len(SETS)):
            for t in range(8):
                rec = struct.pack(">III", 0, lengths[(k, t)], 0)
                for first in (0, MARK_STATIC0):
                    off = MARK_HDR + (first + slot_of(k, t) - 1) * MARK_REC
                    data[off:off + MARK_REC] = rec + bytes(MARK_REC - len(rec))
        data[-2:] = (sum(data[0x10:-2]) & 0xFFFF).to_bytes(2, "big")
        path.write_bytes(bytes(data))


def write_banks(dest):
    for b, (_mname, mtype) in enumerate(MACHINES):
        for suffix in ("work", "strd"):
            path = dest / f"bank{b + 1:02d}.{suffix}"
            if not path.exists():
                continue
            data = bytearray(path.read_bytes())
            for p in range(8):                              # parts 1-4 and their saved copies 5-8
                k = p % 4
                if k >= len(SETS):
                    continue
                base = PART_BASE + p * PART_STRIDE
                for t in range(8):
                    data[base + MTYPE_OFF + t] = mtype
                    data[base + SLOT_OFF + t * 5 + mtype] = slot_of(k, t) - 1
            for pat in range(16):
                for t in range(8):                          # no trigs or trigless locks anywhere
                    off = trac_off(pat, t)
                    data[off:off + 64] = bytes(64)
                    data[off + 0x50], data[off + 0x51] = 16, 2
                tail = PTRN0 + pat * PTRN_FSTRIDE + PTRN_FSTRIDE - 11
                data[tail + 2], data[tail + 3] = 16, 2      # LEN 16, 1X
            for c in conditions():
                if c["bank"] != b or c["name"] == "BASE":
                    continue
                pat, k = c["pattern"], SETS.index(next(s for s in SETS if s[0] == c["set"]))
                data[PTRN0 + pat * PTRN_FSTRIDE + PTRN_FSTRIDE - 5] = k     # the part it plays
                for t in range(c["n"]):
                    data[trac_off(pat, t) + 7] |= 1                         # mask 0, step 1
            if b == 0:
                data[PTRN0 + BASE_PATTERN * PTRN_FSTRIDE + PTRN_FSTRIDE - 5] = 0
            data[-2:] = (sum(data[0x10:-2]) & 0xFFFF).to_bytes(2, "big")
            path.write_bytes(bytes(data))


def check_banks(dest):
    """Read the project back: each condition's pattern names its part and trigs exactly its tracks."""
    for b, (_mname, mtype) in enumerate(MACHINES):
        data = (dest / f"bank{b + 1:02d}.work").read_bytes()
        for c in conditions():
            if c["bank"] != b:
                continue
            pat = c["pattern"]
            trigs = [t for t in range(8) if data[trac_off(pat, t) + 7] & 1]
            assert trigs == list(range(c["n"])), (c["name"], trigs)
            if c["name"] != "BASE":
                k = data[PTRN0 + pat * PTRN_FSTRIDE + PTRN_FSTRIDE - 5]
                assert SETS[k][0] == c["set"], (c["name"], k)
                base = PART_BASE + k * PART_STRIDE
                assert all(data[base + MTYPE_OFF + t] == mtype for t in range(8)), c["name"]
                assert all(data[base + SLOT_OFF + t * 5 + mtype] == slot_of(k, t) - 1 for t in range(8)), c["name"]
        assert (sum(data[0x10:-2]) & 0xFFFF) == int.from_bytes(data[-2:], "big"), "bank checksum"


def cmd_proj(a):
    src, dest = pathlib.Path(a.template), pathlib.Path(a.dest)
    if not (src / "project.work").is_file():
        sys.exit(f"{src} is not a project directory")
    if dest.exists():
        sys.exit(f"{dest} exists; refusing to overwrite")
    shutil.copytree(src, dest)
    lengths = {}
    for k, (_sname, secs, _loop) in enumerate(SETS):
        for t in range(8):
            frames, n = sample(k, t, secs)
            write_wav(dest / wav_name(k, t), frames)
            lengths[(k, t)] = n
    changed = write_project_text(dest, lengths)
    write_markers(dest, lengths)
    write_banks(dest)
    check_banks(dest)
    plan = {"bpm": BPM, "pc_channel": 1, "sets": [list(s) for s in SETS], "conditions": conditions(),
            "settings_changed": changed}
    (dest / PLAN_FILE).write_text(json.dumps(plan, indent=1))
    print(f"{dest}: {len(conditions())} conditions, 24 samples; copy the folder (WAVs included) into a set on the card")


def cmd_plan(_a):
    for c in conditions():
        print(f"PC {c['program']:3d}  bank {'AB'[c['bank']]} pattern {c['pattern'] + 1:2d}  {c['name']}")


def select(conds, only):
    if not only:
        return conds
    words = [w.strip().upper() for w in only.split(",") if w.strip()]
    return [c for c in conds if c["name"] == "BASE" or all(w in c["name"].upper() for w in words)]


def cmd_run(a):
    import ot_ladder as L
    import task_meter as T
    dest = pathlib.Path(a.dest)
    plan = json.loads((dest / PLAN_FILE).read_text())
    conds = select(plan["conditions"], a.only)
    out = pathlib.Path("out/hw/analyzer"); out.mkdir(parents=True, exist_ok=True)
    path = out / f"{a.label}.csv"
    unit = T.Unit()
    unit.ledger()                                   # fails here, before any MIDI, on an image without block 4
    clock = L.Clock(plan["bpm"], a.midi)
    rng = random.Random(a.seed)
    fields = ["label", "rep", "condition", "machine", "set", "n", "program"]
    try:
        for rep in range(1, a.reps + 1):
            order = conds[:]
            rng.shuffle(order)
            for c in order:
                clock.stop(); time.sleep(0.2); clock.stop(); time.sleep(0.5)
                clock.pc(plan["pc_channel"], c["program"]); time.sleep(0.8)
                clock.start()
                time.sleep(a.settle)
                res = T.measure(unit, a.secs, a.interval)
                row = dict(zip(fields, (a.label, rep, c["name"], c["machine"], c["set"], c["n"], c["program"])))
                row.update(T.csv_row(res, a.label))
                new = not path.exists()
                with path.open("a", newline="") as f:
                    w = csv.DictWriter(f, fieldnames=fields + [k for k in T.CSV_FIELDS if k != "label"],
                                       extrasaction="ignore")
                    if new:
                        w.writeheader()
                    w.writerow(row)
                print(f"rep {rep} {c['name']:22s} 98A5C {100 * res['share']['TASK 98A5C']:5.1f}%  "
                      f"IDLE {100 * res['share']['IDLE']:5.1f}%", flush=True)
    finally:
        clock.stop(); time.sleep(0.2); clock.stop()
        clock.close()
    print(f"wrote {path}")


def cmd_report(a):
    rows = []
    for p in a.csv:
        with open(p, newline="") as f:
            rows += list(csv.DictReader(f))
    keys = []
    for r in rows:
        k = (r["label"], r["condition"])
        if k not in keys:
            keys.append(k)
    print("| label | condition | reps | TASK 98A5C % | IDLE % | FRAME IRQ % |")
    print("|---|---|---|---|---|---|")

    def ms(vals):
        vals = [100 * float(v) for v in vals if v != ""]
        if not vals:
            return "-"
        return f"{statistics.mean(vals):.1f} ± {statistics.stdev(vals):.1f}" if len(vals) > 1 else f"{vals[0]:.1f}"
    for label, cond in keys:
        rs = [r for r in rows if r["label"] == label and r["condition"] == cond]
        print(f"| {label} | {cond} | {len(rs)} | {ms([r['TASK 98A5C'] for r in rs])} | {ms([r['IDLE'] for r in rs])} "
              f"| {ms([r['FRAME IRQ'] for r in rs])} |")


def cmd_port_midi(a):
    """The run's MIDI as the port's --midi script: `pre` the first program change, then per condition STOP, STOP,
    the program change and START, `secs` apart (frames after the transport start, 2756.25 a second)."""
    plan = json.loads((pathlib.Path(a.dest) / PLAN_FILE).read_text())
    conds = select(plan["conditions"], a.only)
    ch = plan["pc_channel"] - 1
    lines = [f"pre {0xC0 | ch:02X} {conds[0]['program']:02X}"]
    fps = FS / 16
    t = a.secs
    for c in conds[1:]:
        f = int(t * fps)
        lines += [f"{f} FC", f"{f + 30} FC", f"{f + 200} {0xC0 | ch:02X} {c['program']:02X}", f"{f + 1200} FA"]
        t += a.secs
    pathlib.Path(a.out).write_text("\n".join(lines) + "\n")
    print(f"{a.out}: {len(conds)} conditions, {a.secs} s each ({int(t * fps)} frames)")
    for i, c in enumerate(conds):
        print(f"  {i * a.secs:6.1f} s  {c['name']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan")
    p = sub.add_parser("proj"); p.add_argument("template"); p.add_argument("dest")
    p = sub.add_parser("run"); p.add_argument("dest"); p.add_argument("label")
    p.add_argument("--midi", default="Octatrack"); p.add_argument("--reps", type=int, default=3)
    p.add_argument("--secs", type=float, default=10.0); p.add_argument("--settle", type=float, default=3.0)
    p.add_argument("--interval", type=float, default=0.25); p.add_argument("--only", default="")
    p.add_argument("--seed", type=int, default=1)
    p = sub.add_parser("report"); p.add_argument("csv", nargs="+")
    p = sub.add_parser("port-midi"); p.add_argument("dest"); p.add_argument("out")
    p.add_argument("--secs", type=float, default=4.0); p.add_argument("--only", default="")
    a = ap.parse_args()
    {"plan": cmd_plan, "proj": cmd_proj, "run": cmd_run, "report": cmd_report, "port-midi": cmd_port_midi}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
