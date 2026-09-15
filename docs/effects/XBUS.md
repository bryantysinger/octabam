# The cross-core bus: one aux, delay into reverb, return on T8

The architecture record for the bus. The development logs are
`docs/history/XBUS_LOG.md` (the cross-core race) and `docs/history/BUS.md`
(the per-bank two-bus design this replaced, and the one-aux build of 7 Sep
2026). ✅ measured on the unit, 🟡 measured under the port or the harness,
❓ inferred.

## The shape

```
every track ──SEND──▶ [aux accumulator] ──▶ BusDelay (T1 FX2) ──chain──▶ BusVerb (T5 FX2) ──▶ RET on T8 (Character)
  (SEND's one knob; the hosts' too)         stage 1, WET                 stage 2, WET          one level

CORE 0 (payload A)  tracks 5–8   BusVerb   Y:0x4000–0xBFFF (private) + Y:0x30000–0x37FFF (shared lo) = 65,536 words = 1.49 s
CORE 1 (payload B)  tracks 1–4   BusDelay  Y:0x4000–0xBFFF (private) + Y:0x38000–0x3FFFF (shared hi) = 65,536 words = 1.49 s
```

- ✅ Payload A / core 0 serves tracks 5–8, payload B / core 1 tracks 1–4
  (marker flash, 10 Aug 2026). Host the reverb on track 5, the delay on 1–4.
- Under `SPEC=1` each server exists in one payload and can only be hosted
  on its own core's bank; any track can send into it. The absent server's
  dispatch id is aliased to the SEND client on the other payload, so a
  wrong menu pick runs a send.
- A server's memory is its core's two private FX2 slots plus half of the
  64K shared window `0x30000–0x3FFFF`, where P, X and Y alias ✅. The
  stock allocator's slot table (`X:0x255`, both payloads of the raw image)
  already hands the low half to core 0 and the high half to core 1
  (`docs/firmware/DSP.md` §7).
- Total bus latency is 2 blocks: 32 samples on hardware, 30 in the
  harness's 15-frame blocks (`docs/history/TESTPASS.md`).

## The one aux bus (7 Sep 2026; ✅ flash 7, 9 Sep 2026)

- One send: `SEND` has one knob, `SEND` (slot 0). Both engines carry `SEND`
  at slot 0 as well (the host's own dry into the same accumulator, same
  headroom, count and auto-gain). Stations carry no sends; a part that
  stored 127 in a former send slot sends nothing.
- The chain: each stage stamps a shared word every block it runs (after
  its warm-up): the delay `Y:0x9c3` (read by the reverb) and `Y:0x9c5` (read
  by the return), the reverb `Y:0x9c4`; clear-on-read, one writer one
  reader, three blocks of grace. The delay's stage output goes mono at
  unity into the chain buffer `Y:0x901..0x940` (four rotations × 16 words,
  stored, never cleared). While the delay is live the reverb reads the
  chain buffer with bus gain 1/8 (the loop's `asl #3` lands the sample
  untouched); otherwise the aux accumulator with the 1/√N auto-gain.
  Delay only, reverb only, both, or neither all work.
- WET on each engine (slot 5): `out = in + wet × WET`, `in` the stage's
  chain input passing at unity — a pedal on the send: the send reaches the
  master through both stages and each WET adds its effect. Delay WET 0 = a
  clean reverb send with the delay in the chain (sample-exact against a
  reverb-only run two blocks later); reverb WET 0 = the delay's output at
  the return, the reverb taking nothing out. Until 15 Sep 2026 each stage
  crossfaded (`in × (1 − MIX) + wet × MIX`), so the reverb's MIX faded the
  delay out and both at 0 returned the dry send alone. Each stage publishes
  its output stereo, four deep (`0x9da` reverb, `0xa5a` delay); the host
  prints `wet × WET` under its dry, or nothing while a return is live.
- One return, on track 8: Character's `RET` (page-1 slot 4) returns the
  last live stage's output (the reverb's if it runs, else the delay's, else
  silence), added before the chain, and stamps both hosts quiet while it is
  up. Pinned to dispatch position 3 on payload A (`r7 $6700/$6800`); a
  Character anywhere else, T4 included, returns nothing. The core is read
  off the dispatch table (BusVerb's entry is real on A and the SEND alias on
  B, `X:$21c` vs `X:$21e`); a remix without BusVerb has no return.
