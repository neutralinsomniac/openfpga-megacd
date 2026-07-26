// CDD (CD-drive microcontroller) with a mounted disc image.
//
// v1 disc model: one MODE1/2352 data track (raw BIN). Track 1 starts at
// 00:02:00 (LBA 0); leadout = image size / 2352. No CDDA, no cue sheet.
//
// The no-disc protocol is inherited verbatim from megacd_cdd_stub (GPGX
// cdd.c semantics, hard-won in cosim): status drains STOP->NO_DISC and
// STAYS there; ReadTOC never fabricates entries; OPEN/CLOSE TRAY reply
// with their own status nibbles. With a disc mounted the same command set
// answers with real TOC data, seeks, and streams raw sectors to the CDC
// at 75Hz through the APF sector-fetch handshake.
//
// Status frame: nibbles n0..n9; n0 = status, n1 = latched report type,
// n2..n8 report payload, n9 = ~(sum n0..n8)&F. A frame is emitted every
// 13.3ms; the payload is rebuilt each beat for the latched report type
// (so ABSOLUTE tracks the head while playing).
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
    // load, then closed once it drops -- the drive is visibly busy with a disc
    // instead of reporting NO DISC. This is a LEVEL, not a latched request, so
    // an MCD reset pulse mid-load cannot strand us: the drive comes up STOP and
    // re-enters the tray-open state on the next tick while it is still high.
    input             disc_loading,
    // CD access time, mirroring GPGX's config.cd_latency user option:
    //   0 = accurate (default): 11-frame spin-up base + distance term
    //   1 = fast:               2-frame base, no distance term
    // FMV streaming seeks per chunk, and at 13.3ms/frame the accurate base is
    // 146ms of frozen head per seek, which is what an FMV stutter looks like on
    // the overlay. Upstream exposes this as an option rather than a change
    // because some titles NEED the delay -- GPGX notes the Wolf Team FMV games
    // want >=12 interrupts or they hang -- so the default must stay accurate.
    input             cd_fast_seek,
    output reg [6:0]  toc_addr,
    input      [65:0] toc_q,
    // file holding the current track (multi-bin cue): the host reopens
    // the data slot when this changes between fetches
    output wire [6:0] cd_req_file,

    // hardware-overlay debug: {status, fetch_st, dlv_st, head[7:0]}
    output wire [31:0] dbg_state,
    output wire        dbg_sector_done,
    // audio-path diagnostics: {cmd_cnt[8], seek_cnt[8], backseek_cnt[8],
    // last command c0[4], drv_status[4]}. backseek_cnt = SEEKs whose target is
    // BEHIND the current head (a resync-seek = an audible CDDA replay).
    output wire [31:0] dbg_cmds
);

localparam [3:0] STAT_STOP    = 4'h0;
localparam [3:0] STAT_PLAY    = 4'h1;
localparam [3:0] STAT_SEEK    = 4'h2;
localparam [3:0] STAT_PAUSE   = 4'h4;
localparam [3:0] STAT_OPEN    = 4'h5;
localparam [3:0] STAT_TOC     = 4'h9;   // TOC read done = "disc ready"
localparam [3:0] STAT_NO_DISC = 4'hB;

localparam [25:0] BEAT = 26'd715909;      // 13.3ms @ 53.693175MHz
// Drive tick: sector delivery beat, seek countdown, insertion dance, no-disc
// drain.
//
// TRIED AND REVERTED (hardware): setting this to 715909 = true 75Hz. It breaks
// boot -- never gets past CHECKING DISC with a disc inserted -- and ALSO makes
// BIOS audio play noticeably slow with NO disc inserted, which nothing about a
// 2.56% timing change explains and which is NOT understood. With no disc,
// disc_present is false so owe_inc never fires, and this tick should then only
// be driving the STOP->NO_DISC drain and the tray dance. Do not simply retry
// the constant; find what the audio path takes from this tick first.
//
// The over-delivery described below is nonetheless real and is the FMV
// stutter's cause. The untried surgical variant is to leave THIS tick at
// 698010 so every state machine keeps its present timing, and pace only
// owe_inc off a separate 75Hz counter -- which bisects "boot depends on the
// state-tick rate" against "boot depends on the delivery rate".
//
// It was 698010 cycles = 76.92Hz, 2.56% fast, which over-delivers by +1.92
// sectors/sec. A game streaming FMV overruns its read-ahead buffer at that
// rate and resyncs with a BACKWARD seek to re-read what it missed -- ~one
// every 2.1s for a 4-sector buffer. Each resync pays the seek latency, and
// that is the FMV stutter: measured on hardware as seek_cnt and backseek_cnt
// incrementing in lockstep (i.e. EVERY seek is backward) about once every two
// seconds, in cadence with the audible stutters.
//
// 53693175/75 = 715909 exactly, which is numerically the same as BEAT. The
// theory was that keeping ms_tick a separate counter preserved the
// phase-decoupling the boot header capture needs, and that only the period
// changed. Hardware says otherwise -- see the reverted note above.
localparam [19:0] TICK_13MS = 20'd698010;

