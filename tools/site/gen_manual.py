#!/usr/bin/env python3
"""Render one manual per official remix from the manifests.

    python3 tools/site/gen_manual.py        # also run by gen_pages.py

Writes, gitignored like the rest of the generated site, under
reference/manual/<remix>/ :

  index.md           introduction, installing, the contents
  <chapter>.md       one page per chapter the remix has: bus-setup, effects,
                     machines, parts, midi-usb, settings, utilities, fixes,
                     diagnostics
  appendix-controls.md, appendix-status.md, credits.md

The order is the Octatrack manual's: introduction, installing, the effects,
then the features by area, then appendices. A category the remix has no
module in gets no chapter. Stock effects are not documented here.

Everything that can be read from the manifests is: the contents, which effect
is on FX1 and FX2, the knob layout of each effect's two pages (A to F, the
MODE renames), the settings and what this remix sets them to, the test status,
the credits. The prose is the hand-written usage fragment of each module (the
site's usage directory), inlined with its headings pushed down under the
module's section; its own Parameters table is dropped, since the knobs are
printed from the manifest. A module with no fragment gets its manifest line,
so the manual never has a hole.

The chapter pages are listed by hand in the nav of mkdocs.yml, as the module
pages are; chapters() is the list and tools/verify/verify_docs.py refuses a
nav that does not match it.
"""

import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1])); import toolpath  # noqa: E402,F401  (every tools/ dir on sys.path)

import gen_pages  # noqa: E402
from gen_pages import OUT, _author, _label, _records, _hero_key, title_case  # noqa: E402
from remix import index  # noqa: E402
from remix.schema import PROOF_TEXT, Category, Formatter, Option, Binary, Number, Pin, Trigger, Blob  # noqa: E402

USAGE = OUT.parent / pathlib.Path("usage")
INTROS = OUT.parent / pathlib.Path("manual")

# (category, page, title), in the order a reader meets them.
CHAPTERS = (
    (Category.BUS, "bus-setup", "Bus and effect setup"),
    (Category.TRACK, "effects", "Effects"),
    (Category.MACHINES, "machines", "Machines and the sequencer"),
    (Category.PARTS, "parts", "Parts, Kits and scenes"),
    (Category.MIDI_USB, "midi-usb", "MIDI and USB"),
    (Category.SETTINGS, "settings", "Settings and memory"),
    (Category.UTILITIES, "utilities", "Utilities"),
    (Category.FIXES, "fixes", "Fixes to stock behaviour"),
    (Category.REFERENCE, "diagnostics", "Diagnostics"),
)
APPENDICES = (("appendix-controls", "Appendix A: Effect controls at a glance"),
              ("appendix-status", "Appendix B: Test status"),
              ("credits", "Appendix C: Credits"))

TITLES = {"octabam": "Octabam", "octabam-bus": "Octabam Bus", "cxosc-core": "Octabam CX Osc Core"}
OVERVIEW = {"octabam": "remix-octabam.md", "octabam-bus": "remix-bus.md"}
KNOB = "ABCDEF"
UP = "../../../"            # from reference/manual/<remix>/ to the site root


def title(name: str) -> str:
    return TITLES.get(name, title_case(name.replace("-", " ")))


# ---- the fragment -------------------------------------------------------

def _demote(text: str, by: int) -> str:
    """Push a fragment's headings down `by` levels, leaving fenced code alone
    (a bash comment starts with the same character)."""
    out, fence = [], None
    for line in text.splitlines():
        m = re.match(r"\s*(```+|~~~+)", line)
        if m:
            fence = None if fence == m.group(1)[:3] else (fence or m.group(1)[:3])
        elif fence is None and re.match(r"#{1,5} ", line):
            line = "#" * by + line
        out.append(line)
    return "\n".join(out)


def _relink(text: str) -> str:
    """A fragment is written for the module pages (reference/modules/): its
    sibling links are bare file names and its site links climb two levels.
    The manual sits one level deeper."""
    text = text.replace("](../../", "](" + UP)
    return re.sub(r"\]\((?!https?:|#|\.\./|/)([\w-]+\.md)", r"](../../modules/\1", text)


def _without_parameters(text: str) -> str:
    """Drop a fragment's own Parameters table: the manual prints the knobs
    from the manifest, the one place a knob's name, range and default are
    declared. (The module's own page keeps the hand-written table.)"""
    return re.sub(r"(?ms)^## Parameters\n.*?(?=^## |\Z)", "", text).strip()


