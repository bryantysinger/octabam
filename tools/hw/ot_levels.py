#!/usr/bin/env python3
"""Level the samples of an Octatrack project: measure, then rewrite them
gain-only to one target and put the project's own gain stages back to their
defaults, so the OT's mixer is tested at its defaults instead of compensating
for quiet material.

    python3 tools/hw/ot_levels.py scan PROJECT_DIR
        # every [SAMPLE] with a PATH: type, slot, GAIN, format, peak dBFS,
        # active RMS dBFS; then AMP VOL and LEVEL over every part of every bank
    python3 tools/hw/ot_levels.py normalize SRC_DIR DEST_DIR [--target -18] [--peak -1] [--level 108] [--ampvol 64]
        # copies SRC to DEST, then in DEST: every referenced wav/aif is scaled
        # by min(target - active RMS, peak - peak dBFS) -- the data chunk only,
        # every other chunk byte for byte -- a pool file (../AUDIO/...) is
        # copied into the project first and its PATH repointed; GAIN= goes to
        # 48 (0 dB) on those samples; track LEVEL in every part record of
        # every bank goes to --level (108 = 0 dB on the measured taper) and
        # AMP VOL on T1-7 to --ampvol (64 = 0 dB; a 0 is a silenced track and
        # is kept); checksums recomputed. Writes DEST/LEVELS.md: the gain per file.

Active RMS is the listening protocol's: RMS over 100 ms windows louder than
-60 dBFS, so tails and silence do not vote. Files are 24-bit (the set's all
are) or 16-bit; the scale is applied in integer, rounded, clipped, so a
24-bit file loses nothing audible (rounding at -144 dBFS).

Part layout from ot_project.py: PART+0x1b holds 8 (LEVEL, cue) pairs; the
page-1 array at PART+0x12f, 24 bytes a track, carries the AMP page at bytes
18-23 (ATK HOLD REL VOL BAL x -- VOL at +21, 64 = 0 dB: located 14 Sep 2026
on the 25 Aug pregain backup, where T2's +12 dB AMP VOL reads 0x7f there
and 0x40 everywhere it was not raised; the master T8's row is a different
page and is not decoded).
"""
import math, pathlib, re, shutil, struct, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import ot_project as OP

PART_BASE, PART_STRIDE, NPARTS_ALL = OP.PART_BASE, OP.PART_STRIDE, OP.NPARTS_ALL
P1_OFF, AMP_VOL = 0x12f, 21
LEVEL_OFF = 0x1b
WIN = 4410


# ---- audio files: wav (RIFF) and aif (FORM/AIFF), the data chunk located ----
def _chunks_riff(b):
    pos = 12
    while pos + 8 <= len(b):
        cid = b[pos:pos + 4]; size = struct.unpack("<I", b[pos + 4:pos + 8])[0]
        yield cid, pos + 8, size
        pos += 8 + size + (size & 1)


def _chunks_form(b):
    pos = 12
    while pos + 8 <= len(b):
        cid = b[pos:pos + 4]; size = struct.unpack(">I", b[pos + 4:pos + 8])[0]
        yield cid, pos + 8, size
        pos += 8 + size + (size & 1)


def _ext80(b):
    """the 80-bit extended sample rate of an AIFF COMM chunk"""
    e = struct.unpack(">H", b[:2])[0]; m = struct.unpack(">Q", b[2:10])[0]
    return m * 2.0 ** ((e & 0x7fff) - 16383 - 63)


