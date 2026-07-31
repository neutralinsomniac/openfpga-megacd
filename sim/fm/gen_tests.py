#!/usr/bin/env python3
"""Generate synthetic FMLOG-format write logs, one per YM2612 feature,
for the jt12-vs-Nuked bench (tb_fm). Each test isolates one feature so a
divergence maps straight to a fixable jt12 behavior.

Log format matches GPGX FMLOG capture: "F f=0 a=<port> d=<hex> c=<mcycle>".
Writes are spaced >= 2016 mcycles (48 internal cycles) to clear chip busy.

Usage: gen_tests.py <outdir>   -> writes <outdir>/<name>.log + manifest.txt
"""
import sys, os

MCLK = 53693175
STEP = 2016            # mcycles between writes (> 32-cycle busy window)

class Log:
    def __init__(self):
        self.t = STEP
        self.lines = []
    def w(self, port, reg, val):
        # port: 0 = ch1-3 bank, 1 = ch4-6 bank
        self.lines.append(f'F f=0 a={port*2:x} d={reg:02x} c={self.t}'); self.t += STEP
        self.lines.append(f'F f=0 a={port*2+1:x} d={val:02x} c={self.t}'); self.t += STEP
    def wait(self, seconds):
        self.t += int(seconds * MCLK)
    def save(self, outdir, name):
        with open(os.path.join(outdir, name + '.log'), 'w') as f:
            f.write('\n'.join(self.lines) + '\n')
        return name

# ---- helpers ----------------------------------------------------------

def op_reg(base, ch, op):
    """register address for per-operator reg: op in 0..3 (S1,S3,S2,S4 order
    uses 0,8,4,0xC offsets), ch in 0..2 within bank"""
    return base + [0, 8, 4, 0xC][op] + ch

def init_channel(l, port, ch, alg=7, fb=0, tl_carrier=0, ar=31, dr=0, sl=0, rr=15,
                 mul=1, dt=0, fnum=0x269, block=4, ops=(0,1,2,3), tl_mod=127):
    """Set up one channel; default: algorithm 7 with only slot1 audible."""
    for op in range(4):
        l.w(port, op_reg(0x30, ch, op), (dt << 4) | mul)        # DT/MUL
        audible = op in ops
        l.w(port, op_reg(0x40, ch, op), tl_carrier if audible else tl_mod)  # TL
        l.w(port, op_reg(0x50, ch, op), ar)                     # RS=0 / AR
        l.w(port, op_reg(0x60, ch, op), dr)                     # AM=0 / DR
        l.w(port, op_reg(0x70, ch, op), 0)                      # SR
        l.w(port, op_reg(0x80, ch, op), (sl << 4) | rr)         # SL / RR
        l.w(port, op_reg(0x90, ch, op), 0)                      # SSG-EG off
    l.w(port, 0xB0 + ch, (fb << 3) | alg)
    l.w(port, 0xB4 + ch, 0xC0)                                  # L+R, no LFO sens
    l.w(port, 0xA4 + ch, (block << 3) | (fnum >> 8))
    l.w(port, 0xA0 + ch, fnum & 0xFF)

def keyon(l, ch06, slots=0xF):
    """ch06: 0..5 across both banks"""
    l.w(0, 0x28, (slots << 4) | (ch06 if ch06 < 3 else ch06 + 1))

def keyoff(l, ch06):
    l.w(0, 0x28, ch06 if ch06 < 3 else ch06 + 1)

def base_init(l):
    l.w(0, 0x22, 0x00)   # LFO off
    l.w(0, 0x27, 0x00)   # ch3 normal mode
    l.w(0, 0x2B, 0x00)   # DAC off
    for c in range(6):
        keyoff(l, c)

# ---- tests ------------------------------------------------------------

def t_reference(outdir):
    """single full-scale carrier: gain calibration + absolute level check"""
    l = Log(); base_init(l)
    init_channel(l, 0, 0)
    keyon(l, 0); l.wait(1.0); keyoff(l, 0); l.wait(0.5)
    return l.save(outdir, 'reference')

