"""Airwindows Capacitor2 (Chris Johnson, MIT) -- the float reference CAP is
proven against (tools/verify/verify_spectrum.py). A transcription of
Capacitor2Proc.cpp's processDoubleReplacing with the per-buffer parameter
chase held at its target (ours chases per block) and the dither dropped.
A = lowpass (0..1, 1 open), B = highpass (0..1, 0 off), C = NonLin (0 mild
.. 1 intense), wet = 1."""
import math


class Capacitor2:
    def __init__(self, A, B, C):
        self.lp = A * A; self.hp = B * B
        self.nonLin = 1.0 + ((1.0 - C) * 6.0)
        self.trim = 1.5 / (self.nonLin ** (1.0 / 3.0))
        self.h = [[0.0] * 6, [0.0] * 6]      # A..F per channel
        self.l = [[0.0] * 6, [0.0] * 6]
        self.count = 0

    PAIRS = ((1, 3), (2, 4), (1, 5), (2, 3), (1, 4), (2, 5))   # case 0..5: (B|C, D|E|F)

    def sample(self, ch, x):
        scale = abs(2.0 - ((x + self.nonLin) / self.nonLin))
        lpA = self.lp * scale; hpA = self.hp * scale
        h, l = self.h[ch], self.l[ch]
        for k in (0,) + self.PAIRS[self.count]:
            h[k] = h[k] * (1.0 - hpA) + x * hpA; x -= h[k]
            l[k] = l[k] * (1.0 - lpA) + x * lpA; x = l[k]
        return x * self.trim

    def process(self, L, R):
        outL, outR = [], []
        for a, b in zip(L, R):
            self.count += 1
            if self.count > 5: self.count = 0
            outL.append(self.sample(0, a)); outR.append(self.sample(1, b))
        return outL, outR
