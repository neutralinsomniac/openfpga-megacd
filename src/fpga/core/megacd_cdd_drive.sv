// CDD (CD-drive microcontroller) with a mounted disc image.
//
// CONTROL PLANE IS A LINE-BY-LINE PORT OF GPGX cdd.c (cdd_update/cdd_process,
// see ~/src/Genesis-Plus-GX/core/cd_hw/cdd.c). Where this file and upstream
// disagree, upstream wins unless a divergence is explicitly documented below.
// The key semantics, none of which the previous implementation had:
//
//   - The internal status is NEVER "seek". CD_SEEK (2) exists only in the
//     REPORTED status: Play/Seek commands set the report to (SEEK<<8)|0xF and
//     a pending flag; the next 75Hz tick charges the latency, parks lba on
//     the target, and sets the internal status to the pending PLAY/PAUSE.
//   - The decoder is fed on EVERY tick. PLAY delivers the sector at lba and
//     advances; every other state (latency countdown, pause, stop, TOC, END,
//     scan) re-delivers the sector under the head without advancing (data
//     track), or null-ticks the CDC (DECI + WA/PT advance, no data) for
//     audio/negative positions. GPGX's comments credit MCD-verificator CDC
//     Init and Flags Test #30 for exactly this.
//   - Latency base is 2 + 10*cd_latency (i.e. 12 accurate / 2 fast) for BOTH
//     Play and Seek, plus |dlba|*120/270000 when accurate. Re-issued seeks
//     add nothing: lba is already parked on the target, so |dlba| = 0.
//   - There is no periodic report rebuild. RS1-8 change only in command
//     responses; Get-Drive-Status refreshes them from the live position,
//     gated on latency <= 3, and the report-type memory is RS1 itself.
//   - Reset/Stop with a disc land in TOC(9) internally while the REPORTED
//     status register still shows what it last showed (zeros / STOP once) --
//     which is how upstream avoids the boot hang we once caused by
//     REPORTING 9 at reset (see git history of this file for the disasm).
//
// Documented divergences from upstream (all deliberate):
//   - Data-track re-delivery during latency/pause streams the REAL sector,
//     so the CDC latches the real header; GPGX writes HEAD=00:00:00 for
//     those ticks. Real hardware re-reads the parked sector, so ours is the
//     more faithful of the two.
//   - SCAN walks linearly through inter-track gaps at +/-30 sectors/tick;
//     GPGX jumps straight to the next track's INDEX 01. A 2s gap costs us 5
//     extra ticks; the host stops the scan on the position reports either way.
//   - No-disc REQUEST replies carry a zeroed payload (stub heritage, proven
//     boot path); GPGX fills them from its zeroed TOC, which is nearly but
//     not exactly the same bytes.
//   - The tray/insertion dance, disc_loading hold-open, and media-swap
//     detection have no upstream equivalent (the host mount flow is ours).
//
// Transport (unchanged): 4-sector prefetch bank filled over the APF
// sector-fetch handshake; sectors are streamed to the CDC as 1176 16-bit
// words (~350us), CDDA paced by the DAC FIFO instead.
module megacd_cdd_drive
(
    input             clk,
    input             reset,
    input             mcd_rst_n,
    input      [39:0] cdd_comm,
    input             cdd_send,
    output reg [39:0] cdd_stat,
    output reg        cdd_rec,
    output reg        cdd_dm,

    // disc image (clk_74a datatable value; quasi-static once mounted)
    input      [31:0] img_size,

    // sector fetch: level-held request, offset stable while held; ack is
    // clk_74a-domain and synchronized here
    output reg        cd_req,
    output reg [31:0] cd_req_offset,
    output reg  [1:0] cd_req_slot,   // which of the 4 bank slots to fill
    input             cd_ack_74a,

    // 4-sector prefetch bank read port (32-bit, 1 clk latency, byte0 [7:0]).
    // 4 slots x 1024 words: addr = {slot[1:0], word[9:0]}
    output reg [11:0] cd_buf_addr,
    input      [31:0] cd_buf_q,

    // CDC host feed: one 16-bit word per cdc_dat_wr rising edge
    output reg [15:0] cdc_data,
    output reg        cdc_dat_wr,

    // CDC null decoder tick (GPGX cdc_decoder_update(0) with no data): the
    // CDC raises DECI and advances WA/PT (when WRRQ) without receiving a
    // sector. Pulsed on ticks where nothing is streamed down the data path:
    // audio playback, and any no-data position (negative lba, virtual
    // pregap, bank miss) in a non-delivering state. Held 8 clk so the CDC's
    // 12.5MHz clock-enable domain cannot miss it.
    output reg        cdc_dec_tick,

    // CDDA feed: audio-track sectors go to the CD DAC on the same data
    // bus, paced by its FIFO backpressure
    output reg        cdc_cdda_wr,
    input             cdda_wr_ready,

    // track table from the cue parser (0 = no cue: single data track).
    // toc_q = {audio, pregap[7:0], pre01_gap[9:0], file[6:0],
    //          delta[19:0], disc_lba[19:0]}; pre01_gap = in-file INDEX 00
    // region length before INDEX 01 (region start = disc_lba - pre01)
    input      [6:0]  track_count,
    // 1 = the host is preparing a new image (a .cue was picked; its bins are
    // still being sized). Presented to the BIOS as an open tray for the whole
    // load, then closed once it drops.
    input             disc_loading,
    // GPGX config.cd_latency: 0 selects base 12 + distance term (accurate),
    // 1 selects base 2, no distance term (fast). Note cd_fast_seek=1 maps to
    // upstream cd_latency=0.
    input             cd_fast_seek,
    output reg [6:0]  toc_addr,
    input      [65:0] toc_q,
    // file holding the current track (multi-bin cue): the host reopens
    // the data slot when this changes between fetches
    output wire [6:0] cd_req_file,

    // hardware-overlay debug: {status, fetch_st, dlv_st, head[7:0]}
    output wire [31:0] dbg_state,
    output wire        dbg_sector_done,
    // audio-path diagnostics, one hex digit each:
    //   [31:28] last STATE-CHANGING command c0 (IDLE/REQUEST polls excluded),
    //           or E if playback ran into the lead-out (no command behind it)
    //   [27:24] time spent in PAUSE SO FAR, live, in units of 8 beats
    //           (~107ms), saturating at F (>= 1.6s), 0 whenever not paused
    //   [23:16] seek_cnt      -- SEEK+PLAY / SEEK+PAUSE commands
    //   [15:8]  backseek_cnt  -- of those, targets BEHIND the head
    //   [7:4]   last command c0, polls included
    //   [3:0]   drv_status (internal GPGX status; 2/SEEK never appears here)
    output wire [31:0] dbg_cmds,
    // position/reporting diagnostics:
    //   [31:28] n1 (RS1) -- the live report type (F = busy/seeking)
    //   [27]    cur_audio    [26] in_pregap
    //   [25:20] cur_track
    //   [19:0]  target LBA of the last SEEK+PLAY / SEEK+PAUSE
    output wire [31:0] dbg_pos,
    // sector-integrity diagnostics:
    //   [31:24] data sectors delivered whose 12-byte MODE1 sync was WRONG
    //   [23:4]  LBA of the first such sector
    //   [3]     cur_audio      [2] in_pregap
    output wire [31:0] dbg_integ
);

