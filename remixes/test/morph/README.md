# morph (test remix)

MORPH alone with STORE (which it saves through) and the stock effects, for its gates:
`tools/morph/test_morph.py` runs `morph.s` from its source text (the window, the clock, saving
against mocks of STORE's file calls); `tools/morph/port_morph.py` builds this remix, boots it under
the port with a project (`OT_PROJECT`), opens the window with [T1]+[UP], sets STEPS and x, releases
T1 and reads the per-track weights.
