// Standalone unit test for megacd_cdd_drive's sector fetch/delivery ring.
// Validates the N=4 prefetch bank: correct slot mapping, 4-deep read-ahead,
// correct delivery data, and ride-through of an SD read-latency spike.
//
// The fetch/delivery ring is identical for DATA and CDDA sectors (only the
// delivery strobe + backpressure differ), so a data-track test exercises the
// exact code path the Sonic-CD CDDA skip depends on.

#include "Vmegacd_cdd_drive.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>

static Vmegacd_cdd_drive* dut;
static vluint64_t tk = 0;

// ---- mock APF sector fetch (host) ----
// On cd_req rising, after LAT cycles assert cd_ack and record which file
// offset landed in which bank slot. A one-shot SPIKE injects a long latency.
static uint32_t slot_off[4] = {0,0,0,0};   // file byte offset held by each slot
static int      slot_file[4] = {-1,-1,-1,-1}; // WHICH BIN filled each slot
static int      g_dlv_file = -1;            // bin the last delivered word came from
static bool     slot_val[4] = {false,false,false,false};
static long     lat_ctr = -1;
static long     LAT_NORMAL = 40;            // ~normal fetch latency (cycles)
// stallhammer: per-fetch randomized host latency (SD jitter model)
static bool     g_lat_rand = false;
static uint32_t g_rng = 0xC0FFEE;
static uint32_t rng32(){ g_rng^=g_rng<<13; g_rng^=g_rng>>17; g_rng^=g_rng<<5; return g_rng; }
static long rand_lat(){
    // 70% healthy SD (2-4ms), 30% slow spike straddling and exceeding the
    // 19.5ms pause threshold (15-60ms): freeze phase varies per draw, so
    // thousands of hops explore the engage/release race space the
    // deterministic full co-sim cannot reach.
    if (rng32()%10 < 7) return 100000 + (long)(rng32()%120000);
    return 800000 + (long)(rng32()%2400000);
}
static long     spike_at_fetch = -1;        // fetch index to stall
static long     spike_len = 0;
static long     fetch_idx = 0;
static bool     req_d = false;

// ---- mock cd_buf: 1-cycle read latency; value encodes file byte offset ----
static uint32_t buf_addr_d = 0;
// real-bin mode: serve sector fetches from an actual disc image
static FILE*   bin_data = nullptr;
static uint8_t binbuf[4][2368];
// CDDA sector capture (edge-exact, lives in tick() so no word is missed)
static bool     cap_on = false, cap_ready = false;
static long     cap_secw = 0, cap_head = -1;
static uint16_t cap_sec[1176];
// When set, the mock returns a REAL MODE1/2352 sync (00 FF*10 00) in the first
// 12 bytes of every sector, so the drive's sync check sees a well-formed data
// sector. Left off by default: the other tests encode the file offset in every
// word to verify routing, which is deliberately not a valid sync.
static bool mock_valid_sync = false;

// stats
static long fetch_count = 0, deliver_words = 0, deliver_secs = 0;
static long g_max_fetch_lba = -1;           // highest LBA the host was asked for
static long cdda_words = 0;                  // words delivered via the CDDA path

// ---- TOC model (multi-bin CDDA test) ----
// entry = {audio[65], pregap[64:57], pre01[56:47], file[46:40], delta[39:20], disc_lba[19:0]}
static uint32_t TOC[128][3];
static uint32_t toc_addr_d = 0;
static void toc_set(int idx, bool audio, int pregap, int pre01, int file,
                    uint32_t delta, uint32_t disc_lba){
    unsigned long long lo = ((unsigned long long)(disc_lba & 0xFFFFF))
        | ((unsigned long long)(delta & 0xFFFFF) << 20)
        | ((unsigned long long)(file  & 0x7F)    << 40)
        | ((unsigned long long)(pre01 & 0x3FF)   << 47)
        | ((unsigned long long)(pregap & 0x7F)   << 57);   // pregap[6:0] -> [63:57]
    TOC[idx][0] = (uint32_t)lo;
    TOC[idx][1] = (uint32_t)(lo >> 32);
    TOC[idx][2] = ((pregap >> 7) & 1) | ((audio ? 1u : 0u) << 1); // [64]=pregap7, [65]=audio
}
static bool fail = false;
static void err(const char* m){ printf("FAIL: %s (t=%llu)\n", m, (unsigned long long)tk); fail=true; }

// stallpause_test only: loop stall_pause back into sys_pause the way
// megacd_top wires it. Everywhere else sys_pause stays 0, which makes the
// detector's output a no-op -- identical drive behavior to before the port
// existed, so the legacy tests' expectations are untouched.
static bool loopback_pause = false;
static bool g_sp_parked = false;   // --stallpause-parked variant

static void tick(){
    dut->sys_pause = loopback_pause ? dut->stall_pause : 0;
    dut->clk = 0; dut->eval();
    // ----- drive the mock host (combinational off current outputs) -----
    bool req = dut->cd_req;
    // cd_buf read: value = file offset of that word = slot_off[slot] + word*4
    uint32_t a = dut->cd_buf_addr;            // {slot[1:0], word[9:0]}
    uint32_t slot = (a >> 10) & 3, word = a & 0x3FF;
    // present previous-cycle address' data (1-cycle latency modelled below)
    uint32_t bslot = (buf_addr_d >> 10) & 3, bword = buf_addr_d & 0x3FF;
    if (bin_data)
        dut->cd_buf_q = ((uint32_t)binbuf[bslot][bword*4])
                      | ((uint32_t)binbuf[bslot][bword*4+1] << 8)
                      | ((uint32_t)binbuf[bslot][bword*4+2] << 16)
                      | ((uint32_t)binbuf[bslot][bword*4+3] << 24);
    else if (mock_valid_sync && bword < 3)
        dut->cd_buf_q = (bword==0) ? 0xFFFFFF00u        // bytes 00 FF FF FF
                      : (bword==1) ? 0xFFFFFFFFu        // bytes FF FF FF FF
                                   : 0x00FFFFFFu;       // bytes FF FF FF 00
    else
        dut->cd_buf_q = slot_off[bslot] + bword*4;
    buf_addr_d = a;

    // fetch handshake
    if (req && !req_d){                        // new request
        lat_ctr = (fetch_idx == spike_at_fetch) ? spike_len
                : g_lat_rand ? rand_lat() : LAT_NORMAL;
        // record placement
        uint32_t off = dut->cd_req_offset, s = dut->cd_req_slot;
        if (off % 2352 != 0) err("cd_req_offset not sector-aligned");
        if (((off/2352) & 3) != s) err("cd_req_slot != (lba & 3)");
        slot_off[s] = off;
        slot_file[s] = dut->cd_req_file;
        if (bin_data){
            memset(binbuf[s], 0, 2352);
            fseek(bin_data, off, SEEK_SET);
            size_t got = fread(binbuf[s], 1, 2352, bin_data);
            (void)got;
        }
        long lba = off/2352; if(lba > g_max_fetch_lba) g_max_fetch_lba = lba;
        fetch_idx++;
    }
    if (req){
        if (lat_ctr > 0) lat_ctr--;
        dut->cd_ack_74a = (lat_ctr == 0) ? 1 : 0;
        if (lat_ctr == 0){ uint32_t s = dut->cd_req_slot; slot_val[s]=true; }
    } else {
        dut->cd_ack_74a = 0;
    }
    if (!req && req_d) fetch_count++;
    req_d = req;

    // count delivered words / sectors (data + CDDA paths)
    static bool datwr_d=false, cddawr_d=false;
    bool datwr = dut->cdc_dat_wr;
    if (datwr && !datwr_d){ deliver_words++; g_dlv_file = slot_file[bslot]; }
    datwr_d = datwr;
    bool cddawr = dut->cdc_cdda_wr;
    if (cddawr && !cddawr_d){
        cdda_words++;
        if (cap_on){
            if (cap_secw==0) cap_head = dut->dbg_state & 0xFFFFF;
            if (cap_secw<1176) cap_sec[cap_secw] = dut->cdc_data;
            if (++cap_secw==1176){ cap_secw=0; cap_ready=1; }
        }
    }
    cddawr_d = cddawr;

    // TOC RAM model (1-cycle latency, matching altsyncram read port)
    dut->toc_q[0]=TOC[toc_addr_d][0]; dut->toc_q[1]=TOC[toc_addr_d][1]; dut->toc_q[2]=TOC[toc_addr_d][2];
    toc_addr_d = dut->toc_addr & 127;

    dut->clk = 1; dut->eval();
    tk++;
}

// Present the command word, THEN strobe. On hardware the sub writes CDDC over
// five separate 68000 bus cycles ($FF8042..$FF804A) and only the last one sets
// CDD_SEND, so every nibble is stable tens of clk before the strobe and the
// drive's 4-deep seek-latency pipeline has settled. Raising cdd_send on the
// same tick as cdd_comm (as this did) instead latched a latency computed from
// the PREVIOUS command's MSF: a 50000-sector seek measured as the bare 11-beat
// base, so the distance term -- and every bug in it -- was invisible here.
static void pulse_cmd(uint64_t comm){
    dut->cdd_comm = comm;
    for(int i=0;i<40;i++) tick();
    dut->cdd_send = 1;
    for(int i=0;i<4;i++) tick();
    dut->cdd_send = 0;
    for(int i=0;i<4;i++) tick();
}