class Audio:
    """format, sample width, channels, rate, and the data span [start, end)"""
    def __init__(self, path):
        self.path = pathlib.Path(path); b = self.path.read_bytes(); self.raw = b
        if b[:4] == b"RIFF" and b[8:12] == b"WAVE":
            self.kind, self.big = "wav", False
            for cid, off, size in _chunks_riff(b):
                if cid == b"fmt ":
                    tag, ch, rate, _, _, bits = struct.unpack("<HHIIHH", b[off:off + 16])
                    self.ch, self.rate, self.width = ch, rate, bits // 8
                elif cid == b"data":
                    self.start, self.end = off, off + size
        elif b[:4] == b"FORM" and b[8:12] == b"AIFF":
            self.kind, self.big = "aif", True
            for cid, off, size in _chunks_form(b):
                if cid == b"COMM":
                    ch, nfr, bits = struct.unpack(">hIh", b[off:off + 8])
                    self.ch, self.width, self.rate = ch, bits // 8, _ext80(b[off + 8:off + 18])
                elif cid == b"SSND":
                    o, _ = struct.unpack(">II", b[off:off + 8])
                    self.start, self.end = off + 8 + o, off + size
        else:
            raise ValueError(f"{path}: not RIFF/WAVE or FORM/AIFF")
        self.end = min(self.end, len(b))
        self.n = (self.end - self.start) // (self.width * self.ch)

    def samples(self, max_seconds=None):
        w, big = self.width, self.big
        end = self.end if max_seconds is None else min(self.end, self.start + int(max_seconds * self.rate) * w * self.ch)
        d = self.raw[self.start:end]
        if w == 2:
            return [v / 32768.0 for v in struct.unpack(("> " if big else "<")[0] + f"{len(d) // 2}h", d)]
        if w == 3:
            order = "big" if big else "little"
            return [int.from_bytes(d[i:i + 3], order, signed=True) / 8388608.0 for i in range(0, len(d) - 2, 3)]
        raise ValueError(f"{self.path}: {w * 8}-bit")

    def scaled(self, gain_lin):
        """the whole file with the data chunk scaled, every other byte as is"""
        w, big = self.width, self.big
        d = bytearray(self.raw)
        full = (1 << (8 * w - 1)) - 1
        order = "big" if big else "little"
        for i in range(self.start, self.end - w + 1, w):
            v = int.from_bytes(d[i:i + w], order, signed=True)
            v = int(round(v * gain_lin))
            v = max(-full - 1, min(full, v))
            d[i:i + w] = v.to_bytes(w, order, signed=True)
        return bytes(d)


def measure(a, max_seconds=90):
    s = a.samples(max_seconds)
    if not s:
        return -99.0, -99.0
    pk = max(abs(v) for v in s)
    W = WIN * a.ch
    act = []
    for i in range(0, len(s) - W + 1, W):
        r = math.sqrt(sum(v * v for v in s[i:i + W]) / W)
        if r > 1e-3:
            act.append(r * r)
    arms = math.sqrt(sum(act) / len(act)) if act else 0.0
    db = lambda x: 20 * math.log10(x) if x > 0 else -99.0
    return db(pk), db(arms)


# ---- the project ----------------------------------------------------------------
def samples_of(pdir):
    raw = (pdir / "project.work").read_bytes().decode("latin1")
    out = []
    for m in re.finditer(r"\[SAMPLE\](.*?)(?=\r?\n\[|\Z)", raw, flags=re.S):
        d = dict(re.findall(r"(\w+)=([^\r\n]*)", m.group(1)))
        if d.get("PATH"):
            out.append(d)
    return out


def part_gains(pdir):
    vol, lev = {}, {}
    for f in sorted(pdir.glob("bank??.work")):
        b = f.read_bytes()
        for p in range(NPARTS_ALL):
            base = PART_BASE + PART_STRIDE * p
            for t in range(8):
                vol.setdefault(t + 1, {}).setdefault(b[base + P1_OFF + 24 * t + AMP_VOL], 0)
                vol[t + 1][b[base + P1_OFF + 24 * t + AMP_VOL]] += 1
                lev.setdefault(t + 1, {}).setdefault(b[base + LEVEL_OFF + 2 * t], 0)
                lev[t + 1][b[base + LEVEL_OFF + 2 * t]] += 1
    return vol, lev


def cmd_scan(pdir):
    rows = []
    for d in samples_of(pdir):
        f = pdir / d["PATH"]
        try:
            a = Audio(f); pk, ar = measure(a)
            rows.append((d["TYPE"], int(d["SLOT"]), int(d.get("GAIN", 48)), a.kind, a.width * 8, a.ch, pk, ar, d["PATH"]))
        except Exception as e:
            rows.append((d["TYPE"], int(d["SLOT"]), int(d.get("GAIN", 48)), "?", 0, 0, -99, -99, f"{d['PATH']}  ({e})"))
    print(f"{'type':6} {'slot':4} {'GAIN':>4} {'dB':>5}  fmt      {'peak':>6} {'active':>7}  path")
    for r in rows:
        print(f"{r[0]:6} {r[1]:4d} {r[2]:4d} {(r[2] - 48) / 2:+5.1f}  {r[3]}{r[4]:2d}b{r[5]}ch {r[6]:6.1f} {r[7]:7.1f}  {r[8]}")
    pks = sorted(r[6] for r in rows if r[4]); ars = sorted(r[7] for r in rows if r[4])
    if pks:
        print(f"\n{len(pks)} files: peak median {pks[len(pks) // 2]:.1f} dBFS (min {pks[0]:.1f}), "
              f"active median {ars[len(ars) // 2]:.1f} (min {ars[0]:.1f}); "
              f"{sum(1 for p in pks if p < -12)} peak under -12, {sum(1 for p in ars if p < -20)} active under -20")
    vol, lev = part_gains(pdir)
    print("\nAMP VOL (64 = 0 dB) by track over every part record: " +
          "  ".join(f"T{t}:" + ",".join(f"{v}x{n}" for v, n in sorted(vol[t].items())) for t in range(1, 8)))
    print("LEVEL (108 = 0 dB) by track:                          " +
          "  ".join(f"T{t}:" + ",".join(f"{v}x{n}" for v, n in sorted(lev[t].items())) for t in range(1, 9)))
    return rows


