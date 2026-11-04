"""VOCODER's constants and coefficient arithmetic, without numpy: the manifest builds the
P table from these, and vocoder_ref.py (the float reference) uses the same functions."""
import cmath
import math

FS = 44100.0
CENTRES = (200, 280, 400, 600, 900, 1300, 2000, 2800, 4000, 6000)
Q_BAND = 7.0
EMPH, TILT_DB = 0.9, 9.0
RELEASE_MS = 10.0                 # the envelope is a peak detector: instant attack
MAKEUP_SHIFT = 8
NOTE_LO, NOTE_HI = 24, 84                    # C1 .. C6, NOTE step 0 .. 60
K_BLEP = 12                                  # 1/du is held as 1/(du 2^12): C0 fits Q23
HP_FC, HP_Q = 4000.0, (0.5176, 0.7071, 1.9319)
NOTE_NAMES = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")


def chamberlin_bp(f, q):
    """Band-pass with the input scaled by q: B/X = f q (1 - z^-1) / (1 + (f^2 + f q - 2) z^-1 + (1 - f q) z^-2)."""
    return [f * q, -f * q], [1.0, f * f + f * q - 2.0, 1.0 - f * q]


def band_coefs():
    """Per band (f1, f2, W/2): the pair's tuning and the folded weight, halved to stay below 1."""
    q = 1.0 / Q_BAND
    out = []
    for k, fc in enumerate(CENTRES):
        f1, f2 = (2 * math.sin(math.pi * fc * r / FS) for r in (0.91, 1.10))
        z = cmath.exp(-1j * 2 * math.pi * fc / FS)
        g = 1.0
        for f in (f1, f2):
            b, a = chamberlin_bp(f, q)
            g *= abs((b[0] + b[1] * z) / (a[0] + a[1] * z + a[2] * z * z))
        emph = abs(1 - EMPH * z)
        tilt = 10 ** (-TILT_DB * k / (len(CENTRES) - 1) / 20)
        out.append((f1, f2, emph * tilt / (g * g) / 2))
    return out


def note_name(step):
    n = NOTE_LO + step
    return f"{NOTE_NAMES[n % 12]}{n // 12 - 1}"


def note_inc(step):
    """The phase increment for NOTE step (a cycle is 2^24 of the 24-bit signed phase)."""
    f = 440.0 * 2 ** ((NOTE_LO + step - 69) / 12)
    return round(f / FS * (1 << 24))


def note_idt(step):
    """1/(du 2^11), du = inc / 2^24 the phase step as a fraction of a cycle (Q23 < 1)."""
    return (1 << 24) / note_inc(step) / (1 << K_BLEP)


# ---- 0.2: continuous pitch (NOTE + BEND, GLIDE), GEND, WHSP -------------------------------
# Pitch is a log value P, in semitones above C0, times 2^16 (a Q23 word: P/2^23 = p/128).
# NOTE step n (C1 + n) is p = n + 12; BEND (a bipolar knob, y = value/128 - 1/2) adds 24 y,
# so +-12 semitones. GLIDE smooths P per call, P_s += (n7 K) (P - P_s), 48-bit.
# Then x = P_s 4/3 is octaves/8: o = floor(8x), r = frac(8x); inc = OCT[o] (2^r / 2).
C0_HZ = 440.0 * 2 ** ((12 - 69) / 12)                    # 16.35 Hz, MIDI 12
OCT = tuple(round(C0_HZ * (1 << 24) / FS * (1 << (o + 1))) for o in range(8))   # inc of C(o) x 2
EXP2 = (0.5, 0.34657731, 0.12007039, 0.02793164, 0.00447311, 0.00094755)  # 2^r / 2, r in [0, 1)
GLIDE_MS = (8.0, 30.0, 80.0, 200.0, 500.0)                # OFF is 8 ms: it de-zippers BEND's steps
GLIDE_LABELS = ("OFF", "30", "80", "200", "500")
GLD = tuple(round((1 << 23) / (FS * ms * 1e-3)) for ms in GLIDE_MS)   # per sample; x n7 per call
THIRD = 0x2AAAAB                                          # 1/3, Q23
# GEND scales the voice's formants by alpha = 2^t (octaves), t = y for y >= 0 and y/2 below:
# -64 is x0.84 (-3 semitones, a bigger, male voice), 0 is x1, +63 is x1.41 (+6, a female one;
# Ignorato, by ear, 5 Oct 2026: +-3 was too subtle). The analysis pairs run at f x A, A = 1/alpha = 2^-t,
# so they listen LOWER for a female voice. A/2 by a cubic in t over [-1/4, 1/2).
GEND_POLY = (0.5, -0.346695, 0.12034944, -0.02555639)          # 2^-t / 2, t in [-1/4, 1/2)
# WHSP: a 24-bit LCG, x' = A x + C mod 2^24 (period 2^24, 6.3 s); the sample is x, signed.
LCG_A, LCG_C = 1664525, 1013904223 & 0xFFFFFF
LCG_SEED = 0x2A5F31


def q23(v):
    return min(round(v * (1 << 23)), 0x7FFFFF) & 0xFFFFFF


def sq23(v):
    """Q23 as a signed integer (a coefficient the DSP loads with #>)."""
    return round(v * (1 << 23))


def s24(w):
    """A 24-bit word as a signed integer."""
    w &= 0xFFFFFF
    return w - (1 << 24) if w & 0x800000 else w


def fmul(a, b):
    """mpy a,b then move a1: floor(a b / 2^23), both signed Q23 integers (truncating, no rounding)."""
    return (a * b) >> 23


