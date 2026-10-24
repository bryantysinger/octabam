# SEQUENCER EVENTS

System module that lets multiple modules respond to the same native sequencer
hooks. It owns the transport start/resume and accepted sequencer-note hooks
once, then calls the handlers registered by the selected modules. This avoids clients
competing for the same detour sites, following STORE's registration pattern.

Clients retain their own musical behavior. EUCLID uses the start and resume
notifications to reset its clock; its rhythm engine, DSP and interrupt guard
remain unchanged. SEQUENCER EVENTS adds no controls or persistent state.

## Registration

A client declares `requires=("SEQUENCER EVENTS",)` and registers its module key,
symbol prefix and handled events in `CLIENTS` in `manifest.py`. For example:

```python
('EUCLID', 'eu_seq', ('start', 'resume'))
```

This resolves to `eu_seq_start` and `eu_seq_resume`. Registration happens at
build time: clients absent from the remix are omitted, and unresolved handler
symbols fail linking. EUCLID is currently the only registered client.

## Events

| Event | Callback arguments | Timing |
| --- | --- | --- |
| `start` | d0: native PLAYING value | After the native PLAYING write on a fresh start |
| `resume` | d0: native PLAYING value | After the native PLAYING write on resume |
| `midi_note_accepted` | d0: MIDI track 0–7; d1: native pool kind; d2: packet velocity; d3: packet note number | After the native note sender returns on free-note acceptance or ownership replacement, before final ownership bookkeeping |

`midi_note_accepted` runs per accepted note, so a chord can produce multiple callbacks.
Its note number is the outgoing packet's pitch, not a logical chord root or
source-track pitch. Clients retain their own root, register-history and
accumulator policies. The pool kind is passed through unchanged (1 denotes the
live arp pool); the dispatcher does not filter it.

Native zero-velocity notes and rejected notes bypass these boundaries. Note-offs,
CCs and other MIDI sends are not reported. The arguments reflect the packet buffer
after the sender returns; this is not confirmation of UART delivery or external
playback. Callbacks must not modify that packet or native ownership state.

Each registered handler runs once per occurrence of its event, in registration
order. Handlers must not depend on another client's musical state or callback
order. Dispatch is synchronous; callbacks return normally before native
execution continues.

Callbacks may clobber d0–d7/a0–a6, but must preserve SP and the interrupt mask.
The dispatcher restores native registers and condition codes, and displaced
instructions execute once. Saved arguments and dispatch state live on the
stack. Clients must not emit MIDI or re-enter these hooks from a callback.

## Scope and verification

These hooks provide notifications, not transport control or note transformation.
Pause, STOP and MIDI input are not events in this module. New events
require an audited native boundary, an argument and ordering contract, and
installed-hook tests.

Software tests exercise the assembled dispatcher with zero, one and multiple
clients, checking arguments, callback order, register preservation and native
continuations. Native-code tests also execute packet construction and note
arbitration with a recording sender, checking the emitted note against the
callback payload, free/replacement ownership, rejection and zero-velocity bypass.
Composed-image checks verify exclusive hook ownership and that
selected client callbacks are installed. EUCLID's existing tests cover its
control engine, DSP and playback integration.

### Empty-client cost

Each event independently omits dispatch work at build time when it has no
selected handlers. The hooks and displaced native instructions remain installed.
Empty `start` and `resume` paths execute **3 instructions** versus **one stock
instruction**: **2 added instructions per event**. Tests cover all eight subsets
of event registrations, including MIDI-only, start-only and resume-only clients,
and compare the native PLAYING write, registers, stack and condition codes.

`verify_system_events.py` executes each detour from its installed entry jump to
the native continuation, with no MIDI clients, for all eight tracks and both
pool kinds. Both `0x4009fbb2` (free-note acceptance) and `0x4009fcfa` (ownership
replacement) execute **4 instructions**, including the entry jump and displaced
work, versus **one stock instruction**: **3 added instructions per accepted
note**. A selected MIDI client enables the full dispatcher. Tests cover empty
and transport-only registrations.
The stock instruction and patched path are measured in separate emulator
instances. This counts instructions, not ColdFire cycles, elapsed time or MIDI
latency; memory accesses and multi-register instructions are not cycle-weighted.

### Hardware scope

On radiohagen's MKII (`EUCL EVENTS 98`, owner report, 22 Oct 2026),
start/resume/stop passed with one EUCLID instance, instances on several tracks
and both FX slots on one track; ordinary and arpeggiated MIDI played and stopped
normally.

Ordinary and arpeggiated MIDI start/resume/stop also passed on optimized
`EUCL EVENTS 99` the same day. Empty transport paths without EUCLID remain
software-tested only.

The module retains `Proof.CHECK`: multi-client behavior and precise
callback payloads have software coverage only. EUCLID's unchanged interrupt-mask
guard is documented in its README under "Clock restart ordering"; callback
registration does not introduce a new selectable instance limit.