- The send is refused on track 8: `SEND` at core 0's position 3 contributes
  and registers nothing (the master loop that silenced the unit on 6 Sep
  2026, `FAILURE_MODES.md`). Payload B's position 3 (T4) sends normally; the
  payload is told apart by SEND's `$30000` base literal, rewritten to
  `$38000` on B (`YBase.XBUS`).
- ✅ Flash 7 (tag OCTABAM21): the return reaches T8; the hosts go quiet
  while RET is up and print their own wet again within 3 blocks of RET → 0;
  the send is refused on T8; a T4 station returns nothing; delay-only falls
  through to the delay's output. ✅ Port O12: the send → delay → return path
  bit-identical to `dsp_host` at a 36-sample offset.
- Return balance on material (7 Sep, `out/rig/oneaux/`): drum loop −25.1 dB
  rms with the reverb at MIX 0 and −26.8 at MIX 127; pad −31.4 / −32.8; no
  makeup. (The "wet ~25 dB under the repeats" reading from the 438 Hz gate
  tone was retracted the same day.)

Slots (stamp every project before play, `tools/hw/ot_project.py
stamp-defaults <project> <remix> --all`; without `--all` the stamper
touches only the ids a station replaced):

| | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| SEND | SEND | | | | | | | | | | | |
| BusVerb | SEND | TIME | MOD | SIZE | TONE | WET | MODE | SHMR | DIFF | SHFT | GATE | RATE |
| BusDelay | SEND | TIME | FDBK | TONE | PING | WET | MODE | MDEP | MRAT | SIZE | PTCH | FRZE |
| Character | DRV | FOLD | TXTR | COMP | RET | TONE | MIX | SAT | — | — | WDTH | — |

## What a send is

A track on SEND runs a client that, each block, adds its level-scaled
audio into the current write accumulator and registers in the client
count. Servers consume the summed previous block. Under the two-bus layout
(until 7 Sep 2026) the client had two knobs, `x:(r6+0)` →DELAY and
`x:(r6+1)` →REVERB; driving the wrong one renders silence.

## The accumulators: four rotating buffers

Each bus keeps four accumulator buffers, rotated once per block, read two
buffers back from the write:

- Two buffers cannot be made safe at any clear time: the only clearable
  buffer is the one transitioning read→write, which is the flip a skewed
  reader on the other core may still be inside.
- Four because the count is a power of two: rotation `+16 & $30`, read
  offset `+32 & $30`, no compare, no clamp; the mask sanitises boot garbage.
- Read-two-back puts an idle block on each side of the reader, so either
  core may lead or lag by up to a block; it costs the second block of
  latency.
