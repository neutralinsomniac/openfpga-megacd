// jt12 vs Nuked-OPN2 (ym3438.c) co-sim.
//
// Replays a YM2612 register-write log captured from GPGX (FMLOG=1, see
// ~/src/Genesis-Plus-GX/core/sound/sound.c) into both the Verilated jt12
// used by the core and nukeykt's die-netlist-derived ym3438.c, and dumps
// both raw sample streams for offline diffing (analyze.py).
//
// Time base: one bench tick = one YM input clock = MCLK/7 (~7.67 MHz).
// jt12 runs with cen=1 at that clock (equivalent to gen.sv's
// clk=MCLK/cen=1-of-7 arrangement, 7x faster to simulate). Both models
// advance one internal FM cycle per 6 ticks; a full 6ch sample is 144 ticks.
//
// Log timestamps are master-clock cycles within a video frame; 'E' lines
// carry the frame length so global time is reconstructed by accumulation.
//
// Usage: tb_fm <fmlog.txt> <out_prefix> [tail_seconds]
//   writes <out_prefix>_jt12.s32 and <out_prefix>_nuked.s32
//   (interleaved little-endian int32 stereo, one frame per FM sample)

#include "Vjt12.h"
#include "verilated.h"
extern "C" {
#include "ym3438.h"
}
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <algorithm>

struct Ev { uint64_t t; int type; int a; int d; }; // type 0=write 1=reset

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr, "usage: %s <fmlog.txt> <out_prefix> [tail_s] [--asic]\n", argv[0]); return 1; }
    double tail_s = argc > 3 ? atof(argv[3]) : 3.0;
    bool asic = false;   // YM3438 ASIC mode: no DAC ladder on either model
    for (int i = 3; i < argc; i++) if (!strcmp(argv[i], "--asic")) asic = true;

    // ---- parse log ----
    FILE* f = fopen(argv[1], "r");
    if (!f) { perror(argv[1]); return 1; }
    std::vector<Ev> evs;
    uint64_t base = 0;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        int fr; unsigned a, d, c;
        if (sscanf(line, "F f=%d a=%x d=%x c=%u", &fr, &a, &d, &c) == 4)
            evs.push_back({base + c, 0, (int)a, (int)d});
        else if (sscanf(line, "Z f=%d c=%u", &fr, &c) == 2)
            evs.push_back({base + c, 1, 0, 0});
        else if (sscanf(line, "E f=%d c=%u", &fr, &c) == 2)
            base += c;
    }
    fclose(f);
    std::stable_sort(evs.begin(), evs.end(), [](const Ev& x, const Ev& y){ return x.t < y.t; });
    if (evs.empty()) { fprintf(stderr, "no events in log\n"); return 1; }
    // mcycles -> bench ticks (MCLK/7)
    for (auto& e : evs) e.t /= 7;
    const uint64_t end_tick = evs.back().t + (uint64_t)(tail_s * 53693175.0 / 7.0);
    fprintf(stderr, "events: %zu (%zu writes), sim ticks: %llu (%.1fs)\n",
            evs.size(),
            (size_t)std::count_if(evs.begin(), evs.end(), [](const Ev& e){ return e.type == 0; }),
            (unsigned long long)end_tick, end_tick * 7.0 / 53693175.0);

    // spacing sanity: back-to-back data writes closer than one internal cycle
    int tight = 0;
    for (size_t i = 1; i < evs.size(); i++)
        if (evs[i].type == 0 && evs[i-1].type == 0 && evs[i].t - evs[i-1].t < 6) tight++;
    if (tight) fprintf(stderr, "warning: %d writes <1 internal cycle apart\n", tight);

    // ---- outputs ----
    char path[512];
    snprintf(path, sizeof path, "%s_jt12.s32", argv[2]);
    FILE* fj = fopen(path, "wb");
    snprintf(path, sizeof path, "%s_nuked.s32", argv[2]);
    FILE* fn = fopen(path, "wb");
    snprintf(path, sizeof path, "%s_nuked_ch.s16", argv[2]);
    FILE* fc = fopen(path, "wb");   // 6 x int16 per sample: golden per-channel out
    if (!fj || !fn || !fc) { perror("open output"); return 1; }

    // ---- models ----
    Vjt12* jt = new Vjt12;
    jt->rst = 1; jt->clk = 0; jt->cen = 1;
    jt->cs_n = 0; jt->wr_n = 1; jt->addr = 0; jt->din = 0;
    jt->en_hifi_pcm = 0;
    jt->ladder = asic ? 0 : 1;             // default matches core_top.sv (discrete YM2612)

    OPN2_SetChipType(asic ? ym3438_mode_readmode : ym3438_mode_ym2612);
    ym3438_t nuked;
    memset(&nuked, 0, sizeof nuked);
    OPN2_Reset(&nuked);

    Bit16s accm[24][2] = {{0}};
    int32_t nuked_sample[2] = {0, 0};
    int nuked_cyc = 0;

    auto clkstep = [&](void){ jt->clk = 0; jt->eval(); jt->clk = 1; jt->eval(); };

    // hold reset for 48 ticks before time 0 (jt12 wants >=6 clk&cen)
    for (int i = 0; i < 48; i++) clkstep();
    jt->rst = 0;

    size_t ei = 0;
    uint64_t nsamp_j = 0, nsamp_n = 0;
    int rst_hold = 0;
    bool prev_sample = false;

    for (uint64_t t = 0; t <= end_tick; t++) {
        // both models tick one internal FM cycle per 6 clk
        if (t % 6 == 0) {
            OPN2_Clock(&nuked, accm[nuked_cyc]);
            nuked_cyc = (nuked_cyc + 1) % 24;
            if (nuked_cyc == 0) {
                nuked_sample[0] = nuked_sample[1] = 0;
                for (int j = 0; j < 24; j++) {
                    nuked_sample[0] += accm[j][0];
                    nuked_sample[1] += accm[j][1];
                }
                int32_t s[2] = {nuked_sample[0], nuked_sample[1]};
                fwrite(s, 4, 2, fn);
                fwrite(nuked.ch_out, 2, 6, fc);
                nsamp_n++;
            }
        }

        // due events: mirror GPGX (chip advanced past write time, then write).
        // At most one jt12 write per tick: it rides this tick's clock edge as
        // a one-clk wr_n pulse, so the two models never drift.
        if (ei < evs.size() && evs[ei].t <= t) {
            if (evs[ei].type == 1) {
                OPN2_Reset(&nuked);
                jt->rst = 1; rst_hold = 12;
                ei++;
            } else {
                OPN2_Write(&nuked, evs[ei].a, evs[ei].d);
                if (!rst_hold) {
                    jt->addr = evs[ei].a; jt->din = evs[ei].d;
                    jt->wr_n = 0;
                }
                ei++;
            }
        }

        if (rst_hold && --rst_hold == 0) jt->rst = 0;
        clkstep();
        jt->wr_n = 1;

        if (jt->snd_sample && !prev_sample) {
            int32_t s[2] = {(int16_t)jt->snd_left, (int16_t)jt->snd_right};
            fwrite(s, 4, 2, fj);
            nsamp_j++;
        }
        prev_sample = jt->snd_sample;
    }

    fclose(fj); fclose(fn); fclose(fc);
    fprintf(stderr, "samples: jt12=%llu nuked=%llu\n",
            (unsigned long long)nsamp_j, (unsigned long long)nsamp_n);
    delete jt;
    return 0;
}
