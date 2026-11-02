#!/usr/bin/env python3
"""LOAD METER's figures over USB under the ColdFire port: the vendor request
0xc0/0x57 (modules/usb/usbaudio.s) returns lm_stats, lm_dsp and lm_ot as the
meter holds them.

Boots out/mainos_bus.bin with both DSP cores and the frame interrupt
(`--dsp --frame`, no project), enumerates over the scripted host and reads
the three blocks twice, a second of port time apart. Checks:

  blocks     wValue 0, 1, 2 read whole through wIndex offsets (20, 48 and 256 bytes); no reply is a
             multiple of 64 bytes; an offset at the end and wValue 4 STALL; wValue 3 is DLPUMP's counters when the remix has it, else STALLs
  probes     with FRAME PROFILE (USB_PROBES), or LOAD METER in a probes remix (USB_TESTCMD): wValue 4 is BRAIN's
             task ledger (96 bytes, sent 95 then 1); with FRAME PROFILE wValue 5 is its window (96 bytes, its
             seq rising) and wValue 6 STALLs, without it wValue 5 STALLs; with REC MATRIX as well,
             the test command 0xc0/0x58 reads recorder 1's mask, writes one, reads it back over USB and as the
             long in DRAM the mixer reads (rmx_mask_ptr's first entry), restores it, and STALLs for recorder 9.
             0xc0/0x59 reads RAM as the port's peek (the UI descriptor, the screen's plane in five reads), never
             replies a multiple of 64 and STALLs outside RAM or across a region's end. In any other image
             0xc0/0x58 and 0xc0/0x59 STALL
  match      lm_stats read over USB equals the same words peeked from DRAM at
             the symbol's address (runtime.elf), so the request points at the
             meter's cells and not at a neighbour
  advance    lm_stats seq and lm_dsp seq rise between the reads
  window     lm_stats window is 0.5 s of DMA timer 3 (66,000,000 counts) within 2%
  isr        sum <= window, 0 < longest <= window, count > 0
  dsp        both cores' period between 20,000 and 60,000 counts and busy <=
             period, no more than a few bad records
  slots      lm_ot has samples in at least one slot, each with last <= max

SKIPs when the remix has no USB or no LOAD METER, or the port is not built.
What it cannot see: the unit's timers (the port's timer 0 moves in
1,024-count steps and prices each instruction at one step), a project
playing, and the host stack of a real machine; see tools/hw/load_meter.py.
"""
import os
import pathlib
import shutil
import subprocess
import sys
import threading

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1])); import toolpath  # noqa: E402,F401
sys.path.insert(0, str(ROOT / "tools/hw"))
import load_meter  # noqa: E402
import usb_host  # noqa: E402  (tools/harness)

from remix import registry  # noqa: E402

EMU = ROOT / "out/emu/ot_emu"
IMAGE = ROOT / "out/mainos_bus.bin"
ELF = ROOT / "out/platform/runtime/runtime.elf"


def symbol(name):
    nm = shutil.which("m68k-elf-nm") or shutil.which("m68k-linux-gnu-nm")
    for line in subprocess.run([nm, str(ELF)], capture_output=True, text=True).stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == name:
            return int(parts[0], 16)
    raise RuntimeError(f"{name} not in {ELF}")