- Both directions ride the same rotation (core 1 reading core 0's clears;
  core 1 writing into core 0's accumulator).

Bus scratch, `Y:0x900..` in core 0's half of the shared window
(`modules/send/send_client.asm` is the map): `0x900` rotation, `0x901..0x940`
chain buffer, `0x941` BusVerb host's SEND field, `0x961..0x9a0` aux
accumulator, `0x9c1/0x9c2` role locks, `0x9c3..0x9c5` liveness stamps,
`0x9c7..0x9ca` aux send count per buffer. Role locks make the first
instance of a server the only one: a second instance returns as a
passthrough, so a server's cycle cost is charged once per bank.

## Housekeeping and the rotation

Housekeeping (flip the rotation, clear buffers) is gated to payload A;
every bus participant carries the block, and an election makes the
first-dispatched core-0 instance (position 0 = track 5) run it.

- Clients never read the shared rotation word directly: each core tracks
  it privately, advancing once per block (✅ 9 Sep 2026: per instance
  until then; the port showed core 1's fourth client on the wrong buffer
  every frame; now one tracker per core, `build_bus.py` ROTLATCH).
- The tracked rotation is seeded at `init` and is not self-healing:
  unseeded, a client booting one step out of phase writes the buffer being
  cleared (metallic on every core-1 sender after every power cycle).
- The housekeeper clears the buffer that will be written next block.

## Auto-gain

Every writer contributes with 3 bits of headroom (`asr #3`; eight
full-scale clients sum to 1.0) and registers in the per-block count; the
server multiplies the sum by 1/√N from a reciprocal table and shifts back.
The law was 1/N until 17 Aug 2026 (R27): uncorrelated tracks sum as √N,
so 1/N over-corrected by 3 dB per doubling (`modules/busverb/
reverb_server.asm` "THE LAW IS 1/sqrt(N)"; `docs/history/CAPTURE_18AUG.md`
capture E: three senders, two 10–15 dB quieter, dropped the wet 4.8 dB
against 1/N's predicted −9.5). The "1 through 7 senders render identically"
measurement fed the same tone to every sender, the one case where 1/N and
1/√N agree. Registration is gated on the send knob: a client that
registers and contributes nothing dilutes every real sender by N/(N+1)
(−6 dB with one sender). Every writer registers, the cross-core one
included.

## The three cross-core defects

Each found on hardware, each visible only once the previous one was fixed;
all three closed on the unit (sweep of core-1 tracks × delay modes):

| # | defect | fix |
|---|---|---|
| 1 | clear-vs-read: core 0 zeroing a buffer core 1 was still reading; +18 to +31 dB of broadband hash on the bus path | four buffers, read two back |
| 2 | the rotation read: each client read the shared rotation at its own dispatch time; block-rate amplitude jitter | per-core rotation tracking |
| 3 | clear-vs-write: core 0's clear racing core 1's writers | clear the next-block buffer |

Plus the unseeded rotation tracking above. The diagnostic that isolated
them: change what runs on track 5 (the housekeeper), which moves the flip
in time and nothing else.

## Standing caveats

- 🟡 The fix assumes the cores are rate-locked (same sample clock, constant
  phase offset); drift would show as a slow return of the artifact over
  minutes.
- The artifacts relocate: one (core-1 track, delay mode) pairing is bad at
  a time and moves with the mode or core 0's load; any "fixed" claim needs
  a track × mode sweep.
- `dsp_host` runs both cores since 7 Sep 2026, lock-step or under `-skew`;
  a mismatch under skew is a defect, identity is not evidence
  (`docs/remixer/HARNESS.md`). The decisive configuration is BusDelay on
  track 1, fed over the bus.
- Residual at 6–7 senders: 2 samples in 16,305 differ by ≤ 33 LSB
  (−105 dB) from the lag-0 control; does not scale with amplitude; filed as
  rounding under the added latency.

## Verification

`make verify-bus`: 19 layouts (17 until 18 Aug 2026; the two `IN` cases
were added after the delay's IN decode was deleted by a splice with 17/17
still passing), the three carriers of the housekeeping block, the election,
1–7 senders per bus, both cross-sends, split blocks, compared bit-for-bit
against a stamp (`SAVE=1` first). `tools/verify/verify_onebus.py` (in `make
check`) runs the chain on both cores: the return is the reverb's output and
both hosts are silent under it; delay-only falls through; neither engine
returns silence; delay WET 0 == no delay two blocks later, sample-exact;
reverb WET 0 returns the aux itself; both at WET 0 return the aux through
both stages; delay WET 127 + reverb WET 0 returns the delay-only return; a
SEND on core-0 position 3 at SEND 127
changes nothing and the mirror position on core 1 does; a station with
stored send bytes contributes nothing; the chain is identical under four
instruction-level skews. `make verify-twocore`: SEND, delay and series hops
on their real cores == the DEV hatch.

## The shared window

| range | what | notes |
|---|---|---|
| `0x30000–0x30047` | stock's per-frame parameter staging ✅ | rewritten every frame |
| `0x30000–0x37FFF` | core 0's half: BusVerb's relocated buffers (`0x30000`, `0x34000`), shimmer line, tank state | fully owned |
| `0x31000` / `0x32000` | stock bootstraps A and B ✅ | dead after boot |
| `0x36000+` | bus scratch (`docs/firmware/CHIP.md` for the extent) | both cores touch it |
| `0x38000–0x3FFFF` | core 1's half: BusDelay's LineL, 32,768 words (LineR is core 1's private `Y:0x4000–0xBFFF`, 15 Sep 2026) | 741 ms per line |

AGU modulo addressing needs power-of-2 alignment (big buffers at
`0x30000`/`0x34000`/`0x38000`/`0x3C000`); `0xC000–0x2FFFF` is absent, so no
single 128K buffer; the DSP56720 manual guarantees no bus contention while
the cores touch different 8K blocks ✅. A delay line based in core 0's half
sweeps the rotation word, the accumulators and the role locks every 16,384
samples (12 Aug 2026).

## Program space

`SPEC=1`: each payload carries SEND plus its own server, so the donor region
(2,724 words per core for the DEFAULT harvest, the three stock FX2 reverb
slots; since 3 Sep 2026 any of the thirteen, up to 6,158) is spent once per
effect. `SPEC=1` requires `XBUS=1`: without the bus each half of the tracks
reaches only its own core's server, and the build still makes sound, so the
build guards the combination. The build report is the free-word ledger
(`make bus`).
