"""Airwindows Pockey (Chris Johnson, MIT, 2022) -- the float reference the
TXTR port is proven against (tools/verify/verify_character.py). A direct
transcription of PockeyProc.cpp's processDoubleReplacing at 44.1 kHz, with the
per-block parameter interpolation dropped (ours is per block too) and the
dither left out. A = the frequency slider, B = resolution, wet = 1."""
import math

FREQ_MIN = 0.08          # at 44.1 kHz (0.08 / overallscale)
PHI = 0.618033988749894848204586


def params(A: float, B: float):
    freq = (pow(1.0 - A, 3) * (PHI - FREQ_MIN)) + FREQ_MIN      # 0.08 .. 0.618, "always engaged"
    rez = pow(B * PHI, 3) + 0.000244140625                        # 2^-12 .. ~0.236, "at least 12 bit"
    return freq, rez


def ulaw_enc(x):
    x = max(-1.0, min(1.0, x))
    if x > 0: return math.log(1.0 + 255 * x) / math.log(255)
    if x < 0: return -math.log(1.0 + 255 * -x) / math.log(255)
    return 0.0


def ulaw_dec(x):
    x = max(-1.0, min(1.0, x))
    if x > 0: return (pow(256, x) - 1.0) / 255
    if x < 0: return -(pow(256, -x) - 1.0) / 255
    return 0.0


class Pockey:
    def __init__(self, A, B):
        self.freq, self.rez = params(A, B)
        self.position = [0.0, 0.0]; self.held = [0.0, 0.0]; self.last = [0.0, 0.0]; self.soften = [0.0, 0.0]

    def sample(self, ch, x):
        freq, rez = self.freq, self.rez
        dry = x
        y = ulaw_enc(x)
        offset = y
        if y > 0:
            while offset > 0: offset -= rez
            y -= offset
        if y < 0:
            while offset < 0: offset += rez
            y -= offset
        y *= (1.0 - rez)
        y = ulaw_dec(y)
        self.position[ch] += freq
        out = self.held[ch]
        if self.position[ch] > 1.0:
            self.position[ch] -= 1.0
            p = self.position[ch]
            self.held[ch] = (self.last[ch] * p) + (y * (1 - p))
            out = (self.held[ch] * (1 - p)) + (out * p)
        y = out
        slew = abs(y - self.soften[ch]) * freq
        if slew > 0.5: slew = 0.5
        y = (y * slew) + (self.soften[ch] * (1.0 - slew))
        self.last[ch] = dry
        self.soften[ch] = out
        return y

    def process(self, L, R):
        return [self.sample(0, v) for v in L], [self.sample(1, v) for v in R]


# ---- the port's tables: 257 points each over [0, 1], linearly interpolated --
def enc_table():
    return tuple(round(8388607 * min(1.0, math.log(1 + 255 * i / 256) / math.log(255))) for i in range(257))


def dec_table():
    return tuple(round(8388607 * (256 ** (i / 256) - 1) / 255) for i in range(257))
