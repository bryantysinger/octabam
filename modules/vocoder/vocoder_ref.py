#!/usr/bin/env python3
"""Float reference for VOCODER: the law in the form the DSP computes it.

A ten-band channel vocoder after the Roland VP-330 (service notes, 21 Sept 1979: ten high-Q
band-pass filters, centres 200 Hz to 6 kHz, pre-emphasis before analysis and a de-emphasised
synthesis response, a high-consonant circuit). modules/vocoder/DESIGN.md has the reasons.

  modulator m = (L + R)/2 (MODE INT) or L (MODE EXT); carrier c = the internal 8' and 4'
    sawtooths at NOTE (INT) or R/2 (EXT)
  each band k: two Chamberlin band-pass sections, at fc x 0.91 and fc x 1.10, Q 7, the input
    scaled by q = 1/7 so each section peaks at the input's level; the same pair on m and on c
  envelope: v = (W_k / 2) |band_k(m)|; e = max(v, e (1 - ad)), ad for 10 ms: a peak
    detector, instant attack, as the VP-330's diodes; 48-bit
  out = limit(2^8 sum_k e_k band_k(c) + (CONS/32) hp6(m/2) + (DRY/128) m), the level the
    track's AMP; GEND, WHSP, DRY and CONS each follow their knob through a one-pole per call
    (8 ms, vocoder_law.dz_step), so a scene or crossfader jump does not land as one step
  W_k folds in the VP-330's pre-emphasis (1 - 0.9 z^-1 at fc), its de-emphasis (a 9 dB fall
    across the bands) and the pair's gain at fc (1/g^2), so the bass bands are not starved
    of level before the 24-bit filters
  hp6: the modulator at half level through three Chamberlin high-pass sections at 4 kHz
    (a 6th-order Butterworth: Q 0.518, 0.707, 1.932)
  sawtooths: polyBLEP, branch-free: corr = (1 - min(u/du, 1))^2 - (1 - min((1-u)/du, 1))^2

    python3 modules/vocoder/vocoder_ref.py      # self-check
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from vocoder_law import (FS, CENTRES, Q_BAND, EMPH, TILT_DB, RELEASE_MS,  # noqa: F401
                         MAKEUP_SHIFT, NOTE_LO, NOTE_HI, K_BLEP, HP_FC, HP_Q, NOTE_NAMES,
                         SCALES, RANGE_ST, P_MAX, snap, C0_HZ,
                         band_coefs, note_name, note_inc, note_idt,
                         GLD, LCG_SEED, WHSP_G, pitch_target, inc_of, idt_of, gend_half, lcg, q23, s24,
                         dz_k, dz_step)


def _saw(n, inc, idt, octave):
    """The DSP's sawtooth: signed 24-bit phase (a cycle is 2^24), polyBLEP, x2 for the 4' octave."""
    out = np.empty(n)
    p = 0
    for i in range(n):
        s = p << octave & 0xFFFFFF
        s = (s - (1 << 24) if s & 0x800000 else s) / (1 << 23)          # [-1, 1)
        u = s / 2 + 0.5
        it = idt / (1 << octave)
        ta = min(u * it * (1 << K_BLEP), 1.0)
        tb = min((1 - u) * it * (1 << K_BLEP), 1.0)
        out[i] = s + (1 - ta) ** 2 - (1 - tb) ** 2
        p = (p + inc) & 0xFFFFFF
    return out


def carrier_int(step, n):
    inc, idt = note_inc(step), note_idt(step)
    return 0.3 * _saw(n, inc, idt, 0) + 0.2 * _saw(n, inc, idt, 1)


def _svf_bp(x, f, q):
    low = band = 0.0
    y = np.empty_like(x)
    for i, v in enumerate(x):
        low += f * band
        band += f * (q * v - low - q * band)
        y[i] = band
    return y


def _svf_hp(x, f, q):
    low = band = 0.0
    y = np.empty_like(x)
    for i, v in enumerate(x):
        low += f * band
        h = v - low - q * band
        band += f * h
        y[i] = h
    return y


def _knob(v, nb):
    """A knob per call: a scalar, or one value per call (a p-lock or a fader move)."""
    a = np.asarray(v)
    return np.full(nb, int(a)) if a.ndim == 0 else a[:nb].astype(int)


def _blep(s, idt):
    """The DSP's polyBLEP sawtooth sample at signed phase s in [-1, 1), idt = 1/(du 2^12) as a float."""
    u = s / 2 + 0.5
    ta = min(u * idt, 2.0 ** -K_BLEP) * (1 << K_BLEP)
    tb = min((1 - u) * idt, 2.0 ** -K_BLEP) * (1 << K_BLEP)
    return s + (1 - ta) ** 2 - (1 - tb) ** 2


