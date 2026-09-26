#!/usr/bin/env python3
"""USB AUDIO OUT under the ColdFire port: host audio on EP3 OUT reaches core
0's RX blocks as inputs A-D, and closing the stream gives A-D back to the
jacks.

The bench plays the host: it enumerates, opens interface 4 alt 1 (the input
stream, the implicit-feedback source) and interface 5 alt 1, then each poll
sends one OUT packet carrying as many frames as the previous IN packet did --
what implicit feedback asks of a host. The IN poll and the OUT packet are
queued TOGETHER so the port serves both in one 250 us slot, as a host's
microframe does: issued one after the other, each costs the bench a slot of
device time, the device runs two frames' worth per host packet, and both
rings fail for the bench's reasons (measured 26 Sep 2026: 1.39 state-7
visits per poll against 0.692 pipelined; the unit runs 0.689). Every OUT sample is coded: v = ch << 20 | frame
(ch 0..3 = host channels 1..4 = inputs A..D, frame = a running count), so a
DSP word says which channel and which frame it came from.

  run 1 (streaming): hang up while the stream is running; the RX ring's
    completed blocks must hold the coded samples in DSP slot order (slot 0/1
    = C/D, 2/3 = A/B), bit-exact (default GAIN = unity, gate open),
    consecutive frames, and so must the recorder's input ring.
  run 2 (closed): alt 0 on interface 5, then keep the input stream running;
    the stream flag must be clear and the RX blocks the jacks' (silence
    under the port).

Needs the port (make emu-cf), a built image carrying USB AUDIO OUT, and the
linked runtime (out/platform/runtime/runtime.elf) for the unit's addresses.
"""
import os
import pathlib
import re
import shutil
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import toolpath  # noqa: E402,F401
from harness import usb_host  # noqa: E402

EMU = ROOT / "out/emu/ot_emu"
IMAGE = ROOT / "out/mainos_bus.bin"
ELF = ROOT / "out/platform/runtime/runtime.elf"
COUNTERS = ("produced", "consumed", "pkts", "lastn", "lastfill", "underruns",
            "overruns", "reprimes", "bad", "frames", "seconds", "minfill", "maxfill",
            "err", "partial", "errmask", "lasttok", "lastslot")
fails = []


