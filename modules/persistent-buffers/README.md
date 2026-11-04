# PERSISTENT BUFFERS

On **PROJECT SAVE**, each non-empty recorder buffer (slots 128–135) is
written with the stock synchronous WAV writer (`0x40020f04`) to
`BUFFERS/RECn.wav` under the project (folder created if missing), PATH’d
to that name, and bound in the UI with flex post-load
(`0x40099148(1, slot)`) — no re-load of the WAV (the take is already in
the buffer; same idea as BUFFER SAVER’s mode-2 assign-to-self). A full
slot load after the write made the UI wait on a second card read.

On **PROJECT LOAD** / **RELOAD**, existing `BUFFERS/RECn.wav` files get
PATH + flex slot load + post-load (`0x40096548` / `0x40099148(1, slot)`).

Empty buffers (control-record length ≤ 64) are skipped. The saved path
has **no** `!` prefix (`BUFFERS/…`, matching `nm_pbf`); a leading `!`
makes `SLOT_LOAD` reject the name.

## Save vs load (what the skipped load would set)

Control record `0x46c922c4 + 44·slot` (STORAGE / SAMPLE_SAVE). Flex load
`0x40096548` after a successful WAV read (`0x400210fc`) writes at least:

| field | offset | on flex load | on our save (no load) |
|---|---|---|---|
| format / channel flags | +0, +4..+7 | from WAV header | left as the take set them |
| state | +8 | set to 2 for non-recorders; **recorders (128–135) skip this** | untouched |
| status | +12 | error codes on open/parse fail | untouched |
| length (frames) | +16 | from WAV (floor 64) | already the take length |
| name | +24 | from the file basename | we `sprintf` `REC%d` |
| handle / extras | +20, +36, +40 | refcount / loader scratch | +20 bumped only if load ran |
| sample pool | (arena) | **re-read audio from the card** | already holds the take |

Settings PATH (`0x100b14f0 + 0x448·slot`) is set on both paths. Save then
calls `POST_LOAD(1, slot)` and a batch `REARM`/`REFRESH`, same as stock’s
flex caller after a load (`0x40084b62`).

**Inferred (R6):** for a slot that just recorded, length / format / pool
already match the WAV we wrote; skipping the re-read only drops a
redundant card pass. **Falsified on R7 (pass):** after save (no power
cycle) the slot plays and shows `RECn` like the same slot after PROJECT
LOAD from that `BUFFERS/RECn.wav`.

## vs BUFFER SAVER

[BUFFER SAVER](../buffer-saver/README.md) also writes recorder buffers on
SAVE PROJECT, but only when a take is marked unsaved: it asks
**SAVE SAMPLES?**, writes stock `R<n>-YYMMDD-HHMM` names, and assigns each
buffer to itself. This module always dumps every non-empty slot to fixed
`BUFFERS/RECn.wav` through STORE, with no dialog. Declared
`conflicts` — both would write the same buffers on one save.

## Status

`Proof.HARDWARE`. `verify_persistent_buffers` covers symbols, a save-smoke
call on empty buffers, and a staged-load of `BUFFERS/REC1.wav` under the
port. Record-then-save under a live frame ISR is still not driven by the
port (PROJECT menu); that path is the hardware table below.

Hardware (author's MKII). R1–R6 on personal `minimal` (16–17 Oct 2026).
**R7** on flash stack `PBUF R7.RMX` (`REMIX=latest` on `ilia`, BUILD R7,
22 Oct 2026) — tip then carried the no-reload save + flex load:

| BUILD | measured |
|---|---|
| R1 | only the last slot assigned (async SAVE/ASSIGN shared scratch) |
| R2 | sync `wav_write` wrote all eight WAVs |
| R3 | slot load + post-load bound the UI assignment (`REC*.wav` at project root) |
| R4–R5 | paths under `!BUFFERS/`: WAVs + `PATH=` in `project.work`, UI stayed unassigned (`SLOT_LOAD` status −0x10 INVALID FILENAME — inferred from symptom + status table; falsify: assigned UI with a `!` PATH) |
| R6 | folder renamed to `BUFFERS/` (no `!`) |
| R7 | short + long take: UI shows `RECn` when the write finishes (no second-load lag); all eight slots; empty skipped; PROJECT LOAD + RELOAD; reopen + play; overwrite existing `REC*.wav`; post-save play matches post-load play |

## Remix

Listed next to STORE (required). Gate carrier:
`remixes/test/persistent-buffers`. Hardware R7 was on personal `latest`
(`PBUF R7`); R1–R6 on personal `minimal`.
