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
    output reg        cd_req_buf,
    input             cd_ack_74a,

    // double sector buffer read port (32-bit, 1 clk latency, byte0 in [7:0])
    output reg [10:0] cd_buf_addr,
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
    output reg [6:0]  toc_addr,
    input      [65:0] toc_q,
    // file holding the current track (multi-bin cue): the host reopens
    // the data slot when this changes between fetches
    output wire [6:0] cd_req_file,

    // hardware-overlay debug: {status, fetch_st, dlv_st, head[7:0]}
    output wire [31:0] dbg_state,
    output wire        dbg_sector_done
);

localparam [3:0] STAT_STOP    = 4'h0;
localparam [3:0] STAT_PLAY    = 4'h1;
localparam [3:0] STAT_SEEK    = 4'h2;
localparam [3:0] STAT_PAUSE   = 4'h4;
localparam [3:0] STAT_OPEN    = 4'h5;
localparam [3:0] STAT_TOC     = 4'h9;   // TOC read done = "disc ready"
localparam [3:0] STAT_NO_DISC = 4'hB;

localparam [25:0] BEAT = 26'd715909;      // 13.3ms @ 53.693175MHz
localparam [19:0] TICK_13MS = 20'd698010; // no-disc drain tick

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
reg [31:0] head = 0;          // current LBA
reg [31:0] seek_target = 0;
reg  [3:0] seek_cnt = 0;      // beats remaining in seek
reg        seek_to_play = 0;  // arrive in PLAY (else PAUSE)
reg  [3:0] rs_type = 4'hF;    // latched report type (F = none/status only)
reg  [6:0] rs_track = 1;      // track # latched with a REQUEST 5

///////////////////////////////////////////////
// current-track tracker: linear search of the TOC whenever the head
// moves (idle whenever the report builder owns the TOC port). With no
// cue (track_count==0) the disc is one data track.
///////////////////////////////////////////////
reg  [6:0] cur_track = 1;
reg        cur_audio = 0;
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

wire [3:0] curtrk_bcd10 = cur_track / 7'd10;
wire [3:0] curtrk_bcd1  = cur_track % 7'd10;
wire [3:0] last_bcd10   = (track_count==0) ? 4'd0 : track_count / 7'd10;
wire [3:0] last_bcd1    = (track_count==0) ? 4'd1 : track_count % 7'd10;

// command nibbles
wire [3:0] c0 = cdd_comm[3:0],   c1 = cdd_comm[7:4],   c2 = cdd_comm[11:8];
wire [3:0] c3 = cdd_comm[15:12], c4 = cdd_comm[19:16], c5 = cdd_comm[23:20];
wire [3:0] c6 = cdd_comm[27:24], c7 = cdd_comm[31:28];

// seek target from BCD MSF nibbles (c2..c7), minus the 150-sector pregap
wire [7:0]  m_bcd_in = c2*4'd10 + c3;
wire [7:0]  s_bcd_in = c4*4'd10 + c5;
wire [7:0]  f_bcd_in = c6*4'd10 + c7;
wire [31:0] comm_lba = m_bcd_in*32'd4500 + s_bcd_in*32'd75 + f_bcd_in - 32'd150;

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
        msf_m10 <= msf_m / 10; msf_m1 <= msf_m % 10;
        msf_s10 <= msf_s / 10; msf_s1 <= msf_s % 10;
        msf_f10 <= msf_f / 10; msf_f1 <= msf_f % 10;
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
// sector fetch engine: keep buffer halves holding head and head+1
///////////////////////////////////////////////
reg [31:0] buf_lba [0:1];
reg  [1:0] buf_valid = 0;
reg  [1:0] cdack_s = 0;
reg  [1:0] fetch_st = 0;
reg [31:0] fetch_lba;
wire       fetch_wanted = disc_present &&
                          (drv_status == STAT_PLAY || drv_status == STAT_SEEK ||
                           drv_status == STAT_PAUSE || drv_status == STAT_TOC);
// LBAs are signed: seeks into the track-1 pregap (down to -150) are part
// of the BIOS boot flow. Negative and virtual-pregap sectors are never
// fetched from the file; all real fetches use FILE LBAs (disc - delta).
wire       want_head  = !head[31] && !in_pregap &&
                        !(buf_valid[head_file[0]] && buf_lba[head_file[0]] == head_file);
wire [31:0] head1 = head_file + 1'b1;
wire       want_next  = !head1[31] && !in_pregap &&
                        !(buf_valid[head1[0]] && buf_lba[head1[0]] == head1);