def t_tl(outdir):
    """carrier TL staircase: 0,8,16,...,120"""
    l = Log(); base_init(l)
    init_channel(l, 0, 0)
    for tl in range(0, 128, 8):
        l.w(0, 0x40, tl)
        keyon(l, 0); l.wait(0.25); keyoff(l, 0); l.wait(0.1)
    return l.save(outdir, 'tl_staircase')

def t_ar(outdir):
    """attack rate sweep (slow ones matter most)"""
    l = Log(); base_init(l)
    init_channel(l, 0, 0)
    for ar in [2, 4, 6, 8, 10, 12, 16, 20, 24, 28, 31]:
        l.w(0, 0x50, ar)
        keyon(l, 0); l.wait(1.2); keyoff(l, 0); l.wait(0.2)
    return l.save(outdir, 'attack_rates')

def t_dr_rr(outdir):
    """decay to SL, then release"""
    l = Log(); base_init(l)
    init_channel(l, 0, 0, sl=6)
    for dr in [4, 8, 12, 16, 20, 24]:
        l.w(0, 0x60, dr)
        keyon(l, 0); l.wait(1.2); keyoff(l, 0); l.wait(0.6)
    return l.save(outdir, 'decay_release')

def t_rate_scaling(outdir):
    """RS 0..3 at high and low key codes, medium DR"""
    l = Log(); base_init(l)
    init_channel(l, 0, 0, sl=15, dr=10)
    for rs in range(4):
        for block in (1, 7):
            l.w(0, 0x50, (rs << 6) | 31)
            l.w(0, 0xA4, (block << 3) | 2)
            l.w(0, 0xA0, 0x69)
            keyon(l, 0); l.wait(1.0); keyoff(l, 0); l.wait(0.3)
    return l.save(outdir, 'rate_scaling')

def t_ssg(outdir):
    """all 8 SSG-EG modes, DR chosen so shapes repeat a few times"""
    l = Log(); base_init(l)
    init_channel(l, 0, 0, dr=18, sl=15)
    for mode in range(8):
        l.w(0, 0x90, 0x08 | mode)
        keyon(l, 0); l.wait(1.0); keyoff(l, 0); l.wait(0.3)
    return l.save(outdir, 'ssg_eg')

def t_lfo_am(outdir):
    """LFO AM: each LFO freq at AMS=3 (max), then AMS 1..3 at 6 Hz-ish"""
    l = Log(); base_init(l)
    init_channel(l, 0, 0)
    l.w(0, 0x60, 0x80)          # AM enable on slot1 (D7)
    for f in range(8):
        l.w(0, 0x22, 0x08 | f)
        l.w(0, 0xB4, 0xF0)      # AMS=3? B4: L R AMS(2) - PMS(3): 0xC0|0x30
        keyon(l, 0); l.wait(0.8); keyoff(l, 0); l.wait(0.2)
    return l.save(outdir, 'lfo_am')

def t_lfo_pm(outdir):
    """LFO PM: PMS 1..7 at LFO 6"""
    l = Log(); base_init(l)
    init_channel(l, 0, 0)
    l.w(0, 0x22, 0x0E)
    for pms in range(1, 8):
        l.w(0, 0xB4, 0xC0 | pms)
        keyon(l, 0); l.wait(0.8); keyoff(l, 0); l.wait(0.2)
    return l.save(outdir, 'lfo_pm')

def t_algorithms(outdir):
    """all 8 algorithms with all ops audible-ish, FB 0 and 5"""
    l = Log(); base_init(l)
    for alg in range(8):
        for fb in (0, 5):
            init_channel(l, 0, 0, alg=alg, fb=fb, ops=(0, 1, 2, 3), tl_carrier=16)
            keyon(l, 0); l.wait(0.5); keyoff(l, 0); l.wait(0.3)
    return l.save(outdir, 'algorithms')

def t_detune_mul(outdir):
    """DT -3..+3, MUL 0,1,2,10,15: pitch accuracy"""
    l = Log(); base_init(l)
    for dt in range(8):
        l2mul = [0, 1, 2, 10, 15]
        for mul in l2mul:
            init_channel(l, 0, 0, dt=dt, mul=mul)
            keyon(l, 0); l.wait(0.4); keyoff(l, 0); l.wait(0.15)
    return l.save(outdir, 'detune_mul')