// SEEK+PLAY (c0=3) command word for disc LBA L (BCD MSF of L+150)
static uint64_t mk_seek(long L){
    long fr = L + 150; int m = fr/4500; fr %= 4500; int s = fr/75, f = fr%75;
    return (uint64_t)0x3
        | ((uint64_t)(m/10)<<8) | ((uint64_t)(m%10)<<12)
        | ((uint64_t)(s/10)<<16)| ((uint64_t)(s%10)<<20)
        | ((uint64_t)(f/10)<<24)| ((uint64_t)(f%10)<<28);
}

// Multi-bin CDDA test: a 3-track disc (track1 data/file0, track2 audio/file1,
// track3 audio/file2), seek+play into the middle of track 3, and check the
// drive plays it as a stable single audio track: delivery via the CDDA path,
// cd_req_file pinned to file 2 (no spurious flips that would force reopens ->
// the hitching we see only on multi-bin discs like Sonic CD).
static int cdda_test(){
    dut->reset=1; dut->mcd_rst_n=0; dut->cdd_send=0; dut->cdd_comm=0;
    dut->img_size = 3000*2352; dut->track_count=3; dut->cdda_wr_ready=1; dut->cd_fast_seek=0; dut->disc_loading=0;
    dut->toc_q[0]=0; dut->toc_q[1]=0; dut->toc_q[2]=0; dut->cd_ack_74a=0;
    toc_set(1, /*audio*/false, 0,0, /*file*/0, /*delta*/0,    /*disc*/0);
    toc_set(2, /*audio*/true,  0,0, /*file*/1, /*delta*/1000, /*disc*/1000);
    toc_set(3, /*audio*/true,  0,0, /*file*/2, /*delta*/2000, /*disc*/2000);
    for(int i=0;i<20;i++) tick();
    dut->reset=0; dut->mcd_rst_n=1;
    for(int i=0;i<20;i++) tick();

    pulse_cmd(mk_seek(2100));        // into track 3

    const long BEAT = 715909;
    int  file_lo=99, file_hi=-1, file_flips=0, last_file=-1;
    long stream_beats=0;
    for(long b=0;b<40;b++){
        pulse_cmd(0x0ULL);
        for(long c=0;c<BEAT;c++){
            tick();
            int drv = (dut->dbg_state>>28)&0xF;
            // Sample only while a fetch is actually in flight: cd_req_file is
            // what the HOST latches to pick a bin, and it only ever looks at
            // it while cd_req is asserted. Sampling it unconditionally also
            // catches the few clk after a seek where the track search has not
            // yet caught up, which the host never observes.
            if(drv==1 && dut->cd_req){
                int rf = dut->cd_req_file;
                if(rf<file_lo) file_lo=rf; if(rf>file_hi) file_hi=rf;
                if(last_file>=0 && rf!=last_file){
                    file_flips++;
                    printf("  [trace] beat %ld tick %llu: cd_req_file %d -> %d, head=%ld, cdda_words=%ld\n",
                           b, (unsigned long long)tk, last_file, rf,
                           (long)(dut->dbg_state&0xFFFFF), cdda_words);
                }
                last_file=rf;
            }
        }
        if(((dut->dbg_state>>28)&0xF)==1) stream_beats++;
    }
    int drv_status=(dut->dbg_state>>28)&0xF;
    printf("--- CDDA (multi-bin) results ---\n");
    printf("drv_status=%d  cdda_words=%ld  data_words=%ld  head=%ld\n",
           drv_status, cdda_words, deliver_words, (long)(dut->dbg_state&0xFFFFF));
    printf("cd_req_file during PLAY: lo=%d hi=%d flips=%d (want steady 2)\n",
           file_lo, file_hi, file_flips);

    if(drv_status!=1) err("not in PLAY on the audio track");
    if(cdda_words < 1000) err("no/too little CDDA delivery on the audio track");
    if(deliver_words != 0) err("delivered via DATA path on an AUDIO track");
    if(file_hi != 2 || file_lo != 2) err("cd_req_file not pinned to the track's file (2)");
    if(file_flips != 0) err("cd_req_file flipped during steady CDDA -> spurious reopens");
    printf(fail ? "\n==== CDDA TEST FAILED ====\n" : "\n==== CDDA TEST PASSED ====\n");
    return fail?1:0;
}

// Disc-swap test. img_size drops to 0 whenever the mount FSM restarts (a new
// .cue picked from the menu) and only returns once that image's TOC is final.
// The drive must notice the disc LEAVING from whatever state it is in --
// including TOC(9) -- retire to NO_DISC, and then run the normal insertion
// dance for the new image. Otherwise the BIOS keeps believing the old disc is
// still in the drive and never re-reads the TOC.
static long run_beats(long n, int* saw_status, int want){
    const long BEAT = 715909;
    for(long b=0;b<n;b++){
        pulse_cmd(0x0ULL);                       // BIOS-style DRIVE STATUS poll
        for(long c=0;c<BEAT;c++){
            tick();
            if((dut->dbg_cmds & 0xF) == want){ *saw_status=1; return b; }
        }
    }
    return -1;
}
// GPGX port: a paused (or stopped, or TOC'd) drive keeps feeding the decoder
// the sector under the head at 75Hz -- upstream's cdc_decoder_update in every
// non-PLAY state -- and the head must NOT drift while it does. A paused AUDIO
// track gets null ticks only (no CDDA words: the DAC would loop 13ms of audio
// as a buzz; upstream sends no audio while paused either).
static int pause_test(){
    dut->reset=1; dut->mcd_rst_n=0; dut->cdd_send=0; dut->cdd_comm=0;
    dut->img_size = 3000*2352; dut->track_count=2; dut->cdda_wr_ready=1;
    dut->cd_fast_seek=1; dut->disc_loading=0;
    dut->toc_q[0]=0; dut->toc_q[1]=0; dut->toc_q[2]=0; dut->cd_ack_74a=0;
    toc_set(1, /*audio*/false, 0,0, /*file*/0, /*delta*/0,    /*disc*/0);
    toc_set(2, /*audio*/true,  0,0, /*file*/1, /*delta*/1000, /*disc*/1000);
    for(int i=0;i<20;i++) tick();
    dut->reset=0; dut->mcd_rst_n=1;
    for(int i=0;i<20;i++) tick();

    const long BEAT = 715909;
    // ---- data track: play in, then PAUSE ----
    pulse_cmd(mk_seek(200));
    for(long b=0;b<12;b++){ pulse_cmd(0x0ULL);
        for(long c=0;c<BEAT;c++){ tick(); if((dut->dbg_cmds&0xF)==1) break; } }
    if((dut->dbg_cmds&0xF)!=1) err("data track never reached PLAY");

    pulse_cmd(0x6ULL);                                  // PAUSE
    if((dut->dbg_cmds&0xF)!=4) err("PAUSE command did not reach PAUSE");
    long head0 = dut->dbg_state & 0xFFFFF;
    long secs=0; bool dsd=false;
    for(long b=0;b<10;b++){
        pulse_cmd(0x0ULL);
        for(long c=0;c<BEAT;c++){
            tick();
            bool d = dut->dbg_sector_done;
            if(d && !dsd) secs++;
            dsd = d;
        }
    }
    long head1 = dut->dbg_state & 0xFFFFF;
    printf("paused DATA track: %ld sectors delivered over 10 beats, head %ld -> %ld\n",
           secs, head0, head1);
    if(secs < 8)  err("paused data track stopped feeding the decoder (GPGX re-delivers)");
    if(head1 != head0) err("head moved while paused");

    // ---- audio track: play in, then PAUSE ----
    pulse_cmd(mk_seek(1200));
    for(long b=0;b<12;b++){ pulse_cmd(0x0ULL);
        for(long c=0;c<BEAT;c++){ tick(); if((dut->dbg_cmds&0xF)==1) break; } }
    if((dut->dbg_cmds&0xF)!=1) err("audio track never reached PLAY");
    pulse_cmd(0x6ULL);                                  // PAUSE
    long asecs=0; dsd=false;
    for(long b=0;b<10;b++){
        pulse_cmd(0x0ULL);
        for(long c=0;c<BEAT;c++){
            tick();
            bool d = dut->dbg_sector_done;
            if(d && !dsd) asecs++;
            dsd = d;
        }
    }
    printf("paused AUDIO track: %ld sectors delivered over 10 beats (want 0, hw mutes)\n",
           asecs);
    if(asecs > 1) err("paused audio track keeps feeding the CDDA FIFO (audible buzz)");

    printf(fail ? "\n==== PAUSE TEST FAILED ====\n" : "\n==== PAUSE TEST PASSED ====\n");
    return fail?1:0;
}