always @(posedge clk) begin
    cdack_s <= {cdack_s[0], cd_ack_74a};
    if (reset | ~mcd_rst_n) begin
        cd_req <= 0;
        fetch_st <= 0;
        buf_valid <= 0;
    end else case (fetch_st)
    2'd0: if (fetch_wanted && (want_head || want_next)) begin
        fetch_lba <= want_head ? head_file : head1;
        fetch_st  <= 2'd1;
    end
    2'd1: begin
        // offset = lba * 2352 (2048 + 256 + 32 + 16)
        cd_req_offset <= (fetch_lba << 11) + (fetch_lba << 8) +
                         (fetch_lba << 5)  + (fetch_lba << 4);
        cd_req_buf    <= fetch_lba[0];
        buf_valid[fetch_lba[0]] <= 0;
        cd_req <= 1;
        fetch_st <= 2'd2;
    end
    2'd2: if (cdack_s[1]) begin
        cd_req <= 0;
        buf_lba[fetch_lba[0]]   <= fetch_lba;
        buf_valid[fetch_lba[0]] <= 1;
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
reg        dlv_half;    // buffer half latched at delivery start
reg        dlv_neg;     // pregap sector: synthesize sync+header, zero payload
reg        dlv_kick = 0;
reg        dlv_advance = 0;
// pregap header MSF digits (valid for head in -150..-1): abs = head+150
wire [7:0] pre_v   = head[7:0] + 8'd150;
wire       pre_s   = (pre_v >= 8'd75);
wire [6:0] pre_f   = pre_s ? (pre_v - 8'd75) : pre_v[6:0];
wire [3:0] pre_f10 = pre_f / 7'd10;
wire [3:0] pre_f1  = pre_f % 7'd10;
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
    2'd0: if (dlv_kick && (head[31] || !want_head)) begin
        dlv_w  <= 0;
        dlv_half <= head_file[0];
        dlv_neg  <= head[31];
        dlv_pgap <= in_pregap && !head[31];   // virtual pregap: silence
        dlv_aud  <= (cur_audio || in_pregap) && !head[31];
        dlv_st <= 2'd1;
    end
    2'd1: begin // present address, wait RAM latency
        cd_buf_addr <= {dlv_half, dlv_w[10:1]};
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
    // wait for the beat engine to consume dlv_advance and drop dlv_kick:
    // without this the level-held kick restarts delivery immediately
    // (head not yet advanced -> stale/duplicated sectors, >75Hz rate)
    2'd3: if (!dlv_kick) dlv_st <= 2'd0;
    default: dlv_st <= 0;
    endcase
end

// hex readout: digit0=drv_status digit1={fetch_st,dlv_st}
// digit2={cd_req,buf_valid,dlv_kick} digits3-7=head LBA
assign dbg_state = {drv_status, fetch_st, dlv_st,
                    cd_req, buf_valid, dlv_kick, head[19:0]};
assign dbg_sector_done = dlv_advance;

///////////////////////////////////////////////
// report builder: on each beat rebuild n2..n8 for the latched report
// type, then emit the frame
///////////////////////////////////////////////
reg  [2:0] rpt_st = 0;
reg        frame_go = 0;
reg        rpt_trk_audio = 0;
// REQUEST 5 track number from the command's c4/c5 BCD digits
wire [6:0] req_track = {3'd0,c4}*7'd10 + {3'd0,c5};

always @(posedge clk) begin
    if (reset | ~mcd_rst_n) begin
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
        rs_type  <= 4'hF;
        rs_track <= 7'd1;
        rpt_st   <= 0;
        rpt_toc_use <= 0;
        frame_go <= 0;
        msf_start <= 0;
        dlv_kick <= 0;
    end else begin
        send_d <= cdd_send;
        wdog   <= wdog + 1'b1;
        msf_start <= 0;

        // 13.3ms state tick
        if (ms_tick == TICK_13MS) begin
            ms_tick <= 0;
            if (drv_status == STAT_STOP && !disc_present) begin
                // no-disc drain, proven-clean boot path
                if (latency != 0) latency <= latency - 1'b1;
                else drv_status <= door ? STAT_OPEN : STAT_NO_DISC;
            end
            // disc inserted while empty: emulate a real insertion — tray
            // OPEN for ~0.5s, then closed-with-media (STOP). The bare
            // NO_DISC->STOP nudge was sometimes ignored by the BIOS; the
            // OPEN phase makes it drop its cached no-disc state, and the
            // pulse only fires once the mount is actually complete (which
            // also removes the "reset before the mount finished" race)
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
                // pregap headers roll by to arm its capture window
                dlv_kick <= 1;
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
            dlv_kick <= 0;
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
            n8 <= rs_track % 7'd10;   // track number (BCD units)
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
            case (c0)
                4'h0: begin                   // DRIVE STATUS (IDLE)
                    n0 <= drv_status;
                    // megacdd.cpp: while a seek/play is settling the report
                    // type is F ("busy"); the IDLE poll near completion
                    // flips it to a live absolute-position report — that
                    // F->0 transition is the BIOS's seek-done signal
                    if (rs_type == 4'hF &&
                        (drv_status != STAT_SEEK || seek_cnt <= 4'd3)) begin
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
                        seek_cnt <= 4'd10;
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
                        seek_cnt <= 4'd10;
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
                4'h7: begin                   // RESUME
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