def _fragment(m) -> str | None:
    path = USAGE / f"{m.name}.md"
    if not path.is_file():
        return None
    text = path.read_text().strip()
    if _drawn(m):
        text = _without_parameters(text)
    return _relink(text)


def _figure(record: dict) -> list[str]:
    caption = record["caption"]
    return [f"![{caption}]({UP}img/{record['image']})", "", f"*{caption}*", ""]


# ---- the facts ----------------------------------------------------------

def _values(p) -> str:
    """What a knob's range reads as on the panel."""
    if p.labels:
        # a long list (STEPS 1 to 64, a note, a frequency) reads as its ends
        return " / ".join(p.labels) if len(p.labels) <= 8 else f"{p.labels[0]} to {p.labels[-1]}"
    if p.formatter is Formatter.BIPOLAR:
        return "−64 to +63"
    if p.count and p.count != 128:
        return f"1 to {p.count}" if p.formatter in (Formatter.STEPPED, Formatter.WIDE_STEPPED) else f"0 to {p.count - 1}"
    return "0 to 127"


def _default(p) -> str:
    if p.default is None:
        return "—"
    if p.labels:
        return p.labels[p.default]
    if p.formatter is Formatter.BIPOLAR:
        return f"{p.default - 64:+d}" if p.default != 64 else "0"
    return str(p.default)


def _drawn(m) -> bool:
    return m.menu is not None and any(p.active for p in m.params)


def controls(m) -> list[str]:
    """The two effect pages as the panel lays them out, then each knob."""
    lines = ["### Controls", ""]
    for page in (0, 1):
        slots = range(page * 6, page * 6 + 6)
        if not any(m.params[i].active for i in slots):
            continue
        lines += [f"**Page {page + 1}**", "",
                  "| Knob | Name | Values | Default | What it does |", "|---|---|---|---|---|"]
        for i in slots:
            p = m.params[i]
            if not p.active:
                continue
            doc = (p.doc or "").replace("|", "\\|")
            lines.append(f"| {KNOB[i % 6]} | {p.name.decode()} | {_values(p)} | {_default(p)} | {doc} |")
        lines.append("")
    if m.mode_slot is not None and m.mode_views:
        mode = m.params[m.mode_slot]
        renames = [(v, {s: n.decode() for s, n in v.names.items()}) for v in m.mode_views if v.names]
        if renames:
            lines += [f"**What {mode.name.decode()} renames**", "",
                      "| " + mode.name.decode() + " | Knob | Reads as |", "|---|---|---|"]
            for v, names in renames:
                label = mode.labels[v.mode] if mode.labels and v.mode < len(mode.labels) else str(v.mode)
                for slot, name in sorted(names.items()):
                    lines.append(f"| {label} | {KNOB[slot % 6]} on page {slot // 6 + 1} "
                                 f"({m.canon_name(slot) or '—'}) | {name} |")
            lines.append("")
    return lines


def _kind_text(k) -> str:
    if isinstance(k, Binary):
        return "off / on"
    if isinstance(k, Option):
        return " / ".join(k.labels)
    if isinstance(k, Number):
        return f"{k.min} to {k.max}" + (f" {k.unit}" if k.unit else "")
    if isinstance(k, Trigger):
        return "an action"
    if isinstance(k, Blob):
        return "text"
    return "?"


def _setting_value(k, v) -> str:
    if isinstance(k, Binary):
        return "on" if v else "off"
    if isinstance(k, Option):
        i = k.index(v)
        return k.labels[i] if i is not None else str(v)
    return str(v)


def settings(m, r) -> list[str]:
    """The module's settings with the value this remix gives them: a pinned
    setting has no menu row and cannot be changed on the unit."""
    if not m.settings or m.store is None:
        return []
    lines = ["### Settings in this image", "",
             "| Setting | Values | In this image | Takes effect | What it does |", "|---|---|---|---|---|"]
    applies = {"live": "at once", "callback": "after a load or an edit", "next_boot": "at the next boot",
               "build": "set when the image is built"}
    for s in m.settings:
        mine = r.settings.get((m.store.id, s.name), s.default)
        if isinstance(mine, Pin):
            now = f"{_setting_value(s.kind, mine.value)} (fixed)"
        else:
            now = _setting_value(s.kind, mine)
        when = applies[s.apply.value]
        if s.apply.value != "build":
            when += " (stored with the project)" if s.scope.value == "project" else " (stored on the card)"
        doc = (s.doc or "").replace("|", "\\|")
        lines.append(f"| {s.name} | {_kind_text(s.kind)} | {now} | {when} | {doc} |")
    return lines + [""]