def smoothed(v, nb, frames=15, prime=False):
    """A knob per call through the de-zipper, as the DSP holds it (a Q23 integer per call). The
    state starts at 0 (init), or with prime at the first call's knob (GEND)."""
    t = _knob(v, nb) << 16
    k = dz_k(frames)
    out = np.empty(nb, int); s = None if prime else 0
    for b in range(nb):
        s = int(t[b]) if s is None else dz_step(s, int(t[b]), k)
        out[b] = s
    return out


def incs_02(nb, note, bend, glide, frames=15, scal=0, key=0, rang=0):
    """The phase increment of each of nb calls, bit for bit as the DSP makes it: NOTE snapped to
    SCAL in KEY, BEND scaled by RANG, P held to C0 .. under C8, glided per call in 48 bits."""
    nt, bd, gl, sc, ky, rg = (_knob(k, nb) for k in (note, bend, glide, scal, key, rang))
    incs = np.empty(nb, int); ps48 = None
    for b in range(nb):
        P = pitch_target(int(nt[b]) << 16, int(bd[b]) << 16, int(sc[b]) << 8, int(ky[b]) << 16, int(rg[b]) << 8)
        if ps48 is None:
            ps48 = P << 24
        else:
            k = frames * GLD[min(int(gl[b]), 4)]
            d = P - (ps48 >> 24)
            ps48 += 2 * d * k                              # mac: 48 bits
        incs[b] = inc_of(ps48 >> 24)
    return incs