// SCAN: fast forward (c0=8) / fast rewind (c0=9), ended by recover-initial-
// state (c0=A). These were unimplemented -- acknowledged and ignored -- so the
// head never moved and a host scanning for the next track waited forever. The
// host stops a scan by watching the position reports, so the only thing that
// really matters is that the head MOVES, in the right direction, and that A
// returns the drive to 1x play from wherever the scan left it.
static int scan_test(){
    dut->reset=1; dut->mcd_rst_n=0; dut->cdd_send=0; dut->cdd_comm=0;
    dut->img_size = 40000*2352; dut->track_count=0; dut->cdda_wr_ready=1;
    dut->cd_fast_seek=1; dut->disc_loading=0;
    dut->toc_q[0]=0; dut->toc_q[1]=0; dut->toc_q[2]=0; dut->cd_ack_74a=0;
    for(int i=0;i<20;i++) tick();
    dut->reset=0; dut->mcd_rst_n=1;
    for(int i=0;i<20;i++) tick();

    const long BEAT = 715909;
    pulse_cmd(mk_seek(5000));
    for(long b=0;b<12;b++){ pulse_cmd(0x0ULL);
        for(long c=0;c<BEAT;c++){ tick(); if((dut->dbg_cmds&0xF)==1) break; } }
    if((dut->dbg_cmds&0xF)!=1) err("never reached PLAY before the scan");

    auto head = [&]{ return (long)(dut->dbg_state & 0xFFFFF); };
    auto run  = [&](int beats){ for(int b=0;b<beats;b++){ pulse_cmd(0x0ULL);
                                  for(long c=0;c<BEAT;c++) tick(); } };

    run(4);              // drain the residual seek latency (scan does not
                         // walk while latency counts, matching upstream)
    long h0 = head();
    pulse_cmd(0x8ULL);                              // FAST FORWARD
    if((dut->dbg_cmds&0xF)!=3) err("FF did not report SCAN (status 3)");
    run(10);
    long h1 = head();
    printf("fast forward: head %ld -> %ld over 10 beats (+%ld)\n", h0, h1, h1-h0);
    // GPGX CD_SCAN_SPEED = 30 sectors per 75Hz update
    if(h1 - h0 < 250 || h1 - h0 > 350) err("fast forward rate is not ~30 sectors/beat");

    // 0x0A: GPGX lands this in PAUSE, not PLAY (it is sent just before a
    // SEEK/PLAY). Whichever it is, the head must stop moving at scan rate.
    pulse_cmd(0xAULL);                              // N-track jump control
    if((dut->dbg_cmds&0xF)!=4) err("0x0A did not land in PAUSE (GPGX: CD_PAUSE)");
    long h2 = head();
    run(5);
    long h3 = head();
    printf("0x0A: PAUSE at head %ld, +%ld over 5 beats (want 0, scan stopped)\n",
           h2, h3-h2);
    if(h3-h2 > 2) err("still scanning after 0x0A");

    pulse_cmd(0x9ULL);                              // FAST REWIND
    if((dut->dbg_cmds&0xF)!=3) err("FR did not report SCAN (status 3)");
    long h4 = head();
    run(10);
    long h5 = head();
    printf("fast rewind:  head %ld -> %ld over 10 beats (%ld)\n", h4, h5, h5-h4);
    if(h4 - h5 < 250 || h4 - h5 > 350) err("fast rewind rate is not ~30 sectors/beat");

    pulse_cmd(0xAULL);
    if((dut->dbg_cmds&0xF)!=4) err("0x0A after rewind did not land in PAUSE");

    // scan off the end of the disc: GPGX reports CD_END (0xC), not PAUSE
    pulse_cmd(mk_seek(39980));
    for(long b=0;b<12;b++){ pulse_cmd(0x0ULL);
        for(long c=0;c<BEAT;c++){ tick(); if((dut->dbg_cmds&0xF)==1) break; } }
    pulse_cmd(0x8ULL);                              // FAST FORWARD into leadout
    run(4);
    printf("scan into lead-out: status=%lX head=%ld (want C @ 40000)\n",
           (long)(dut->dbg_cmds&0xF), head());
    if((dut->dbg_cmds&0xF)!=0xC) err("lead-out did not report CD_END (C)");
    if(head()!=40000) err("scan did not clamp at the lead-out LBA");

    printf(fail ? "\n==== SCAN TEST FAILED ====\n" : "\n==== SCAN TEST PASSED ====\n");
    return fail?1:0;
}

// Cross-bin prefetch collision. The bank tags slots by FILE lba, and every bin
// of a multi-bin cue restarts at file lba 0, so tags collide across files: play
// in one bin, then seek to the SAME file lba in another, and a stale slot reads
// as a hit. The drive then delivers the previous bin's bytes and never issues a
// fetch -- silent data corruption, and for a data track it means the sector
// "header" handed to the CDC is arbitrary audio, so a host searching for a
// target header never matches.
//
// Built so the two tracks share file lbas exactly: track 2 (file 1) and track 3
// (file 2) both start at their own file lba 0, at disc 1000 and 2000.
static int binswap_test(){
    dut->reset=1; dut->mcd_rst_n=0; dut->cdd_send=0; dut->cdd_comm=0;
    dut->img_size = 4000*2352; dut->track_count=3; dut->cdda_wr_ready=1;
    dut->cd_fast_seek=1; dut->disc_loading=0;
    dut->toc_q[0]=0; dut->toc_q[1]=0; dut->toc_q[2]=0; dut->cd_ack_74a=0;
    toc_set(1, /*audio*/false, 0,0, /*file*/0, /*delta*/0,    /*disc*/0);
    toc_set(2, /*audio*/false, 0,0, /*file*/1, /*delta*/1000, /*disc*/1000);
    toc_set(3, /*audio*/false, 0,0, /*file*/2, /*delta*/2000, /*disc*/2000);
    for(int i=0;i<20;i++) tick();
    dut->reset=0; dut->mcd_rst_n=1;
    for(int i=0;i<20;i++) tick();

    const long BEAT = 715909;
    // Play only a FEW sectors of track 2 so the bank holds file 1's file lbas
    // 0..3 -- the same file lbas track 3 will ask for. This overlap is the
    // whole point: land anywhere further in and the tags simply differ and the
    // collision cannot occur.
    pulse_cmd(mk_seek(1000));
    for(long b=0;b<5;b++){ pulse_cmd(0x0ULL); for(long c=0;c<BEAT;c++) tick(); }
    long h2 = dut->dbg_state & 0xFFFFF;
    printf("track 2 (file 1): head=%ld -> file lba %ld, bank holds file 1 lbas 0..3\n",
           h2, h2-1000);
    if(h2-1000 > 6) err("test setup: ran too far into track 2 to collide");

    // seek to track 3 -> file 2, asking for the SAME file lbas 0..3
    long fetches_before = fetch_count;
    int  file_seen = -1;
    long wrong_bin_words = 0, delivered_words = 0;
    // the pending window (1 tick) and any in-flight hold sector legitimately
    // deliver the OLD position (file 1) -- GPGX reads the old lba there too.
    // Only what is delivered once the head has settled on track 3 may be
    // held against the bank.
    pulse_cmd(mk_seek(2000));
    for(long b=0;b<3;b++){ pulse_cmd(0x0ULL); for(long c=0;c<BEAT;c++) tick(); }
    long dw_before = deliver_words;
    for(long b=0;b<8;b++){
        pulse_cmd(0x0ULL);
        for(long c=0;c<BEAT;c++){
            long dw = deliver_words;
            tick();
            if(dut->cd_req) file_seen = dut->cd_req_file;
            // count DELIVERED words that came out of a slot still holding
            // another bin's data -- the fetch count alone cannot see this,
            // because the bank rotates and only SOME slots collide.
            if(deliver_words != dw && g_dlv_file >= 0 && g_dlv_file != 2)
                wrong_bin_words++;
        }
    }
    delivered_words = deliver_words - dw_before;
    long fetched = fetch_count - fetches_before;
    printf("track 3 (file 2): %ld fetches, cd_req_file=%d, %ld/%ld delivered words "
           "came from the WRONG bin\n", fetched, file_seen,
           wrong_bin_words, delivered_words);
    if(file_seen != 2)
        err("fetched from the wrong bin after crossing");
    if(delivered_words == 0)
        err("test setup: nothing delivered from track 3");
    if(wrong_bin_words != 0)
        err("stale bank served ANOTHER BIN'S data as track 3 sectors");

    printf(fail ? "\n==== BINSWAP TEST FAILED ====\n" : "\n==== BINSWAP TEST PASSED ====\n");
    return fail?1:0;
}

// Two-sided check of the sector-integrity detector (dbg_integ): it must stay
// silent on well-formed MODE1 sectors and fire on malformed ones. Without both
// halves the counter could be stuck at zero, or firing on everything, and a
// hardware reading of it would mean nothing.
static int integ_test(){
    dut->reset=1; dut->mcd_rst_n=0; dut->cdd_send=0; dut->cdd_comm=0;
    dut->img_size = 3000*2352; dut->track_count=0; dut->cdda_wr_ready=1;
    dut->cd_fast_seek=1; dut->disc_loading=0;
    dut->toc_q[0]=0; dut->toc_q[1]=0; dut->toc_q[2]=0; dut->cd_ack_74a=0;
    mock_valid_sync = true;
    for(int i=0;i<20;i++) tick();
    dut->reset=0; dut->mcd_rst_n=1;
    for(int i=0;i<20;i++) tick();

    const long BEAT = 715909;
    pulse_cmd(mk_seek(100));
    for(long b=0;b<16;b++){ pulse_cmd(0x0ULL); for(long c=0;c<BEAT;c++) tick(); }
    long good = (dut->dbg_integ >> 24) & 0xFF;
    printf("well-formed sectors: bad-sync count = %ld (want 0)\n", good);
    if(good != 0) err("sync check false-positives on valid MODE1 sectors");

    // now hand it malformed sectors and require it to notice
    mock_valid_sync = false;
    for(long b=0;b<16;b++){ pulse_cmd(0x0ULL); for(long c=0;c<BEAT;c++) tick(); }
    long bad = (dut->dbg_integ >> 24) & 0xFF;
    long lba = (dut->dbg_integ >> 4) & 0xFFFFF;
    printf("malformed sectors:   bad-sync count = %ld, first bad LBA = %ld\n",
           bad, lba);
    if(bad == 0) err("sync check missed malformed sectors entirely");
    if(lba == 0) err("first-bad LBA was never latched");

    printf(fail ? "\n==== INTEG TEST FAILED ====\n" : "\n==== INTEG TEST PASSED ====\n");
    return fail?1:0;
}

