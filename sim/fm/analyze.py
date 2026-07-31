#!/usr/bin/env python3
"""Compare jt12 vs Nuked-OPN2 sample streams produced by tb_fm.

Usage: analyze.py <prefix> [--wav]
  reads <prefix>_jt12.s32 / <prefix>_nuked.s32 (interleaved int32 stereo,
  one frame per FM sample, rate = 53693175/1008 ~= 53267 Hz)

Aligns the streams (small integer lag), least-squares fits the gain between
them, then reports global error and the worst 20 ms windows so divergences
can be traced back to the register log.
"""
import sys
import numpy as np

RATE = 53693175 / 1008.0

def load(path):
    a = np.fromfile(path, dtype='<i4').astype(np.float64)
    return a.reshape(-1, 2)

def main():
    prefix = sys.argv[1]
    write_wav = '--wav' in sys.argv
    j = load(f'{prefix}_jt12.s32')
    n = load(f'{prefix}_nuked.s32')
    ln = min(len(j), len(n))
    j, n = j[:ln], n[:ln]
    print(f'samples: {ln} ({ln/RATE:.2f}s)')

    # mono for alignment
    jm, nm = j.sum(1), n.sum(1)

    # find best lag in +-32 samples over the loudest 2^20 span of the golden stream
    seg = min(ln, 1 << 20)
    c = np.concatenate(([0.0], np.cumsum(nm**2)))
    s0 = int((c[seg:] - c[:-seg]).argmax())
    best, bestlag = -np.inf, 0
    for lag in range(-32, 33):
        a = jm[s0+lag : s0+lag+seg] if s0+lag >= 0 else None
        if a is None or len(a) < seg:
            continue
        b = nm[s0 : s0+seg]
        c = float(np.dot(a, b))
        if c > best:
            best, bestlag = c, lag
    print(f'best lag (jt12 relative to nuked): {bestlag} samples')
    if bestlag > 0:
        j, n = j[bestlag:], n[:len(j)-bestlag]
    elif bestlag < 0:
        n, j = n[-bestlag:], j[:len(n)+bestlag]
    ln = min(len(j), len(n)); j, n = j[:ln], n[:ln]

    # least-squares gain jt12 -> nuked scale
    denom = float((j*j).sum())
    g = float((j*n).sum()) / denom if denom > 0 else 1.0
    j = j * g
    print(f'gain fit (nuked/jt12): {g:.4f}')

    d = j - n
    ref = np.sqrt((n**2).mean()) or 1.0
    print(f'global relative RMS error: {np.sqrt((d**2).mean())/ref*100:.3f}%')

    # windowed report
    W = 1024  # ~19 ms
    nw = ln // W
    dw = d[:nw*W].reshape(nw, W, 2)
    nwin = n[:nw*W].reshape(nw, W, 2)
    rms_d = np.sqrt((dw**2).mean(axis=(1, 2)))
    rms_n = np.sqrt((nwin**2).mean(axis=(1, 2)))
    rel = rms_d / np.maximum(rms_n, ref*0.01)   # floor: quiet windows judged vs global level
    order = np.argsort(rel)[::-1]
    print('\nworst windows (time_s  rel_err  jt12_rms  nuked_rms):')
    for i in order[:15]:
        t = i*W/RATE
        print(f'  {t:8.3f}  {rel[i]*100:7.2f}%  {np.sqrt((dw[i]**2).mean()):9.1f}  {rms_n[i]:9.1f}')

    active = rel[rms_n > ref*0.05]
    if len(active):
        print(f'\nactive windows: {len(active)}, median rel err {np.median(active)*100:.2f}%, '
              f'p95 {np.percentile(active, 95)*100:.2f}%')

    if write_wav:
        import wave
        for name, data in (('jt12', j), ('nuked', n), ('diff', d)):
            peak = np.abs(data).max() or 1.0
            pcm = (data / peak * 32000).astype('<i2')
            with wave.open(f'{prefix}_{name}.wav', 'wb') as w:
                w.setnchannels(2); w.setsampwidth(2); w.setframerate(int(RATE))
                w.writeframes(pcm.tobytes())
        print(f'\nwrote {prefix}_{{jt12,nuked,diff}}.wav')

if __name__ == '__main__':
    main()
