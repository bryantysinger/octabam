"""Firmware-free checks of the MIDI CC numbers CC MAP reads and CC FEEDBACK
sends (issue #981): none is stateful, none collides with stock or another
module, CC FEEDBACK's table matches CC MAP's, and CC MAP's entry decodes
exactly those numbers."""
import importlib.util
import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
import toolpath  # noqa: E402,F401
from remix import midi_cc  # noqa: E402

HAS_UNICORN = importlib.util.find_spec("unicorn") is not None

# Stock's audio-track CCs (docs/firmware/MIDI.md section 1) and the CCs other
# modules read (modules/free-loop/README.md, modules/rec-trig-mute/README.md).
STOCK = {7, 8, *range(16, 62), *range(112, 128)}
OTHERS = {80, *range(83, 94)}


def _manifest():
    spec = importlib.util.spec_from_file_location("ccmap_manifest", ROOT / "modules/cc-map/manifest.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class Numbers(unittest.TestCase):
    def setUp(self):
        self.fx2, self.fx1 = midi_cc.ccmap_ccs()
        self.ccs = set(self.fx2) | set(self.fx1)

    def test_twelve_distinct(self):
        self.assertEqual(len(self.fx2), 6)
        self.assertEqual(len(self.fx1), 6)
        self.assertEqual(len(self.ccs), 12)

    def test_none_stateful(self):
        self.assertFalse(self.ccs & set(midi_cc.STATEFUL))

    def test_no_collision(self):
        self.assertFalse(self.ccs & STOCK, "stock's audio-track CCs")
        self.assertFalse(self.ccs & OTHERS, "FREE LOOP / REC TRIG MUTE")

    def test_refuse_stateful(self):
        with self.assertRaises(ValueError) as e:
            midi_cc.refuse_stateful("x", (63, 64))
        self.assertIn("CC 64 (sustain)", str(e.exception))
        with self.assertRaises(ValueError):
            midi_cc.refuse_stateful("x", (102, 102))
        self.assertEqual(midi_cc.refuse_stateful("x", [102, 14]), (102, 14))

    def test_ccmap_cc(self):
        self.assertEqual(midi_cc.ccmap_cc("FX2", 6), self.fx2[0])
        self.assertEqual(midi_cc.ccmap_cc("fx1", 11), self.fx1[5])
        with self.assertRaises(ValueError):
            midi_cc.ccmap_cc("FX1", 5)

    def test_feedback_sends_ccmap_numbers(self):
        """cf_map's page-2 rows (region 2): FX1 at +12..17, FX2 at +18..23."""
        src = (ROOT / "modules/cc-feedback/cc_feedback.s").read_text()
        body = src[src.index("cf_map:"):]
        triples = [tuple(int(x) for x in t) for t in
                   re.findall(r"(\d+),\s*(\d+),\s*(\d+)", body.split("0,0,0")[0])]
        page2 = {off: cc for region, off, cc in triples if region == 2}
        self.assertEqual(tuple(page2[12 + i] for i in range(6)), self.fx1)
        self.assertEqual(tuple(page2[18 + i] for i in range(6)), self.fx2)
        # Page 1 is stock's numbering (CC 16-45), which holds CC 32 (bank
        # select LSB, LFO) and CC 38 (data entry LSB, FX1): stock sends them
        # on a panel turn and CC FEEDBACK at a load. Not ours to renumber;
        # midi_cc.STOCK_STATEFUL records them.
        sent = {cc for region, _, cc in triples if region != 2}
        self.assertEqual(sent & set(midi_cc.STATEFUL), set(midi_cc.STOCK_STATEFUL))


@unittest.skipUnless(HAS_UNICORN, "existing emu extra not installed")
class Decode(unittest.TestCase):
    """CC MAP's oracle bytes (the linked source, checked by verify_cc_map)
    run from the entry for every CC: the page-2 path (MAPBUILD) with the
    right slot index for the declared numbers, CC_NEXT for every other."""

    MAPBUILD, CC_NEXT, MAPGLOB = 0x40001854, 0x4000e79c, 0x46104cf4

    def run_cc(self, m, cc):
        import unicorn as un
        from unicorn import m68k_const as mc
        at = m.ORACLE_AT
        u = un.Uc(un.UC_ARCH_M68K, un.UC_MODE_BIG_ENDIAN)
        u.ctl_set_cpu_model(mc.UC_CPU_M68K_CFV4E)
        u.mem_map(0x40000000, 0x200000)
        u.mem_map(self.MAPGLOB & ~0xffff, 0x10000)
        u.mem_map(0x47000000, 0x10000)
        u.mem_write(at, m.legacy_bytes(at))
        sp, msg = 0x47008000, 0x47000100
        u.mem_write(msg, bytes([0xb0, cc, 5]))
        u.mem_write(sp, (0x40000000).to_bytes(4, "big") + msg.to_bytes(4, "big"))
        u.reg_write(mc.UC_M68K_REG_A7, sp)
        out = []

        def hook(uc, addr, size, _):
            if addr == self.CC_NEXT:
                out.append("next")
                uc.emu_stop()
            elif addr == self.MAPBUILD:
                out.append(uc.reg_read(mc.UC_M68K_REG_D4))
                uc.emu_stop()
        u.hook_add(un.UC_HOOK_CODE, hook)
        u.emu_start(at, 0, count=200)
        return out[0] if out else None

    def test_every_cc(self):
        m = _manifest()
        want = {cc: i for i, cc in enumerate(m.FX2_CCS + m.FX1_CCS)}
        for cc in range(128):
            with self.subTest(cc=cc):
                self.assertEqual(self.run_cc(m, cc), want.get(cc, "next"))


if __name__ == "__main__":
    unittest.main()