// In-file INDEX 00 gap (pre01): GPGX holds the "no audio playing" flag from
// the previous track's end until INDEX 01 and gates the DAC on it, so the
// gap's file content is NEVER heard -- it plays as silence. Regression for
// the Shining Force CD symptom of ~2s of the next song bleeding through
// after the intro. Two-sided: the gap must be silent AND the track proper
// must still deliver real file bytes (a mute that never lifts would pass a
// one-sided check).
static int gap_test(){
    dut->reset=1; dut->mcd_rst_n=0; dut->cdd_send=0; dut->cdd_comm=0;
    dut->img_size = 4000*2352; dut->track_count=2; dut->cdda_wr_ready=1;
    dut->cd_fast_seek=1; dut->disc_loading=0;
    dut->toc_q[0]=0; dut->toc_q[1]=0; dut->toc_q[2]=0; dut->cd_ack_74a=0;
    // single-file cue: track 2 audio, INDEX 01 at disc 2000, 150-sector
    // in-file INDEX 00 region before it (region start 1850)
    toc_set(1, /*audio*/false, 0,   0, /*file*/0, /*delta*/0, /*disc*/0);
    toc_set(2, /*audio*/true,  0, 150, /*file*/0, /*delta*/0, /*disc*/2000);
    for(int i=0;i<20;i++) tick();
    dut->reset=0; dut->mcd_rst_n=1;
    for(int i=0;i<20;i++) tick();

    const long BEAT = 715909;
    pulse_cmd(mk_seek(1830));            // late in the data track
    long gap_words=0, gap_nz=0, post_words=0, post_nz=0;
    bool cw=false;
    for(long b=0;b<200;b++){
        pulse_cmd(0x0ULL);
        for(long c=0;c<BEAT;c++){
            tick();
            bool w = dut->cdc_cdda_wr;
            if(w && !cw){
                long h = dut->dbg_state & 0xFFFFF;
                if(h >= 1850 && h < 2000){ gap_words++;  if(dut->cdc_data) gap_nz++; }
                if(h >= 2004 && h < 2050){ post_words++; if(dut->cdc_data) post_nz++; }
            }
            cw = w;
        }
        if((dut->dbg_state & 0xFFFFF) >= 2050) break;
    }
    printf("gap  (1850..1999): %ld CDDA words, %ld nonzero (want 0 nonzero)\n",
           gap_words, gap_nz);
    printf("track (2004..2049): %ld CDDA words, %ld nonzero (want mostly nonzero)\n",
           post_words, post_nz);
    if(gap_words < 1000) err("gap was not delivered through the CDDA path at all");
    if(gap_nz != 0)      err("in-file INDEX 00 gap leaked file audio (GPGX plays silence)");
    if(post_nz < post_words/2) err("track proper is silent past INDEX 01 (mute never lifted)");

    printf(fail ? "\n==== GAP TEST FAILED ====\n" : "\n==== GAP TEST PASSED ====\n");
    return fail?1:0;
}

// End-of-track auto-pause (Shining Force CD title-jingle / intro handoff).
// GPGX ground truth (headless libretro run of shining.cue, CDD logging): the
// game plays track 2 with an exact INDEX 01 seek (cmd 3006331900); while it
// plays, the BIOS rotates REQUEST polls 2000/2001/2002 (abs time / rel time /
// track number) one per 75Hz frame, and sends Pause (cmd 6) ~4 frames after
// the track-number report flips to the next track -- upstream's drive parks
// ~5 sectors into the 150-frame silent gap, so nothing of track 3 is heard.
// This test replays that exact host sequence against the real Shining Force
// TOC numbers and fails if ANY nonzero CDDA word is delivered at/after the
// track 2 -> gap boundary (bleed), or if the reports would make the BIOS
// pause late (track report not flipping when the head crosses).
// CD_DAC FIFO model (CDDA_FIFO.v numbers): 1280-word capacity, drains one
// stereo sample per ~1217 clk (44.1kHz @ 53.693175MHz), WRITE_READY while
// filled <= 1280-588. Two cdc_cdda_wr edges = one 32-bit FIFO word.
static long dacfifo_filled = 0, dacfifo_drain = 0;
static int  dacfifo_halfword = 0;
static void dacfifo_tick(){
    bool w = dut->cdc_cdda_wr;
    static bool w_d = false;
    if (w && !w_d){ if(++dacfifo_halfword == 2){ dacfifo_halfword=0; dacfifo_filled++; } }
    w_d = w;
    if (++dacfifo_drain >= 1217){ dacfifo_drain = 0; if (dacfifo_filled) dacfifo_filled--; }
    dut->cdda_wr_ready = (dacfifo_filled <= (1280-588)) ? 1 : 0;
}

static int jingle_test(){
    dut->reset=1; dut->mcd_rst_n=0; dut->cdd_send=0; dut->cdd_comm=0;
    dut->img_size = 200000u*2352u; dut->track_count=3; dut->cdda_wr_ready=1;
    dut->cd_fast_seek=0; dut->disc_loading=0;
    dut->toc_q[0]=0; dut->toc_q[1]=0; dut->toc_q[2]=0; dut->cd_ack_74a=0;
    // shining.cue, single bin: t2 INDEX00 29195 INDEX01 29344 (pre01 149),
    // t3 INDEX00 29945 INDEX01 30095 (pre01 150). Boundary under test: 29945.
    toc_set(1, /*audio*/false, 0,   0, /*file*/0, /*delta*/0, /*disc*/0);
    toc_set(2, /*audio*/true,  0, 149, /*file*/0, /*delta*/0, /*disc*/29344);
    toc_set(3, /*audio*/true,  0, 150, /*file*/0, /*delta*/0, /*disc*/30095);
    for(int i=0;i<20;i++) tick();
    dut->reset=0; dut->mcd_rst_n=1;
    for(int i=0;i<20;i++) tick();

    const long BEAT = 715909;
    const long T2_END = 29945, T3_START = 30095;
    pulse_cmd(mk_seek(29750));           // late in the jingle (track 2 proper)

    long gap_words=0, gap_nz=0, t3_words=0, t3_nz=0;
    long cross_beat=-1, flip_beat=-1, pause_beat=-1, dm_head=-1;
    int  rot=0; bool cw=false, dm_d=dut->cdd_dm;
    for(long b=0;b<400;b++){
        uint64_t cmd;
        if(pause_beat<0 && flip_beat>=0 && b >= flip_beat+4){
            cmd = 0x6; pause_beat = b;   // BIOS auto-pause, 4 frames after flip
        } else {
            cmd = 0x2 | ((uint64_t)(rot)<<12); rot = (rot+1)%3;
        }
        pulse_cmd(cmd);
        for(long c=0;c<BEAT;c++){
            tick();
            dacfifo_tick();
            long h = dut->dbg_state & 0xFFFFF;
            if(cross_beat<0 && h >= T2_END) cross_beat = b;
            bool dm = dut->cdd_dm;
            if(dm && !dm_d && dm_head<0 && b>2) dm_head = h;
            dm_d = dm;
            bool w = dut->cdc_cdda_wr;
            if(w && !cw){
                if(h >= T2_END && h < T3_START){ gap_words++; if(dut->cdc_data) gap_nz++; }
                if(h >= T3_START)              { t3_words++;  if(dut->cdc_data) t3_nz++; }
            }
            cw = w;
        }
        // reply to this beat's poll (latched at the beat edge just passed)
        int n1=(dut->cdd_stat>>4)&0xF, n2=(dut->cdd_stat>>8)&0xF, n3=(dut->cdd_stat>>12)&0xF;
        if(flip_beat<0 && n1==2 && (n2*10+n3)==3) flip_beat = b;
        if(pause_beat>=0 && b >= pause_beat+40) break;
    }
    long head_end = dut->dbg_state & 0xFFFFF;
    int  drv = (dut->dbg_cmds) & 0xF;
    printf("--- jingle results ---\n");
    printf("head crossed %ld at beat %ld; track report flipped to 03 at beat %ld\n",
           T2_END, cross_beat, flip_beat);
    printf("cdd_dm went 1 at head=%ld (want %ld)\n", dm_head, T2_END);
    printf("pause sent at beat %ld; final head=%ld status=%d (want gap park: %ld..%ld, status 4)\n",
           pause_beat, head_end, drv, T2_END, T3_START);
    printf("gap  CDDA words=%ld nonzero=%ld (want 0 nonzero)\n", gap_words, gap_nz);
    printf("t3   CDDA words=%ld nonzero=%ld (want NONE AT ALL)\n", t3_words, t3_nz);

    if(cross_beat<0)                err("head never reached the track 2 end boundary");
    if(flip_beat<0)                 err("track-number report never flipped to 03");
    // the BIOS polls track number only every 3rd frame (2000/2001/2002
    // rotation), so a flip can surface up to 3 beats after the crossing --
    // GPGX has the identical poll latency (pause landed at crossing+4/5)
    if(cross_beat>=0 && flip_beat>=0 && flip_beat > cross_beat+3)
                                    err("track report flipped LATE -> BIOS auto-pause would be late");
    if(dm_head<0)                   err("cdd_dm never rose at the track end");
    if(dm_head>=0 && (dm_head < T2_END-1 || dm_head > T2_END+2))
                                    err("cdd_dm rose at the wrong head position");
    if(pause_beat<0)                err("pause was never sent (no flip seen)");
    if(drv!=4)                      err("drive not PAUSED at the end");
    if(head_end < T2_END || head_end >= T3_START)
                                    err("pause did not park the head inside the gap");
    if(gap_nz != 0)                 err("gap leaked nonzero CDDA (bleed)");
    if(t3_words != 0 || t3_nz != 0) err("track 3 was reached/delivered before the pause (bleed)");

    printf(fail ? "\n==== JINGLE TEST FAILED ====\n" : "\n==== JINGLE TEST PASSED ====\n");
    return fail?1:0;
}