# ---- SCAL, KEY and RANG (page 2, slots 7, 10 and 9) ----------------------------------------
# SCAL snaps NOTE to the nearest note of the scale at or below it (monotonic: a sweep up never
# goes down); KEY is the scale's root; CHRO, value 0, leaves NOTE as it is. RANG sets BEND's
# reach; value 0 is 0.2's +-12 semitones. Value 0 of all three is 0.2 bit for bit.
SCALES = (("CHRO", tuple(range(12))),
          ("MAJ", (0, 2, 4, 5, 7, 9, 11)),
          ("MIN", (0, 2, 3, 5, 7, 8, 10)),          # natural minor (aeolian)
          ("DOR", (0, 2, 3, 5, 7, 9, 10)),
          ("PHRY", (0, 1, 3, 5, 7, 8, 10)),
          ("MIXO", (0, 2, 4, 5, 7, 9, 10)),
          ("HMIN", (0, 2, 3, 5, 7, 8, 11)),         # harmonic minor
          ("PMAJ", (0, 2, 4, 7, 9)),                # major pentatonic
          ("PMIN", (0, 3, 5, 7, 10)),               # minor pentatonic
          ("BLUE", (0, 3, 5, 6, 7, 10)))            # blues hexatonic
SCALE_LABELS = tuple(n for n, _ in SCALES)
KEY_LABELS = NOTE_NAMES
RANGE_ST = (12, 6, 24)                              # BEND's reach, +- semitones, by RANG
RANGE_LABELS = ("12ST", "6ST", "24ST")
RNG = (0x180000, 0x0C0000, 0x300000)                # R = 3/16, 3/32, 3/8: 2 R 2^23 is the reach x 2^16
P_MAX = 0x5FFFFF                                    # P held under C8 (96 semitones above C0): OCT's top


def scale_down(scale):
    """For each degree above the root (0..11), the semitones down to the scale note at or below."""
    return tuple(next(j for j in range(12) if (d - j) % 12 in scale) for d in range(12))


DOWN_WORDS = tuple(v << 16 for _, iv in SCALES for v in scale_down(set(iv)))   # 120 words, x 2^16


def snap(n, scal=0, key=0):
    """q(n), NOTE step n (C1 + n) snapped as the DSP does: n - DOWN[scal][(n + 12 - key) mod 12]."""
    n = min(n, 60); scal = min(scal, len(SCALES) - 1); key = min(key, 11)
    return n - (DOWN_WORDS[12 * scal + (n + 12 - key) % 12] >> 16)


def pitch_target(note_raw, bend_raw, scal_raw=0, key_raw=0, rang_raw=0):
    """P from the knob words as the DSP reads them: NOTE, BEND and KEY in the knob field
    (value << 16), SCAL and RANG in the companion field (value << 8)."""
    n = min((note_raw & 0x7F0000) >> 16, 60)
    k = min((key_raw & 0x7F0000) >> 16, 11)
    s = min((scal_raw & 0x7F00) >> 8, len(SCALES) - 1)
    r = min((rang_raw & 0x7F00) >> 8, 2)
    y = (bend_raw & 0x7F0000) - 0x400000
    p = ((snap(n, s, k) + 12) << 16) + ((y * RNG[r]) >> 23)
    return min(max(p, 0), P_MAX)


def inc_of(ps):
    """The phase increment for a glided P (an integer, Q23 semitones/128), exactly as the DSP."""
    x = ps + fmul(ps, THIRD)                               # octaves / 8
    o = x >> 20
    r = (x << 3) & 0x7FFFFF
    t = sq23(EXP2[5])
    for c in EXP2[4::-1]:
        t = sq23(c) + fmul(r, t)                            # Horner, each step truncated
    return fmul(OCT[o], t) if o < 8 else fmul(OCT[7], 0x7FFFFF)


def idt_of(inc):
    """1/(du 2^12) as Q23: floor(2^35 / inc), the DSP's integer division."""
    return (1 << 35) // inc


def gend_half(gend_s):
    """A/2 for GEND's smoothed word (the knob's 0x7F0000 field, smoothed per call: dz_step),
    by the DSP's truncating Horner."""
    y = s24(gend_s) - 0x400000
    x = y if y >= 0 else y >> 1                              # asr, then tpl: the halving below 0
    t = sq23(GEND_POLY[3])
    for c in GEND_POLY[2::-1]:
        t = sq23(c) + fmul(x, t)
    return t


# De-zipper: GEND, WHSP, DRY and CONS each follow their knob through a one-pole per call,
# s += k (T - s), k = n7 DZ_K, rounded to 24 bits (macr), with the same 8 ms as GLDE OFF, so a
# scene jump, a crossfader move or a p-lock lands over a few ms instead of as one step. Rounded,
# a settled value stands still (no -1 creep), so GEND's coefficients are not rewritten for it.
DZ_MS = GLIDE_MS[0]
DZ_K = GLD[0]


def dz_k(frames):
    """k for a call of `frames` samples, as the DSP makes it: mpy n7, K; asr; a0."""
    return frames * DZ_K


def dz_step(s, target, k):
    """One call of the de-zipper: macr x1,y0,a with a = s, x1 = k, y0 = target - s; the 48-bit
    sum rounded (convergent, the chip's default) to its high word."""
    v = (s24(s) << 24) + 2 * k * (target - s24(s))
    q, r = v >> 24, v & 0xFFFFFF
    if r > 0x800000 or (r == 0x800000 and q & 1):
        q += 1
    return q


def lcg(x):
    return (s24(x) * LCG_A + LCG_C) & 0xFFFFFF

WHSP_G = 0.31622777                          # uniform noise x G has the sawtooth mix's RMS
TABLE_BAND, TABLE_OCT, TABLE_GLD, TABLE_RNG, TABLE_DOWN = 0, 30, 38, 43, 46   # P table offsets:
# BAND[10] x {W/2, f1, f2}, OCT[8], GLD[5], RNG[3], DOWN[10][12]
