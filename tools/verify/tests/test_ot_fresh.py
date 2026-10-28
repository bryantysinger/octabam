"""ot_fresh.stamp_settings: the generated project's MIDI receive keys are switched on, the file keeps its length,
and a project without a key is an error."""
import pathlib
import sys
import unittest

HERE = pathlib.Path(__file__).resolve()
sys.path.insert(0, str(HERE.parents[2] / "hw"))
import ot_fresh  # noqa: E402

BLANK = (b"[SETTINGS]\r\nMIDI_CLOCK_RECEIVE=0\r\nMIDI_PROGRAM_CHANGE_RECEIVE=0\r\n"
         b"MIDI_PROGRAM_CHANGE_RECEIVE_CH=-1\r\nMIDI_TRANSPORT_RECEIVE=0\r\nTEMPOx24=2880\r\n")


class Stamp(unittest.TestCase):
    def test_keys_are_switched_on_and_nothing_else_moves(self):
        out = ot_fresh.stamp_settings(BLANK)
        self.assertEqual(out, BLANK.replace(b"MIDI_CLOCK_RECEIVE=0", b"MIDI_CLOCK_RECEIVE=1")
                         .replace(b"MIDI_PROGRAM_CHANGE_RECEIVE=0", b"MIDI_PROGRAM_CHANGE_RECEIVE=1")
                         .replace(b"CHANGE_RECEIVE_CH=-1", b"CHANGE_RECEIVE_CH=00")
                         .replace(b"MIDI_TRANSPORT_RECEIVE=0", b"MIDI_TRANSPORT_RECEIVE=1"))

    def test_length_is_kept(self):
        self.assertEqual(len(ot_fresh.stamp_settings(BLANK)), len(BLANK))

    def test_stamping_twice_changes_nothing(self):
        once = ot_fresh.stamp_settings(BLANK)
        self.assertEqual(ot_fresh.stamp_settings(once), once)

    def test_missing_key_is_an_error(self):
        with self.assertRaises(ValueError):
            ot_fresh.stamp_settings(b"[SETTINGS]\r\nTEMPOx24=2880\r\n")

    def test_value_wider_than_the_field_is_an_error(self):
        with self.assertRaises(ValueError):
            ot_fresh.stamp_settings(BLANK, {"MIDI_CLOCK_RECEIVE": 10})

    def test_stamp_project_covers_work_and_strd(self):
        out = ot_fresh.stamp_project({"project.work": BLANK, "project.strd": BLANK, "bank01.work": b"x"})
        self.assertEqual(out["project.work"], out["project.strd"])
        self.assertEqual(out["bank01.work"], b"x")
        self.assertIn(b"MIDI_PROGRAM_CHANGE_RECEIVE=1", out["project.work"])


if __name__ == "__main__":
    unittest.main()
