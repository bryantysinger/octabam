#!/usr/bin/env python3
"""Strict, local acceptance evidence. Never flashes a unit or publishes artifacts."""
import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import toolpath  # noqa: E402,F401
from remix import registry  # noqa: E402

SCHEMA_VERSION = 1
# A skip means missing evidence, even if the child returns zero. [N/A] is
# reserved for an explicit inapplicable branch in a verifier.
SKIP = re.compile(r"^\s*(?:\[SKIP\]|SKIP:)", re.M)
FAIL = re.compile(r"^\s*\[FAIL\]", re.M)
NA = re.compile(r"^\s*\[N/A\].*$", re.M)
LIMITATIONS = [
    "Emulator evidence is not hardware validation.",
    "DSP static costs omit contention; instruction meters are not CPU percentages.",
    "No calibrated ColdFire deadline, storage I/O budget, or hardware soak is certified.",
    "Pressure samples layouts; it does not prove every ordering or cross-core timing.",
    "Generated project playback covers A01; A02-A04 transitions are not automated here.",
]


def sha256(path):
    with open(path, "rb") as f:
        digest = hashlib.sha256()
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inventory(path):
    """Hashes only: never put firmware, project bytes, or audio in the report."""
    return {p.relative_to(path).as_posix(): sha256(p)
            for p in sorted(path.rglob("*")) if p.is_file()}


def sample_inventory(project):
    """Project sample paths may point outside the project, e.g. ../AUDIO."""
    from ot_project import read_project
    _, slots = read_project(project)
    result = {}
    for slot in slots:
        rel = slot["path"]
        if not rel:
            continue
        path = (project / rel).resolve()
        metadata = path.with_suffix(".ot")
        result[rel] = dict(sha256=sha256(path) if path.is_file() else None,
                           metadata_sha256=sha256(metadata) if metadata.is_file() else None)
    return result


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def provenance():
    binaries = [
        ROOT / "vendor/dsp56300/build/source/dsp_host/dsp_asm",
        ROOT / "vendor/dsp56300/build/source/dsp_host/dsp_host",
        ROOT / "out/emu/ot_emu",
    ]
    for name in ("make", "m68k-elf-as", "m68k-elf-ld", "m68k-elf-gcc"):
        if shutil.which(name):
            binaries.append(pathlib.Path(shutil.which(name)))
    return {
        "commit": git("rev-parse", "HEAD"),
        "working_tree": git("status", "--porcelain", "--untracked-files=all"),
        "source_sha256": {name: sha256(ROOT / name) for name in
                          subprocess.check_output(["git", "ls-files", "-z", "--cached",
                                                   "--others", "--exclude-standard"],
                                                  cwd=ROOT).decode().split("\0")
                          if name and (ROOT / name).is_file()},
        "diff_sha256": hashlib.sha256(subprocess.check_output(
            ["git", "diff", "HEAD", "--binary"], cwd=ROOT)).hexdigest(),
        "submodules": git("submodule", "status", "--recursive").splitlines(),
        "python": sys.version,
        "platform": platform.platform(),
        "tools": {str(p): sha256(p) for p in binaries if p.is_file()},
        "firmware_sha256": (sha256(ROOT / "out/raw/section_3_MAIN_OS.bin")
                            if (ROOT / "out/raw/section_3_MAIN_OS.bin").is_file() else None),
    }


def run_gate(name, command, out, env, timeout):
    """A failed command, timeout, or successful-but-skipped gate cannot pass."""
    log = out / (name + ".log")
    start = time.monotonic()
    result = dict(name=name, command=command, status="failed", exit_code=None,
                  log=log.name, duration_seconds=0, skips=[], not_applicable=[])
    print(f"acceptance: {name}", flush=True)
    stdout = out / (name + ".stdout")
    with log.open("w", encoding="utf-8") as f, stdout.open("w", encoding="utf-8") as output:
        try:
            proc = subprocess.Popen(command, cwd=ROOT, env=env, stdout=output,
                                    stderr=f,
                                    start_new_session=(os.name == "posix"))
            try:
                result["exit_code"] = proc.wait(timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt) as exc:
                if os.name == "posix":
                    os.killpg(proc.pid, signal.SIGKILL)
                else:
                    proc.kill()
                proc.wait()
                if isinstance(exc, KeyboardInterrupt):
                    raise
                result["reason"] = f"timed out after {timeout} seconds"
        except OSError as exc:
            result["reason"] = str(exc)
    text = stdout.read_text(encoding="utf-8", errors="replace") + "\n" + log.read_text(encoding="utf-8", errors="replace")
    log.write_text(text, encoding="utf-8")
    result["stdout"] = stdout.name
    result["skips"] = [line.strip() for line in text.splitlines() if SKIP.match(line)]
    result["not_applicable"] = [line.strip() for line in NA.findall(text)]
    if result["exit_code"] == 0 and not FAIL.search(text):
        result["status"] = "blocked" if result["skips"] else "passed"
    result["duration_seconds"] = round(time.monotonic() - start, 3)
    print(f"acceptance: {name}: {result['status']} ({log})", flush=True)
    return result


