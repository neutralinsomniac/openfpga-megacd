#!/usr/bin/env python3
"""Per-test comparison of jt12 vs Nuked streams from tb_fm.

Usage: compare_test.py <prefix> [gain]
  gain = fixed nuked/jt12 scale (from the 'reference' test). If omitted,
  fitted per-test (masks absolute-level bugs; fine for shape-only tests).

Reports amplitude-envelope error (2 ms bins, dB), pitch mismatch on
voiced segments, and the worst divergent regions with timestamps.
Exit summary line is machine-grepable: "SUMMARY <prefix> ..."
"""
import sys
import numpy as np

RATE = 53693175 / 1008.0
BIN = int(RATE * 0.002)          # 2 ms envelope bins
SILENCE_DB = -55.0

def load(p):
    return np.fromfile(p, dtype='<i4').astype(np.float64).reshape(-1, 2).sum(1)

def envelope_db(x, full):
    n = len(x) // BIN
    e = np.abs(x[:n*BIN]).reshape(n, BIN).max(1)
    return 20*np.log10(np.maximum(e, 1e-9) / full)

def seg_freq(x):
    """fundamental via autocorrelation peak"""
    x = x - x.mean()
    if np.abs(x).max() < 1:
        return 0.0
    ac = np.correlate(x, x, 'full')[len(x)-1:]
    ac[:8] = 0
    lag = int(ac.argmax())
    return RATE/lag if lag > 0 else 0.0

def main():
    prefix = sys.argv[1]
    gain = float(sys.argv[2]) if len(sys.argv) > 2 else None
    j = load(f'{prefix}_jt12.s32')
    n = load(f'{prefix}_nuked.s32')
    ln = min(len(j), len(n))
    j, n = j[:ln], n[:ln]
    if gain is None:
        denom = float((j*j).sum())
        gain = float((j*n).sum())/denom if denom else 1.0
    j = j * gain

    full = max(np.abs(n).max(), 1.0)
    ej, en = envelope_db(j, full), envelope_db(n, full)
    m = min(len(ej), len(en)); ej, en = ej[:m], en[:m]

    active = (en > SILENCE_DB) | (ej > SILENCE_DB)
    d = np.where(active, np.abs(ej - en), 0.0)
    # ignore single-bin edges (keyon/keyoff staircase alignment)
    d3 = np.minimum(d, np.minimum(np.roll(d, 1), np.roll(d, -1)))

    bad = d3 > 1.0
    print(f'{prefix}: active bins {int(active.sum())}, '
          f'>1dB sustained: {int(bad.sum())} ({100*bad.sum()/max(active.sum(),1):.1f}%), '
          f'max sustained err {d3.max():.2f} dB, gain {gain:.3f}')

    # worst regions
    if d3.max() > 1.0:
        idx = np.argsort(d3)[::-1]
        shown = []
        for i in idx:
            t = i * BIN / RATE
            if any(abs(t - s) < 0.05 for s in shown):
                continue
            shown.append(t)
            print(f'   t={t:7.3f}s  err={d3[i]:6.2f} dB  jt12={ej[i]:7.1f} dB  nuked={en[i]:7.1f} dB')
            if len(shown) == 8:
                break

    # pitch check on 100ms voiced segments
    seg = int(0.1 * RATE)
    mism = 0
    for s0 in range(0, ln - seg, seg):
        if np.abs(n[s0:s0+seg]).max() < full * 10**(SILENCE_DB/20):
            continue
        fj, fn_ = seg_freq(j[s0:s0+seg]), seg_freq(n[s0:s0+seg])
        if fn_ > 0 and abs(fj - fn_) / fn_ > 0.01:
            if mism < 5:
                print(f'   pitch t={s0/RATE:7.3f}s jt12={fj:8.1f}Hz nuked={fn_:8.1f}Hz')
            mism += 1
    print(f'SUMMARY {prefix} badpct={100*bad.sum()/max(active.sum(),1):.1f} '
          f'maxdb={d3.max():.2f} pitch_mism={mism}')

if __name__ == '__main__':
    main()