def relations(m, mods) -> list[str]:
    out = []
    if m.requires:
        out.append("Needs " + ", ".join(_ref(mods, k) for k in m.requires) + " in the same image.")
    for other, why in m.conflicts:
        out.append(f"Cannot share an image with {_ref(mods, other)}: {why}.")
    return [" ".join(out), ""] if out else []


def _ref(mods, key) -> str:
    return f"[{_label(mods[key])}](../../modules/{mods[key].name}.md)" if key in mods else key


def _on_fx2(m, r) -> bool:
    """FX2 unless the module has a SLOTS build setting that this remix leaves
    on FX1 (the stations: an FX2 instance there is a dry pass)."""
    for s in m.settings:
        if s.name == "SLOTS" and isinstance(s.kind, Option) and m.store is not None:
            mine = r.settings.get((m.store.id, s.name), s.default)
            mine = mine.value if isinstance(mine, Pin) else mine
            i = s.kind.index(mine)
            return i is not None and "FX2" in s.kind.labels[i]
    return True


def where(m, r) -> str | None:
    """Which chooser an effect is in, read from the remix."""
    if m.menu is None or m.is_stock:
        return None
    on = [n for n, ok in (("FX1", m.key in r.fx1), ("FX2", _on_fx2(m, r))) if ok]
    text = " and ".join(on)
    if m.key in r.locked:
        text += " (locked to its host track; the chooser cannot change it)"
    if m.menu.replaces:
        text += f", in place of {m.menu.replaces}"
    return text


# ---- sections ------------------------------------------------------------

def module_section(num: str, m, r, mods) -> list[str]:
    lines = [f"## {num} {_label(m)}", ""]
    lines += [f"*By {_author(m)}.* **Test status:** {index.proof_text(m).rstrip('.')}.", ""]
    place = where(m, r)
    if place:
        lines += [f"**Chooser:** {place}.", ""]
    recs = _records(m)
    key = _hero_key(m)
    if key:
        lines += _figure(recs[key])
    frag = _fragment(m)
    lines += [_demote(frag, 1) if frag else m.doc, ""]
    if _drawn(m):
        lines += controls(m)
    lines += settings(m, r)
    lines += relations(m, mods)
    rest = [rec for k, rec in recs.items() if k != key]
    if rest:
        lines += ["### Screens", ""]
        for rec in rest:
            lines += _figure(rec)
    return lines


def chapters(r, mods) -> list[tuple[str, str, list]]:
    """(page, title, modules) for each module chapter this remix has. Stock
    effects are not documented."""
    out = []
    for cat, page, name in CHAPTERS:
        ms = [mods[k] for k in r.modules if (mods[k].category or Category.REFERENCE) is cat]
        if ms:
            out.append((page, name, sorted(ms, key=lambda m: _label(m).lower())))
    return out


def _effects(chaps) -> list:
    return sorted((m for _, _, ms in chaps for m in ms if _drawn(m)), key=lambda m: _label(m).lower())


def pages_of(r, mods) -> list[str]:
    """The page names (no extension) of one remix's manual, in order."""
    chaps = chapters(r, mods)
    apps = [p for p, _ in APPENDICES if p != "appendix-controls" or _effects(chaps)]
    return ["index"] + [p for p, _, _ in chaps] + apps


def _page(heading: str, body: list[str]) -> str:
    return "\n".join([f"# {heading}", ""] + body) + "\n"


