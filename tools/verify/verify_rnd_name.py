#!/usr/bin/env python3
"""RND NAME under the port: FUNC+CUE fills YYMMDD + pool words.

    python3 tools/verify/verify_rnd_name.py REMIX [--project DIR]

Checks three project-name editors under `--mkii` with a pinned RTC:

1. CREATE EMPTY PROJECT (NAME THE NEW PROJECT) — live-script path
2. SAVE PROJECT AS… — PROJECT > SAVE TO NEW
3. CHOOSE NEW PROJECT NAME — PROJECT > EXPORT TO SET > YES > YES

Each asserts `YYMMDD ` (pinned RTC) plus a joined pool name, and that the
fill fits the editor's ED_MAX. A second chord on CREATE must also be a
dated pool join.

SKIPs without the port or a project.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import struct
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import toolpath  # noqa: E402,F401
from remix import registry  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
EMU = ROOT / "out/emu/ot_emu"
PY = ROOT / ".venv/bin/python3"
OUT = ROOT / "out/rndname_verify"
BUF, CB, WIN, DISP = 0x460E436A, 0x460E761A, 0x460E7612, 0x460E743C
BUF_PTR = 0x460E761E
ED_MAX = 0x400D0730
CREATE_CB = 0x400644F0
SAVEAS_CB = 0x40063D30
CHOOSE_CB = 0x40063B00

POOL_A = ('FOG', 'DUB', 'DARK', 'COLD', 'DRONE', 'SLEEP', 'WARE', 'ECHO', 'VOID', 'SUB', 'LATE', 'GRID', 'SOFT', 'DEEP', 'SLOW', 'MIST', 'RAW', 'WET', 'DRY', 'LOW', 'HI', 'DIM', 'WARM', 'THIN', 'THICK', 'SHARP', 'BLUNT', 'FAST', 'IDLE', 'LOUD', 'MUTE', 'NOISE', 'GLASS', 'IRON', 'RUST', 'DUST', 'ASH', 'SMOKE', 'STEAM', 'ICE', 'STONE', 'CLAY', 'BONE', 'WIRE', 'TAPE', 'FILM', 'VHS', 'CRT', 'NEON', 'ACID', 'BASE', 'PHASE', 'PULSE', 'SWEEP', 'GLIDE', 'SNAP', 'CLICK', 'THUMP', 'RUMBLE', 'CRACK', 'BLEED', 'GHOST', 'SHADOW', 'TRACE')
POOL_B = ('BED', 'LOOP', 'WASH', 'TAPE', 'CHAIN', 'VERB', 'SCENE', 'LOCK', 'HUM', 'PAD', 'GATE', 'YARD', 'HAZE', 'DRIFT', 'POOL', 'STEM', 'HIT', 'KICK', 'SNAR', 'CLAP', 'HAT', 'TOM', 'RIM', 'CLICK', 'BASS', 'LEAD', 'ARP', 'SEQ', 'FX', 'BUS', 'SEND', 'RET', 'ROOM', 'HALL', 'PLATE', 'SPRING', 'CAB', 'AMP', 'PEDAL', 'RACK', 'TAKE', 'CLIP', 'SHOT', 'PASS', 'RUN', 'CUE', 'DROP', 'RISE', 'SLOT', 'BANK', 'PART', 'PATT', 'KIT', 'SET', 'DIR', 'FILE', 'WAVE', 'BUF', 'RING', 'CORE', 'NODE', 'PORT', 'LANE', 'TRACK')
POOL = {a + b for a in POOL_A for b in POOL_B}
# 2026-10-14 12:00:00 UTC — --rtc Fixed epoch for a stable prefix
RTC_EPOCH = 1791979200
DATE_PREFIX = "261014 "


def tap(code: int, t: int, gap: int = 500):
    return [f"{t} key {code:#x} down", f"{t + 30} key {code:#x} up"], t + gap


def chord_func_cue(t: int, gap: int = 800):
    """FUNC hold, CUE tap, FUNC release — Digitakt SETTINGS analog on OT."""
    return [
        f"{t} key 0x2d down",
        f"{t + 80} key 0x2a down",
        f"{t + 120} key 0x2a up",
        f"{t + 200} key 0x2d up",
    ], t + gap


def cstr(raw: bytes) -> str:
    return raw.split(b"\x00", 1)[0].decode("ascii", "replace")


def assert_dated_pool(name: str, label: str, ed_max: int, log: pathlib.Path) -> None:
    if not name.startswith(DATE_PREFIX):
        sys.exit(f"verify_rnd_name: {label} buffer {name!r} missing date "
                 f"prefix {DATE_PREFIX!r} -- {log}")
    tail = name[len(DATE_PREFIX):]
    if tail not in POOL:
        sys.exit(f"verify_rnd_name: {label} buffer {name!r} tail {tail!r} "
                 f"not a pool join -- {log}")
    if ed_max and len(name) > ed_max:
        sys.exit(f"verify_rnd_name: {label} buffer {name!r} len {len(name)} "
                 f"> ED_MAX {ed_max} -- {log}")


def check_create(image: pathlib.Path, card: pathlib.Path, set_name: str,
                 name: str) -> str:
    """CREATE EMPTY PROJECT via the measured live-script path. Returns fill."""
    lines, tt = [], 2000
    # NO, PROJ, YES, YES, UP, YES -> NAME THE NEW PROJECT (brain pset_new path)
    for code, gap in ((0x32, 400), (0x1c, 1000), (0x31, 1000), (0x31, 1000),
                      (0x33, 600), (0x31, 1400)):
        l, tt = tap(code, tt, gap)
        lines += l
    l, tt = chord_func_cue(tt)
    lines += l
    dump1 = OUT / "name1.bin"
    lines.append(f"{tt} quit")
    script = OUT / "create1.script"
    script.write_text("\n".join(lines) + "\n")
    log = OUT / "create1.txt"
    dumps = (f"{BUF:#x},32={dump1};{CB:#x},4={OUT / 'cb.bin'};"
             f"{WIN:#x},4={OUT / 'win.bin'};{DISP:#x},32={OUT / 'disp.bin'};"
             f"{ED_MAX:#x},4={OUT / 'edmax.bin'}")

    def run_script(script_path, log_path, mem_dump):
        cmd = [str(EMU), "--image", str(image), "--card", str(card),
               "--set", set_name, "--project", name, "--load-ms", "90000",
               "--mkii", "--rtc", str(RTC_EPOCH),
               "--live-script", str(script_path), "--mem-dump", mem_dump]
        with open(log_path, "w") as fh:
            return subprocess.run(cmd, cwd=ROOT, stdout=fh, stderr=subprocess.STDOUT)

    r = run_script(script, log, dumps)
    text = log.read_text()
    if r.returncode or "ended on quit" not in text:
        sys.exit(f"verify_rnd_name: create1 run did not finish -- {log}")

    cb = struct.unpack(">I", (OUT / "cb.bin").read_bytes())[0]
    win = struct.unpack(">I", (OUT / "win.bin").read_bytes())[0]
    ed_max = struct.unpack(">I", (OUT / "edmax.bin").read_bytes())[0]
    filled = cstr(dump1.read_bytes())
    if cb != CREATE_CB:
        sys.exit(f"verify_rnd_name: editor callback {cb:#x}, want create "
                 f"{CREATE_CB:#x} (name editor not open?) -- {log}")
    if win == 0:
        sys.exit(f"verify_rnd_name: name-editor window handle is 0 -- {log}")
    assert_dated_pool(filled, "CREATE", ed_max, log)
    # Cold seed used to take only tempo^clock^K and the low 6 LCG bits:
    # at 120 BPM with the clock stopped that was always FOGRET.
    if filled[len(DATE_PREFIX):] == "FOGRET":
        sys.exit(f"verify_rnd_name: CREATE still draws FOGRET ({filled!r}) "
                 f"-- cold-seed / low-bit bias -- {log}")
    print(f"  [PASS] verify_rnd_name: FUNC+CUE -> {filled!r} "
          f"(CREATE editor open, ED_MAX={ed_max})")

    # Second chord: different name.
    lines, tt = [], 2000
    for code, gap in ((0x32, 400), (0x1c, 1000), (0x31, 1000), (0x31, 1000),
                      (0x33, 600), (0x31, 1400)):
        l, tt = tap(code, tt, gap)
        lines += l
    l, tt = chord_func_cue(tt)
    lines += l
    l, tt = chord_func_cue(tt + 200)
    lines += l
    dump2 = OUT / "name2.bin"
    lines.append(f"{tt} quit")
    script2 = OUT / "create2.script"
    script2.write_text("\n".join(lines) + "\n")
    log2 = OUT / "create2.txt"
    r = run_script(script2, log2, f"{BUF:#x},32={dump2}")
    if r.returncode or "ended on quit" not in log2.read_text():
        sys.exit(f"verify_rnd_name: create2 run did not finish -- {log2}")
    name2 = cstr(dump2.read_bytes())
    assert_dated_pool(name2, "CREATE#2", ed_max, log2)
    if name2 == filled:
        print(f"  [PASS] verify_rnd_name: second FUNC+CUE -> {name2!r} "
              f"(same as first; rare)")
    else:
        print(f"  [PASS] verify_rnd_name: second FUNC+CUE -> {name2!r} (changed)")
    return filled


def check_saveas_choose(image: pathlib.Path, card: pathlib.Path,
                        set_name: str, project: str, export_row: int = 5) -> None:
    """SAVE PROJECT AS and CHOOSE NEW PROJECT NAME under MenuPort."""
    sys.path.insert(0, str(ROOT / "tools" / "verify"))
    sys.path.insert(0, str(ROOT / "tools" / "panel"))
    from stems_panel import MenuPort  # noqa: E402
    from panel_server import popup_geometry  # noqa: E402

    log = OUT / "menu.txt"

    def menu_proj_row(p, row: int) -> None:
        # Selectable PROJECT rows skip separators: CHANGE=0 … SAVE TO NEW=4,
        # EXPORT TO SET=5 (MAINMENU.md). COPY PROJECT used to insert at 5 and
        # push EXPORT to 6; since #931 it lives on CHANGE→FUNC+BANK instead.
        if popup_geometry(p.rt.uc) != (5, 0, 0xf6, 0x40):
            p.open_menu()
        p.press("left", settle=80)
        for _ in range(5):
            p.press("up", settle=40)
        p.press("right", settle=120)
        for _ in range(20):
            p.press("up", settle=30)
        for _ in range(row):
            p.press("down", settle=60)
        p.press("yes", settle=500)

    def chord(p) -> None:
        p.key("func", True)
        p.run(100)
        p.press("cue", settle=80)
        p.key("func", False)
        p.run(400)

    def read_editor(p):
        cb = p.long(CB)
        win = p.long(WIN)
        bptr = p.long(BUF_PTR)
        ed_max = p.long(ED_MAX)
        name = p.cstr(bptr, 32) if bptr else ""
        return cb, win, ed_max, name

    with MenuPort(image.resolve(), card.resolve(), set_name, project, True,
                  log_path=log, extra=("--rtc", str(RTC_EPOCH))) as p:
        p.settle()

        # SAVE TO NEW -> SAVE PROJECT AS…
        menu_proj_row(p, 4)
        p.run(600)
        cb, win, ed_max, name = read_editor(p)
        if cb != SAVEAS_CB or win == 0:
            sys.exit(f"verify_rnd_name: SAVEAS editor not open "
                     f"(cb={cb:#x} win={win:#x}) -- {log}")
        chord(p)
        cb, win, ed_max, name = read_editor(p)
        assert_dated_pool(name, "SAVEAS", ed_max, log)
        print(f"  [PASS] verify_rnd_name: FUNC+CUE -> {name!r} "
              f"(SAVEAS editor open, ED_MAX={ed_max})")

        for _ in range(3):
            p.press("no", settle=300)
        p.run(400)  # dismiss residual SAVEAS chrome before re-entering PROJECT

        # EXPORT TO SET -> YES -> YES -> CHOOSE NEW PROJECT NAME
        menu_proj_row(p, export_row)
        p.run(600)
        for step in range(4):
            p.press("yes", settle=400)
            p.run(200)
            cb, win, ed_max, name = read_editor(p)
            if cb == CHOOSE_CB and win:
                break
        else:
            sys.exit(f"verify_rnd_name: CHOOSE editor not open "
                     f"(cb={cb:#x} win={win:#x}) -- {log}")
        chord(p)
        cb, win, ed_max, name = read_editor(p)
        if cb != CHOOSE_CB or win == 0:
            sys.exit(f"verify_rnd_name: CHOOSE editor lost after chord "
                     f"(cb={cb:#x} win={win:#x}) -- {log}")
        assert_dated_pool(name, "CHOOSE", ed_max, log)
        print(f"  [PASS] verify_rnd_name: FUNC+CUE -> {name!r} "
              f"(CHOOSE editor open, ED_MAX={ed_max})")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("remix", nargs="?", default=os.environ.get("REMIX"))
    default_proj = str(ROOT / "template_project/!DEF_N1")
    ap.add_argument("--project", default=os.environ.get("OT_PROJECT", default_proj))
    ap.add_argument("--set-name", default="OCTABAM")
    ap.add_argument("--name", default="PNR")
    a = ap.parse_args()
    remix = registry.remix(a.remix)
    if "RND NAME" not in remix.modules:
        print(f"  [ -- ] verify_rnd_name: {a.remix} carries no RND NAME")
        return 0
    if not EMU.is_file():
        print("  [SKIP] verify_rnd_name: no port binary (make emu-cf)")
        return 0
    pdir = pathlib.Path(a.project).expanduser()
    if not (pdir / "project.work").is_file():
        # OT_PROJECT=. (or another non-project cwd) is common in agent shells;
        # fall back to the repo template so the gate still runs.
        fallback = pathlib.Path(default_proj)
        if (fallback / "project.work").is_file():
            pdir = fallback
        else:
            print(f"  [SKIP] verify_rnd_name: no project at {a.project}")
            return 0

    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, REMIX=a.remix, XBUS="1", SPEC="1")
    env.setdefault("BUILD", "0")
    image = OUT / "mainos.bin"
    r = subprocess.run([sys.executable, str(ROOT / "tools/build/build_bus.py")],
                       env=env, capture_output=True, text=True, cwd=ROOT)
    if r.returncode:
        sys.exit(f"verify_rnd_name: build failed:\n{(r.stdout + r.stderr)[-1500:]}")
    image.write_bytes((ROOT / "out/mainos_bus.bin").read_bytes())

    # Static: FUNC-held keys pointer was rewritten off stock 0x400d0916.
    img = image.read_bytes()
    ptr = struct.unpack_from(">I", img, 0x400D08F2 - 0x40000400)[0]
    if not (0x40A00000 <= ptr < 0x4F000000):
        sys.exit(f"verify_rnd_name: 0x400d08f2 still {ptr:#x}, want DRAM rnd_func_keys")
    print(f"  [PASS] verify_rnd_name: name-editor FUNC keys -> {ptr:#x}")

    card, tree = OUT / "card.img", OUT / "tree"
    r = subprocess.run(
        [str(PY), str(ROOT / "tools/emu/ot_emu/stage_card.py"),
         str(pdir), a.set_name, a.name, "--tree", str(tree), "--out", str(card)],
        cwd=ROOT, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"verify_rnd_name: stage_card failed:\n{r.stdout[-800:]}{r.stderr[-800:]}")

    check_create(image, card, a.set_name, a.name)
    # EXPORT TO SET is stock index 5; COPY PROJECT no longer grows PROJECT (#931).
    check_saveas_choose(image, card, a.set_name, a.name, export_row=5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
