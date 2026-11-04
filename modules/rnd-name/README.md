# `rnd-name` — RND NAME

Hold **FUNC** and press **CUE** in supported name editors to fill a random
name from two 64-word pools (4096 joins).

## Behaviour

| Editor | FUNC+CUE |
|--------|----------|
| NAME THE NEW PROJECT | `YYMMDD ` + two pool words (e.g. `261014 SWEEPPAD`) |
| SAVE PROJECT AS… / CHOOSE NEW PROJECT NAME | `YYMMDD ` + two pool words |
| COPY PROJECT (with COPY PROJECT in the remix) | `YYMMDD ` + two pool words |
| SAVE SAMPLE AS… | two pool words (no date) |
| NAME THE NEW DIR / NAME THE NEW SET | two pool words |
| KITS → SAVE KIT (name editor) | one short pool word (7-char max) |
| RENAME PROJECT / PART / ARR / remarks / card | stock (inert) |

Stock create still seeds `PROJECT DDMMYY` until the chord runs. Stock
FUNC+REC / PLAY / STOP (PASTE / CLEAR / COPY NAME) stay.

Date is from the DS1390 (same fields as sample timestamps). Fill length
follows the editor’s `ED_MAX`. Entropy: LCG seeded from tempo, clock, and
RTC h:m:s; pool index from bits 16..21 (low 6 collapsed under BPM×24).

**Gating:** date vs words-only is decided only from the name-editor
done-callback in `CB_SLOT` (`0x460e761a`), never the window title. The
date branch is CREATE `0x400644f0`, SAVEAS `0x40063d30`, CHOOSE
`0x40063b00`, and (when linked) COPY PROJECT’s `cp_named`.

## Measured / inferred

- **Measured (port):** FUNC+CUE under `ot_emu` (`verify_rnd_name`, `--rtc`
  pinned) writes `YYMMDD ` + a pool join on CREATE EMPTY PROJECT, SAVE
  PROJECT AS… (PROJECT → SAVE TO NEW), and CHOOSE NEW PROJECT NAME
  (PROJECT → EXPORT TO SET → YES → YES). A second chord on CREATE changes
  the words. Each fill fits that editor’s `ED_MAX`. Name-editor FUNC keys
  pointer leaves stock `0x400d0916` for DRAM `rnd_func_keys`.
- **Measured (stock image):** create seeds `PROJECT ` + `DDMMYY` via
  `0x40081b30`; editor opens and callback sites for sample / save-as /
  dir / set from pea's into `0x4007e664`.
- **Inferred:** KITS SAVE KIT is any name-editor callback in the DRAM
  arena (`0x40a00000..0x4f000000`); falsifier: another DRAM module opens
  this editor with a different done-cb and gets an unwanted fill.
- **Not gated under the port:** sample / new dir / set / kits / COPY PROJECT
  chord paths.

## Remix

```python
modules=(..., "RND NAME", ...)
```

Smoke: `remixes/test/rnd-name`.