def manual(name: str, r, mods) -> dict[str, str]:
    """The pages of one remix's manual, keyed by file name."""
    heading = title(name)
    chaps = chapters(r, mods)
    numbered = [(i + 3, page, t, ms) for i, (page, t, ms) in enumerate(chaps)]
    out = {}

    intro = [f"The manual for the **{heading}** image: an Octatrack OS 1.40C patched by "
             f"the modules listed here, each credited to its author. It is generated from the "
             f"module manifests, so it lists what this image contains and nothing else.", ""]
    if name in OVERVIEW:
        intro += [f"For the short version, see the [{heading} overview]({UP}{OVERVIEW[name]}).", ""]
    intro += ["## Contents", "",
              "- [1 Introduction](#1-introduction)", "- [2 Installing](#2-installing)"]
    intro += [f"- [{n} {t}]({page}.md)" for n, page, t, _ in numbered]
    has = set(pages_of(r, mods))
    intro += [f"- [{t}]({page}.md)" for page, t in APPENDICES if page in has] + [""]
    # The introduction: a hand-written fragment per remix (the site's manual
    # directory), written for the manual page it lands in, so its links are
    # relative to reference/manual/<remix>/. Without one, the remix's own line.
    written = INTROS / f"{name}.md"
    if written.is_file():
        text = written.read_text().strip()
        k = len(re.findall(r"(?m)^### 1\.\d ", text))
        about = [text, ""]
    else:
        k = 1
        about = [f"### 1.1 About {heading}", "", r.doc, ""]
    intro += ["## 1 Introduction", ""] + about
    intro += [f"### 1.{k + 1} Conventions", "",
              "Names in capitals are what the unit's screen prints. Effects sit on the FX1 and "
              "FX2 keys; each has two pages of six knobs, A to F, reached with the PAGE keys "
              "as on any Octatrack effect. A module's **Test status** says how far it has been proven:", "",
              gen_pages.PROOF_LEGEND, "",
              f"### 1.{k + 2} What is in this image", "",
              "| Chapter | Features |", "|---|---|"]
    for n, page, t, ms in numbered:
        intro.append(f"| [{n} {t}]({page}.md) | " + ", ".join(_label(m) for m in ms) + " |")
    intro += ["", "## 2 Installing", "",
              f"Build the image from your own copy of OS 1.40C and install it as described in "
              f"[Build and Install]({UP}web-builder.md). Nothing from Elektron is in the repository "
              f"or on this site; the builder patches your copy in your browser. "
              f"After the flash, SYSTEM STATUS → OS VERSION shows `{r.name.upper()}` and the build tag.", "",
              f"Back up the card first. To go back to stock, follow [Safety and Recovery]({UP}safety.md).", ""]
    out["index.md"] = _page(f"{heading} Manual", intro)

    for n, page, t, ms in numbered:
        body = []
        for i, m in enumerate(ms, 1):
            body += module_section(f"{n}.{i}", m, r, mods)
        out[f"{page}.md"] = _page(f"{n} {t}", body)

    effects = _effects(chaps)
    body = ["Knob names as the panel prints them (a MODE can rename some; see each effect).", ""]
    for page in (0, 1):
        body += [f"**Page {page + 1}**", "",
                 "| Effect | " + " | ".join(KNOB) + " |", "|---|" + "---|" * 6]
        for m in effects:
            row = [(m.params[i].name or b"").decode() or "—" if m.params[i].active else "—"
                   for i in range(page * 6, page * 6 + 6)]
            if any(c != "—" for c in row):
                body.append(f"| {_label(m)} | " + " | ".join(row) + " |")
        body.append("")
    if effects:
        out["appendix-controls.md"] = _page(APPENDICES[0][1], body)

    allmods = [m for _, _, _, ms in numbered for m in ms]
    body = ["| Feature | Status |", "|---|---|"]
    body += [f"| {_label(m)} | {PROOF_TEXT[m.proof]} |" for m in allmods] + [""]
    out["appendix-status.md"] = _page(APPENDICES[1][1], body)

    by_author = {}
    for m in allmods:
        by_author.setdefault((m.author, m.author_url), []).append(m)
    body = []
    for (author, url), ms in sorted(by_author.items(), key=lambda kv: kv[0][0].lower()):
        who = f"[{author}]({url})" if url else author
        body.append(f"- {who}: " + ", ".join(_label(m) for m in sorted(ms, key=lambda m: m.key)))
    body += ["", "[Feature directory](../../modules.md)"]
    out["credits.md"] = _page(APPENDICES[2][1], body)
    return out


def main(mods, official) -> dict[str, str]:
    """The manual pages, keyed by their path under reference/."""
    jobs = {}
    for name, r in official:
        for page, text in manual(name, r, mods).items():
            jobs[f"manual/{name}/{page}"] = text
    return jobs


if __name__ == "__main__":
    sys.exit(gen_pages.main())