// GPGX cdd.h status values (CD_SEEK is report-only, never stored)
localparam [3:0] STAT_STOP    = 4'h0;
localparam [3:0] STAT_PLAY    = 4'h1;
localparam [3:0] STAT_SEEK    = 4'h2;
localparam [3:0] STAT_SCAN    = 4'h3;
localparam [3:0] STAT_PAUSE   = 4'h4;
localparam [3:0] STAT_OPEN    = 4'h5;
localparam [3:0] STAT_TOC     = 4'h9;   // TOC read done = "disc ready"
localparam [3:0] STAT_NO_DISC = 4'hB;
localparam [3:0] STAT_END     = 4'hC;   // lead-out reached (GPGX CD_END)

// ONE tick. GPGX runs cdd_update at exactly 75Hz on the same event that
// raises INT4, and the whole protocol above assumes that single phase; the
// old ms_tick/owe_inc phase-sweep machinery existed to patch protocol
// deficiencies (stale position reports, no decoder feed during latency)
// that the port removes at the source. If boot regresses on hardware, debug
// it in the co-sim -- it boots the sub now -- instead of re-growing sweeps.
localparam [25:0] BEAT = 26'd715909;      // 13.3ms @ 53.693175MHz

wire disc_present = (img_size >= 32'd2352);
wire [31:0] leadout_lba = img_lba;        // computed at mount

reg  [3:0] drv_status /*verilator public_flat_rd*/ = STAT_NO_DISC; // cdd.status
reg  [3:0] pending = 0;                   // cdd.pending (0 = none)
reg  [7:0] latency = 0;                   // cdd.latency, in 75Hz frames
reg [31:0] head /*verilator public_flat_rd*/ = 0;  // cdd.lba (signed)
reg [31:0] pend_lba = 0;                  // target latched with a Play/Seek
reg        scan_rev = 0;                  // cdd.scanOffset sign
// GPGX: #define CD_SCAN_SPEED 30; cdd.lba += scanOffset each update
localparam [7:0] SCAN_STEP = 8'd30;

reg  [3:0] n0, n1, n2, n3, n4, n5, n6, n7, n8;   // RS0..RS8 (persistent)
wire [3:0] csum = ~(n0 + n1 + n2 + n3 + n4 + n5 + n6 + n7 + n8) & 4'hF;

reg        door /*verilator public_flat_rd*/ = 0;
reg  [5:0] ins_cnt = 0;   // insertion tray-open pulse, in beats
reg [25:0] wdog = 0;
reg        send_d = 0;
reg  [3:0] rec_cnt = 0;

// GPGX latency model: base 2 + 10*cd_latency for Play AND Seek, plus
// |dlba|*120/270000 (== /2250) when accurate. SEEK_CAP is only an 8-bit
// overflow guard (upstream is uncapped, bounded by disc size).
localparam [12:0] SEEK_MULT   = 13'd7457; // 7457/2^24 ~= 1/2250
localparam [4:0]  SEEK_RSHIFT = 5'd24;
localparam [7:0]  SEEK_CAP    = 8'd200;

// instrumentation: last CDD command word + counters (sim log + hw overlay)
reg [39:0] dbg_last_comm /*verilator public_flat_rd*/ = 0;
reg  [7:0] dbg_seek_cnt  /*verilator public_flat_rd*/ = 0;  // SEEK cmds
reg  [7:0] dbg_backseek_cnt /*verilator public_flat_rd*/ = 0; // backward SEEKs
reg  [3:0] dbg_last_c0   = 0;
reg  [3:0] dbg_last_real_c0 /*verilator public_flat_rd*/ = 4'hF;
reg  [6:0] dbg_pause_run /*verilator public_flat_rd*/ = 0;
assign dbg_cmds = {dbg_last_real_c0, dbg_pause_run[6:3],
                   dbg_seek_cnt, dbg_backseek_cnt,
                   dbg_last_c0, drv_status};
reg [19:0] dbg_seek_lba /*verilator public_flat_rd*/ = 0;  // last SEEK target

///////////////////////////////////////////////
// current-track tracker: linear search of the TOC whenever the head
// moves (idle whenever the report builder owns the TOC port). With no
// cue (track_count==0) the disc is one data track.
///////////////////////////////////////////////
reg  [6:0] cur_track = 1;
reg        cur_audio /*verilator public_flat_rd*/ = 0;
reg [19:0] cur_delta = 0;     // disc->file offset for the current track
reg  [6:0] cur_file = 0;      // which bin holds the current track
reg [19:0] cur_start = 0;     // current track's disc start (INDEX 01)
reg [19:0] pgap_lo = 20'hFFFFF, pgap_hi = 20'hFFFFF; // next track's
                              // virtual-pregap window [lo, hi)
reg [31:0] srch_head = 32'hFFFFFFFF;
reg  [6:0] srch_t;
reg  [2:0] srch_st = 0;
reg [65:0] srch_next;         // entry of track t+1, latched at loop end
reg        srch_has_next;
reg  [6:0] rpt_toc_addr;
reg        rpt_toc_use = 0;   // report builder owns the TOC port
wire [6:0] srch_toc_addr;
assign srch_toc_addr = (srch_st == 3'd4) ? srch_t : (srch_t + 7'd1);
always @* toc_addr = rpt_toc_use ? rpt_toc_addr : srch_toc_addr;
assign cd_req_file = cur_file;

// sector is inside the NEXT track's virtual pregap: silence, not file data
wire in_pregap = !head[31] && (head[19:0] >= pgap_lo) && (head[19:0] < pgap_hi)
                 && (head[31:20] == 12'd0);
assign dbg_pos = {n1, cur_audio, in_pregap, cur_track[5:0], dbg_seek_lba};
assign dbg_integ = {dbg_badsync_cnt, dbg_badsync_lba, cur_audio, in_pregap, 2'b00};
// disc LBA -> file LBA for fetch/delivery
wire [31:0] head_file = head - {12'd0, cur_delta};

// Constant divide/modulo by 10, by reciprocal multiply: (v*205)>>11 == v/10
// exactly for v <= 1023. Quartus infers a full lpm_divide per `/`/`%`
// otherwise (~275 ALMs across this file at 99% utilization).
function [7:0] div10;
    input [7:0] v;
    reg [15:0] p;
    begin
        p     = v * 16'd205;
        div10 = {3'd0, p[15:11]};
    end
endfunction

function [7:0] mod10;
    input [7:0] v;
    reg [7:0] q;
    begin
        q     = div10(v);
        mod10 = v - {q[4:0], 3'd0} - {q[6:0], 1'd0};   // v - q*10
    end
endfunction

wire [3:0] curtrk_bcd10 = div10(cur_track);
wire [3:0] curtrk_bcd1  = mod10(cur_track);
wire [3:0] last_bcd10   = (track_count==0) ? 4'd0 : div10(track_count);
wire [3:0] last_bcd1    = (track_count==0) ? 4'd1 : mod10(track_count);

// command nibbles
wire [3:0] c0 = cdd_comm[3:0],   c1 = cdd_comm[7:4],   c2 = cdd_comm[11:8];
wire [3:0] c3 = cdd_comm[15:12], c4 = cdd_comm[19:16], c5 = cdd_comm[23:20];
wire [3:0] c6 = cdd_comm[27:24], c7 = cdd_comm[31:28];

// seek target from BCD MSF nibbles (c2..c7), minus the 150-sector pregap
wire [7:0]  m_bcd_in = c2*4'd10 + c3;
wire [7:0]  s_bcd_in = c4*4'd10 + c5;
wire [7:0]  f_bcd_in = c6*4'd10 + c7;
wire [31:0] comm_lba = m_bcd_in*32'd4500 + s_bcd_in*32'd75 + f_bcd_in - 32'd150;

// --- seek-latency pipeline -------------------------------------------------
// |pend_lba - head| * 7457 >> 24 (== GPGX |dlba|*120/270000), capped to 8
// bits. As a single combinational cone this failed setup on the 107MHz clock
// (TNS -358, the boot-corruption regression), so it free-runs in stages;
// both inputs are stable thousands of clk before the tick that consumes the
// result. Distance is measured from the LIVE head, exactly like upstream
// measuring from cdd.lba at apply time: after the first apply parks the head
// on the target, a re-issued identical seek measures |dlba| = 0 and adds
// nothing (the old compounding-latency bug cannot exist in this shape).
reg  [31:0] pend_lba_r   = 0;
reg  [31:0] head_r       = 0;
reg  [31:0] seek_dist_r  = 0;
reg  [31:0] seek_dterm_r = 0;
reg   [7:0] dterm_cap_r  = 0;
wire signed [31:0] seek_diff = $signed(pend_lba_r) - $signed(head_r);
wire [31:0] seek_dist   = seek_diff[31] ? (~seek_diff + 32'd1) : seek_diff;
wire [44:0] seek_scaled = seek_dist_r * SEEK_MULT;
wire [31:0] seek_dterm  = seek_scaled >> SEEK_RSHIFT;
wire  [7:0] lat_base_cfg = cd_fast_seek ? 8'd2 : 8'd12;  // 2 + 10*cd_latency

task zeros; begin
    n2 <= 0; n3 <= 0; n4 <= 0; n5 <= 0; n6 <= 0; n7 <= 0; n8 <= 0;
end endtask

///////////////////////////////////////////////
// mount: image size / 2352 -> leadout LBA (sequential divider, runs once
// whenever img_size changes)
///////////////////////////////////////////////
reg [31:0] img_size_d = 0;
reg [31:0] img_lba = 0;
reg [31:0] div_rem = 0;
reg [31:0] div_q = 0;
reg  [5:0] div_bit = 0;
reg        div_run = 0;
always @(posedge clk) begin
    img_size_d <= img_size;
    if (img_size != img_size_d) begin
        div_rem <= 0; div_q <= 0; div_bit <= 6'd32; div_run <= 1;
    end else if (div_run) begin
        if (div_bit == 0) begin
            img_lba <= div_q;
            div_run <= 0;
        end else begin : divstep
            reg [31:0] r;
            r = {div_rem[30:0], img_size[div_bit-1]};
            if (r >= 32'd2352) begin
                div_rem <= r - 32'd2352;
                div_q   <= {div_q[30:0], 1'b1};
            end else begin
                div_rem <= r;
                div_q   <= {div_q[30:0], 1'b0};
            end
            div_bit <= div_bit - 1'b1;
        end
    end
end

///////////////////////////////////////////////
// LBA -> BCD MSF converter (sequential; ~200 cycles worst case)
// start: msf_start with msf_lba; done: msf_done, digits in msf_*
///////////////////////////////////////////////
reg        msf_start = 0;
reg [31:0] msf_lba = 0;
reg        msf_done = 0;
reg  [3:0] msf_m10, msf_m1, msf_s10, msf_s1, msf_f10, msf_f1;
reg  [1:0] msf_st = 0;
reg [31:0] msf_acc;
reg  [7:0] msf_m, msf_s, msf_f;
always @(posedge clk) begin
    msf_done <= 0;
    case (msf_st)
    2'd0: if (msf_start) begin
        msf_acc <= msf_lba;
        msf_m <= 0; msf_s <= 0;
        msf_st <= 2'd1;
    end
    2'd1: begin // minutes
        if (msf_acc >= 32'd4500) begin
            msf_acc <= msf_acc - 32'd4500;
            msf_m <= msf_m + 1'b1;
        end else msf_st <= 2'd2;
    end
    2'd2: begin // seconds
        if (msf_acc >= 32'd75) begin
            msf_acc <= msf_acc - 32'd75;
            msf_s <= msf_s + 1'b1;
        end else begin
            msf_f <= msf_acc[7:0];
            msf_st <= 2'd3;
        end
    end
    2'd3: begin // BCD split
        msf_m10 <= div10(msf_m); msf_m1 <= mod10(msf_m);
        msf_s10 <= div10(msf_s); msf_s1 <= mod10(msf_s);
        msf_f10 <= div10(msf_f); msf_f1 <= mod10(msf_f);
        msf_done <= 1;
        msf_st <= 2'd0;
    end
    endcase
end

///////////////////////////////////////////////
// current-track search (runs when the head moves and the report builder
// is not using the TOC port)
///////////////////////////////////////////////
always @(posedge clk) begin
    if (reset | ~mcd_rst_n) begin
        srch_st <= 0;
        cur_track <= 1;
        cur_audio <= 0;
        srch_head <= 32'hFFFFFFFF;
    end else if (rpt_toc_use) begin
        if (srch_st != 0) begin
            srch_st <= 0;
            srch_head <= 32'hFFFFFFFF;   // retry once the port is free
        end
    end else case (srch_st)
    3'd0: begin
        if (track_count == 0) begin
            cur_track <= 1; cur_audio <= 0; cur_delta <= 0; cur_start <= 0;
            cur_file <= 0;
            pgap_lo <= 20'hFFFFF; pgap_hi <= 20'hFFFFF;
        end else if (head != srch_head) begin
            srch_head <= head;
            srch_t <= 7'd1;
            srch_st <= 3'd1;
        end
    end
    3'd1: srch_st <= 3'd2;               // toc_q latency for entry srch_t+1
    3'd2: begin
        if (!srch_head[31] && srch_t < track_count &&
            srch_head >= {12'd0, toc_q[19:0] - {10'd0, toc_q[56:47]}}) begin
            srch_t <= srch_t + 1'b1;
            srch_st <= 3'd1;
        end else begin
            srch_next <= toc_q;           // entry t+1 (valid if has_next)
            srch_has_next <= (srch_t < track_count) && !srch_head[31];
            srch_st <= 3'd4;              // fetch srch_t's own entry
        end
    end
    3'd4: srch_st <= 3'd5;
    3'd5: begin
        cur_track <= srch_t;
        cur_audio <= toc_q[65];
        cur_delta <= toc_q[39:20];
        cur_file  <= toc_q[46:40];
        cur_start <= toc_q[19:0];
        if (srch_has_next) begin
            // next track's virtual pregap window sits just before its
            // in-file INDEX 00 region
            pgap_lo <= (srch_next[19:0] - {10'd0, srch_next[56:47]})
                       - {12'd0, srch_next[64:57]};
            pgap_hi <= srch_next[19:0] - {10'd0, srch_next[56:47]};
        end else begin
            pgap_lo <= 20'hFFFFF; pgap_hi <= 20'hFFFFF;
        end
        srch_st <= 3'd0;
    end
    default: srch_st <= 3'd0;
    endcase
end

///////////////////////////////////////////////
// sector fetch engine: keep a 4-sector bank holding head_file .. head_file+3
// (slot = file_lba[1:0]). The extra read-ahead depth rides out SD read-latency
// spikes during continuous CDDA (delivery still meters to the DAC at 1x; the
// bank just buffers ahead). Deep look-ahead (k>=2) is confined to clean
// mid-track streaming so every banked sector shares the current cur_delta.
//
// GPGX-port note: because the head parks on the target the moment a seek is
// applied, this engine starts prefetching the TARGET during the seek latency
// -- the read-ahead a real drive's own buffer does -- so when PLAY delivery
// begins the bank is already warm.
///////////////////////////////////////////////
// buf_lba is the FILE LBA held in each slot (21 bits: a CD never reaches
// 2^20 sectors, and narrow comparators matter at ~98% ALM).
reg [20:0] buf_lba [0:3];
reg  [3:0] buf_valid = 0;
reg  [6:0] buf_file = 0;   // which bin the bank currently holds (see below)
reg  [1:0] cdack_s = 0;
reg  [1:0] fetch_st = 0;
reg [31:0] fetch_lba;
// cur_track/cur_delta/cur_file describe srch_head, which is NOT necessarily
// the current head: the track search takes ~6 clk to walk the TOC. Fetching
// in that window would use a stale delta/file. With no cue there is a single
// track and the registers are always valid.
wire       toc_settled = (track_count == 7'd0) ||
                         ((srch_st == 3'd0) && (srch_head == head));
// every state except the trays wants the bank warm: PLAY consumes it, and
// all other states re-deliver the sector under the head each tick
wire       fetch_wanted = disc_present && toc_settled &&
                          (drv_status != STAT_OPEN) &&
                          (drv_status != STAT_NO_DISC);
// LBAs are signed: seeks into the track-1 pregap (down to -150) are part
// of the BIOS boot flow. Negative and virtual-pregap sectors are never
// fetched from the file; all real fetches use FILE LBAs (disc - delta).
wire [31:0] hf0 = head_file;
wire [31:0] hf1 = head_file + 32'd1;
wire [31:0] hf2 = head_file + 32'd2;
wire [31:0] hf3 = head_file + 32'd3;
wire       head_banked = buf_valid[hf0[1:0]] && buf_lba[hf0[1:0]] == hf0[20:0];
wire       want_head = !head[31] && !in_pregap && !head_banked;
wire       want_next = !hf1[31] && !in_pregap &&
                       !(buf_valid[hf1[1:0]] && buf_lba[hf1[1:0]] == hf1[20:0]);
// deep look-ahead only when head is positive, not in a pregap window, and the
// whole [head, head+3] window sits before the next track's pregap start (so
// cur_delta is valid for hf2/hf3). Near a boundary this falls back to head+1.
wire       deep_ok   = !head[31] && !in_pregap && (head[31:20] == 12'd0) &&
                       ((head[19:0] + 20'd4) < pgap_lo);
wire       want_d2   = deep_ok &&
                       !(buf_valid[hf2[1:0]] && buf_lba[hf2[1:0]] == hf2[20:0]);
wire       want_d3   = deep_ok &&
                       !(buf_valid[hf3[1:0]] && buf_lba[hf3[1:0]] == hf3[20:0]);
wire       any_want  = want_head || want_next || want_d2 || want_d3;
// nearest-to-head wanted sector wins (keeps head itself highest priority)
wire [31:0] fetch_pick = want_head ? hf0 : want_next ? hf1 : want_d2 ? hf2 : hf3;
always @(posedge clk) begin
    cdack_s <= {cdack_s[0], cd_ack_74a};
    if (reset | ~mcd_rst_n) begin
        cd_req <= 0;
        fetch_st <= 0;
        buf_valid <= 0;
        buf_file <= 0;
    end else begin
        case (fetch_st)
        2'd0: if (fetch_wanted && any_want) begin
            fetch_lba <= fetch_pick;
            fetch_st  <= 2'd1;
        end
        2'd1: begin
            // offset = lba * 2352 (2048 + 256 + 32 + 16)
            cd_req_offset <= (fetch_lba << 11) + (fetch_lba << 8) +
                             (fetch_lba << 5)  + (fetch_lba << 4);
            cd_req_slot   <= fetch_lba[1:0];
            buf_valid[fetch_lba[1:0]] <= 0;
            cd_req <= 1;
            fetch_st <= 2'd2;
        end
        2'd2: if (cdack_s[1]) begin
            cd_req <= 0;
            buf_lba[fetch_lba[1:0]]   <= fetch_lba[20:0];
            buf_valid[fetch_lba[1:0]] <= 1;
            fetch_st <= 2'd3;
        end
        2'd3: if (!cdack_s[1]) fetch_st <= 2'd0;
        endcase
        // BANK IS TAGGED BY FILE LBA ONLY, so it must be dropped whenever the
        // current bin changes: every bin of a multi-bin cue restarts at file
        // LBA 0, so slot tags collide across files and a stale entry from one
        // bin reads as a hit for another -- silent wrong-bin data (2 sectors
        // in 5 in the tb_drive --binswap repro).
        if (cur_file != buf_file) begin
            buf_file  <= cur_file;
            buf_valid <= 0;
        end
    end
end

///////////////////////////////////////////////
// sector delivery: stream 1176 words to the CDC (16 clks per word: 8 high,
// 8 low = ~350us per sector) or to the CDDA DAC (FIFO-paced, ~13ms).
// dlv_hold marks a re-delivery of the sector under a parked head (latency /
// pause / any non-PLAY state): it feeds the decoder but must not advance.
///////////////////////////////////////////////
reg  [1:0] dlv_st = 0;
reg [10:0] dlv_w;       // word index 0..1175
reg  [3:0] dlv_ph;
reg  [1:0] dlv_slot;    // bank slot (file_lba[1:0]) latched at delivery start
reg        dlv_neg;     // pregap sector: synthesize sync+header, zero payload
// sectors owed to the delivery FSM: +1 per PLAY tick, -1 per delivered
// sector. A COUNTER, not a level flag, so a tick landing on the same clock
// as a completion is never lost, and CDDA backpressure stalls can burst-
// catch-up afterwards. Hold ticks never stack (one re-delivery at a time).
reg  [3:0] dlv_owed = 0;
reg        dlv_hold_req = 0;   // this tick's owed delivery is a hold
reg        dlv_hold;           // latched per delivery
reg        dlv_advance /*verilator public_flat_rd*/ = 0;
// seek-apply generation stamp: a delivery that started before a pending seek
// was applied must not advance the freshly parked head when it completes
reg        apply_tog = 0;
reg        dlv_stamp;
// pregap header MSF digits (valid for head in -150..-1): abs = head+150
wire [7:0] pre_v   = head[7:0] + 8'd150;
wire       pre_s   = (pre_v >= 8'd75);
wire [6:0] pre_f   = pre_s ? (pre_v - 8'd75) : pre_v[6:0];
wire [3:0] pre_f10 = div10(pre_f);
wire [3:0] pre_f1  = mod10(pre_f);
reg [15:0] dlv_synth;
always @* begin
    case (dlv_w)
    11'd0:   dlv_synth = 16'hFF00;                        // sync 00 FF..
    11'd1, 11'd2, 11'd3, 11'd4: dlv_synth = 16'hFFFF;     // ..FF FF..
    11'd5:   dlv_synth = 16'h00FF;                        // ..FF 00
    11'd6:   dlv_synth = {7'd0, pre_s, 8'h00};            // {ss BCD, mm=00}
    11'd7:   dlv_synth = {8'h01, pre_f10, pre_f1};        // {mode 1, ff BCD}
    default: dlv_synth = 16'h0000;
    endcase
end
reg dlv_badsync;             // this sector failed the sync check
reg  [7:0] dbg_badsync_cnt /*verilator public_flat_rd*/ = 0;  // saturating
reg [19:0] dbg_badsync_lba /*verilator public_flat_rd*/ = 0;  // first bad one
reg        dbg_badsync_seen = 0;
reg dlv_aud;    // audio sector: route to the CDDA DAC, pace on its FIFO
reg dlv_pgap;   // virtual-pregap sector: deliver silence
always @(posedge clk) begin
    dlv_advance <= 0;
    if (reset | ~mcd_rst_n) begin
        dlv_st <= 0;
        cdc_dat_wr <= 0;
        cdc_cdda_wr <= 0;
        dlv_badsync <= 0;
        dbg_badsync_cnt <= 0;
        dbg_badsync_seen <= 0;
    end else case (dlv_st)
    2'd0: if (dlv_owed != 0 && (head[31] || !want_head)) begin
        dlv_w  <= 0;
        dlv_slot <= head_file[1:0];
        dlv_neg  <= head[31];
        dlv_pgap <= in_pregap && !head[31];   // virtual pregap: silence
        dlv_aud  <= (cur_audio || in_pregap) && !head[31];
        dlv_hold <= dlv_hold_req;
        dlv_stamp <= apply_tog;
        dlv_badsync <= 0;
        dlv_st <= 2'd1;
    end
    2'd1: begin // present address, wait RAM latency
        cd_buf_addr <= {dlv_slot, dlv_w[10:1]};
        dlv_ph <= 0;
        dlv_st <= 2'd2;
    end
    2'd2: begin // latch word, pulse wr 8 high / 8 low
        if (dlv_ph == 2 && dlv_aud && !cdda_wr_ready) begin
            // stall until the CDDA FIFO can take another word
        end else begin
            dlv_ph <= dlv_ph + 1'b1;
            if (dlv_ph == 1) cdc_data <= dlv_pgap ? 16'h0000 :
                                         dlv_neg  ? dlv_synth :
                                         dlv_w[0] ? cd_buf_q[31:16] : cd_buf_q[15:0];
            if (dlv_ph == 2) begin
                if (dlv_aud) cdc_cdda_wr <= 1;
                else         cdc_dat_wr <= 1;
                // SYNC CHECK (instrumentation): every MODE1/2352 sector opens
                // with 00 FF*10 00 == dlv_synth words 0..5. A mismatch means
                // this is not a data sector at all (wrong bin / wrong offset /
                // audio routed down the data path).
                if (!dlv_aud && !dlv_pgap && !dlv_neg && dlv_w <= 11'd5
                    && cdc_data != dlv_synth)
                    dlv_badsync <= 1;
            end
            if (dlv_ph == 10) begin cdc_dat_wr <= 0; cdc_cdda_wr <= 0; end
            if (dlv_ph == 15) begin
                if (dlv_w == 11'd1175) begin
                    dlv_advance <= 1;   // sector fully delivered
                    if (dlv_badsync) begin
                        if (dbg_badsync_cnt != 8'hFF)
                            dbg_badsync_cnt <= dbg_badsync_cnt + 1'b1;
                        if (!dbg_badsync_seen) begin
                            dbg_badsync_seen <= 1;
                            dbg_badsync_lba  <= head[19:0];
                        end
                    end
                    dlv_st <= 2'd3;
                end else begin
                    dlv_w  <= dlv_w + 1'b1;
                    dlv_st <= 2'd1;
                end
            end
        end
    end
    // one-cycle drain: hold here while dlv_advance propagates so the main
    // block advances head and decrements dlv_owed before state 0 re-arms
    2'd3: dlv_st <= 2'd0;
    default: dlv_st <= 0;
    endcase
end

// hex readout: digit0=drv_status digit1={fetch_st,dlv_st}
// digit2={cd_req,buf_valid,owed!=0} digits3-7=head LBA
assign dbg_state = {drv_status, fetch_st, dlv_st,
                    cd_req, buf_valid[1:0], (dlv_owed != 0), head[19:0]};
assign dbg_sector_done = dlv_advance;

///////////////////////////////////////////////
// report builder (command-triggered ONLY, per GPGX: there is no periodic
// payload rebuild; Get-Drive-Status and REQUEST update RS1-8 when processed)
///////////////////////////////////////////////
localparam [3:0] K_NONE=0, K_ABS=1, K_REL=2, K_TRK_REQ=3, K_TRK_STAT=4,
                 K_LEADOUT=5, K_FIRSTLAST=6, K_TRKSTART=7, K_ERRINFO=8;
reg  [3:0] rpt_kind = K_NONE;
reg  [2:0] rpt_st = 0;
reg  [6:0] rpt_track = 1;     // REQUEST 5 argument
reg        rpt_trk_audio = 0;
// REQUEST 5 track number from the command's c4/c5 BCD digits
wire [6:0] req_track = {3'd0,c4}*7'd10 + {3'd0,c5};

// the decoder-feed decision for this tick (combinational at the tick):
// stream the sector under the head down the data path when it is a real,
// banked data sector; otherwise pulse the CDC null tick. PLAY audio streams
// to the DAC and null-ticks the CDC, per upstream's "audio blocks are still
// sent to CDC as well".
wire tick_data_ok = disc_present && toc_settled && !head[31] && !in_pregap &&
                    !cur_audio && head_banked;
reg  [3:0] dec_tick_hold = 0;   // 8-clk stretcher for cdc_dec_tick

always @(posedge clk) begin
    if (reset | ~mcd_rst_n) begin
        // GPGX cdd_reset(): lba = 0, latency = 0, pending = 0, and the
        // INTERNAL status is TOC with a disc / NO_DISC without one. What the
        // host SEES at reset is the zeroed status register file (upstream
        // memsets scd.regs), i.e. it reads STOP until its first command gets
        // answered -- coming up 9 internally is safe precisely because it is
        // not REPORTED unsolicited. (Reporting 9 at reset is the historic
        // BIOS boot hang; see git history for the jump-table disasm.)
        drv_status <= disc_present ? STAT_TOC : STAT_NO_DISC;
        pending  <= 0;
        latency  <= 0;
        head     <= 0;
        pend_lba <= 0;
        scan_rev <= 0;
        n0 <= 0; n1 <= 0;
        n2 <= 0; n3 <= 0; n4 <= 0; n5 <= 0; n6 <= 0; n7 <= 0; n8 <= 0;
        cdd_stat <= {4'hF, 36'h0};
        // GPGX memsets the reg file at reset, so the audio flag comes up 0
        // ("audio playing"), odd as that reads; the old proven boot path
        // also reset it to 0. First PLAY/command tick sets it properly.
        cdd_dm   <= 1'b0;
        cdd_rec  <= 0;
        cdc_dec_tick <= 0;
        dec_tick_hold <= 0;
        wdog     <= 0;
        rec_cnt  <= 0;
        send_d   <= 0;
        door     <= 0;
        ins_cnt  <= 0;
        apply_tog <= 0;
        dlv_hold_req <= 0;
        pend_lba_r <= 0; head_r <= 0; seek_dist_r <= 0; seek_dterm_r <= 0;
        dterm_cap_r <= 0;
        rpt_kind <= K_NONE;
        rpt_st   <= 0;
        rpt_track <= 7'd1;
        rpt_toc_use <= 0;
        msf_start <= 0;
        dlv_owed <= 0;
    end else begin : main
        // effective latency after this tick's decrement, GPGX sequential
        // semantics (the pending block sees the already-decremented value)
        reg [7:0] lat_after;
        reg       tick_streamed;   // a data sector was queued this tick

        send_d <= cdd_send;
        wdog   <= wdog + 1'b1;
        msf_start <= 0;

        // seek-latency pipeline advance (free-running; see the wire block)
        pend_lba_r   <= pend_lba;
        head_r       <= head;
        seek_dist_r  <= seek_dist;
        seek_dterm_r <= seek_dterm;
        dterm_cap_r  <= (seek_dterm_r > {24'd0, SEEK_CAP})
                        ? SEEK_CAP : seek_dterm_r[7:0];

        // null-tick stretcher
        if (dec_tick_hold != 0) begin
            dec_tick_hold <= dec_tick_hold - 1'b1;
            cdc_dec_tick  <= 1;
        end else cdc_dec_tick <= 0;

        // sectors owed to the delivery FSM (single assignment so a tick and
        // a completion on the same clock cannot cancel each other out)
        dlv_owed <= dlv_owed
                  + (((wdog == BEAT) && owe_this_tick && dlv_owed != 4'hF) ? 4'd1 : 4'd0)
                  - ((dlv_advance && dlv_owed != 4'd0) ? 4'd1 : 4'd0);

        // sector delivered: advance the head. Only PLAY deliveries advance
        // (dlv_hold marks re-deliveries), and never across a seek apply.
        if (dlv_advance && !dlv_hold && dlv_stamp == apply_tog &&
            drv_status == STAT_PLAY && !(|latency)) begin
            head <= head + 1'b1;
        end

        ///////////////////////////////////////////////////////////////////
        // THE 75Hz TICK -- a line-by-line port of GPGX cdd_update()
        ///////////////////////////////////////////////////////////////////
        if (wdog == BEAT) begin : tick
            lat_after = latency;
            tick_streamed = 0;
            dlv_hold_req <= 0;

            if (latency != 0) begin
                // drive latency: count down, decoder keeps running
                // ("fixes MCD-verificator CDC Init")
                lat_after = latency - 1'b1;
                if (tick_data_ok) begin
                    dlv_hold_req <= 1; tick_streamed = 1;
                end
            end else if (drv_status == STAT_PLAY) begin
                if (!head[31] && head >= leadout_lba) begin
                    // end of disc detection
                    drv_status <= STAT_END;
                    dbg_last_real_c0 <= 4'hE;   // no command behind this one
                end else begin
                    // deliver the sector at lba and advance (advance happens
                    // at stream completion, see dlv_advance above)
                    tick_streamed = 1;   // queue below whether data or CDDA
                    // GPGX audio-flag semantics: 0x36 goes low only once an
                    // audio track is past its INDEX 01; the inter-track gap
                    // and all data sectors report "no audio playing"
                    if (cur_audio && !in_pregap && !head[31] &&
                        (head[31:20] == 12'd0) && (head[19:0] >= cur_start))
                         cdd_dm <= 1'b0;
                    else cdd_dm <= 1'b1;
                end
            end else begin
                // decoder still running while the disc is not being read
                // ("fixes MCD-verificator CDC Flags Test #30")
                if (tick_data_ok) begin
                    dlv_hold_req <= 1; tick_streamed = 1;
                end
                // scanning disc
                if (drv_status == STAT_SCAN && disc_present) begin
                    if (!scan_rev) begin
                        if (head + {24'd0, SCAN_STEP} >= leadout_lba) begin
                            head <= leadout_lba;      // end of disc
                            drv_status <= STAT_END;
                            cdd_dm     <= 1'b1;
                        end else head <= head + {24'd0, SCAN_STEP};
                    end else begin
                        if ($signed(head) <= $signed({24'd0, SCAN_STEP})) begin
                            head <= 0;                // start of first track
                        end else head <= head - {24'd0, SCAN_STEP};
                    end
                    // (GPGX skips inter-track gaps to the next INDEX 01; we
                    // walk them linearly at the same 30/tick -- documented)
                    cdd_dm <= !(cur_audio && !in_pregap && !head[31] &&
                                (head[31:20] == 12'd0) &&
                                (head[19:0] >= cur_start));
                end
            end

            // check if a seek/play command is pending (LAST, sequentially
            // after the latency decrement, exactly like upstream)
            if (pending != 0) begin
                // if (!cdd.latency) cdd.latency = 2 + 10*config.cd_latency;
                // cdd.latency += |dlba| * 120 / 270000  (accurate only)
                if (lat_after == 0) begin
                    lat_after = lat_base_cfg;
                end
                if (!cd_fast_seek) begin
                    lat_after = ({1'b0, lat_after} + {1'b0, dterm_cap_r} >
                                 {1'b0, SEEK_CAP})
                                ? SEEK_CAP : lat_after + dterm_cap_r;
                end
                head       <= pend_lba;    // cdd.lba = lba (park on target)
                apply_tog  <= ~apply_tog;  // cancel in-flight head advances
                cdd_dm     <= 1'b1;        // no audio track playing (yet)
                drv_status <= pending;     // status = pending end status
                pending    <= 0;
            end
            latency <= lat_after;

            // decoder feed for this tick: anything that did not queue a data
            // stream gets the CDC null tick (audio, pregap, bank miss, no
            // disc with DECEN armed -- the CDC gates on DECEN internally)
            if (!tick_streamed || (drv_status == STAT_PLAY && latency == 0 &&
                                   pending == 0 && (cur_audio || in_pregap)))
                dec_tick_hold <= 4'd8;

            // ---- host-integration housekeeping (no upstream equivalent) --
            // MEDIA GONE: img_size drops to 0 whenever the mount FSM starts
            // over (including a new .cue pick) and stays 0 until the new TOC
            // is final. Retire to NO_DISC so the insertion dance below runs
            // for the new image. Skipped while door=1 (host commanded).
            if (!disc_present && !door && !disc_loading &&
                drv_status != STAT_NO_DISC) begin
                drv_status <= STAT_NO_DISC;
                ins_cnt    <= 0;
            end
            // disc inserted mid-session: tray OPEN ~0.5s then closed-with-
            // media, landing in TOC(9). (Present-at-boot / post-MCD-reset are
            // handled by the reset block coming up TOC directly -- this path
            // is too slow to survive the BIOS's reset pulsing.)
            if (drv_status == STAT_NO_DISC && disc_present && !door) begin
                drv_status <= STAT_OPEN;
                ins_cnt <= 6'd38;
            end
            if (drv_status == STAT_OPEN && ins_cnt != 0) begin
                ins_cnt <= ins_cnt - 1'b1;
                // land in TOC(9): a real drive reads the TOC by itself after
                // a close, and the BIOS idle screen polls for 9
                if (ins_cnt == 6'd1) drv_status <= STAT_TOC;
            end
            // LOADING: hold the tray open while the host prepares the image
            if (disc_loading && !door) begin
                drv_status <= STAT_OPEN;
                ins_cnt    <= 0;
            end
            // LOADING DONE: close the tray (normal dance with media; plain
            // NO_DISC if the mount failed)
            if (!disc_loading && !door && drv_status == STAT_OPEN &&
                ins_cnt == 0) begin
                if (disc_present) ins_cnt <= 6'd38;
                else drv_status <= STAT_NO_DISC;
            end
            // PAUSE dwell meter (instrumentation)
            if (drv_status == STAT_PAUSE) begin
                if (dbg_pause_run != 7'd127) dbg_pause_run <= dbg_pause_run + 1'b1;
            end else dbg_pause_run <= 0;
        end

        ///////////////////////////////////////////////////////////////////
        // report payload builder (runs for a few us after a command)
        ///////////////////////////////////////////////////////////////////
        case (rpt_st)
        3'd1: begin
            case (rpt_kind)
            K_ABS: begin
                msf_lba <= head + 32'd150; msf_start <= 1; rpt_st <= 3'd2;
            end
            K_REL: begin   // abs(lba - track start)
                msf_lba <= head[31] ? (~head + 1'b1)
                          : (head >= {12'd0, cur_start})
                            ? (head - {12'd0, cur_start})
                            : ({12'd0, cur_start} - head);
                msf_start <= 1; rpt_st <= 3'd2;
            end
            K_LEADOUT: begin
                msf_lba <= leadout_lba + 32'd150; msf_start <= 1; rpt_st <= 3'd2;
            end
            K_TRK_REQ: begin    // REQUEST 2: full payload
                n2 <= curtrk_bcd10; n3 <= curtrk_bcd1;
                n4 <= 0; n5 <= 0; n6 <= 0; n7 <= 0; n8 <= 0;
                rpt_st <= 3'd0;
            end
            K_TRK_STAT: begin   // Get-Status with RS1==2: RS2-3 only (GPGX)
                n2 <= curtrk_bcd10; n3 <= curtrk_bcd1;
                rpt_st <= 3'd0;
            end
            K_FIRSTLAST: begin
                n2 <= 0; n3 <= 1;
                n4 <= last_bcd10; n5 <= last_bcd1;
                n6 <= 0; n7 <= 0; n8 <= 0;
                rpt_st <= 3'd0;
            end
            K_ERRINFO: begin    // REQUEST 6: no error
                zeros;
                rpt_st <= 3'd0;
            end
            K_TRKSTART: begin
                if (track_count == 0) begin       // no cue: single data track
                    rpt_trk_audio <= 0;
                    msf_lba <= 32'd150; msf_start <= 1; rpt_st <= 3'd3;
                end else begin                    // look the track up in the TOC
                    rpt_toc_use <= 1;
                    rpt_toc_addr <= rpt_track;
                    rpt_st <= 3'd5;
                end
            end
            default: rpt_st <= 3'd0;
            endcase
        end
        3'd2: if (msf_done) begin // MSF payload (abs/rel/leadout)
            n2 <= msf_m10; n3 <= msf_m1;
            n4 <= msf_s10; n5 <= msf_s1;
            n6 <= msf_f10; n7 <= msf_f1;
            // RS8 block flags: bit2 = data track (GPGX: type ? 0x04 : 0x00);
            // the lead-out report carries 0
            n8 <= (rpt_kind != K_LEADOUT && disc_present && !cur_audio)
                  ? 4'h4 : 4'h0;
            rpt_st <= 3'd0;
        end
        3'd3: if (msf_done) begin // track start (REQUEST 5)
            n2 <= msf_m10; n3 <= msf_m1;
            n4 <= msf_s10; n5 <= msf_s1;
            n6 <= msf_f10 | (rpt_trk_audio ? 4'h0 : 4'h8); n7 <= msf_f1;
            n8 <= mod10(rpt_track);   // track number, low digit
            rpt_st <= 3'd0;
        end
        3'd5: rpt_st <= 3'd6;         // TOC read latency
        3'd6: begin
            rpt_trk_audio <= toc_q[65];
            msf_lba <= {12'd0, toc_q[19:0]} + 32'd150;
            msf_start <= 1;
            rpt_toc_use <= 0;
            rpt_st <= 3'd3;
        end
        default: ;
        endcase

        ///////////////////////////////////////////////////////////////////
        // command handling -- a line-by-line port of GPGX cdd_process()
        ///////////////////////////////////////////////////////////////////
        if (cdd_send & ~send_d) begin
            dbg_last_comm <= cdd_comm;      // instrumentation
            dbg_last_c0   <= c0;
            if (c0 != 4'h0 && c0 != 4'h2) dbg_last_real_c0 <= c0;
            if (c0 == 4'h3 || c0 == 4'h4) begin       // SEEK+PLAY / SEEK+PAUSE
                dbg_seek_cnt <= dbg_seek_cnt + 1'b1;
                dbg_seek_lba <= comm_lba[19:0];
                if (disc_present && !head[31] &&
                    $signed(comm_lba) < $signed(head))
                    dbg_backseek_cnt <= dbg_backseek_cnt + 1'b1;
            end
            case (c0)
                4'h0: begin                   // Get Drive Status
                    // RS0-1 unchanged until the previous command has been
                    // processed; latency runs one frame ahead of the update
                    if (latency <= 8'd3) begin
                        n0 <= drv_status;
                        // no RS1-8 update while stopped or in any status
                        // above PAUSE (OPEN/TOC/NO_DISC/END)
                        if (!(drv_status == STAT_STOP ||
                              drv_status > STAT_PAUSE)) begin
                            if (n1 == 4'hF) begin
                                // seeking has ended: return valid infos,
                                // absolute time by default (fixes Lunar)
                                n1 <= 4'h0;
                                rpt_kind <= K_ABS; rpt_st <= 3'd1;
                            end
                            else if (n1 == 4'h0) begin
                                rpt_kind <= K_ABS; rpt_st <= 3'd1;
                            end
                            else if (n1 == 4'h1) begin
                                rpt_kind <= K_REL; rpt_st <= 3'd1;
                            end
                            else if (n1 == 4'h2) begin
                                rpt_kind <= K_TRK_STAT; rpt_st <= 3'd1;
                            end
                            // RS1 3..6: RS2-8 keep their last values
                        end
                    end
                end
                4'h1: begin                   // Stop Drive
                    // GPGX: status = loaded ? CD_TOC : NO_DISC, reply reads
                    // CD_STOP once with RS1=0xF; drive position resets.
                    // (pending/latency deliberately NOT cleared -- upstream
                    // quirk kept as-is.)
                    drv_status <= disc_present ? STAT_TOC : STAT_NO_DISC;
                    cdd_dm <= 1'b1;
                    n0 <= STAT_STOP; n1 <= 4'hF; zeros;
                    head <= 0;
                    apply_tog <= ~apply_tog;
                end
                4'h2: begin                   // Report TOC infos (type in c3)
                    if (disc_present) begin
                        n0 <= drv_status;
                        n1 <= c3;
                        case (c3)
                        4'h0: begin rpt_kind <= K_ABS;       rpt_st <= 3'd1; end
                        4'h1: begin rpt_kind <= K_REL;       rpt_st <= 3'd1; end
                        4'h2: begin rpt_kind <= K_TRK_REQ;   rpt_st <= 3'd1; end
                        4'h3: begin rpt_kind <= K_LEADOUT;   rpt_st <= 3'd1; end
                        4'h4: begin rpt_kind <= K_FIRSTLAST; rpt_st <= 3'd1; end
                        4'h5: begin
                            rpt_track <= (req_track == 0 ||
                                          (track_count != 0 && req_track > track_count))
                                         ? 7'd1 : req_track;
                            rpt_kind <= K_TRKSTART; rpt_st <= 3'd1;
                        end
                        4'h6: begin rpt_kind <= K_ERRINFO;   rpt_st <= 3'd1; end
                        default: ; // invalid request: regs unchanged (GPGX)
                        endcase
                    end else begin
                        // no-disc: zeroed payload (stub heritage; proven
                        // boot path -- documented divergence)
                        n0 <= drv_status; n1 <= c3; zeros;
                    end
                end
                4'h3, 4'h4: begin             // Play / Seek
                    if (disc_present) begin
                        // report (CD_SEEK<<8)|0xF: RS0 shows seeking, RS1=F
                        // invalidates track infos until the drive is ready
                        n0 <= STAT_SEEK; n1 <= 4'hF; zeros;
                        // one-interrupt delay before seeking starts: pending
                        // is applied by the next tick (fixes Radical Rex)
                        pending  <= (c0 == 4'h3) ? STAT_PLAY : STAT_PAUSE;
                        pend_lba <= comm_lba;
                    end else begin
                        n0 <= drv_status;
                    end
                end
                4'h6: begin                   // Pause
                    if (disc_present) begin
                        drv_status <= STAT_PAUSE;
                        cdd_dm <= 1'b1;       // no audio track playing
                    end
                    n0 <= disc_present ? STAT_PAUSE : drv_status;
                end
                4'h7: begin                   // Resume
                    if (disc_present) drv_status <= STAT_PLAY;
                    n0 <= disc_present ? STAT_PLAY : drv_status;
                end
                4'h8, 4'h9: begin             // Forward / Rewind Scan
                    if (disc_present) begin
                        drv_status <= STAT_SCAN;
                        scan_rev   <= (c0 == 4'h9);
                    end
                    n0 <= disc_present ? STAT_SCAN : drv_status;
                end
                4'hA: begin                   // N-Track Jump Control
                    if (disc_present) begin
                        drv_status <= STAT_PAUSE;
                        cdd_dm     <= 1'b1;
                    end
                    n0 <= disc_present ? STAT_PAUSE : drv_status;
                end
                4'hC: begin                   // Close Tray
                    door <= 0;
                    cdd_dm <= 1'b1;
                    drv_status <= disc_present ? STAT_TOC : STAT_NO_DISC;
                    n0 <= STAT_STOP; n1 <= 4'hF; zeros;
                    head <= 0;
                    apply_tog <= ~apply_tog;
                end
                4'hD: begin                   // Open Tray
                    door <= 1;
                    cdd_dm <= 1'b1;
                    drv_status <= STAT_OPEN;
                    n0 <= STAT_OPEN; n1 <= 4'hF; zeros;
                    head <= 0;
                    apply_tog <= ~apply_tog;
                end
                default: begin                // unknown command
                    n0 <= drv_status;
                end
            endcase
        end

        // fixed 75Hz exchange (the frame latched here carries the regs as
        // the commands left them -- GPGX's "process one frame ahead")
        if (wdog == BEAT) begin
            cdd_stat <= {csum, n8, n7, n6, n5, n4, n3, n2, n1, n0};
            cdd_rec  <= 1;
            rec_cnt  <= 4'd8;
            wdog     <= 0;
        end else if (rec_cnt != 0) begin
            rec_cnt <= rec_cnt - 1'b1;
        end else begin
            cdd_rec <= 0;
        end
    end
end

// does this tick owe the delivery FSM a sector? PLAY streams and advances;
// every other state (and any latency) re-delivers the banked sector under
// the head (dlv_hold_req). Audio PLAY streams to the DAC.
wire owe_this_tick =
    (latency != 0)              ? tick_data_ok :
    (drv_status == STAT_PLAY)   ? (disc_present &&
                                   !(!head[31] && head >= leadout_lba)) :
                                  tick_data_ok;

endmodule
