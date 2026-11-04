"""verify_usb skips its runtime rows when no early setting has a CS1 offset, where it used to
raise `max() iterable argument is empty` in cs1_block (a USB remix without BRAIN)."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]


def _load():
    spec = importlib.util.spec_from_file_location("verify_usb", ROOT / "tools/verify/verify_usb.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class EarlySlot(unittest.TestCase):
    def test_entries_without_an_offset_are_not_a_block(self):
        usb = _load()
        self.assertFalse(usb.has_early_slot([]))
        self.assertFalse(usb.has_early_slot([("m", "s", None), ("m", "t", None)]))

    def test_one_offset_is(self):
        usb = _load()
        self.assertTrue(usb.has_early_slot([("m", "s", None), ("m", "t", 0x10000020)]))


if __name__ == "__main__":
    unittest.main()
