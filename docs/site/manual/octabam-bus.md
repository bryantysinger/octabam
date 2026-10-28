### 1.1 About Octabam Bus

Octabam Bus is Octatrack OS 1.40C with a **delay and reverb bus** built
in, and the same sequencing, Kit, scene, MIDI and USB features as
[Octabam](../octabam/index.md). Every track's FX2 takes part in one chain:
a send on each track feeds a delay and a reverb, and their wet signal comes
out on the tracks that host them. Three new effects, SPECTRUM, CHARACTER
and MODULATION, join ten stock effects on FX1.

### 1.2 What changes on the unit

- **The bus.** Track 1 hosts the delay and track 5 the reverb. Every other
  track's FX2 is a SEND with two knobs, DEL and REV, that set how much of
  the track goes to each. The delay's repeats also feed the reverb.
- **A new Part is wired for you.** Track 1's FX2 is the Delay Server,
  track 5's the Reverb Server, track 8's the stock DELAY and the rest are
  SENDs, so a project made on the unit hosts the bus with no setup.
- **The FX2 chooser is locked.** It cannot change a track's effect. A Part
  or pattern paste, a Kit load and a project's stored effects can still
  set FX2.
- **The TEMPO window.** Press **TEMPO** to see and edit both engines'
  controls in one place. The delay follows the project tempo.
- **Everything else is as in Octabam:** BRAIN, Kits, page 2 locks and
  scene locks, MIDI scenes, CC mapping, USB and the sequencer, recorder
  and card fixes.

!!! warning "Set up tracks 1 and 5 first"
    Set tracks 1 and 5 to THRU with no trigs of their own. This is the only
    bus setup tested so far. Sounds programmed on track 1 made the delay
    pop and click, and the cause is still open. Track 5 with a sample
    machine or trigs has not been tested.

### 1.3 Before you install

Back up the CF card first. KITS writes a file into each project it loads.
A project made on the unit after installing needs no preparation; a project
made before needs it once, as described in
[Build and Install](../../../web-builder.md). To return to stock OS, follow
[Safety and Recovery](../../../safety.md). The [overview](../../../remix-bus.md)
shows the bus as a diagram.