def budget_result(data):
    """A lower-bound estimate over the wall is a rejection; below is no guarantee."""
    if (not isinstance(data.get("worst_core"), int)
            or not isinstance(data.get("usable"), int) or data["usable"] <= 0):
        raise ValueError("cycle report has no valid worst_core/usable measurement")
    return "failed" if data["worst_core"] > data["usable"] else "passed"


def pressure_profile(modules):
    # pressure.py's DEAR/ODD and the opposite-core SEND fixture only cover
    # the existing rig. Do not quietly run unknown modules at default knobs.
    from pressure import DEAR
    dsp_keys = {m.key for m in modules if m.dsp is not None}
    if not dsp_keys:
        return "not_applicable", "remix has no DSP modules"
    if dsp_keys != set(DEAR):
        return "blocked", ("no pressure profile for this DSP selection; "
                           "the current profile requires " + ", ".join(sorted(DEAR)))
    return "ready", "bamsep26 station/bus pressure profile"


def pressure_evidence_error(rows, price):
    """Missing meters or layouts are missing evidence, even after exit zero."""
    counts = {}
    for row in rows:
        core = row.get("core")
        if core not in (0, 1) or row.get("rc") != 0 or row.get("flags"):
            return "failed or invalid pressure layout"
        meter = row.get("meter", {}).get(str(core))
        if not meter or len(meter) != 2 or any(v <= 0 for v in meter):
            return "pressure layout has no positive instruction meter"
        counts[core] = counts.get(core, 0) + 1
    for core in (0, 1):
        label = f"core {core} (T{'5-8' if core == 0 else '1-4'})"
        layouts = price["cores"][label]["layouts"]
        expected = min(6, layouts) + min(4, max(0, layouts - 6))
        if expected == 0 or counts.get(core, 0) != expected:
            return f"core {core}: incomplete pressure sample"
    return None


def aggregate(gates):
    if any(g["status"] == "failed" for g in gates):
        return "failed"
    if any(g["status"] in ("blocked", "not_run") for g in gates):
        return "blocked"
    return "passed"


