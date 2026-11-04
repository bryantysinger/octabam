"""build_bus refuses a DSP source where one label is a prefix of another.
tools/build/nolabelprefix.py, called by build_bus.assemble_syms."""
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/build"))
sys.path.insert(0, str(ROOT / "tools"))
import nolabelprefix  # noqa: E402


class LabelPrefix(unittest.TestCase):
    def test_a_planted_prefix_pair_is_refused(self):
        for a, b in (("end", "endb"), ("warmz", "warmz2"), ("loop1", "loop10")):
            src = f"init:\n{a}:     nop\n        do #<2,>{b}\n{b}:    nop\nproc:\n"
            with self.assertRaises(SystemExit) as c:
                nolabelprefix.refuse_label_prefix(src, "fixture")
            self.assertIn("label prefix in a DSP source (fixture)", str(c.exception))
            self.assertIn(f"{a} / {b}", str(c.exception))

    def test_distinct_names_comments_and_operands_are_fine(self):
        nolabelprefix.refuse_label_prefix("""init:
        move    x:(r1)+,x0      ; end: in a comment
        do      #$18,>st_a_01
        div     x0,a
st_a_01:
st_b_01: nop
proc:   move    y:(r4),a
        bra     init
""")

    def test_the_sources_carry_none(self):
        bad = []
        files = sorted((ROOT / "modules").glob("*/*.asm")) + sorted((ROOT / "dsp").glob("*.asm"))
        for f in files:
            if "upstream" in f.parts:
                continue
            clashes = nolabelprefix.label_prefix_clashes(f.read_text(encoding="utf-8", errors="replace"))
            if clashes:
                bad.append(f"{f.relative_to(ROOT)}: {clashes[:3]}")
        self.assertEqual(bad, [])


if __name__ == "__main__":
    unittest.main()