// Delivered-content audit against the REAL disc image. The jingle test above
// proves the protocol (reports/flag/pause) is right; this proves (or refutes)
// that the SAMPLES delivered at head H are actually file[H]. Motivated by the
// Shining Force CD bleed forensics: the rip's INDEX 00 gaps are digitally
// silent, yet pre-d8b0da45 hardware audibly played "2s of the next track"
// during the gap -- impossible unless the delivered content is offset from
// the head by about a pregap (+150). Plays the tail of the title jingle
// (track 2) from the real bin and byte-compares every delivered CDDA sector
// against file[head], file[head+149] and file[head+150].
static int content_test(const char* binpath){
    bin_data = fopen(binpath, "rb");
    if(!bin_data){ printf("FAIL: cannot open %s\n", binpath); return 1; }
    fseek(bin_data, 0, SEEK_END);
    long fsz = ftell(bin_data);

    dut->reset=1; dut->mcd_rst_n=0; dut->cdd_send=0; dut->cdd_comm=0;
    dut->img_size = (uint32_t)fsz; dut->track_count=4; dut->cdda_wr_ready=1;
    dut->cd_fast_seek=0; dut->disc_loading=0;
    dut->toc_q[0]=0; dut->toc_q[1]=0; dut->toc_q[2]=0; dut->cd_ack_74a=0;
    toc_set(1, /*audio*/false, 0,   0, 0, 0, 0);
    toc_set(2, /*audio*/true,  0, 149, 0, 0, 29344);
    toc_set(3, /*audio*/true,  0, 150, 0, 0, 30095);
    toc_set(4, /*audio*/true,  0, 150, 0, 0, 31578);
    for(int i=0;i<20;i++) tick();
    dut->reset=0; dut->mcd_rst_n=1;
    for(int i=0;i<20;i++) tick();

    const long BEAT = 715909;
    cap_on = true; cap_ready = false; cap_secw = 0;
    pulse_cmd(mk_seek(29750));           // tail of the jingle (track 2)

    long m_h=0, m_h149=0, m_h150=0, m_none=0, gap_z=0, gap_nz=0;
    for(long b=0;b<380;b++){
        pulse_cmd(0x0ULL);
        for(long c=0;c<BEAT;c++){
            tick();
            dacfifo_tick();
            if(cap_ready){
                cap_ready = false;
                long h_start = cap_head;
                uint16_t* cursec = cap_sec;
                {
                    if(h_start>=29750 && h_start<29945){
                        uint8_t fb[3][2352];
                        long offs[3] = {h_start, h_start+149, h_start+150};
                        int verdict=-1;
                        for(int k=0;k<3;k++){
                            fseek(bin_data, offs[k]*2352L, SEEK_SET);
                            if(fread(fb[k],1,2352,bin_data)!=2352) memset(fb[k],0xAA,2352);
                            bool ok=true;
                            for(int wd=0; wd<1176 && ok; wd++){
                                uint16_t e = (uint16_t)fb[k][wd*2] | ((uint16_t)fb[k][wd*2+1]<<8);
                                if(cursec[wd]!=e) ok=false;
                            }
                            if(ok){ verdict=k; break; }
                        }
                        if(verdict==0) m_h++;
                        else if(verdict==1) m_h149++;
                        else if(verdict==2) m_h150++;
                        else {
                            if(m_none==0){
                                int fd=-1;
                                for(int wd=0; wd<1176 && fd<0; wd++){
                                    uint16_t e = (uint16_t)fb[0][wd*2] | ((uint16_t)fb[0][wd*2+1]<<8);
                                    if(cursec[wd]!=e) fd=wd;
                                }
                                printf("  first mismatching sector: head=%ld first diff word=%d\n", h_start, fd);
                                for(int wd=(fd<3?0:fd-3); wd<fd+5 && wd<1176; wd++){
                                    uint16_t e = (uint16_t)fb[0][wd*2] | ((uint16_t)fb[0][wd*2+1]<<8);
                                    printf("    w%-4d dlv=%04x file[h]=%04x file[h+150]=%04x\n",
                                           wd, cursec[wd], e,
                                           (uint16_t)fb[2][wd*2] | ((uint16_t)fb[2][wd*2+1]<<8));
                                }
                            }
                            m_none++;
                        }
                    } else if(h_start>=29945 && h_start<30095){
                        bool z=true;
                        for(int wd=0; wd<1176 && z; wd++) if(cursec[wd]) z=false;
                        if(z) gap_z++; else gap_nz++;
                    }
                }
            }
        }
        if((dut->dbg_state & 0xFFFFF) >= 30100) break;
    }
    cap_on = false;
    printf("--- content audit (track 2 tail, real bin) ---\n");
    printf("sectors matching file[head]     : %ld  (correct)\n", m_h);
    printf("sectors matching file[head+149] : %ld  (SHIFTED)\n", m_h149);
    printf("sectors matching file[head+150] : %ld  (SHIFTED)\n", m_h150);
    printf("sectors matching none           : %ld\n", m_none);
    printf("gap sectors zero/nonzero        : %ld/%ld\n", gap_z, gap_nz);
    if(m_h < 100)           err("too few correct sectors delivered");
    if(m_h149 || m_h150)    err("delivered content is OFFSET from the head");
    if(m_none)              err("delivered content matches nothing in the file");
    if(gap_nz)              err("gap leaked nonzero CDDA");
    printf(fail ? "\n==== CONTENT TEST FAILED ====\n" : "\n==== CONTENT TEST PASSED ====\n");
    fclose(bin_data); bin_data=nullptr;
    return fail?1:0;
}

static int swap_test(){
    dut->reset=1; dut->mcd_rst_n=0; dut->cdd_send=0; dut->cdd_comm=0;
    dut->img_size = 0; dut->track_count=1; dut->cdda_wr_ready=1; dut->cd_fast_seek=0; dut->disc_loading=0;
    dut->toc_q[0]=0; dut->toc_q[1]=0; dut->toc_q[2]=0; dut->cd_ack_74a=0;
    toc_set(1, /*audio*/false, 0,0, /*file*/0, /*delta*/0, /*disc*/0);
    for(int i=0;i<20;i++) tick();
    dut->reset=0; dut->mcd_rst_n=1;
    for(int i=0;i<20;i++) tick();

    int saw=0;
    dut->disc_loading = 0;
    if(run_beats(20,&saw,0xB) < 0){ err("never drained to NO_DISC at boot"); return 1; }
    printf("boot (nothing mounted): NO_DISC(B) — no tray shown\n");

    // --- user picks disc A: tray opens IMMEDIATELY, stays open while the
    //     bins are sized, then closes once the TOC is final ---
    dut->disc_loading = 1; dut->img_size = 0;
    saw=0;
    if(run_beats(4,&saw,0x5) < 0){ err("picking a cue did not open the tray"); return 1; }
    printf("disc A picked: tray OPEN(5) immediately\n");
    // hold through a long load, and pulse the MCD reset the way the BIOS does
    for(long i=0;i<20;i++){
        pulse_cmd(0x0ULL);
        for(long c=0;c<715909;c++) tick();
        if(i==10){ dut->mcd_rst_n=0; for(int k=0;k<2000;k++) tick();
                   dut->mcd_rst_n=1; for(int k=0;k<2000;k++) tick(); }
    }
    if((dut->dbg_cmds & 0xF) != 0x5){
        err("tray did not stay open across the load / MCD reset pulse"); return 1; }
    printf("disc A: tray held OPEN(5) for 20 beats incl. an MCD reset pulse\n");
    // TOC final: disc appears, tray closes
    dut->img_size = 3000*2352; dut->disc_loading = 0;
    saw=0;
    if(run_beats(60,&saw,0x9) < 0){ err("disc A never reached TOC(9) after load"); return 1; }
    printf("disc A: TOC final -> tray closed -> TOC(9)\n");

    // --- user picks a different .cue ---
    dut->disc_loading = 1; dut->img_size = 0;
    saw=0;
    long b = run_beats(4,&saw,0x5);
    if(b < 0){ err("swap: tray did not reopen for the new image"); return 1; }
    printf("disc B picked: tray OPEN(5) again (no NO_DISC flash)\n");

    // --- disc B's TOC becomes final ---
    dut->img_size = 5000*2352; dut->disc_loading = 0;
    saw=0;
    if(run_beats(60,&saw,0x9) < 0){ err("disc B never reached TOC(9) — close dance did not run"); return 1; }
    printf("disc B: closed and reached TOC(9)\n");

    // --- a load that fails (no disc ever appears) must not strand the tray ---
    dut->disc_loading = 1; dut->img_size = 0;
    saw=0;
    if(run_beats(4,&saw,0x5) < 0){ err("failed load: tray did not open"); return 1; }
    dut->disc_loading = 0;                       // give up, still no media
    saw=0;
    if(run_beats(20,&saw,0xB) < 0){ err("failed load left the tray stuck OPEN"); return 1; }
    printf("failed load: fell back to NO_DISC(B) instead of hanging open\n");

    printf(fail ? "\n==== SWAP TEST FAILED ====\n" : "\n==== SWAP TEST PASSED ====\n");
    return fail?1:0;
}