def carrier_02(n, note, bend, glide, whsp, frames=15, scal=0, key=0, rang=0):
    """The 0.2 INT carrier, per call of `frames` samples as dsp_host makes them: NOTE (snapped
    to SCAL in KEY) + BEND (its reach set by RANG) as a log pitch, glided in 48 bits, to a phase
    increment (bit-exact: the phase must not drift), then the 8' and 4' polyBLEP sawtooths;
    WHSP (smoothed per call) blends to the LCG's noise. Returns (c, incs)."""
    nb = -(-n // frames)
    incs = incs_02(nb, note, bend, glide, frames, scal, key, rang)
    wh = smoothed(whsp, nb, frames)
    c = np.empty(n)
    p = 0; x = LCG_SEED; G = WHSP_G
    for b in range(nb):
        inc = int(incs[b]); idt = idt_of(inc)
        i8, i4 = idt / (1 << 23), (idt >> 1) / (1 << 23)
        w = wh[b] / (1 << 23)
        for i in range(b * frames, min(n, (b + 1) * frames)):
            s8 = s24(p) / (1 << 23)
            s4 = s24(p << 1) / (1 << 23)
            mix = 0.3 * _blep(s8, i8) + 0.2 * _blep(s4, i4)
            x = lcg(x)
            c[i] = mix + w * (G * s24(x) / (1 << 23) - mix)
            p = (p + inc) & 0xFFFFFF
    return c, incs


def _svf_bp_k(x, fk, frames):
    """A Chamberlin band-pass whose coefficient may change per call (fk: one per call)."""
    q = 1.0 / Q_BAND
    low = band = 0.0
    y = np.empty_like(x)
    for i, v in enumerate(x):
        f = fk[i // frames]
        low += f * band
        band += f * (q * v - low - q * band)
        y[i] = band
    return y


def analysis_coefs(gend_s):
    """Per band (f1a, f2a) as the DSP writes them to its Y slot: the synthesis coefficient x A,
    floor(4 f (A/2) / 2^24), limited to the largest Q23. gend_s: GEND's smoothed word."""
    ah = gend_half(gend_s)
    return [tuple(min((4 * q23(f) * ah) >> 24, 0x7FFFFF) / (1 << 23) for f in (f1, f2))
            for f1, f2, _ in band_coefs()]


def vocode(L, R, mode=0, note=24, bend=64, gend=64, whsp=0, cons=48, dry=0, glide=0, frames=15,
           scal=0, key=0, rang=0):
    """0.2: MODE 0 INT, 1 EXT; knob values as the panel gives them (a scalar, or one per call of
    `frames` samples). LEVL is gone: the level is the track's AMP. Returns the mono output."""
    L = np.asarray(L, float); R = np.asarray(R, float); n = len(L)
    nb = -(-n // frames)
    m = (L + R) / 2 if mode == 0 else L
    c = carrier_02(n, note, bend, glide, whsp, frames, scal, key, rang)[0] if mode == 0 else R / 2
    q = 1.0 / Q_BAND
    ad = 1 - math.exp(-1 / (FS * RELEASE_MS * 1e-3))
    g = smoothed(gend, nb, frames, prime=True)
    per_call = [analysis_coefs(int(v)) for v in g]
    acc = np.zeros(n)
    for k, (f1, f2, w) in enumerate(band_coefs()):
        a = _svf_bp_k(_svf_bp_k(m, [pc[k][0] for pc in per_call], frames), [pc[k][1] for pc in per_call], frames)
        b = _svf_bp(_svf_bp(c, f1, q), f2, q)
        e = np.empty(n); ev = 0.0
        for i, v in enumerate(w * np.abs(a)):
            ev = max(v, ev * (1 - ad))               # a peak detector: instant attack
            e[i] = ev
        acc += e * b
    hf = 2 * math.sin(math.pi * HP_FC / FS)
    hp = m / 2
    for qq in HP_Q:
        hp = _svf_hp(hp, hf, 1 / qq)
    cs, dr = smoothed(cons, nb, frames), smoothed(dry, nb, frames)
    csn = np.repeat(cs, frames)[:n] / (1 << 21)              # 4 CONS, CONS a Q23 word
    drn = np.repeat(dr, frames)[:n] / (1 << 23)
    return np.clip(acc * (1 << MAKEUP_SHIFT) + csn * hp + drn * m, -1.0, 1.0 - 2 ** -23)


if __name__ == "__main__":
    ok = True
    cf = band_coefs()
    print("f1", [round(x, 5) for x, _, _ in cf]); print("f2", [round(x, 5) for _, x, _ in cf])
    print("W/2", [round(w, 4) for _, _, w in cf]); ok &= all(0 < w < 1 for _, _, w in cf)
    print("NOTE", note_name(0), "..", note_name(60), "; C3 is step", [s for s in range(61) if note_name(s) == "C3"][0])
    ok &= all(note_idt(s) < 1 for s in range(61))
    # the sawtooth's aliasing: a C6 saw against an ideal band-limited one
    n = 1 << 15; s = _saw(n, note_inc(60), note_idt(60), 0)
    X = np.abs(np.fft.rfft(s * np.blackman(n))); fr = np.fft.rfftfreq(n, 1 / FS); f0 = note_inc(60) * FS / (1 << 24)
    harm = np.zeros_like(X, bool)
    for h in range(1, int(FS / 2 / f0) + 1):
        harm |= np.abs(fr - h * f0) < 15
    band = (fr > 100) & (fr < 7000)
    alias = 10 * math.log10(np.sum(X[band & ~harm] ** 2) / np.sum(X[band & harm] ** 2))
    print(f"C6 polyBLEP saw: aliased power 100 Hz-7 kHz {alias:.1f} dB under its harmonics"); ok &= alias < -40
    # a silent modulator gives silence; a steady vowel-like modulator gives the carrier
    t = np.arange(int(FS)) / FS
    y0 = vocode(np.zeros(len(t)), np.zeros(len(t)), cons=48)
    _, incs = carrier_02(4410, 24, 64, 0, 0)
    print("C3 at BEND centre: inc", incs[0], "=", note_inc(24), "(0.1's table)"); ok &= incs[0] == note_inc(24)
    _, incs = carrier_02(15 * 3000, 24, np.r_[[64] * 10, [127] * 2990], 2, 0)
    st = 12 * np.log2(incs / incs[0])                  # the glide runs on log pitch
    k63 = int(np.argmax(st > 0.632 * st[-1])) - 10
    print(f"GLIDE 80 ms: 63 % of a bend reached after {k63 * 15 / FS * 1000:.1f} ms"); ok &= abs(k63 * 15 / FS * 1000 - 80) < 4
    print("silence in, INT: peak", float(np.max(np.abs(y0)))); ok &= not np.any(y0)
    # the de-zipper: a jump 0 -> 127 reaches 63 % in about 8 ms and settles on the knob's word
    sm = smoothed(np.r_[[0] * 4, [127] * 400], 404)
    k63 = int(np.argmax(sm > 0.632 * (127 << 16))) - 4
    print(f"de-zipper: 63 % of a jump after {k63 * 15 / FS * 1000:.1f} ms, settles {(127 << 16) - sm[-1]} LSB under it")
    ok &= abs(k63 * 15 / FS * 1000 - 8) < 1 and abs((127 << 16) - sm[-1]) < 16
    # ---- SCAL, KEY, RANG -----------------------------------------------------------------------
    def old_target(nr, br):                          # 0.2 as built before SCAL, KEY and RANG
        n = min((nr & 0x7F0000) >> 16, 60); y = (br & 0x7F0000) - 0x400000
        return ((n + 12) << 16) + ((y * 0x180000) >> 23)
    same = all(pitch_target(n << 16, b << 16) == old_target(n << 16, b << 16)
               for n in range(128) for b in range(128))
    print("SCAL CHRO, KEY C, RANG 12ST (all 0): P is 0.2's for every NOTE and BEND byte:", same); ok &= same

    def hz(P):
        return inc_of(P) * FS / (1 << 24)

    def ideal(n, iv, key):                            # the rule, written out apart from the table
        m = n
        while (m - key) % 12 not in iv:
            m -= 1
        return m
    worst, mono = 0.0, True
    for si, (nm, iv) in enumerate(SCALES):
        for key in range(12):
            qs = [snap(n, si, key) for n in range(61)]
            mono &= all(b >= a for a, b in zip(qs, qs[1:]))
            for n in range(61):
                want = 440.0 * 2 ** ((NOTE_LO + ideal(n, set(iv), key) - 69) / 12)
                got = hz(pitch_target(n << 16, 64 << 16, si << 8, key << 16, 0))
                worst = max(worst, abs(got / want - 1))
    print(f"SCAL x KEY x NOTE (10 x 12 x 61): pitch within {worst * 100:.4f} % of the table; monotonic: {mono}")
    ok &= worst < 5e-4 and mono
    worst = 0.0
    for r, st in enumerate(RANGE_ST):
        for n in (0, 24, 60):
            for b in (0, 64, 127):
                semis = NOTE_LO + n - 12 + st * (b - 64) / 64        # above C0
                want = C0_HZ * 2 ** (max(semis, 0) / 12)
                got = hz(pitch_target(n << 16, b << 16, 0, 0, r << 8))
                worst = max(worst, abs(got / want - 1))
    print(f"RANG x NOTE C1 C3 C6 x BEND -64 0 +63: pitch within {worst * 100:.4f} % (C0 the floor)"); ok &= worst < 5e-4
    top = pitch_target(60 << 16, 127 << 16, 0, 0, 2 << 8)
    print(f"the top: C6 + 23.6 semitones, P 0x{top:06x} under P_MAX 0x{P_MAX:06x}, {hz(top):.1f} Hz; "
          f"the floor: C1 - 24 is held at C0, {hz(pitch_target(0, 0, 0, 0, 2 << 8)):.2f} Hz")
    ok &= top < P_MAX and pitch_target(0, 0, 0, 0, 2 << 8) == 0
    inc = inc_of(top); s = _saw(n := 1 << 15, inc, idt_of(inc) / (1 << 23), 0)
    X = np.abs(np.fft.rfft(s * np.blackman(n))); f0 = inc * FS / (1 << 24)
    harm = np.zeros_like(X, bool)
    for h in range(1, int(FS / 2 / f0) + 1):
        harm |= np.abs(fr - h * f0) < 15
    alias = 10 * math.log10(np.sum(X[band & ~harm] ** 2) / np.sum(X[band & harm] ** 2))
    print(f"top polyBLEP saw ({f0:.0f} Hz): aliased power 100 Hz-7 kHz {alias:.1f} dB re its harmonics there")
    print("SELF-CHECK", "OK" if ok else "FAILED")
