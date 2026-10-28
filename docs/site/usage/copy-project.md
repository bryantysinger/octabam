Duplicate a project folder on the CompactFlash card without loading it
first — stock files and module extras (`kits.work`, `scenes.work`,
`brain.work`, `p2lk*`, `BUFFERS/`, …). Stock SAVE TO NEW does not keep
those extras.

## Access

MAIN MENU → PROJECT → CHANGE → highlight a project → FUNC+BANK → COPY
(under RENAME / DELETE). Mount the set that holds the source first
(CHANGE set if needed). Not available on `<CREATE EMPTY PROJECT>`.

## Operation

1. Open the CHANGE project list and highlight the source.
2. FUNC+BANK → COPY.
3. Edit the suggested name (`PROJECT` + date). With RND NAME in the
   remix, FUNC+CUE fills `YYMMDD` + two pool words. The name editor
   caps at 32 characters.
4. Confirm `COPY SRC -> DST?`.
5. On success: `PROJECT COPIED` / `OPEN IT?` — YES loads the copy and
   closes CHOOSE PROJECT. NO leaves the live project as it was.
   `COPY FAILED` on error; a partial destination folder is removed.

## Disk only — what SAVE is for

COPY copies the **folder on the card**, not live RAM. Stock already
autosaves banks into `.work`, so most trig edits are on disk without an
explicit SAVE. OPEN IT? does **not** ask to save the live project (a
wrong “project open” check used to prompt every time).

If you use **PERSISTENT BUFFERS**, recorder takes land in `BUFFERS/RECn.wav`
only when you **PROJECT → SAVE**. SAVE before COPY if those takes should
be in the duplicate; otherwise the copy has no `BUFFERS/` for them and
LOAD cannot restore them.

v1 copies within the mounted set only. Also refuses (no silent truncate)
when the set has more than 64 projects, a directory has more than 256
entries, or an entry name inside the tree is longer than 32 characters.