def t_ch3_special(outdir):
    """ch3 special mode: per-operator fnum"""
    l = Log(); base_init(l)
    init_channel(l, 0, 2, alg=7, ops=(0, 1, 2, 3), tl_carrier=8)
    l.w(0, 0x27, 0x40)
    fnums = [(0x269, 4), (0x2B4, 4), (0x30F, 4), (0x1CC, 5)]
    for i, (fn, bl) in enumerate(fnums):     # A9,AA,A8 = op1..3, A2 = op4
        reg_hi = [0xAD, 0xAE, 0xAC, 0xA6][i]
        reg_lo = [0xA9, 0xAA, 0xA8, 0xA2][i]
        l.w(0, reg_hi, (bl << 3) | (fn >> 8))
        l.w(0, reg_lo, fn & 0xFF)
    keyon(l, 2); l.wait(1.0); keyoff(l, 2); l.wait(0.3)
    l.w(0, 0x27, 0x00)
    return l.save(outdir, 'ch3_special')

def t_csm(outdir):
    """CSM mode: timer A auto key-on of ch3"""
    l = Log(); base_init(l)
    init_channel(l, 0, 2)
    l.w(0, 0x24, 0xC0)   # timer A msb
    l.w(0, 0x25, 0x00)
    l.w(0, 0x27, 0x80 | 0x01 | 0x04)  # CSM + load A + enable A? (0x85)
    l.wait(1.5)
    l.w(0, 0x27, 0x00)
    l.wait(0.3)
    return l.save(outdir, 'csm')

def t_dac(outdir):
    """DAC mode: square-ish wave via 2A writes, plus DAC/FM ch6 switching"""
    l = Log(); base_init(l)
    init_channel(l, 1, 2)     # ch6 FM patch
    keyon(l, 5); l.wait(0.3)
    l.w(0, 0x2B, 0x80)        # DAC on
    for i in range(2000):     # ~200 Hz square at one write per 24 STEP... keep simple
        l.w(0, 0x2A, 0xF0 if (i // 25) % 2 else 0x10)
    l.w(0, 0x2B, 0x00)        # back to FM
    l.wait(0.4); keyoff(l, 5); l.wait(0.2)
    return l.save(outdir, 'dac')

def t_keyon_slots(outdir):
    """partial slot key-on combinations on alg 7 (all carriers)"""
    l = Log(); base_init(l)
    init_channel(l, 0, 0, alg=7, ops=(0, 1, 2, 3), tl_carrier=8)
    for slots in (0x1, 0x2, 0x4, 0x8, 0x3, 0xC, 0xF):
        keyon(l, 0, slots); l.wait(0.4); keyoff(l, 0); l.wait(0.2)
    return l.save(outdir, 'keyon_slots')

def t_fnum_latch(outdir):
    """block/fnum latch protocol order, incl. cross-channel latch sharing"""
    l = Log(); base_init(l)
    init_channel(l, 0, 0)
    init_channel(l, 0, 1)
    keyon(l, 0); keyon(l, 1)
    # slide ch1 while interleaving ch2 latch writes (latch is shared on real chip)
    for fn in range(0x200, 0x300, 8):
        l.w(0, 0xA4, (4 << 3) | (fn >> 8))     # latch for ch1
        l.w(0, 0xA5, (5 << 3) | 1)             # ch2 latch write in between (clobbers?)
        l.w(0, 0xA0, fn & 0xFF)                # apply ch1: which latch wins?
        l.wait(0.02)
    keyoff(l, 0); keyoff(l, 1); l.wait(0.3)
    return l.save(outdir, 'fnum_latch')

TESTS = [t_reference, t_tl, t_ar, t_dr_rr, t_rate_scaling, t_ssg, t_lfo_am,
         t_lfo_pm, t_algorithms, t_detune_mul, t_ch3_special, t_csm, t_dac,
         t_keyon_slots, t_fnum_latch]

def main():
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    names = [t(outdir) for t in TESTS]
    with open(os.path.join(outdir, 'manifest.txt'), 'w') as f:
        f.write('\n'.join(names) + '\n')
    print('\n'.join(names))

if __name__ == '__main__':
    main()