def write_report(out, report):
    report["status"] = aggregate(report["gates"]) if "finished_at" in report else "running"
    tmp = out / "report.json.tmp"
    tmp.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    tmp.replace(out / "report.json")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--remix", default=os.environ.get("REMIX", "bamsep26"))
    fixture = ap.add_mutually_exclusive_group()
    fixture.add_argument("--project", type=pathlib.Path)
    fixture.add_argument("--stress-source", type=pathlib.Path,
                         help="generate the bamsep26 fixture from a local project")
    ap.add_argument("--out", type=pathlib.Path,
                    default=ROOT / "out/acceptance" / dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
    ap.add_argument("--timeout", type=int, default=3600, help="seconds per command")
    args = ap.parse_args(argv)
    if args.timeout <= 0:
        ap.error("--timeout must be positive")
    out = args.out.resolve()
    if out.exists():
        ap.error("--out already exists; choose a fresh directory to avoid stale evidence")
    out.mkdir(parents=True)
    names = ("preflight", "fixture", "check", "cycles", "pressure_price", "pressure_render")
    report = dict(schema_version=SCHEMA_VERSION, remix=args.remix,
                  started_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                  status="blocked", validation_level="local-emulator",
                  hardware_validated=False, limitations=LIMITATIONS,
                  gates=[dict(name=n, status="not_run") for n in names],
                  provenance={}, modules=[], fixtures={}, measurements={})

    def record(result):
        report["gates"][names.index(result["name"])] = result
        write_report(out, report)
        return result["status"] in ("passed", "not_applicable")

    env = dict(os.environ, REMIX=args.remix)
    # Serialize recursive Make even when this runner is invoked by make -j.
    env.pop("MAKEFLAGS", None)
    env.pop("MFLAGS", None)
    env.pop("MAKEOVERRIDES", None)
    env.setdefault("BUILD", "0")

    def run(name, command):
        return record(run_gate(name, command, out, env, args.timeout))

    try:
        report["provenance"] = provenance()
        remix = registry.remix(args.remix)
        modules = registry.selected(remix)
        report["modules"] = [
            dict(key=m.key, name=m.name, kind=m.kind.value,
                 manifest_sha256=(sha256(ROOT / "modules" / m.name / "manifest.py")
                                  if (ROOT / "modules" / m.name / "manifest.py").is_file() else None))
            for m in modules]
        profile, reason = pressure_profile(modules)
        project = args.project
        if project is None and args.stress_source is None and os.environ.get("OT_PROJECT"):
            project = pathlib.Path(os.environ["OT_PROJECT"])
        problems = []
        if project is None and args.stress_source is None:
            problems.append("provide --project / OT_PROJECT or --stress-source")
        if args.stress_source and args.remix != "bamsep26":
            problems.append("the generated stress fixture is for bamsep26 only")
        if profile == "blocked":
            problems.append(reason)
        required = [ROOT / "out/raw/section_3_MAIN_OS.bin",
                    ROOT / "out/emu/ot_emu", ROOT / ".venv/bin/python3"]
        if any(m.dsp is not None for m in modules):
            required += [ROOT / "vendor/dsp56300/build/source/dsp_host/dsp_host",
                         ROOT / "vendor/dsp56300/build/source/dsp_host/dsp_asm"]
        problems += [f"missing prerequisite: {p}" for p in required if not p.is_file()]
        if not record(dict(name="preflight", status="blocked" if problems else "passed",
                           reasons=problems, pressure_profile=reason)):
            return 1

        if args.stress_source:
            project = out / "STRESS"
            if not run("fixture", [sys.executable, "tools/harness/stress_project.py",
                                   "--source", str(args.stress_source.expanduser().resolve()),
                                   "--out", str(project)]):
                return 1
            report["fixtures"]["source"] = {
                p.name: sha256(p) for p in sorted(args.stress_source.expanduser().resolve().iterdir())
                if p.is_file() and p.suffix in (".work", ".strd")}
        else:
            project = project.expanduser().resolve()
            if not (project / "project.work").is_file() or not (project / "bank01.work").is_file():
                record(dict(name="fixture", status="blocked", reason="project.work and bank01.work are required"))
                return 1
            record(dict(name="fixture", status="passed", reason="operator-supplied project"))
        report["fixtures"]["project"] = inventory(project)
        report["fixtures"]["referenced_samples"] = sample_inventory(project)
        env["OT_PROJECT"] = str(project)
        report["parameters"] = dict(build=env["BUILD"], bank=env.get("OT_BANK"),
                                    pressure=dict(top=6, sample=4, seed=1, seconds=2, frames=16))
        report["measurements"]["units"] = dict(
            dsp_static="static cycles/sample/core; contention omitted",
            pressure_meter="emulated instructions/block and instructions/sample/core")
        write_report(out, report)

        if not run("check", ["make", "-j1", "check", f"REMIX={args.remix}",
                              f"BUILD={env['BUILD']}", f"OT_PROJECT={project}"]):
            return 1
        # Preserve the exact restored image for every pressure invocation.
        image = out / "image.bin"
        shutil.copy2(ROOT / "out/mainos_bus.bin", image)
        report["provenance"]["image_sha256"] = sha256(image)
        if not run("cycles", [sys.executable, "tools/build/cycle_count.py", "--json"]):
            return 1
        data = json.loads((out / "cycles.stdout").read_text())
        report["measurements"]["dsp_static"] = data
        cycle_gate = report["gates"][names.index("cycles")]
        cycle_gate["status"] = budget_result(data)
        if not record(cycle_gate):
            return 1
        if profile == "not_applicable":
            for name in ("pressure_price", "pressure_render"):
                record(dict(name=name, status="not_applicable", reason=reason))
            return 0
        pressure_out = out / "pressure"
        if not run("pressure_price", [sys.executable, "tools/harness/pressure.py",
                                     "price", "--remix", args.remix, "--out", str(pressure_out)]):
            return 1
        price = json.loads((pressure_out / f"{args.remix}_price.json").read_text())
        report["measurements"]["pressure_price"] = price
        if any(core["over"] for core in price["cores"].values()):
            gate = report["gates"][names.index("pressure_price")]
            gate.update(status="failed", reason="selectable layouts exceed the static DSP wall")
            record(gate)
            return 1
        # Deterministic, non-silent input on ALL eight tracks, no external audio.
        from stress_project import make_sample
        stems = out / "stems"
        stems.mkdir()
        for track in range(1, 9):
            make_sample(stems / f"T{track}.wav")
        report["fixtures"]["stems"] = inventory(stems)
        rendered_ok = run("pressure_render", [sys.executable, "tools/harness/pressure.py",
                                             "render", "--remix", args.remix, "--image", str(image),
                                             "--out", str(pressure_out), "--stems", str(stems),
                                             "--top", "6", "--sample", "4", "--seed", "1",
                                             "--seconds", "2"])
        result_file = pressure_out / f"{args.remix}_render.json"
        rendered = json.loads(result_file.read_text()) if result_file.is_file() else []
        report["measurements"]["pressure_render"] = rendered
        if not rendered_ok:
            return 1
        evidence_error = pressure_evidence_error(rendered, price)
        if evidence_error:
            gate = report["gates"][names.index("pressure_render")]
            gate.update(status="failed", reason=evidence_error)
            record(gate)
            return 1
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, SystemExit) as exc:
        report["gates"].append(dict(name="runner", status="failed", reason=str(exc)))
        return 1
    finally:
        report["finished_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
        write_report(out, report)
        print(f"acceptance: {report['status']}: {out / 'report.json'}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
