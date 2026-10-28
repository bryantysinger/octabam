# COPY PROJECT

Duplicate a project folder on the CompactFlash card without loading it
first.

**PROJECT → CHANGE → highlight a project → FUNC+BANK → COPY** (under
RENAME / DELETE) asks for a name, confirms, and copies the source folder
byte-for-byte into a new folder — stock project files and module extras
alike. Stock SAVE TO NEW writes a fresh project and drops those extras.
After a successful copy it asks whether to open the copy (stock LOAD
PROJECT).

Entry used to be a PROJECT menu TableGrow (15→16); that blob no longer
packs beside long FX1 + QUANTIZER on a full tip (#931). The FUNC+BANK
popup grows 2→3 instead (`docs/firmware/PANEL.md`).

**Sidecars** = non-stock files modules leave in the project folder
(`kits.work` / `kits.strd`, `scenes.work`, `brain.work`, `p2lkNN.work`,
`BUFFERS/`, …). A folder copy keeps them; SAVE TO NEW does not. On a
live card set they show up next to `project.work` / `bankNN.work` (e.g.
`261018 IDLEYARD`, `!DEF_TMPL`).

## Use

1. Mount the set that holds the source project (CHANGE set if needed).
2. PROJECT → CHANGE → highlight the source (folders with `project.work` /
   `project.strd`; not `<CREATE EMPTY PROJECT>`).
3. FUNC+BANK → COPY.
4. Edit the suggested name (`PROJECT YYMMDD`, or FUNC+CUE with RND NAME)
   and YES. The name editor itself caps at 32 characters.
5. Confirm `COPY SRC -> DST?` (16-char display cap on the line).
6. On success: `PROJECT COPIED` / `OPEN IT?` — YES loads the copy and
   closes CHOOSE PROJECT. NO leaves the live project as it was.
   `COPY FAILED` on error; a partial destination folder is removed so a
   retry does not hit `NAME ALREADY IN USE!`.

## What gets copied (disk only)

COPY is **card-to-card**: the highlighted folder as it sits on the CF,
including stock `.work` / `.strd` and module sidecars (`kits.*`,
`scenes.*`, `brain.*`, `p2lk*`, `BUFFERS/`, …). It does **not** read live
RAM.

**Trigs / banks.** Stock already autosaves the loaded project into
`.work` (and flushes dirty banks ~1 s after STOP). So edits you hear
after a stop are usually already on disk; CHANGE often has nothing to
ask. A short window (still playing, or before that flush) can leave RAM
ahead of the card — SAVE PROJECT if you care about that snapshot before
copying.

**No “save before open” prompt.** An earlier build asked every time by
calling `0x400255ec`, which means “a project is open”, not “dirty”.
There is no reliable cheap dirty check here; OPEN IT? just loads the
copy. SAVE the live project yourself first if you need `.strd` / sidecar
commits.

**Recorder buffers (PERSISTENT BUFFERS).** That module writes
`BUFFERS/RECn.wav` only on **PROJECT → SAVE**, and reloads them on LOAD.
COPY will carry `BUFFERS/` only if SAVE already wrote it. Takes that
exist only in RAM are not in the folder and will not appear in the copy.
SAVE TO NEW still drops these sidecars; COPY keeps them when present.

Limits that refuse with `COPY FAILED` (no silent truncate / partial
copy): more than 64 projects in the set, a directory with more than 256
entries, an entry name longer than 32 characters inside the tree, or
nesting deeper than 6 folders.

## Measured

🟡 FUNC+BANK LISTPOP handlers/labels at `0x400cbaac` / `0x400cbab4`,
count poke at `0x400641a2`; selection name `0x100f8378` (same pea as
stock RENAME/DELETE). Mapped under the port 27 Oct 2026.

🟡 Dir-scan borrow/restore follows REMIX SWITCH
(`docs/contributing/FAILURE_MODES.md`). Copy uses stock `DIRSCAN`
(`0x4007f598`), mkdir (`0x46c8240a`), and file copy (`0x40016388`) from
an engine job (type 21), posted like REMIX SWITCH's deferred load.
Failed-copy cleanup uses stock's recursive walker (`0x40090a14`, mode 0).
Gated under the port: a source directory with more than 256 entries
forces `COPY FAILED`, removes the partial destination, leaves SRC
intact, and a retry with the same name does not read
`NAME ALREADY IN USE!`.

## On the unit

- **17 Oct 2026 (MKII):** PROJECT-menu COPY (pre-#931). BUILD not recorded.
- **27 Oct 2026 (MKII), `CORE CP`:** FUNC+BANK COPY; OPEN IT? YES loads the
  copy and closes CHOOSE PROJECT with no save prompt; OPEN IT? NO leaves
  the live project. Owner report on this tip.

U1 (`LATEST U1`, 19 Oct 2026): a long project name stretched the pick
list until nothing drew — fixed by the 16-char display cap (full name
still copied). Name editor >32 is unreachable (form cap). Sidecars
present on the author's DEFAULT set (`kits.work`, `scenes.work`,
`brain.work`, `p2lk*`, `BUFFERS/`). Not tried: a directory near/over 256
entries, or copying while the sequencer plays.

## Open

- Cross-set copy (v1 is the mounted set only).

## Gates

`make check REMIX=copy-project` (test remix). Port gate:
`tools/verify/verify_copy_project.py` — CHANGE → FUNC+BANK → COPY,
stages SRC, copies to the stock default name under a pinned RTC, checks
`project.work` and the rest of the folder.