// Seek-latency restart test.
//
// GPGX only charges the fixed spin-up base when no latency is already pending:
//
//    if (!cdd.latency) cdd.latency = 2 + 10*config.cd_latency;   // cdd.c
//    cdd.latency += ((|dlba| * 120 * config.cd_latency) / 270000);
//
// so a Play re-issued while the drive is still seeking does NOT restart the
// base -- the original countdown keeps running. Ours assigns seek_cnt
// unconditionally, so every re-issue restarts the full 11-frame (146ms) base
// and the head stays frozen for as long as the commands keep coming. That is
// the shape of an FMV stutter: drv_status parked at SEEK(2) with head stalled.
static int reseek_test(){
    dut->reset=1; dut->mcd_rst_n=0; dut->cdd_send=0; dut->cdd_comm=0;
    // full-size disc: the distance term only bites past ~2250 sectors
    dut->img_size = 330000u*2352u; dut->track_count=0; dut->cdda_wr_ready=1; dut->cd_fast_seek=0;
    if(getenv("FASTSEEK")) dut->cd_fast_seek=1;
    dut->disc_loading=0;
    dut->toc_q[0]=0; dut->toc_q[1]=0; dut->toc_q[2]=0; dut->cd_ack_74a=0;
    for(int i=0;i<20;i++) tick();
    dut->reset=0; dut->mcd_rst_n=1;
    for(int i=0;i<20;i++) tick();

    const long BEAT = 715909;
    auto head = [&]{ return (long)(dut->dbg_state & 0xFFFFF); };
    // GPGX semantics: the head parks ON the target at the apply tick and the
    // internal status is PLAY throughout the latency; "seek done" is when the
    // head starts ADVANCING. Latency = 1 apply tick + base(12 acc / 2 fast) +
    // dist/2250 (accurate only).
    auto seek_and_wait = [&](long L, int reissue_ivl, int reissue_for)->long{
        pulse_cmd(mk_seek(L));
        for(long b=0;b<400;b++){
            pulse_cmd(0x0ULL);                    // Get-Drive-Status poll
            if(reissue_ivl && b<reissue_for && (b%reissue_ivl)==0)
                pulse_cmd(mk_seek(L));
            for(long c=0;c<BEAT;c++){ tick(); }
            if(head() > L) return b;              // first advance past target
        }
        return -1;
    };

    long base_exp = getenv("FASTSEEK") ? 2 : 12;

    long single = seek_and_wait(100, 0, 0);
    printf("single SEEK+PLAY      -> head moves after %ld beats (expect ~%ld)\n",
           single, base_exp+1);
    if(single < base_exp-1 || single > base_exp+3)
        err("short seek latency does not match GPGX base");

    long FAR = 50000;
    long far_exp = base_exp + (getenv("FASTSEEK") ? 0 : FAR/2250);
    long fars = seek_and_wait(FAR, 0, 0);
    printf("long  SEEK+PLAY (%ld) -> head moves after %ld beats (expect ~%ld)\n",
           FAR, fars, far_exp+1);
    if(fars < far_exp-2 || fars > far_exp+4)
        err("long-stroke latency does not match base + |dlba|/2250");

    // head must be PARKED on the target while the latency drains (upstream
    // cdd.lba = lba at apply): sample mid-latency
    pulse_cmd(mk_seek(100));
    for(long b=0;b<5;b++){ pulse_cmd(0x0ULL); for(long c=0;c<BEAT;c++) tick(); }
    if(!getenv("FASTSEEK") && head() != 100)
        err("head not parked on the target during seek latency");

    // re-issued while pending: |dlba| = 0 from the parked head, so the
    // latency must not restart or compound (the old accumulate bug)
    // drain current
    for(long b=0;b<20;b++){ pulse_cmd(0x0ULL); for(long c=0;c<BEAT;c++) tick(); }
    long re = seek_and_wait(FAR/2, 2, 20);
    printf("re-issued every 2 beats -> head moves after %ld beats (expect ~%ld)\n",
           re, base_exp + (getenv("FASTSEEK")?0:(FAR/2 - 100)/2250) + 1);
    // Only meaningful while the base exceeds the re-issue interval. Under
    // FASTSEEK the base is 2 and we re-issue every 2: each command's apply
    // legitimately re-parks lba and recharges the base -- upstream behaves
    // identically (cdd.lba = lba on every apply), so 20+ beats is CORRECT
    // there, not the compounding bug this guards against.
    long re_exp = base_exp + (getenv("FASTSEEK")?0:(FAR/2)/2250);
    if(!getenv("FASTSEEK") && re > re_exp + 6)
        err("re-issued seek restarts/compounds the latency (upstream does not)");

    printf(fail ? "\n==== RESEEK TEST FAILED ====\n" : "\n==== RESEEK TEST PASSED ====\n");
    return fail?1:0;
}

// Pause-on-stall test: a host outage during PLAY delivery must raise
// stall_pause after ~78ms (2^22 clk) of head starvation, hold the drive's
// 75Hz world frozen while asserted (head parked, zero deliveries, zero
// stale sectors), and release within a handful of clk of the fetch landing.
// The outage is modelled as one fetch whose ack never comes for spike_len
// clk -- from the drive's side that IS a dead host, since the fetch FSM is
// serial and parks on the un-acked request.
static int stallpause_test(){
    mock_valid_sync = true;
    loopback_pause = true;
    dut->reset=1; dut->mcd_rst_n=0; dut->cdd_send=0; dut->cdd_comm=0;
    dut->img_size = 30000u*2352u; dut->track_count=0; dut->cdda_wr_ready=1;
    dut->cd_fast_seek=0; dut->disc_loading=0;
    dut->toc_q[0]=0; dut->toc_q[1]=0; dut->toc_q[2]=0; dut->cd_ack_74a=0;
    for(int i=0;i<20;i++) tick();
    dut->reset=0; dut->mcd_rst_n=1;
    for(int i=0;i<20;i++) tick();

    // --stallpause-parked: SEEK+PAUSE variant. The drive parks on the target
    // and prefetches it during the latency countdown; with the host dead the
    // fetch hangs, and the latency-window term of stall_cond must engage
    // MID-SEEK (well before the 12-beat latency elapses), then keep holding
    // through the parked re-delivery phase. The outage starts BEFORE the
    // seek so the target fetch itself is the one that hangs.
    if(g_sp_parked){
        spike_at_fetch = fetch_idx; spike_len = 20000000;
        uint64_t comm = mk_seek(500) & ~0xFULL; comm |= 0x4;   // c0=4 SEEK+PAUSE
        pulse_cmd(comm);
        vluint64_t t0=tk, t_on=0, t_off=0;
        while(tk < t0 + 26000000){
            tick();
            if(((tk-t0) % 4000000)==0)
                printf("  [parked] t=+%lld head=%ld drv=%d req=%d bufv=%d\n",
                       (long long)(tk-t0), (long)(dut->dbg_state & 0xFFFFF),
                       (int)((dut->dbg_state>>28)&0xF),
                       (int)((dut->dbg_state>>23)&1),
                       (int)((dut->dbg_state>>21)&3));
            bool sp = dut->stall_pause;
            if(sp && !t_on) t_on=tk;
            if(t_on && !sp){ t_off=tk; break; }
        }
        int drv=(dut->dbg_state>>28)&0xF;
        printf("--- parked (SEEK+PAUSE) stall results ---\n");
        printf("pause ON %s+%lld, OFF %s+%lld, drv_status=%d badsync=%u\n",
               t_on?"":"never ", t_on?(long long)(t_on-t0):-1,
               t_off?"":"never ", t_off?(long long)(t_off-t0):-1,
               drv, (unsigned)((dut->dbg_integ>>24)&0xFF));
        if(!t_on)  err("stall_pause never asserted for a starved parked sector");
        // 12-beat latency ~= 8.6M: the pause must fire INSIDE the latency
        // window (~ threshold after the seek applies), not after it elapses
        if(t_on && (long long)(t_on-t0) > 8000000)
                   err("pause did not engage during the seek-latency window");
        if(!t_off) err("stall_pause never released after the fetch landed");
        if(drv!=4) err("drive fell out of PAUSE");
        if(((dut->dbg_integ>>24)&0xFF)!=0) err("badsync in parked stall");
        printf(fail ? "\n==== PARKED STALL TEST FAILED ====\n"
                    : "\n==== PARKED STALL TEST PASSED ====\n");
        return fail?1:0;
    }

    pulse_cmd(mk_seek(10));
    const long BEAT = 715909;
    const long THRESH = 1048576;             // STALL_PAUSE_AT in the drive

    // 1) establish streaming. deliver_words is NOT the signal here: the
    //    drive re-delivers the parked head sector every beat in TOC/latency
    //    states (decoder-keeps-running behavior), which pumps the word count
    //    long before PLAY delivery begins. Head ADVANCE is what only PLAY
    //    deliveries do, so wait for a few of those.
    long b=0;
    while((long)(dut->dbg_state & 0xFFFFF) < 13 && b < 60){ pulse_cmd(0x0ULL);
        for(long c=0;c<BEAT;c++) tick(); b++; }
    if((long)(dut->dbg_state & 0xFFFFF) < 13){ err("streaming never established"); return 1; }

    // 2) host outage: the next fetch's ack is withheld for ~223ms
    const long OUTAGE = 12000000;
    spike_at_fetch = fetch_idx;
    spike_len = OUTAGE;
    vluint64_t t_out0 = tk;
    long words_at_out0 = deliver_words;

    // 3) run through the outage watching for the pause. No IDLE polls in
    //    here: the real sub-CPU is frozen by the pause and sends nothing.
    vluint64_t t_on=0, t_off=0, t_spike_req=0;
    long head_at_on=-1, words_at_on=-1;
    bool frozen_moved=false, frozen_delivered=false;
    { long head_d = dut->dbg_state & 0xFFFFF; bool req_dd = dut->cd_req;
      int ev=0;
      while(tk < t_out0 + OUTAGE + 9000000){
        tick();
        long hd = dut->dbg_state & 0xFFFFF; bool rq = dut->cd_req;
        if(ev<40 && hd!=head_d){ printf("  [ev] t=+%lld head %ld->%ld\n",
            (long long)(tk-t_out0), head_d, hd); ev++; }
        if(rq && !req_dd){
            // this loop sees the rise one tick before the mock assigns
            // lat_ctr, so identify the spiked fetch by its index instead
            bool spiked = (fetch_idx == spike_at_fetch);
            if(ev<40) printf("  [ev] t=+%lld req off=%u lat=%ld%s\n",
                (long long)(tk-t_out0), (unsigned)dut->cd_req_offset, lat_ctr,
                spiked ? " <SPIKE>" : ""); ev++;
            if(spiked && !t_spike_req) t_spike_req = tk;
        }
        head_d=hd; req_dd=rq;
        bool sp = dut->stall_pause;
        if(sp && !t_on){ t_on = tk;
            printf("  [ev] t=+%lld PAUSE ON\n",(long long)(tk-t_out0));
            head_at_on = dut->dbg_state & 0xFFFFF;
            words_at_on = deliver_words; }
        if(sp){
            if((long)(dut->dbg_state & 0xFFFFF) != head_at_on) frozen_moved=true;
            if(deliver_words != words_at_on) frozen_delivered=true;
        }
        if(t_on && !sp){ t_off = tk;
            printf("  [ev] t=+%lld PAUSE OFF\n",(long long)(tk-t_out0)); break; }
      }
    }
    printf("--- pause-on-stall results ---\n");
    printf("outage at t=%llu, pause ON +%lld clk, OFF +%lld clk (outage %ld)\n",
           (unsigned long long)t_out0,
           t_on ? (long long)(t_on-t_out0) : -1,
           t_off ? (long long)(t_off-t_out0) : -1, OUTAGE);
    printf("head@ON=%ld  frozen_moved=%d frozen_delivered=%d  badsync=%u\n",
           head_at_on, frozen_moved, frozen_delivered,
           (unsigned)((dut->dbg_integ>>24)&0xFF));

    if(!t_on)  err("stall_pause never asserted during a >200ms host outage");
    if(!t_spike_req) err("spiked fetch never issued (test setup broken)");
    // All timing is relative to the SPIKED REQUEST's start: its ack lands at
    // t_spike_req+OUTAGE, and starvation begins once the bank (<=5 sectors
    // incl. in-flight) drains after it.
    if(t_on && t_spike_req && (long long)(t_on-t_spike_req) < THRESH)
               err("stall_pause asserted before the 78ms threshold");
    if(t_on && t_spike_req && (long long)(t_on-t_spike_req) > THRESH + 6*BEAT)
               err("stall_pause asserted late (starvation start + 78ms expected)");
    if(!t_off) err("stall_pause never released after the host came back");
    if(t_off && t_spike_req && (long long)(t_off-t_spike_req) > OUTAGE+1000)
               err("stall_pause released late (release must track the ack)");
    if(frozen_moved)     err("head advanced while paused");
    if(frozen_delivered) err("sectors delivered while paused");
    if(((dut->dbg_integ>>24)&0xFF)!=0) err("stale sector delivered (badsync)");
    if(((dut->dbg_state>>28)&0xF)!=1) err("drive fell out of PLAY across the outage");
    if(!(dut->dbg_integ & 1)) err("sticky stall-seen debug bit not set");

    // 4) recovery: streaming resumes at full rate with the head continuous
    long words_at_rec = deliver_words;
    long head_at_rec = dut->dbg_state & 0xFFFFF;
    for(long bb=0;bb<8;bb++){ pulse_cmd(0x0ULL);
        for(long c=0;c<BEAT;c++) tick(); }
    long secs_rec = (deliver_words - words_at_rec)/1176;
    long head_now = dut->dbg_state & 0xFFFFF;
    printf("recovery: +%ld sectors in 8 beats, head %ld -> %ld\n",
           secs_rec, head_at_rec, head_now);
    if(secs_rec < 6) err("delivery did not resume at rate after the pause");
    if(head_now - head_at_rec != (long)(deliver_words-words_at_rec)/1176)
        err("head skipped sectors across the pause/recovery");
    if(((dut->dbg_integ>>24)&0xFF)!=0) err("badsync after recovery");

    printf(fail ? "\n==== STALL-PAUSE TEST FAILED ====\n"
                : "\n==== STALL-PAUSE TEST PASSED ====\n");
    return fail?1:0;
}