def check(what, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {what}{'  ' + str(detail) if detail else ''}")
    if not ok:
        fails.append(what)


def symbols():
    nm = shutil.which("m68k-elf-nm") or shutil.which("m68k-linux-gnu-nm")
    out = subprocess.run([nm, str(ELF)], capture_output=True, text=True).stdout
    return {p[2]: int(p[0], 16) for p in (l.split() for l in out.splitlines()) if len(p) == 3}


def coded(ch, frame):
    return (ch << 20) | (frame & 0xFFFFF)


def packet(frame0, n):
    """n frames from frame0, 4 channels, 24 bits in the top of 4-byte LE subslots."""
    b = bytearray()
    for f in range(frame0, frame0 + n):
        for ch in range(4):
            v = coded(ch, f)
            b += bytes((0, v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF))
    return bytes(b)


def replies(b, n):
    """The next n reply lines, in order (Bench.wait would drop the other one)."""
    out = []
    while len(out) < n:
        i = b.buf.find(b"\n")
        if i >= 0:
            out.append(b.buf[:i].decode())
            b.buf = b.buf[i + 1:]
            continue
        chunk = b.sock.recv(65536)
        if not chunk:
            raise RuntimeError("bench closed the socket")
        b.buf += chunk
    return out


def vendor(b):
    """USB AUDIO OUT's counters over its vendor request (0xc0/0x56)."""
    raw = b.ctrl_in(0xc0, 0x56, 0, 0, 4 * len(COUNTERS))
    if len(raw) != 4 * len(COUNTERS):
        raise RuntimeError(f"vendor 0x56: {len(raw)} bytes")
    return dict(zip(COUNTERS, struct.unpack(f">{len(COUNTERS)}I", raw)))


def run(tag, sym, packets, close_first):
    sock = f"/tmp/ot-usbout-{os.getpid()}-{tag}.sock"
    log = ROOT / f"out/verify_usb_out_{tag}.log"
    dump = ROOT / f"out/verify_usb_out_{tag}"
    dump.mkdir(parents=True, exist_ok=True)
    peek = "0:X:8100,576;0:X:202,1"
    mem = (f"{sym['out_counters']:#x},{4 * len(COUNTERS)}={dump}/counters.bin;"
           f"{sym['out_tx']:#x},8={dump}/tx.bin;0x80005660,2048={dump}/ring.bin")
    with open(log, "w") as lf:
        emu = subprocess.Popen([str(EMU), "--image", str(IMAGE), "--usb-host", sock,
                                "--usb-hold-ms", "300000", "--frame", "--dsp",
                                "--dsp-peek", peek, "--mem-dump", mem],
                               cwd=ROOT, stdout=lf, stderr=subprocess.STDOUT)
    try:
        b = usb_host.Bench(sock, timeout=120.0)
        usb_host.enumerate_device(b, hs=True)
        b.ctrl_nodata(0x01, 0x0b, 1, 4)                 # SET_INTERFACE 4 alt 1: input stream
        b.ctrl_nodata(0x01, 0x0b, 1, 5)                 # SET_INTERFACE 5 alt 1: output stream
        frame, sizes, empty, last_n = 0, set(), 0, 11
        snaps = []
        for k in range(packets):
            if k in (packets // 4, packets - packets // 4):
                snaps.append((k, vendor(b)))            # over EP0, as a host on the unit reads them
            pkt = packet(frame, last_n)
            frame += last_n
            b.sock.sendall(f"in 3 1024\nout 3 {pkt.hex()}\n".encode())
            for line in replies(b, 2):
                p = line.split()
                if p[0] == "err":
                    raise RuntimeError(line)
                if p[0] == "in":
                    last_n = (len(p[2]) // 2) // 80 if len(p) > 2 else 0
                    sizes.add(last_n)
                    empty += last_n == 0
        if close_first:
            b.ctrl_nodata(0x01, 0x0b, 0, 5)             # alt 0: output stream closed
            for _ in range(400):                        # 100 ms more of the input stream
                b.ep_in(3, 1024)
        b.sock.close()
    finally:
        emu.wait(timeout=600)
    txt = log.read_text()
    m = re.search(r"core 0 X:0x08100:((?: [0-9a-f]{6})+)", txt)
    rx = [int(v, 16) for v in m[1].split()] if m else []
    cur = re.search(r"core 0 X:0x00202: ([0-9a-f]{6})", txt)
    cur = int(cur[1], 16) if cur else None
    cnt = dict(zip(COUNTERS, struct.unpack(f">{len(COUNTERS)}I", (dump / "counters.bin").read_bytes())))
    tx = (dump / "tx.bin").read_bytes()
    ring = (dump / "ring.bin").read_bytes()
    return dict(frames=frame, sizes=sorted(sizes), empty=empty, rx=rx, cur=cur,
                cnt=cnt, tx=tx, ring=ring, log=log, snaps=snaps)


SLOT_CH = (2, 3, 0, 1)          # DSP slots 0..3 carry host channels C, D, A, B


def block_frame(words):
    """The first frame of a 64-word RX block if every word is the coded sample
    for its slot and consecutive frames, else None."""
    f0 = words[2] & 0xFFFFF                             # slot 2 = channel A (0)
    for s in range(16):
        for k in range(4):
            if words[4 * s + k] != coded(SLOT_CH[k], f0 + s):
                return None
    return f0


def main():
    if not EMU.is_file():
        print("  [SKIP] verify_usb_out: the port is not built (make emu-cf)")
        return 0
    if not ELF.is_file():
        print("  [FAIL] verify_usb_out: no linked runtime (build a remix with USB AUDIO OUT)")
        return 1
    sym = symbols()
    if "out_counters" not in sym:
        print("  [FAIL] verify_usb_out: the runtime has no USB AUDIO OUT unit")
        return 1

    print("== run 1: streaming ==")
    polls = int(os.environ.get("POLLS", "8000"))       # 2 s of device time
    r = run("stream", sym, polls, close_first=False)
    c = r["cnt"]
    print(f"  host: {r['frames']} frames in {polls} polls, IN packet sizes {r['sizes']} frames, {r['empty']} empty IN polls")
    print(f"  device counters: {c}")
    (k0, s0), (k1, s1) = r["snaps"]
    rate = (s1["frames"] - s0["frames"]) / (k1 - k0)
    check("vendor request 0x56 reads the counters back over EP0",
          s0["pkts"] <= s1["pkts"] <= c["pkts"] and s1["frames"] > s0["frames"], f"{s0['pkts']} -> {s1['pkts']} pkts")
    check("state 7 runs once per 16-sample frame: 0.689 per 250 us poll (between the two reads)",
          abs(rate - 0.689) < 0.01 and abs(c["frames"] - c["seconds"]) <= 1,
          f"{rate:.4f} per poll; first {c['frames']} / second {c['seconds']} visits")
    print(f"  OUT fill while consuming: min {c['minfill']} max {c['maxfill']} (target 384)")
    check("every OUT packet retired, whole frames, no errors",
          c["pkts"] >= polls - 2 and c["bad"] == 0, f"pkts {c['pkts']} bad {c['bad']}")
    check("the ring took every frame the host sent (the last packet or two may be in flight)",
          0 <= r["frames"] - c["produced"] <= 24, f"produced {c['produced']} sent {r['frames']}")
    check("no underrun after the cushion filled, no overrun, no re-prime",
          c["underruns"] == 0 and c["overruns"] == 0 and c["reprimes"] == 0,
          f"underruns {c['underruns']} overruns {c['overruns']} reprimes {c['reprimes']}")
    check("the stream flag is set", len(r["tx"]) >= 4 and (r["tx"][2] << 8 | r["tx"][3]) & 0x100,
          r["tx"][:4].hex())
    if r["rx"] and r["cur"] is not None:
        cb = (r["cur"] - 0x8100) // 64
        got = []
        for back in range(7):                           # the completed blocks, newest first
            blk = (cb - back) % 9
            got.append(block_frame(r["rx"][blk * 64:(blk + 1) * 64]))
        print(f"  RX blocks, newest first: first frames {got}")
        check("the 7 completed RX blocks hold the host's samples, slot order C D A B, bit-exact",
              all(g is not None for g in got), str(got))
        ok = all(g is not None for g in got) and all(a - b == 16 for a, b in zip(got, got[1:]))
        check("... in consecutive frames (no drop, no repeat)", ok)
    else:
        check("the port printed the RX ring", False)
    # the recorder's input ring: 8 frames, slots 0/1 in the first 128 B, 2/3 in the second
    rf = []
    for fr in range(8):
        w = struct.unpack(">64i", r["ring"][fr * 256:(fr + 1) * 256])
        f0 = (w[32] >> 8) & 0xFFFFF                     # slot 2 = A, sample 0
        ok = all((w[2 * s] >> 8) == coded(2, f0 + s) and (w[2 * s + 1] >> 8) == coded(3, f0 + s) and
                 (w[32 + 2 * s] >> 8) == coded(0, f0 + s) and (w[32 + 2 * s + 1] >> 8) == coded(1, f0 + s)
                 for s in range(16))
        rf.append(f0 if ok else None)
    print(f"  recorder input ring frames: {rf}")
    check("the recorder's input ring carries them too (8 frames exact)", all(x is not None for x in rf))

    print("== run 2: output stream closed ==")
    r2 = run("closed", sym, 2000, close_first=True)
    print(f"  device counters: {r2['cnt']}")
    check("the stream flag is clear after alt 0", len(r2["tx"]) >= 4 and not ((r2["tx"][2] << 8 | r2["tx"][3]) & 0x100),
          r2["tx"][:4].hex())
    rx2 = r2["rx"]
    if rx2 and r2["cur"] is not None:
        cb = (r2["cur"] - 0x8100) // 64
        blks = [rx2[((cb - back) % 9) * 64:((cb - back) % 9 + 1) * 64] for back in range(7)]
        coded_left = sum(1 for bl in blks if block_frame(bl) is not None)
        check("the RX blocks are the jacks' again (no host samples in the 7 completed blocks)",
              coded_left == 0, f"{coded_left} coded block(s)")
    print(f"verify_usb_out: {'OK' if not fails else f'{len(fails)} FAILED'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
