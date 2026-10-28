# The manual site

The musician-facing manual, built with MkDocs with the shadcn theme and deployed to
GitHub Pages by `.github/workflows/pages.yml` on pushes to main. The same
build, without the deploy, runs as the `site` job on every PR
(`.github/workflows/ci.yml`).

`gen_pages.py` renders the generated pages from this commit's manifests
(`tools/remix/index.py`, the registry). The generated files sit under
`reference/` in the site directory, are gitignored, and never appear in
the tree, so the site and the manifests cannot drift: a merge to main
rebuilds them.

Generated, gitignored:

- the module reference (every module grouped by category, with author,
  kind, proof status, FX2 id and knobs; stock effects in their own
  section; every module name links to its own page)
- one `modules/<name>.md` page per module (what it does, the manifest
  facts — author, kind, proof, FX2 id, knobs, requires, conflicts — and
  which official remixes carry it; stock effects included). The pages are
  not in the nav (there are ~70): each carries a `not_in_nav` line and is
  reached from the module reference and the remix pages' module tables.
  The remix-page link back is looked up in the nav in `mkdocs.yml` (the
  one file that names the hand-written pages).
- the credits (authors linked, with their module keys)
- one `_remix-<name>.md` fragment per non-test remix (the remix doc, its
  proof line, and its module table, whose rows link to the per-module
  pages), pulled into each remix page with
  `pymdownx.snippets` (`--8<-- "reference/_remix-<name>.md"`)

## The remix manuals

`gen_manual.py` (run by `gen_pages.py`) writes one manual per official
remix under `reference/manual/<remix>/`, one page per chapter, in the order
of the Octatrack's own manual: `index.md` (1 Introduction, 2 Installing and
the contents), then a numbered chapter per module category the remix has
(bus setup, effects, machines, Parts and scenes, MIDI and USB, settings,
utilities, fixes, diagnostics), then Appendix A (every effect's knobs, page
1 and 2, A to F), B (test status) and C (credits). A remix with no module in
a category has no page for it. Stock effects are not documented.

The chapter pages are listed by hand under Manuals in `mkdocs.yml`, as the
module pages are; `verify_docs.py` refuses a nav that differs from the pages
the manifests produce, naming the page.

Each module is a numbered section of its chapter. From the manifest, never typed: the
byline, test status, which chooser it is in (FX1, FX2, read from the remix's
`fx1` and the module's `SLOTS` setting), the knob layout (name, values,
default, one-line meaning), what a MODE renames, the settings with the value
this remix gives them (pinned ones marked fixed), `requires` and `conflicts`.
From the hand-written usage fragment: the prose, inlined with its headings
pushed down under the section. A fragment's own `## Parameters` table is
dropped from the manual, because the knob tables come from the manifest;
the module's own page keeps it. A module with no fragment shows its manifest
line, so the manual has no hole.

The introduction (chapter 1) of each manual is hand-written, one file per
remix in the site's manual directory (`octabam.md`, `octabam-bus.md`,
`cxosc-core.md`). Write it as sections `### 1.1`, `### 1.2`, ... for the page
it lands in, so its links are relative to `reference/manual/<remix>/`
(`../../../brain.md` reaches the site root, `../octabam/index.md` another
manual); the generator numbers its own sections after yours. A remix without
one gets its `Remix.doc` line.

To improve a knob's row in the manual, edit the `Param` `doc` in the
manifest. To improve a module's prose, edit its usage fragment. The remix's
own paragraph is `Remix.doc`. A new official remix, or a module in a category the remix had none of,
needs its nav entries (`verify_docs.py` names them).

## Rules the doclinks gate forces on these files

`tools/verify/doclinks.py` scans every tracked text file, these pages
included. Three consequences:

- The `REPOPATH` rule matches any `docs/…md`, `tools/…md`,
  `modules/…md` or `remixes/…md` string anywhere in a tracked file and
  requires the path to exist. The remix pages are therefore named flat at
  the site root (`remix-core.md`, `remix-inserts.md`, `remix-bus.md`) so
  the nav needs no `remixes/…` entry, and links into the repository are
  written as full `https://github.com/sambanks/octabam/…` URLs.
  `reference/…` paths are safe (not in the alternation). `gen_pages.py`
  builds all paths with pathlib joins and all GitHub links as f-strings
  (strings containing `{}` are exempt), so it stays quiet too.
- Markdown links in a tracked page must resolve from the page's own
  directory, and `#anchor` targets must match a heading under GitHub's
  slug rule. The hand-written remix pages link into `reference/`, whose
  files are generated and untracked, so `tools/verify/verify_docs.py`
  renders them (quietly) before it resolves links — as does CI's docs
  job.
- No section sign in any tracked page ("section N" instead).

`mkdocs build --strict` is the complementary gate: it fails on a broken
site link or a broken snippet include (it does not check anchors;
doclinks does).

## Build

```bash
python3 -m venv .venv-site
.venv-site/bin/pip install -r docs/site/requirements.txt
python3 tools/site/gen_pages.py
.venv-site/bin/mkdocs serve --config-file docs/site/mkdocs.yml   # http://127.0.0.1:8000
.venv-site/bin/mkdocs build --strict --config-file docs/site/mkdocs.yml
```

`gen_pages.py` needs the submodules initialized (`git submodule update
--init`): the registry execs the authors' manifests.

## LCD illustrations

The manual uses exact firmware captures rendered in black on white.
`tools/emu/lcd_view.py` now defaults to the white palette; `--palette yellow`
selects the former LCD colours for PNG output. `live_shots.py` uses that
renderer, so new scripted captures also default to white.

Take fresh captures from the emulator's actual panel UART with:

```bash
python3 tools/site/capture_manual.py core features inserts bus extras machines probes
```

The command uses `OT_PROJECT` or `~/.octabam_project`, or accepts
`--project <path>`. It copies the project and stages private cards beneath
`out/manual-captures/`; the user's project is never edited. Each capture
is recorded in `screenshots.json`, including the firmware hash and remix.
The generated module galleries and screenshot coverage index read this
manifest. `screen-notes.json` accounts for modules without a separate LCD
interface and records blocked captures explicitly. Review the captured
screens before publishing: a successful key sequence alone does not prove
it reached the intended page. The `probes` group captures CF meter from
the standalone `cfmeter` remix; the `waveload` image does not assemble
(`meter.s:91`, short branch displacement 130).

Keep image assets included in the site; only usage and remix fragments
belong in `exclude_docs`.

Usage fragments are included beneath a generated page title. Start them
with an introduction, not another H1. Link screenshots relative to the
resulting generated module page. Main manual chapters use their own local
image paths. `manual.css` handles reading width, spacing and image framing
while retaining the theme's typeface and colour tokens.