def cmd_normalize(src, dest, target, peakcap, level, ampvol):
    if dest.exists():
        sys.exit(f"{dest} exists -- refusing to overwrite a project")
    shutil.copytree(src, dest)
    raw = (dest / "project.work").read_bytes().decode("latin1")
    report = [f"# {dest.name}: levelled from {src.name} (target active {target} dBFS, peak cap {peakcap} dBFS, LEVEL {level})\n",
              "| slot | file | was peak / active | gain | now peak / active | GAIN was | heard level shift |", "|---|---|---|---|---|---|---|"]
    done = {}
    for d in samples_of(dest):
        path = d["PATH"]
        local = path
        if path.startswith(".."):
            local = pathlib.Path(path).name
            if not (dest / local).exists():
                shutil.copy2(src / path, dest / local)
        if local not in done:
            a = Audio(dest / local); pk, ar = measure(a)
            g = min(target - ar, peakcap - pk)
            (dest / local).write_bytes(a.scaled(10 ** (g / 20)))
            a2 = Audio(dest / local); pk2, ar2 = measure(a2)
            done[local] = (pk, ar, g, pk2, ar2)
        pk, ar, g, pk2, ar2 = done[local]
        was_gain = (int(d.get("GAIN", 48)) - 48) / 2.0        # the attribute's dB
        shift = g - was_gain                                   # what the ear will hear, this slot
        report.append(f"| {d['TYPE']} {int(d['SLOT'])} | {local} | {pk:.1f} / {ar:.1f} | {g:+.1f} dB | {pk2:.1f} / {ar2:.1f} | {was_gain:+.1f} dB | {shift:+.1f} dB |")
        # GAIN -> 48 and the path local, on the section whose TYPE, SLOT and
        # PATH match (SLOT numbers repeat across types)
        for m in re.finditer(r"\[SAMPLE\]((?:(?!\[SAMPLE\]).)*?)(?=\r?\n\[|\Z)", raw, flags=re.S):
            body = m.group(1)
            if f"TYPE={d['TYPE']}" in body and re.search(rf"SLOT={int(d['SLOT']):03d}\b", body) and f"PATH={path}" in body:
                new = body.replace(f"PATH={path}", f"PATH={local}")
                new = re.sub(r"GAIN=\d+", "GAIN=48", new)
                raw = raw[:m.start(1)] + new + raw[m.end(1):]
                break
    (dest / "project.work").write_bytes(raw.encode("latin1"))
    # every part record's LEVEL, every bank
    nb = 0
    for f in sorted(dest.glob("bank??.work")):
        b = bytearray(f.read_bytes())
        for p in range(NPARTS_ALL):
            base = PART_BASE + PART_STRIDE * p
            for t in range(8):
                b[base + LEVEL_OFF + 2 * t] = level
            for t in range(7):                       # T8's row is the master's, not decoded
                at = base + P1_OFF + 24 * t + AMP_VOL
                if b[at] != 0:                       # 0 = a track silenced on purpose: kept
                    b[at] = ampvol
        chk = sum(b[0x10:-2]) & 0xFFFF
        b[-2:] = struct.pack(">H", chk)
        f.write_bytes(bytes(b)); nb += 1
    report.append(f"\n{len(done)} files rewritten, GAIN 48 on {len(samples_of(dest))} sample slots, LEVEL {level} on 8 tracks and AMP VOL {ampvol} on T1-7 (a 0 kept) in {NPARTS_ALL} part records x {nb} banks.")
    (dest / "LEVELS.md").write_text("\n".join(report) + "\n")
    print("\n".join(report))


def main():
    import argparse
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan"); s.add_argument("project")
    n = sub.add_parser("normalize"); n.add_argument("src"); n.add_argument("dest")
    n.add_argument("--target", type=float, default=-18.0); n.add_argument("--peak", type=float, default=-1.0)
    n.add_argument("--level", type=int, default=108); n.add_argument("--ampvol", type=int, default=64)
    a = ap.parse_args()
    if a.cmd == "scan":
        cmd_scan(pathlib.Path(a.project))
    else:
        cmd_normalize(pathlib.Path(a.src), pathlib.Path(a.dest), a.target, a.peak, a.level, a.ampvol)


if __name__ == "__main__":
    main()
