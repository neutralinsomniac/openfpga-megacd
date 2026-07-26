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

static Vmegacd_cdd_drive* dut;
static vluint64_t tk = 0;

// ---- mock APF sector fetch (host) ----
// On cd_req rising, after LAT cycles assert cd_ack and record which file
// offset landed in which bank slot. A one-shot SPIKE injects a long latency.
static uint32_t slot_off[4] = {0,0,0,0};   // file byte offset held by each slot
static bool     slot_val[4] = {false,false,false,false};
static long     lat_ctr = -1;
static long     LAT_NORMAL = 40;            // ~normal fetch latency (cycles)
static long     spike_at_fetch = -1;        // fetch index to stall
static long     spike_len = 0;
static long     fetch_idx = 0;
static bool     req_d = false;

// ---- mock cd_buf: 1-cycle read latency; value encodes file byte offset ----
static uint32_t buf_addr_d = 0;

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

static void tick(){
    dut->clk = 0; dut->eval();
    // ----- drive the mock host (combinational off current outputs) -----
    bool req = dut->cd_req;
    // cd_buf read: value = file offset of that word = slot_off[slot] + word*4
    uint32_t a = dut->cd_buf_addr;            // {slot[1:0], word[9:0]}
    uint32_t slot = (a >> 10) & 3, word = a & 0x3FF;
    // present previous-cycle address' data (1-cycle latency modelled below)
    uint32_t bslot = (buf_addr_d >> 10) & 3, bword = buf_addr_d & 0x3FF;
    dut->cd_buf_q = slot_off[bslot] + bword*4;
    buf_addr_d = a;

    // fetch handshake
    if (req && !req_d){                        // new request
        lat_ctr = (fetch_idx == spike_at_fetch) ? spike_len : LAT_NORMAL;
        // record placement
        uint32_t off = dut->cd_req_offset, s = dut->cd_req_slot;
        if (off % 2352 != 0) err("cd_req_offset not sector-aligned");
        if (((off/2352) & 3) != s) err("cd_req_slot != (lba & 3)");
        slot_off[s] = off;
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
    if (datwr && !datwr_d) deliver_words++;
    datwr_d = datwr;
    bool cddawr = dut->cdc_cdda_wr;
    if (cddawr && !cddawr_d) cdda_words++;
    cddawr_d = cddawr;

    // TOC RAM model (1-cycle latency, matching altsyncram read port)
    dut->toc_q[0]=TOC[toc_addr_d][0]; dut->toc_q[1]=TOC[toc_addr_d][1]; dut->toc_q[2]=TOC[toc_addr_d][2];
    toc_addr_d = dut->toc_addr & 127;

    dut->clk = 1; dut->eval();
    tk++;
}

static void pulse_cmd(uint64_t comm){
    dut->cdd_comm = comm; dut->cdd_send = 1;
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
    dut->img_size = 3000*2352; dut->track_count=0; dut->cdda_wr_ready=1; dut->cd_fast_seek=0;
    if(getenv("FASTSEEK")) dut->cd_fast_seek=1;   // isolate: fast from t=0
    dut->disc_loading=0;
    dut->toc_q[0]=0; dut->toc_q[1]=0; dut->toc_q[2]=0; dut->cd_ack_74a=0;
    for(int i=0;i<20;i++) tick();
    dut->reset=0; dut->mcd_rst_n=1;
    for(int i=0;i<20;i++) tick();

    const long BEAT = 715909;

    // baseline: one SEEK+PLAY, left alone -> PLAY after the 11-frame base
    pulse_cmd(mk_seek(100));
    long single=-1;
    for(long b=0;b<40 && single<0;b++){
        pulse_cmd(0x0ULL);
        for(long c=0;c<BEAT;c++){ tick(); if((dut->dbg_cmds&0xF)==1){ single=b; break; } }
    }
    printf("single SEEK+PLAY      -> PLAY after %ld beats (%.0f ms)\n",
           single, single*13.3);

    // re-issued: same target, re-commanded every 2 beats for 20 beats, then
    // left alone. Measured from the FIRST command.
    pulse_cmd(mk_seek(500));
    long reissued=-1, last_cmd_beat=0;
    for(long b=0;b<60 && reissued<0;b++){
        pulse_cmd(0x0ULL);
        if(b<20 && (b%2)==0){ pulse_cmd(mk_seek(500)); last_cmd_beat=b; }
        for(long c=0;c<BEAT;c++){ tick(); if((dut->dbg_cmds&0xF)==1){ reissued=b; break; } }
    }
    printf("re-issued every 2 beats -> PLAY after %ld beats (%.0f ms), last cmd at beat %ld\n",
           reissued, reissued*13.3, last_cmd_beat);
    printf("head frozen for the whole seek; extra stall vs baseline = %ld beats (%.0f ms)\n",
           reissued-single, (reissued-single)*13.3);

    // Only meaningful while the base exceeds the re-issue interval. Under
    // FASTSEEK the base is 2 beats and we re-issue every 2, so the latency
    // legitimately drains to 0 between commands and each one re-charges it --
    // upstream's guard is likewise "no latency pending", so that is correct,
    // not the restart bug this checks for.
    if(!getenv("FASTSEEK") && reissued > single + 2)
        err("re-issued SEEK+PLAY restarts the latency base (upstream does not)");

    // CD Access Time (menu). Checked per-invocation rather than by toggling
    // mid-run, which is how the option is actually used -- it is a menu setting,
    // not something that changes between seeks. FASTSEEK=1 selects GPGX's
    // cd_latency=0 profile: base 2 and no distance term.
    //   accurate: 11 beats = 146ms   fast: 2 beats = 27ms
    if(getenv("FASTSEEK")){
        if(single > 4) err("FASTSEEK set but the seek still paid the long base");
    } else {
        if(single < 9) err("accurate mode lost the 11-frame spin-up base");
    }
    printf(fail ? "\n==== RESEEK TEST FAILED ====\n" : "\n==== RESEEK TEST PASSED ====\n");
    return fail?1:0;
}

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    dut = new Vmegacd_cdd_drive;
    bool cdda_mode=false, swap_mode=false, reseek_mode=false;
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
    }
    if(cdda_mode){ int r=cdda_test(); delete dut; return r; }
    if(swap_mode){ int r=swap_test(); delete dut; return r; }
    if(reseek_mode){ int r=reseek_test(); delete dut; return r; }

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