def main():
    if not EMU.is_file():
        print("  [SKIP] verify_usb_load_meter: the port is not built (make emu-cf)")
        return 0
    if not IMAGE.is_file():
        print("  [FAIL] verify_usb_load_meter: no out/mainos_bus.bin (make bus)")
        return 1
    rmx = registry.remix(os.environ.get("REMIX"))
    mods = rmx.modules
    if "USB" not in mods or "LOAD METER" not in mods:
        print("  [SKIP] verify_usb_load_meter: the remix has no USB or no LOAD METER")
        return 0
    sock = f"/tmp/ot-usblm-{os.getpid()}.sock"
    emu = subprocess.Popen([str(EMU), "--image", str(IMAGE), "--interactive", "--usb-host", sock,
                            "--main-level", "off", "--dsp", "--frame"],
                           cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, bufsize=1)
    fails = []

    def check(what, ok, detail=""):
        print(f"  [{'PASS' if ok else 'FAIL'}] {what}{'  ' + detail if detail else ''}")
        if not ok:
            fails.append(what)

    def reply():
        while True:
            line = emu.stdout.readline()
            if not line:
                raise RuntimeError("the port exited")
            if line.startswith(("ready", "ok", "err", "peek", "status")):
                return line.split()

    def cmd(c):
        emu.stdin.write(c + "\n")
        emu.stdin.flush()
        r = reply()
        if r[0] == "err":
            raise RuntimeError(f"{c}: {' '.join(r)}")
        return r

    def serve(fn):
        """Run a bench call on a thread while the port runs, as the enumeration does."""
        out = {}

        def t():
            try:
                out["v"] = fn()
            except Exception as e:  # noqa: BLE001
                out["e"] = e
        th = threading.Thread(target=t)
        th.start()
        while th.is_alive():
            cmd("run 20")
            th.join(0.01)
        if "e" in out:
            raise out["e"]
        return out["v"]

    def ctrl_for(b):
        return lambda w, off, n: bytes(serve(lambda: b.ctrl_in(0xc0, 0x57, w, off, n)))

    def blocks(b):
        c = ctrl_for(b)
        return [load_meter.read_block(c, w, n) for w, n in ((0, 20), (1, 48), (2, 256))]

    b = None
    try:
        reply()
        cmd("run 3000")
        res = {}

        def bench():
            res["b"] = usb_host.Bench(sock, timeout=60.0)
            usb_host.enumerate_device(res["b"], hs=True)
        th = threading.Thread(target=bench)
        th.start()
        while th.is_alive():
            cmd("run 50")
            th.join(0.01)
        b = res["b"]
        cmd("run 1500")
        first = blocks(b)
        check("blocks 0, 1, 2 read whole: 20, 48 and 256 bytes", [len(x) for x in first] == [20, 48, 256],
              str([len(x) for x in first]))
        c = ctrl_for(b)
        lens = {n: len(c(2, 0, n)) for n in (64, 128, 192, 256, 255, 100)}
        check("no reply is a multiple of 64 bytes (the next control request would return 0 bytes)",
              all(v % 64 for v in lens.values()) and lens[256] == 255 and lens[100] == 100, str(lens))
        check("wIndex resumes: the byte after a 255-byte reply is the block's last",
              c(2, 255, 1) == first[2][255:], f"{c(2, 255, 1).hex()} vs {first[2][255:].hex()}")
        try:
            c(0, 20, 4)
            check("an offset at the block's end STALLs", False, "a reply came back")
        except Exception as e:  # noqa: BLE001
            check("an offset at the block's end STALLs", True, type(e).__name__)
        probes = "FRAME PROFILE" in mods
        # USB_TESTCMD (modules/usb/manifest.py probes_inc): block 4 and 0xc0/0x58, 0x59 in a probes
        # remix with LOAD METER, FRAME PROFILE or not
        testcmd = ("LOAD METER" in mods and getattr(rmx, "family", None) == "probes") or probes

        def stalls(what, fn):
            try:
                serve(fn)
                check(f"{what} STALLs", False, "a reply came back")
            except Exception as e:  # noqa: BLE001
                check(f"{what} STALLs", True, type(e).__name__)
        if testcmd or probes:
            if "BRAIN" in mods:
                led = load_meter.read_block(c, 4, 96)
                check("wValue 4 is BRAIN's task ledger: 96 bytes", len(led) == 96, str(len(led)))
            else:
                stalls("wValue 4 (no BRAIN)", lambda: b.ctrl_in(0xc0, 0x57, 4, 0, 4))
        else:
            stalls("wValue 4", lambda: b.ctrl_in(0xc0, 0x57, 4, 0, 4))
        if probes:
            f1 = load_meter.read_block(c, 5, 96)
            cmd("run 1500")
            f2 = load_meter.read_block(c, 5, 96)
            seq = lambda raw: int.from_bytes(raw[:4], "big")
            check("wValue 5 is FRAME PROFILE's window: 96 bytes, its seq rising",
                  len(f1) == 96 and seq(f2) > seq(f1), f"seq {seq(f1)} -> {seq(f2)}")
            stalls("wValue 6", lambda: b.ctrl_in(0xc0, 0x57, 6, 0, 4))
        else:
            stalls("wValue 5 (no FRAME PROFILE)", lambda: b.ctrl_in(0xc0, 0x57, 5, 0, 4))
        mask = lambda rec, val=None: int.from_bytes(bytes(serve(lambda: b.ctrl_in(
            0xc0, 0x58, (val or 0) & 0xFFFF, rec | (0x100 if val is not None else 0), 4))), "big", signed=True)
        if testcmd and "REC MATRIX" in mods:
            ptr = int(cmd(f"peek {symbol('rmx_mask_ptr'):#x} 4")[1], 16)
            dram = lambda: int.from_bytes(bytes.fromhex(cmd(f"peek {ptr:#x} 4")[1]), "big", signed=True)
            was = mask(0)
            check("0xc0/0x58 reads recorder 1's mask as the long in DRAM", was == dram(), f"{was} vs {dram()}")
            got = mask(0, 0xC0C0)                        # CUE set: negative, as BRAIN keeps it
            check("0xc0/0x58 writes the mask, sign-extended, and replies it",
                  got == dram() == -0x3F40, f"reply {got}, dram {dram()}")
            mask(0, was & 0xFFFF)
            check("0xc0/0x58 restores the mask", dram() == was, f"{dram()} vs {was}")
            stalls("0xc0/0x58 for recorder 9", lambda: b.ctrl_in(0xc0, 0x58, 0, 8, 4))
        else:
            stalls("0xc0/0x58 (not a test image or no REC MATRIX)", lambda: b.ctrl_in(0xc0, 0x58, 0, 0, 4))
        peek = lambda addr, n: bytes(serve(lambda: b.ctrl_in(0xc0, 0x59, addr & 0xFFFF, addr >> 16, n)))
        if testcmd:
            desc = 0x400bf10a                            # the UI surface descriptor (docs/firmware/PANEL.md)
            got = peek(desc, 16)
            want = bytes.fromhex("".join(cmd(f"peek {desc + 4 * i:#x} 4")[1] for i in range(4)))
            check("0xc0/0x59 reads memory as the port's peek: the UI descriptor (128 x 64, 2 bpp)",
                  got == want and got[:4] == bytes.fromhex("00000080"), f"{got.hex()} vs {want.hex()}")
            plane = b"".join(peek(0x46c7e0ea + o, n) for o, n in ((0, 255), (255, 255), (510, 255), (765, 255),
                                                                    (1020, 4)))
            check("0xc0/0x59 reads the screen's plane whole (1,024 bytes in five reads)", len(plane) == 1024,
                  str(len(plane)))
            check("0xc0/0x59 never replies a multiple of 64 bytes", len(peek(0x40000400, 64)) == 63)
            stalls("0xc0/0x59 outside RAM (0xfc060000, a UART)", lambda: b.ctrl_in(0xc0, 0x59, 0x0000, 0xfc06, 4))
            stalls("0xc0/0x59 across the SRAM's end", lambda: b.ctrl_in(0xc0, 0x59, 0xfff0, 0x8000, 32))
        else:
            stalls("0xc0/0x59 (not a test image)", lambda: b.ctrl_in(0xc0, 0x59, 0x0400, 0x4000, 4))
        if "DLPUMP" in mods:               # block 3 is DLPUMP's counters: 16 longs, sent a byte short of 64
            check("wValue 3 returns DLPUMP's counters (63 bytes for a 64-byte request)",
                  len(serve(lambda: b.ctrl_in(0xc0, 0x57, 3, 0, 64))) == 63)
        else:
            try:
                serve(lambda: b.ctrl_in(0xc0, 0x57, 3, 0, 4))
                check("wValue 3 STALLs (no DLPUMP)", False, "a reply came back")
            except Exception as e:  # noqa: BLE001
                check("wValue 3 STALLs (no DLPUMP)", True, type(e).__name__)
        cmd("run 1000")
        second = blocks(b)
        a, c = load_meter.decode(*first), load_meter.decode(*second)

        stats_addr = symbol("lm_stats")
        peeked = bytes.fromhex("".join(cmd(f"peek {stats_addr + 4 * i:#x} 4")[1] for i in range(5)))
        # the unit moves on between the request and the peek: only seq may differ, and by one window at most
        sp, ss = load_meter.decode(peeked, first[1], first[2])["cf"], a["cf"]
        check("lm_stats over USB is the cell at lm_stats", 0 <= sp["seq"] - c["cf"]["seq"] <= 3 and
              abs(sp["window"] - ss["window"]) <= 0.02 * ss["window"], f"seq usb {c['cf']['seq']}, dram {sp['seq']}")
        check("lm_stats and lm_dsp seq rise between the reads",
              c["cf"]["seq"] > a["cf"]["seq"] and c["dsp"]["seq"] > a["dsp"]["seq"],
              f"stats {a['cf']['seq']} -> {c['cf']['seq']}, dsp {a['dsp']['seq']} -> {c['dsp']['seq']}")
        cf = c["cf"]
        check(f"window is 0.5 s of timer 3: {cf['window']}", abs(cf["window"] - 66_000_000) <= 0.02 * 66_000_000)
        check(f"isr: sum {cf['sum']} <= window, longest {cf['longest']}, count {cf['count']}",
              cf["sum"] <= cf["window"] and 0 < cf["longest"] <= cf["window"] and cf["count"] > 0)
        d = c["dsp"]
        ok = all(20000 <= d[k]["period"] <= 60000 and d[k]["busy"] <= d[k]["period"] for k in ("core0", "core1"))
        check(f"dsp: core 0 {d['core0']['busy']}/{d['core0']['period']}, core 1 {d['core1']['busy']}/{d['core1']['period']}; "
              f"bad {d['bad']} of {d['seq'] + d['bad']}", ok and d["bad"] <= 4 + d["seq"] // 100)
        live = [s for s in c["slots"] if s["count"]]
        check(f"lm_ot: {len(live)} slots sampled", bool(live) and all(s["last"] <= s["max"] for s in live))
    except Exception as e:  # noqa: BLE001 -- a hang or a stall is the finding
        check(f"the probe completed ({type(e).__name__}: {e})", False)
    finally:
        if b is not None:
            b.sock.close()
        try:
            cmd("quit")
            emu.wait(timeout=30)
        except Exception:  # noqa: BLE001
            emu.kill()
    print(f"verify_usb_load_meter: {'OK' if not fails else str(len(fails)) + ' FAILED'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
