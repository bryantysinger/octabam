# Module acceptance evidence

`make check REMIX=<name>` is the development floor. It can skip checks
when local prerequisites are absent. `make accept` is the stricter
evidence-producing workflow: a nonzero command, failure marker, timeout,
missing prerequisite, or applicable `[SKIP]` prevents acceptance.
A verifier's explicit `[N/A]` means the tested behavior is absent, not
that its tools or fixture are missing.

## Run locally

Use your own stock 1.40C, initialized submodules, the documented assembler
toolchain, DSP host, emulator venv and a worktree-local `make emu-cf`
build. Nothing flashes hardware.

```sh
make accept REMIX=bamsep26 STRESS_SOURCE="/path/to/local/project"
# Or supply a project you prepared for this remix:
make accept REMIX=bamsep26 OT_PROJECT="/path/to/local/project"
# Optional fresh destination and per-command timeout:
make accept REMIX=bamsep26 OT_PROJECT="/path/to/local/project" \
  ACCEPTARGS='--out out/acceptance/review-1 --timeout 3600'
```

The generated fixture reuses the stress-project work from
`repeat98/octamad` commit `28957d7`: eight FLEX tracks, three LFOs per
track, dense parameter locks, and four Parts/patterns.
T2 SEND is reserved for the existing MIDI assertion (14 locked slots on
T2, 15 elsewhere); its third LFO targets FX1 instead.
Only its generator is distributed. Project bytes stay local.
The sample path is project-relative, so `verify_set` can find and stage
the generated audio. See [STRESS_PROJECT](../../tools/harness/STRESS_PROJECT.md).

Acceptance runs these stages, serially:

1. Check prerequisites and the available stress profile.
2. Generate or fingerprint the project fixture.
3. Run the existing `make check` with the exact remix, build and project;
   refuse missing evidence even when a verifier returns zero.
4. Save the restored shipping image's fingerprint and price the selected
   remix. Reject a static estimate above its declared DSP wall.
5. Price the existing rig's layouts; reject any layout over the wall.
6. Render the six dearest and four seeded random layouts per core using
   deterministic input on all eight tracks, dirty memory and write guards.
   Record the per-layout flags and instruction meters.

A failed stage stops dependent stages, which stay `not_run` in the report.
Use a fresh output directory for each run; old output is never accepted
as new evidence. Existing checks and pressure tools still use their
worktree's `out/`, so run one acceptance job per worktree.

## Coverage is explicit

The initial DSP pressure profile covers precisely the six DSP modules
in bamsep26 (SEND, the two servers and the three stations). Other DSP
selections are **blocked** until a profile specifies their worst settings,
routing, fixtures and assertions. Adding a module must not silently test
it at default settings. ColdFire-only remixes have no DSP pressure stage;
the ordinary image, oracle and project gates still apply.

A generated project's automated playback checks A01 through the existing
`verify_set`. A02-A04 exist for further testing; this workflow does not
claim automated pattern/Part transitions, long soaks, or recording/storage
stress. Operator-supplied projects are fingerprinted but their workload
coverage is the operator's responsibility.

A result below the static DSP wall is not proof of real-time headroom.
The counter omits contention and has known error. ColdFire instruction
counts, DSP static costs and emulator meters are different measurements.
No calibrated CPU deadline or storage budget is introduced by this PR.

`passed` means the required local stages passed for these inputs.
It does not mean safe on every combination or verified on hardware.
Reports always carry `hardware_validated: false` and the known
limitations. Hardware captures, listening and timing remain separate
evidence; unresolved upstream burst failures are not waived.

## Report v1

Each run writes `out/acceptance/<timestamp>/report.json`, logs and local
artifacts. [acceptance.schema.json](acceptance.schema.json) defines the
versioned interchange envelope. Consumers must check `schema_version`
before reading it.

- `status`: `running` until finalization, then `passed`, `blocked`, or
  `failed`. A pass is published only after the measurement files validate.
- `gates`: command, exit code, elapsed time, log references, skip/N/A
  messages and one of `passed`, `failed`, `blocked`, `not_applicable`,
  `not_run`. Stages without a command carry their reason instead.
- `provenance`: repository revision, dirty state, source/diff hashes,
  submodule revisions, tool fingerprints, Python/platform, stock and
  tested image hashes. Uncommitted source is identifiable too.
- `modules`: selected keys, kinds and manifest hashes.
- `fixtures`: relative filenames and hashes, never project/audio bytes.
  Referenced samples outside the project (including their `.ot` metadata)
  are fingerprinted too; missing referenced files have null hashes.
- `parameters`: build/bank and pressure sampling settings.
- `measurements`: existing cycle/price/render JSON, preserving its units
  and per-layout findings rather than translating it to a CPU percentage.

Firmware, generated projects, audio and raw logs remain local in ignored
`out/`. Do not attach the output directory to a PR. Review reports/logs
before sharing: filenames and paths can reveal local project information.

## PR checks

`make test-acceptance` runs firmware-free negative controls: successful
commands that skip, stderr skips, swallowed failures, timeouts, unknown
DSP profiles, missing prerequisites, stale destinations, absent meters, incomplete sampling and budget
overruns. The CI job tests this machinery only; a green job does not
replace a local acceptance report.

Submit the command, source revision, report status, coverage, skipped or
blocked stages, and outstanding hardware evidence with a module PR.
A new module's profile and behavioral tests belong in that same PR.