wire disc_present = (img_size >= 32'd2352);
wire [31:0] leadout_lba = img_lba;        // computed at mount

reg  [3:0] drv_status /*verilator public_flat_rd*/ = STAT_STOP;
reg  [3:0] n0, n1, n2, n3, n4, n5, n6, n7, n8;
wire [3:0] csum = ~(n0 + n1 + n2 + n3 + n4 + n5 + n6 + n7 + n8) & 4'hF;

reg        door /*verilator public_flat_rd*/ = 0;
reg  [5:0] ins_cnt = 0;   // insertion tray-open pulse, in beats
reg [25:0] wdog = 0;
reg        send_d = 0;
reg  [3:0] rec_cnt = 0;
reg [19:0] ms_tick = 0;
reg  [3:0] latency = 4'd10;

// playback state
reg [31:0] head /*verilator public_flat_rd*/ = 0;  // current LBA
reg [31:0] seek_target = 0;
reg  [7:0] seek_cnt = 0;      // beats remaining in seek (1 beat ~= 13.3ms)
reg        seek_to_play = 0;  // arrive in PLAY (else PAUSE)

// distance-proportional seek latency, matching GPGX/MiSTer cdd_t::SeekToLBA:
//   frames = (play ? 11 : 0) + |Δlba| * 120 / 270000
// The distance term is |Δlba|/2250; done here as *7457>>24 (7457/2^24 =
// 1/2249.7, which reproduces MiSTer's truncated integer result to the frame
// across the whole disc). 1 beat (frame) ~= 13.3ms (the ms_tick period below).
// Full-disc play seek ~= 11 + 146 = 157 frames ~= 2.1s; base play ~= 0.15s.
// MiSTer applies no cap (bounded by disc size); SEEK_CAP is only an 8-bit
// overflow guard past that natural max.
localparam [12:0] SEEK_MULT      = 13'd7457; // 7457/2^24 ~= 1/2250
localparam [4:0]  SEEK_RSHIFT    = 5'd24;
localparam [7:0]  SEEK_PLAY_BASE = 8'd11;    // +11 frames on PLAY only
localparam [7:0]  SEEK_CAP       = 8'd200;   // overflow guard (MiSTer: uncapped)
reg  [3:0] rs_type = 4'hF;    // latched report type (F = none/status only)
reg  [6:0] rs_track = 1;      // track # latched with a REQUEST 5
// instrumentation: last CDD command word + counters (sim log + hw overlay)
reg [39:0] dbg_last_comm /*verilator public_flat_rd*/ = 0;
reg  [7:0] dbg_cmd_cnt   /*verilator public_flat_rd*/ = 0;
reg  [7:0] dbg_seek_cnt  /*verilator public_flat_rd*/ = 0;  // SEEK cmds
reg  [7:0] dbg_backseek_cnt /*verilator public_flat_rd*/ = 0; // backward SEEKs
reg  [3:0] dbg_last_c0   = 0;
assign dbg_cmds = {dbg_cmd_cnt, dbg_seek_cnt, dbg_backseek_cnt,
                   dbg_last_c0, drv_status};

///////////////////////////////////////////////
// current-track tracker: linear search of the TOC whenever the head
// moves (idle whenever the report builder owns the TOC port). With no
// cue (track_count==0) the disc is one data track.
///////////////////////////////////////////////
reg  [6:0] cur_track = 1;
reg        cur_audio /*verilator public_flat_rd*/ = 0;
reg [19:0] cur_delta = 0;     // disc->file offset for the current track
reg  [6:0] cur_file = 0;      // which bin holds the current track
reg [19:0] cur_start = 0;     // current track's disc start
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
// disc LBA -> file LBA for fetch/delivery
wire [31:0] head_file = head - {12'd0, cur_delta};

// Constant divide/modulo by 10, by reciprocal multiply.
//
// Every `/ 10` and `% 10` in this file is BCD digit-splitting of track
// numbers and MSF timecode, but Quartus was inferring a full lpm_divide
// block for each: 13 of them, ~275 ALMs, on a design sitting at 99% ALM
// utilization. This is the same trick the seek math above already uses
// (SEEK_MULT), just applied to the BCD conversions as well.
//
// (v * 205) >> 11 == v/10 exactly for v <= 1023: the error term is v/10240,
// and the tightest case is v = 9 (mod 10), where the fractional part is 0.9,
// so it stays below the next integer while v < 1024. Every caller here is
// 7 or 8 bits (<= 255), so there is ample margin.
//
// Callers assign into 4-bit fields and therefore truncate exactly as the
// original `/` and `%` did -- these functions return the full value and
// deliberately do not change that behaviour.
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

// seek stroke = |target - head| in sectors. Both are signed LBAs (pregap
// sectors are small negatives), so signed subtraction keeps boot-pregap
// parks (head~0 -> ~-2) a short hop rather than a full-stroke seek.
// --- seek-latency pipeline -------------------------------------------------
// This distance math is two chained multiplies (comm_lba's BCD*constants, then
// |Δlba|*7457) plus the cap adders — as a single combinational cone from
// cdd_comm/head into seek_cnt it was ~32ns and failed setup on the 107MHz
// clock by ~14ns (TNS -358): the boot-corruption regression. cdd_comm and head
// are stable for thousands of clk cycles before the cdd_send strobe or the
// 13.3ms tick that consume the result, so these free-running stages have long
// settled by the time a command latches seek_cnt. Same operations and
// bit-exact values as the old single-cycle path — only pipelined off it.
reg  [31:0] comm_lba_r   = 0;   // stage 0: BCD*const multiplies resolved
reg  [31:0] head_r       = 0;
reg  [31:0] seek_dist_r  = 0;   // stage 1: |target - head|
reg  [31:0] seek_dterm_r = 0;   // stage 2: distance term (the *7457 multiply)
reg   [7:0] play_beats_r  = 0;  // stage 3: distance term + PLAY base, capped
reg   [7:0] pause_beats_r = 0;  // stage 3: distance term (PAUSE), capped

wire signed [31:0] seek_diff = $signed(comm_lba_r) - $signed(head_r);
wire [31:0] seek_dist   = seek_diff[31] ? (~seek_diff + 32'd1) : seek_diff;
// distance term = |Δlba| * 7457 >> 24  (== MiSTer's |Δlba|/2250)
wire [44:0] seek_scaled = seek_dist_r * SEEK_MULT;
wire [31:0] seek_dterm  = seek_scaled >> SEEK_RSHIFT;
// SEEK+PLAY carries the +11 base; SEEK+PAUSE has none (MiSTer play flag).
//
// The base is charged only when no seek is already pending, matching GPGX:
//
//     if (!cdd.latency) cdd.latency = 2 + 10*config.cd_latency;
//     cdd.latency += ((|dlba| * 120 * config.cd_latency) / 270000);
//
// Assigning it unconditionally meant a PLAY re-issued mid-seek restarted the
// whole 11-frame (146ms) base, so a host that re-commands while the drive is
// still seeking could hold the head frozen indefinitely -- measured at 386ms
// vs 146ms for a seek re-issued every 2 beats (tb_drive --reseek).
// seek_cnt IS cdd.latency, so the guard maps directly: nonzero = a seek is
// still pending, keep its remaining count as the base; zero = charge the base.
// Keying off drv_status instead would misfire in the window where the count
// has hit 0 but the status has not yet flipped to PLAY, handing a command
// landing there a base of 0 and an instant seek.
//
// cd_fast_seek picks the upstream cd_latency=0 profile: base 2 (GPGX's
// "2 + 10*config.cd_latency" with the option off) and no distance term.
wire [7:0]  seek_base_cfg   = cd_fast_seek ? 8'd2 : SEEK_PLAY_BASE;
wire [31:0] seek_dterm_eff  = cd_fast_seek ? 32'd0 : seek_dterm_r;
wire [31:0] seek_base_r     = (seek_cnt != 8'd0) ? {24'd0, seek_cnt}
                                                : {24'd0, seek_base_cfg};
wire [31:0] play_beats_raw  = seek_base_r + seek_dterm_eff;
wire [31:0] pause_beats_raw = seek_dterm_eff;

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
///////////////////////////////////////////////
// buf_lba is the FILE LBA held in each slot. A CD never reaches 2^20 sectors,
// so 21 bits fully distinguish sectors -- narrower than the 32-bit head lets
// the 4 "is it banked?" comparators cost far fewer ALMs (this design fits at
// ~98% util, so the prefetch scan is kept lean).
reg [20:0] buf_lba [0:3];
reg  [3:0] buf_valid = 0;
reg  [1:0] cdack_s = 0;
reg  [1:0] fetch_st = 0;
reg [31:0] fetch_lba;
// cur_track/cur_delta/cur_file describe srch_head, which is NOT necessarily
// the current head: the track search takes ~6 clk to walk the TOC, so right
// after a seek they still describe wherever the head used to be. Fetching in
// that window computes head_file from a stale cur_delta and tags it with a
// stale cur_file, so the drive asks the host for the wrong offset in the wrong
// bin. The bad sector is never delivered (its buf_lba cannot match once the
// search corrects, since two tracks only share a delta when they share a file)
// but it costs a wasted round-trip plus a reopen away and back on every
// track-crossing seek -- the multi-bin startup hitch.
//
// With no cue there is a single track and the registers are always valid;
// srch_head is never updated in that branch, so it must be excluded or the
// drive would never fetch at all.
wire       toc_settled = (track_count == 7'd0) ||
                         ((srch_st == 3'd0) && (srch_head == head));
wire       fetch_wanted = disc_present && toc_settled &&
                          (drv_status == STAT_PLAY || drv_status == STAT_SEEK ||
                           drv_status == STAT_PAUSE || drv_status == STAT_TOC);
// LBAs are signed: seeks into the track-1 pregap (down to -150) are part
// of the BIOS boot flow. Negative and virtual-pregap sectors are never
// fetched from the file; all real fetches use FILE LBAs (disc - delta).
wire [31:0] hf0 = head_file;
wire [31:0] hf1 = head_file + 32'd1;
wire [31:0] hf2 = head_file + 32'd2;
wire [31:0] hf3 = head_file + 32'd3;
wire       want_head = !head[31] && !in_pregap &&
                       !(buf_valid[hf0[1:0]] && buf_lba[hf0[1:0]] == hf0[20:0]);
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
    end else case (fetch_st)
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
end

///////////////////////////////////////////////
// sector delivery: on each beat while PLAY, stream 1176 words to the CDC
// (16 clks per word: 8 high, 8 low = ~350us per sector)
///////////////////////////////////////////////
reg  [1:0] dlv_st = 0;
reg [10:0] dlv_w;       // word index 0..1175
reg  [3:0] dlv_ph;
reg  [1:0] dlv_slot;    // bank slot (file_lba[1:0]) latched at delivery start
reg        dlv_neg;     // pregap sector: synthesize sync+header, zero payload
// sectors owed to the delivery FSM: +1 per PLAY beat, -1 per delivered
// sector (saturating). A COUNTER, not a level flag: the old dlv_kick level
// was raised on the beat and lowered on completion in the same always-block,
// so a beat landing on the same clock as a completion was silently dropped.
// During CDDA the FIFO backpressure stretches each sector's delivery to
// nearly a full beat, so completion sat right on the next beat boundary and
// that collision recurred every few beats -> dropped sectors -> FIFO
// underrun -> audible skips. The counter never loses a beat and lets the
// engine burst-catch-up after a stall (the CDDA FIFO / CDC ring absorb it).
reg  [3:0] dlv_owed = 0;
reg        dlv_advance /*verilator public_flat_rd*/ = 0;
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
reg dlv_aud;    // audio sector: route to the CDDA DAC, pace on its FIFO
reg dlv_pgap;   // virtual-pregap sector: deliver silence
always @(posedge clk) begin
    dlv_advance <= 0;
    if (reset | ~mcd_rst_n) begin
        dlv_st <= 0;
        cdc_dat_wr <= 0;
        cdc_cdda_wr <= 0;
    end else case (dlv_st)
    2'd0: if (dlv_owed != 0 && (head[31] || !want_head)) begin
        dlv_w  <= 0;
        dlv_slot <= head_file[1:0];
        dlv_neg  <= head[31];
        dlv_pgap <= in_pregap && !head[31];   // virtual pregap: silence
        dlv_aud  <= (cur_audio || in_pregap) && !head[31];
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
            end
            if (dlv_ph == 10) begin cdc_dat_wr <= 0; cdc_cdda_wr <= 0; end
            if (dlv_ph == 15) begin
                if (dlv_w == 11'd1175) begin
                    dlv_advance <= 1;   // sector fully delivered
                    dlv_st <= 2'd3;
                end else begin
                    dlv_w  <= dlv_w + 1'b1;
                    dlv_st <= 2'd1;
                end
            end
        end
    end
    // one-cycle drain: hold here while dlv_advance propagates so the report
    // block advances head and decrements dlv_owed before state 0 re-arms
    // (else delivery could restart on the not-yet-advanced head)
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
// report builder: on each beat rebuild n2..n8 for the latched report
// type, then emit the frame
///////////////////////////////////////////////
reg  [2:0] rpt_st = 0;
reg        frame_go = 0;
reg        rpt_trk_audio = 0;

// a delivery is owed for each beat spent in PLAY with a disc present.
// NOTE: paced off ms_tick==TICK_13MS, which is now a true 75Hz (see the
// localparam). Retiming this to wdog==BEAT BROKE the BIOS disc-check handshake
// (stuck at CHECKING DISC every boot) — the boot header capture depends on the
// delivery beat being on ms_tick, decoupled from the 75Hz status frame; that
// is about the counter, not the rate, so correcting ms_tick's period is a
// different change from driving delivery off wdog. The
// FMV audio glitch is a PCM UNDERRUN (sub can't refill in time), so a slower
// delivery would not fix it anyway; left on ms_tick to preserve boot.
//
// TRIED AND REJECTED (hardware): owing a sector during STAT_SEEK as well, to
// match GPGX, which keeps the decoder running for the whole seek latency --
//
//     if (cdd.latency > 0) { cdd.latency--; cdc_decoder_update(0); }
//
// -- so the sub keeps receiving DECI at 75Hz while seeking instead of nothing
// for the 11-frame (146ms) base. Implemented faithfully (owe_inc covering
// SEEK, head parked on the target at command time as upstream's cdd.lba = lba,
// head advanced only in PLAY) and verified in sim: 10 sectors decoded across an
// 11-beat seek versus 0, all drive tests passing.
//
// It hangs the BIOS at CHECKING DISC on hardware. Same failure as retiming the
// beat to wdog, and for the same reason: the boot header capture depends on
// exactly which frames deliver, and the co-sim cannot catch it because the MCD
// is held in reset there so drv_status never leaves STOP. Do not retry without
// first working out what the boot handshake requires of the delivery beat.
//
// Note also that the FMV motivation above is weak: a PCM underrun is a
// CPU-throughput problem, and extra DECI only helps if the sub's refill loop is
// BLOCKED on DECI rather than short of cycles.
wire owe_inc = (ms_tick == TICK_13MS) && (drv_status == STAT_PLAY) && disc_present;
// REQUEST 5 track number from the command's c4/c5 BCD digits
wire [6:0] req_track = {3'd0,c4}*7'd10 + {3'd0,c5};

always @(posedge clk) begin
    if (reset | ~mcd_rst_n) begin
        // Come up disc-ready (TOC) if a disc is present. A real CDD keeps its
        // disc knowledge across sub-CPU/MCD resets; the BIOS pulses the MCD
        // reset during boot, and resetting the drive to STOP left it stuck
        // (STOP+disc has no path to TOC) -> CHECKING DISC forever. TOC is the
        // "disc ready" state the BIOS idle screen polls for.
        //
        // Do NOT replace this with a timed transition (e.g. NO_DISC -> OPEN
        // -> TOC) to give the BIOS an edge to observe: that was tried and is
        // strictly worse. The BIOS pulses this reset repeatedly, so a ~0.5s
        // dance never completes -- the drive just oscillates NO_DISC(B) <->
        // OPEN(5) forever and never reaches disc-ready. Landing directly in
        // TOC is what makes the state survive the pulsing.
        // Always come up STOP(0), even with a disc present.
        //
        // dc3e80be made this report TOC(9) when a disc was present, to fix a
        // CHECKING DISC hang, on the premise that "STOP+disc has no path to
        // TOC". That premise is wrong -- the REQUEST handler below promotes
        // STOP to TOC on the first report request (megacdd.cpp semantics) --
        // and reporting 9 here is what hung the BIOS whenever a disc was
        // already mounted at reset.
        //
        // Co-sim located it exactly. The sub-BIOS dispatches on the drive
        // status nibble through a jump table:
        //     0F60  MOVE.B $5844(A5),D0     ; drive status
        //     0F68  ANDI.W #$000F,D0
        //     0F6C  ADD.W D0,D0 (x2)        ; *4
        //     0F70  JMP $02(PC,D0.W)
        //     0F74  BRA $0FDC               ; index 0 = STOP  -> boots
        //     ...
        //     0F98  BRA $1048               ; index 9 = TOC   -> never completes
        // Coming up 9 selects the $1048 handler, which at boot never reaches
        // the code that writes CFS; the main CPU then waits on $A1200E
        // forever and pulses the MCD reset in a loop. Coming up 0 selects
        // $0FDC, the same path a discless boot takes, and the drive then
        // reaches TOC by itself: verified in co-sim going 0 -> 9 -> 2 -> 4
        // -> 1 (STOP, TOC, SEEK, PAUSE, PLAY) with the sub-CPU writing CFS
        // normally.
        //
        // Do NOT "fix" this by reporting a timed NO_DISC -> OPEN -> TOC
        // transition instead: that was tried and is strictly worse, because
        // the BIOS pulses the MCD reset repeatedly and the ~0.5s tray dance
        // never survives to completion.
        drv_status <= STAT_STOP;
        n0 <= STAT_STOP; n1 <= 0;
        n2 <= 0; n3 <= 0; n4 <= 0; n5 <= 0; n6 <= 0; n7 <= 0; n8 <= 0;
        cdd_stat <= {4'hF, 36'h0};
        cdd_dm   <= 0;
        cdd_rec  <= 0;
        wdog     <= 0;
        rec_cnt  <= 0;
        send_d   <= 0;
        ms_tick  <= 0;
        latency  <= 4'd10;
        door     <= 0;
        head     <= 0;
        seek_cnt <= 0;
        comm_lba_r <= 0; head_r <= 0; seek_dist_r <= 0; seek_dterm_r <= 0;
        play_beats_r <= 0; pause_beats_r <= 0;
        rs_type  <= 4'hF;
        rs_track <= 7'd1;
        rpt_st   <= 0;
        rpt_toc_use <= 0;
        frame_go <= 0;
        msf_start <= 0;
        dlv_owed <= 0;
    end else begin
        send_d <= cdd_send;
        wdog   <= wdog + 1'b1;
        msf_start <= 0;

        // seek-latency pipeline advance (free-running; see the wire block
        // above). Inputs are stable long before a command reads the result.
        comm_lba_r   <= comm_lba;
        head_r       <= head;
        seek_dist_r  <= seek_dist;
        seek_dterm_r <= seek_dterm;
        play_beats_r  <= (play_beats_raw  > {24'd0, SEEK_CAP})
                         ? SEEK_CAP : play_beats_raw[7:0];
        pause_beats_r <= (pause_beats_raw > {24'd0, SEEK_CAP})
                         ? SEEK_CAP : pause_beats_raw[7:0];

        // sectors owed to the delivery FSM. Increment and decrement are
        // combined into ONE assignment so a beat that lands on the same clock
        // as a completion is not lost (the bug the old dlv_kick level had).
        dlv_owed <= dlv_owed
                  + ((owe_inc && dlv_owed != 4'hF) ? 4'd1 : 4'd0)
                  - ((dlv_advance && dlv_owed != 4'd0) ? 4'd1 : 4'd0);

        // 13.3ms state tick
        if (ms_tick == TICK_13MS) begin
            ms_tick <= 0;
            if (drv_status == STAT_STOP && !disc_present) begin
                // no-disc drain, proven-clean boot path
                if (latency != 0) latency <= latency - 1'b1;
                else drv_status <= door ? STAT_OPEN : STAT_NO_DISC;
            end
            // MEDIA GONE. img_size drops to 0 whenever the mount FSM starts
            // over -- including when the user picks a different .cue -- and
            // stays 0 until the new TOC is final. Only the drain above
            // noticed, and it only looks at STOP, so after a swap the drive
            // sat in TOC(9) holding the OLD disc: the BIOS never saw the disc
            // leave, and the insertion dance below (which fires only from
            // NO_DISC) never ran for the new image. Fall back to STOP from any
            // state that implies media so the drain retires us to NO_DISC and
            // the normal insertion path runs again. Skipped while door=1: an
            // explicit OPEN TRAY is the host's own doing, not an eject.
            if (!disc_present && !door && !disc_loading &&
                drv_status != STAT_NO_DISC && drv_status != STAT_STOP) begin
                drv_status <= STAT_STOP;
                latency    <= 4'd0;   // drain to NO_DISC on the next tick
                ins_cnt    <= 0;      // cancel an insertion dance in flight
            end
            // disc inserted mid-session (drive was NO_DISC): emulate a real
            // insertion — tray OPEN ~0.5s then closed-with-media, landing in
            // TOC(9). (Present-at-boot and post-MCD-reset are handled by the
            // reset block bringing the drive up disc-ready, see above -- this
            // path is too slow to survive the BIOS's reset pulsing.)
            if (drv_status == STAT_NO_DISC && disc_present && !door) begin
                drv_status <= STAT_OPEN;
                ins_cnt <= 6'd38;
            end
            if (drv_status == STAT_OPEN && ins_cnt != 0) begin
                ins_cnt <= ins_cnt - 1'b1;
                // land in TOC (9), not STOP: a real drive reads the TOC by
                // itself after a close, and the BIOS's idle screen only
                // watches DRIVE STATUS for 9 — ending in STOP deadlocks
                // (BIOS waits for 9, we wait for a TOC request)
                if (ins_cnt == 6'd1) drv_status <= STAT_TOC;
            end
            // LOADING: hold the tray open for as long as the host is preparing
            // the image. Placed after the rules above so it wins over the drain
            // and the dance. door is deliberately NOT set -- that reg means
            // "the host commanded a tray state", and setting it here would
            // block the insertion path. Status alone is what the BIOS reads.
            if (disc_loading && !door) begin
                drv_status <= STAT_OPEN;
                ins_cnt    <= 0;
            end
            // LOADING DONE: close the tray. With media, run the normal close
            // dance so we land in TOC(9) exactly as a real insertion does; if
            // the mount failed and no disc appeared, fall back to the drain.
            if (!disc_loading && !door && drv_status == STAT_OPEN &&
                ins_cnt == 0) begin
                if (disc_present) ins_cnt <= 6'd38;
                else begin
                    drv_status <= STAT_STOP;
                    latency    <= 4'd0;
                end
            end
            if (drv_status == STAT_SEEK) begin
                if (seek_cnt != 0) seek_cnt <= seek_cnt - 1'b1;
                else begin
                    head <= seek_target;
                    drv_status <= seek_to_play ? STAT_PLAY : STAT_PAUSE;
                end
            end
            if (drv_status == STAT_PLAY && disc_present) begin
                cdd_dm <= ~cur_audio;           // data/music flag per track
                // pregap sectors (negative LBA) are synthesized by the
                // delivery FSM: the BIOS parks at 00:01:73 and watches the
                // pregap headers roll by to arm its capture window.
                // The beat is accounted by owe_inc -> dlv_owed above.
            end
        end else begin
            ms_tick <= ms_tick + 1'b1;
        end

        // rebuild the report payload just before each frame emit (~19us,
        // build takes ~5us worst case), and immediately after a REQUEST so
        // the reply frame carries the newly latched type's data
        if (wdog == BEAT - 26'd1024) rpt_st <= 3'd1;

        // sector delivered: advance the head (the consumed half is naturally
        // refetched: after head++ the lba->half mapping asks it for head+1)
        if (dlv_advance) begin
            if (head != leadout_lba) head <= head + 1'b1;
            else drv_status <= STAT_PAUSE;  // ran into leadout
        end

        // report payload builder (runs between beats, few us)
        case (rpt_st)
        3'd1: begin
            n0 <= drv_status;
            case (rs_type)
            4'h0: begin msf_lba <= head + 32'd150; msf_start <= 1; rpt_st <= 3'd2; end
            4'h1: begin msf_lba <= head[31] ? (~head + 1'b1)
                                  : (head >= {12'd0, cur_start})
                                    ? (head - {12'd0, cur_start})
                                    : ({12'd0, cur_start} - head);
                        msf_start <= 1; rpt_st <= 3'd2; end
            4'h3: begin msf_lba <= leadout_lba + 32'd150; msf_start <= 1; rpt_st <= 3'd2; end
            4'h2: begin n1 <= 4'h2; n2 <= curtrk_bcd10; n3 <= curtrk_bcd1;
                        n4 <= 0; n5 <= 0; n6 <= 0; n7 <= 0; n8 <= 0; rpt_st <= 3'd4; end
            4'h4: begin n1 <= 4'h4; n2 <= 0; n3 <= 1;
                        n4 <= last_bcd10; n5 <= last_bcd1;
                        n6 <= 0; n7 <= 0; n8 <= 0; rpt_st <= 3'd4; end
            4'h5: begin
                if (track_count == 0) begin       // no cue: single data track
                    rpt_trk_audio <= 0;
                    msf_lba <= 32'd150; msf_start <= 1; rpt_st <= 3'd3;
                end else begin                    // look the track up in the TOC
                    rpt_toc_use <= 1;
                    rpt_toc_addr <= rs_track;
                    rpt_st <= 3'd5;
                end
            end
            default: rpt_st <= 3'd4; // keep last payload
            endcase
        end
        3'd2: if (msf_done) begin // MSF payload (types 0/1/3)
            n1 <= rs_type;
            n2 <= msf_m10; n3 <= msf_m1;
            n4 <= msf_s10; n5 <= msf_s1;
            n6 <= msf_f10; n7 <= msf_f1;
            // megacdd.cpp: ABSOLUTE and RELATIVE both report the current
            // track's type<<2 in n8 (the BIOS checks it before PLAYing)
            n8 <= (rs_type != 4'h3 && disc_present && !cur_audio) ? 4'h4 : 4'h0;
            rpt_st <= 3'd4;
        end
        3'd3: if (msf_done) begin // track start (type 5): data flag in n6 bit3
            n1 <= 4'h5;
            n2 <= msf_m10; n3 <= msf_m1;
            n4 <= msf_s10; n5 <= msf_s1;
            n6 <= msf_f10 | (rpt_trk_audio ? 4'h0 : 4'h8); n7 <= msf_f1;
            n8 <= mod10(rs_track);   // track number (BCD units)
            rpt_st <= 3'd4;
        end
        3'd4: begin frame_go <= 1; rpt_st <= 3'd0; end
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

        // command handling: immediate reply nibbles per megacdd.cpp/GPGX
        if (cdd_send & ~send_d) begin
            dbg_last_comm <= cdd_comm;      // instrumentation
            dbg_cmd_cnt   <= dbg_cmd_cnt + 1'b1;
            dbg_last_c0   <= c0;
            if (c0 == 4'h3 || c0 == 4'h4) begin       // SEEK+PLAY / SEEK+PAUSE
                dbg_seek_cnt <= dbg_seek_cnt + 1'b1;
                // target behind the current head = a backward resync-seek,
                // which replays audio (the CDDA "repeat" the user hears)
                if (disc_present && !head[31] && comm_lba < head)
                    dbg_backseek_cnt <= dbg_backseek_cnt + 1'b1;
            end
            case (c0)
                4'h0: begin                   // DRIVE STATUS (IDLE)
                    n0 <= drv_status;
                    // megacdd.cpp: while a seek/play is settling the report
                    // type is F ("busy"); the IDLE poll near completion
                    // flips it to a live absolute-position report — that
                    // F->0 transition is the BIOS's seek-done signal
                    if (rs_type == 4'hF &&
                        (drv_status != STAT_SEEK || seek_cnt <= 8'd3)) begin
                        rs_type <= 4'h0;
                        rpt_st <= 3'd1;
                    end
                end
                4'h1: begin                   // STOP
                    drv_status <= disc_present ? STAT_STOP : STAT_STOP;
                    latency <= 4'd0;
                    n0 <= STAT_STOP; n1 <= 0; zeros;
                    rs_type <= 4'hF;
                end
                4'h2: begin                   // REQUEST report c3
                    if (disc_present) begin
                        // megacdd.cpp: first TOC request while stopped moves
                        // the drive to TOC (9) — the "disc ready" resting
                        // state the BIOS polls for before booting
                        if (drv_status == STAT_STOP) drv_status <= STAT_TOC;
                        rs_type <= c3;
                        // REQUEST 5 carries the track number in c4/c5 (BCD)
                        if (c3 == 4'h5)
                            rs_track <= (req_track == 0 ||
                                         (track_count != 0 && req_track > track_count))
                                        ? 7'd1 : req_track;
                        n0 <= (drv_status == STAT_STOP) ? STAT_TOC : drv_status;
                        n1 <= c3;
                        rpt_st <= 3'd1;       // rebuild payload now
                    end else begin
                        n0 <= drv_status; n1 <= c3; zeros;
                    end
                end
                4'h3: begin                   // SEEK + PLAY
                    if (disc_present) begin
                        seek_target <= comm_lba;
                        seek_to_play <= 1;
                        seek_cnt <= play_beats_r;
                        drv_status <= STAT_SEEK;
                        rs_type <= 4'hF;      // busy until an IDLE poll near done
                        n0 <= STAT_SEEK; n1 <= 4'hF; zeros;
                    end else begin
                        n0 <= drv_status;
                    end
                end
                4'h4: begin                   // SEEK + PAUSE
                    if (disc_present) begin
                        seek_target <= comm_lba;
                        seek_to_play <= 0;
                        seek_cnt <= pause_beats_r;
                        drv_status <= STAT_SEEK;
                        rs_type <= 4'hF;      // busy until an IDLE poll near done
                        n0 <= STAT_SEEK; n1 <= 4'hF; zeros;
                    end else begin
                        n0 <= drv_status;
                    end
                end
                4'h6: begin                   // PAUSE
                    if (disc_present) drv_status <= STAT_PAUSE;
                    n0 <= disc_present ? STAT_PAUSE : drv_status;
                end
                4'h7: begin                   // RESUME (PAUSE->PLAY)
                    // Instant, matching GPGX/MiSTer: RESUME goes straight to
                    // PLAY from PAUSE/STOP/TOC with no spin-up delay.
                    if (disc_present) drv_status <= STAT_PLAY;
                    n0 <= disc_present ? STAT_PLAY : drv_status;
                end
                4'hD: begin                   // OPEN TRAY
                    door <= 1;
                    drv_status <= STAT_OPEN;
                    latency <= 4'd0;
                    n0 <= STAT_OPEN; n1 <= 0; zeros;
                end
                4'hC: begin                   // CLOSE TRAY (reply STOP; with a
                    door <= 0;                // disc the drive lands in TOC)
                    drv_status <= disc_present ? STAT_TOC : STAT_NO_DISC;
                    latency <= 4'd0;
                    n0 <= STAT_STOP; n1 <= 0; zeros;
                end
                default: begin
                    n0 <= drv_status;
                end
            endcase
        end

        // fixed 75Hz exchange
        if (wdog == BEAT) begin
            cdd_stat <= {csum, n8, n7, n6, n5, n4, n3, n2, n1, n0};
            cdd_rec  <= 1;
            rec_cnt  <= 4'd8;
            wdog     <= 0;
            frame_go <= 0;
        end else if (rec_cnt != 0) begin
            rec_cnt <= rec_cnt - 1'b1;
        end else begin
            cdd_rec <= 0;
        end
    end
end

endmodule
