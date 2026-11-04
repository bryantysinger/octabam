# EVENTS clients

A focused fixture for the shared EVENTS migration: EUCLID consumes transport
notifications and PLOCKS P2 consumes held edits and copy notifications. Both
clients are selected together, installing 25 event hooks. FILTER and COMPRESSOR
provide stock controls; PLATE REV supplies the page-2 fallback used by the
editor gates.

USB presents MAIN and CUE only (four channels), so the hardware stress runner's
first stereo pair observes MAIN. LOAD METER supplies frame-interrupt and DSP
readings. This is a dedicated integration-test selection.

Run `make check REMIX=events-clients` with `OT_PROJECT` pointing to a disposable
project. For a unit, follow [HARDWARE_TESTING](../../../docs/contributing/HARDWARE_TESTING.md):
generate a fresh project and the stimulus layouts, qualify the exact image,
then run the focused EUCLID layouts and transport sequence. BASE has no effects;
it still carries both event subscribers. Zero-subscriber omission is verified
separately by `events-empty`.

The standard stress generator covers START/STOP but not CONTINUE. Resume needs
an explicit sequence or the panel. Panel operations have emulator coverage; physical panel timing and a real
save/power-cycle check need the operator. USB capture does not validate the
analog outputs.

## Hardware results

Tested on radiohagen's MKII, 25 October 2026. EVENTS image `EVT871E3`
was built from `d476ab24`; the matched upstream control `EVT871B1` from
`ae69a3be`. Projects `EVT871E3_01` and `EVT871B1_01` contain identical
pattern, Part and sample data. USB captures MAIN and CUE at 44.1 kHz.

| Check | Recorded result |
| --- | --- |
| EUCLID in FX1 or FX2, all eight tracks | 90 seconds per layout: no audio-analysis flags, clipping, USB faults or DSP bad records |
| START / STOP / CONTINUE, both slots | Audio resumes and stops; subsequent 90 BPM playback produces audio; zero USB faults or DSP bad records |
| Mixed transport, tempo and program changes | Seed 871: 223 operations over 604 seconds, zero USB faults or DSP bad records, no clipping; audio present through the earlier 431.5-second failure interval |

The mixed sequence uses 60–160 BPM. Its silence window is 18 seconds: a
64-step pattern at 60 BPM plus two seconds for the next programmed trigger.
The longest sampled frame interrupt in that run was 536 us, with healthy
frame processing throughout.

Matched BASE and both-slot captures, 90 seconds each at 120 BPM:

| Layout | EVENTS RMS dBFS | Upstream RMS dBFS | EVENTS mean CF share | Upstream mean CF share | EVENTS longest CF interrupt | Upstream longest CF interrupt |
| --- | --- | --- | --- | --- | --- | --- |
| BASE | -36.98 | -36.98 | 61.00% | 61.57% | 364.7 us | 371.9 us |
| EUCLID FX1 + FX2 | -32.32 | -32.41 | 71.03% | 71.39% | 417.5 us | 411.4 us |

Both images had zero clipping, USB overrun/underrun/duplicate-bank deltas,
and DSP bad records. The both-slot level increase also occurs upstream;
its transient detector reported 3 threshold hits with EVENTS and 134
upstream. These are detector hits, not counts of audible clicks. Mean
frame-interrupt load did not increase in these captures. Sampled maxima
are not a worst-case bound or a measurement of total CPU headroom.

The captures use `ot_matrix.py run` with `--play 90 --tail 3 --bpm 120`:
`--only 0,6,10` for EVENTS and `--only 0,10` for the upstream control.
Transport uses `ot_fuzz.py` with the recorded seed-871 sequence and an
explicit START/STOP/CONTINUE capture.

PLOCKS hardware checks on `EVT871E2` (`9a752f97`) confirmed that stopped
trig-paste undo restores both an existing MIX 64 lock and an explicitly
empty destination. The snapshot implementation is unchanged in E3;
current-source emulator gates cover its native snapshot/restore paths.
The [failure register](../../../docs/contributing/FAILURE_MODES.md#plocks-trig-paste-undo-keeps-copied-page-two-locks)
records the original defect and controlled verification.