// stallhammer: the Shining Force CD battle workload, randomized. Battles hop
// CDDA Play targets between audio-track bins every few seconds (no data
// reads); since the seek-latency-window stall coverage (0.3.5), any hop whose
// host round trips exceed ~19.5ms freeze-cycles the whole machine mid-seek.
// This drives thousands of such hops with per-fetch latency jitter straddling
// the threshold, plus impatient mid-latency re-seeks, with the sub modeled
// frozen during pauses (no commands land while stall_pause is up). Invariants:
// every freeze releases (bounded hold), every hop reaches its target and
// streams, no badsync. The full co-sim is deterministic and slow (2 hops in
// 3h); this explores the engage/release phase space directly.
static bool g_hammer_fast = false;   // --hammer-fast: cd_fast_seek=1 variant
static int stallhammer_test(long niter){
    mock_valid_sync = true;
    loopback_pause = true;
    g_lat_rand = true;
    dut->reset=1; dut->mcd_rst_n=0; dut->cdd_send=0; dut->cdd_comm=0;
    dut->img_size = 30000u*2352u; dut->track_count=4; dut->cdda_wr_ready=1;
    dut->cd_fast_seek=g_hammer_fast; dut->disc_loading=0; dut->cd_ack_74a=0;
    toc_set(1,false,0,0,/*file*/0,/*delta*/0,    /*disc*/0);      // data
    toc_set(2,true, 0,0,/*file*/1,/*delta*/10000,/*disc*/10000);  // audio
    toc_set(3,true, 0,0,/*file*/2,/*delta*/20000,/*disc*/20000);  // audio
    toc_set(4,true, 0,0,/*file*/3,/*delta*/25000,/*disc*/25000);  // audio
    for(int i=0;i<20;i++) tick();
    dut->reset=0; dut->mcd_rst_n=1;
    for(int i=0;i<20;i++) tick();

    const long BEAT = 715909;
    const long HOP_TIMEOUT = 90000000;   // ~1.7s >> latency + worst spike runs
    const long PAUSE_LIMIT = 30000000;   // no single freeze may hold > ~560ms
    long freezes=0, max_hold=0, reseeks=0;
    for(long it=0; it<niter && !fail; it++){
        long tgt;
        switch(rng32()%8){               // battle-ish mix: mostly audio hops
            case 0:  tgt =  2000 + (long)(rng32()%4000); break;   // data load
            case 1: case 2: case 3:
                     tgt = 10500 + (long)(rng32()%8000); break;   // track 2
            case 4: case 5:
                     tgt = 20200 + (long)(rng32()%4000); break;   // track 3
            default: tgt = 25200 + (long)(rng32()%4000); break;   // track 4
        }
        pulse_cmd(mk_seek(tgt));
        long resk_at = (rng32()%5==0) ? 2000000 + (long)(rng32()%7000000) : -1;
        long resk_tgt = 10500 + (long)(rng32()%18000);
        long cur_tgt = tgt;
        vluint64_t t0=tk, pause_on=0;
        long adv=0, head_d=-1, poll_ctr=0;
        bool ok=false;
        while((long)(tk-t0) < HOP_TIMEOUT && !fail){
            tick(); dacfifo_tick();
            if(dut->stall_pause){ if(!pause_on){ pause_on=tk; freezes++; } }
            else if(pause_on){ long h=(long)(tk-pause_on);
                               if(h>max_hold) max_hold=h; pause_on=0; }
            if(pause_on && (long)(tk-pause_on) > PAUSE_LIMIT){
                err("stall_pause held past limit -- release failure"); break; }
            // the frozen sub sends nothing; when running, poll each beat and
            // fire the scheduled impatient re-seek
            if(!dut->stall_pause){
                if(++poll_ctr >= BEAT){ poll_ctr=0; pulse_cmd(0x0ULL); }
                if(resk_at>=0 && (long)(tk-t0) >= resk_at){
                    resk_at=-1; reseeks++; cur_tgt=resk_tgt;
                    pulse_cmd(mk_seek(resk_tgt));
                }
            }
            long hd = (long)(dut->dbg_state & 0xFFFFF);
            int drv = (int)((dut->dbg_state>>28)&0xF);
            if(drv==1 && head_d>=0 && hd!=head_d
               && hd>=cur_tgt && hd<=cur_tgt+64){
                if(++adv>=3 && resk_at<0){ ok=true; break; } }
            if(hd!=head_d) head_d=hd;
        }
        if(!ok && !fail){
            printf("hop %ld: TIMEOUT tgt=%ld head=%ld drv=%d req=%d bufv=%d "
                   "pause=%d lat_ctr=%ld fetch=%ld\n",
                   it, cur_tgt, (long)(dut->dbg_state&0xFFFFF),
                   (int)((dut->dbg_state>>28)&0xF), (int)((dut->dbg_state>>23)&1),
                   (int)((dut->dbg_state>>21)&3), (int)dut->stall_pause,
                   lat_ctr, fetch_idx);
            err("hop never reached target / streaming");
        }
        if((it%50)==0)
            printf("  hammer: %ld/%ld hops, freezes=%ld max_hold=%ldk, reseeks=%ld\n",
                   it, niter, freezes, max_hold/1000, reseeks);
    }
    unsigned bs = (unsigned)((dut->dbg_integ>>24)&0xFF);
    printf("--- stallhammer results ---\n");
    printf("hops=%ld freezes=%ld max_hold=%ld clk (%.1fms) reseeks=%ld badsync=%u\n",
           niter, freezes, max_hold, max_hold/53693.0, reseeks, bs);
    if(bs) err("badsync during hammer");
    if(!freezes) err("hammer never froze -- latency model broken?");
    printf(fail ? "\n==== STALLHAMMER FAILED ====\n"
                : "\n==== STALLHAMMER PASSED ====\n");
    return fail?1:0;
}

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    dut = new Vmegacd_cdd_drive;
    bool cdda_mode=false, swap_mode=false, reseek_mode=false, pause_mode=false, scan_mode=false, binswap_mode=false, integ_mode=false, gap_mode=false, jingle_mode=false, stallpause_mode=false, hammer_mode=false;
    long hammer_n=400;
    const char* content_bin=nullptr;
    for(int i=1;i<argc;i++){
        // --lat N: SUSTAINED per-fetch host latency in clk, modelling real SD
        // round-trip cost rather than a one-off stall. This is the number that
        // decides whether streaming keeps up: the fetch FSM is serial, so the
        // drive must retire roughly one fetch per sector period (BEAT =
        // 715909 clk = 13.3ms) to hold 1 sector/beat, no matter how deep the
        // prefetch bank is. Depth buys burst tolerance, not throughput.
        if(!strcmp(argv[i],"--lat")&&i+1<argc) LAT_NORMAL=atol(argv[++i]);
        if(!strcmp(argv[i],"--spike-at")&&i+1<argc) spike_at_fetch=atol(argv[++i]);
        if(!strcmp(argv[i],"--spike-len")&&i+1<argc) spike_len=atol(argv[++i]);
        if(!strcmp(argv[i],"--cdda")) cdda_mode=true;
        if(!strcmp(argv[i],"--swap")) swap_mode=true;
        if(!strcmp(argv[i],"--reseek")) reseek_mode=true;
        if(!strcmp(argv[i],"--pause")) pause_mode=true;
        if(!strcmp(argv[i],"--scan")) scan_mode=true;
        if(!strcmp(argv[i],"--binswap")) binswap_mode=true;
        if(!strcmp(argv[i],"--integ")) integ_mode=true;
        if(!strcmp(argv[i],"--gap")) gap_mode=true;
        if(!strcmp(argv[i],"--jingle")) jingle_mode=true;
        if(!strcmp(argv[i],"--stallpause")) stallpause_mode=true;
        if(!strcmp(argv[i],"--stallpause-parked")){ stallpause_mode=true; g_sp_parked=true; }
        if(!strcmp(argv[i],"--stallhammer")) hammer_mode=true;
        if(!strcmp(argv[i],"--hammer-n")&&i+1<argc) hammer_n=atol(argv[++i]);
        if(!strcmp(argv[i],"--hammer-seed")&&i+1<argc) g_rng=(uint32_t)strtoul(argv[++i],0,0);
        if(!strcmp(argv[i],"--hammer-fast")) g_hammer_fast=true;
        if(!strcmp(argv[i],"--content")&&i+1<argc) content_bin=argv[++i];
    }
    if(cdda_mode){ int r=cdda_test(); delete dut; return r; }
    if(swap_mode){ int r=swap_test(); delete dut; return r; }
    if(reseek_mode){ int r=reseek_test(); delete dut; return r; }
    if(pause_mode){ int r=pause_test(); delete dut; return r; }
    if(scan_mode){ int r=scan_test(); delete dut; return r; }
    if(binswap_mode){ int r=binswap_test(); delete dut; return r; }
    if(integ_mode){ int r=integ_test(); delete dut; return r; }
    if(gap_mode){ int r=gap_test(); delete dut; return r; }
    if(jingle_mode){ int r=jingle_test(); delete dut; return r; }
    if(stallpause_mode){ int r=stallpause_test(); delete dut; return r; }
    if(hammer_mode){ int r=stallhammer_test(hammer_n); delete dut; return r; }
    if(content_bin){ int r=content_test(content_bin); delete dut; return r; }

    // reset
    dut->reset=1; dut->mcd_rst_n=0; dut->cdd_send=0; dut->cdd_comm=0;
    dut->img_size = 300*2352;      // 300-sector disc, single data track
    dut->track_count=0; dut->cdda_wr_ready=1; dut->cd_fast_seek=0; dut->disc_loading=0;
    dut->toc_q[0]=0; dut->toc_q[1]=0; dut->toc_q[2]=0;   // 66-bit VlWide
    dut->cd_ack_74a=0;
    for(int i=0;i<20;i++) tick();
    dut->reset=0; dut->mcd_rst_n=1;
    for(int i=0;i<20;i++) tick();

    // SEEK+PLAY to LBA 10 -> MSF of 10+150=160 = 00:02:10
    // c0=3, c2c3=mm(00), c4c5=ss(02), c6c7=ff(10)
    // comm nibbles [3:0]=c0 ... [31:28]=c7
    uint64_t comm = 0x3ULL       // c0=3 SEEK+PLAY
                  | (0x0ULL<<8)  // c2=0
                  | (0x0ULL<<12) // c3=0
                  | (0x0ULL<<16) // c4=0
                  | (0x2ULL<<20) // c5=2
                  | (0x1ULL<<24) // c6=1
                  | (0x0ULL<<28);// c7=0
    pulse_cmd(comm);

    // Run beats. BEAT = 715909 cycles. Poll IDLE (DRIVE STATUS c0=0) each beat
    // like the BIOS so the seek completes (F->0 report handshake). Measure
    // per-beat delivery, prefetch lead (max sectors banked ahead of head), and
    // ride-through of an injected fetch-latency spike.
    const long BEAT = 715909;
    long last_head = -1, max_lead = 0;
    long streaming_beats = 0, streaming_delivers = 0;
    long spike_ride = 0;                 // sectors delivered while a spike fetch is stalled
    bool spike_seen = false, spike_active_prev = false;
    long spike_ride_max = 0;
    bool dsd_d=false;

    for(long b=0;b<45;b++){
        pulse_cmd(0x0ULL);                     // DRIVE STATUS (IDLE) poll
        long beat_delivers = 0;
        for(long c=0;c<BEAT;c++){
            tick();
            long head = dut->dbg_state & 0xFFFFF;
            // spike window = the injected long-latency fetch is in flight
            bool spike_active = (spike_at_fetch>=0) && (fetch_idx==spike_at_fetch+1)
                                && dut->cd_req && lat_ctr>0;
            if(spike_active) spike_seen=true;
            // prefetch lead: how far the fetched frontier runs ahead of head
            long lead = g_max_fetch_lba - head;
            if(lead>max_lead) max_lead=lead;
            bool dsd = dut->dbg_sector_done;
            if(dsd && !dsd_d){
                deliver_secs++; beat_delivers++;
                // count deliveries that happen while a spike fetch is stalled
                if(spike_active){ spike_ride++; if(spike_ride>spike_ride_max) spike_ride_max=spike_ride; }
            }
            if(!spike_active && spike_active_prev) spike_ride=0;
            spike_active_prev=spike_active;
            dsd_d=dsd;
            last_head=head;
        }
        // count "streaming" beats = after PLAY has begun delivering
        if(((dut->dbg_state>>28)&0xF)==1 && deliver_secs>0){
            streaming_beats++; streaming_delivers += beat_delivers;
        }
    }

    int drv_status = (dut->dbg_state>>28)&0xF;
    printf("--- results ---\n");
    printf("drv_status=%d  fetch_count=%ld  deliver_secs=%ld  deliver_words=%ld\n",
           drv_status, fetch_count, deliver_secs, deliver_words);
    printf("max prefetch lead (sectors ahead of head)=%ld  last head=%ld\n", max_lead, last_head);
    printf("streaming_beats=%ld  streaming_delivers=%ld (want ~1/beat)\n",
           streaming_beats, streaming_delivers);
    if(spike_at_fetch>=0)
        printf("spike: seen=%d  ride-through sectors delivered while stalled=%ld\n",
               spike_seen, spike_ride_max);

    // ---- assertions ----
    if(drv_status != 1) err("drive not in PLAY at end");
    if(deliver_secs < 25) err("too few sectors delivered (streaming stalled?)");
    // sustained ~1 sector/beat during steady streaming
    if(streaming_delivers < streaming_beats - 2)
        err("streaming fell below ~1 sector/beat");
    // N=4 read-ahead: the bank should fill ~3 sectors ahead of the play head
    if(spike_at_fetch<0 && max_lead < 3)
        err("prefetch bank did not read >=3 sectors ahead (N=4 depth broken)");
    // spike ride-through: delivery must continue from the bank while a fetch
    // is stalled. N=4 keeps ~3 sectors banked ahead -> >=2 rides through.
    if(spike_at_fetch>=0){
        if(!spike_seen) err("spike window never observed (test mis-timed)");
        else if(spike_ride_max < 2) err("bank did not ride through the spike (>=2 expected)");
    }

    printf(fail ? "\n==== TEST FAILED ====\n" : "\n==== TEST PASSED ====\n");
    delete dut;
    return fail ? 1 : 0;
}
