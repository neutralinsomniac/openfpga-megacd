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
    output reg        cdc_dat_wr
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

reg  [3:0] drv_status = STAT_STOP;
reg  [3:0] n0, n1, n2, n3, n4, n5, n6, n7, n8;
wire [3:0] csum = ~(n0 + n1 + n2 + n3 + n4 + n5 + n6 + n7 + n8) & 4'hF;

reg        door = 0;
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
// of the BIOS boot flow. Negative sectors are never fetched from the file.
wire       want_head  = !head[31] &&
                        !(buf_valid[head[0]]   && buf_lba[head[0]]   == head);
wire [31:0] head1 = head + 1'b1;
wire       want_next  = !head1[31] &&
                        !(buf_valid[head1[0]] && buf_lba[head1[0]] == head1);
always @(posedge clk) begin
    cdack_s <= {cdack_s[0], cd_ack_74a};
    if (reset | ~mcd_rst_n) begin
        cd_req <= 0;
        fetch_st <= 0;
        buf_valid <= 0;
    end else case (fetch_st)
    2'd0: if (fetch_wanted && (want_head || want_next)) begin
        fetch_lba <= want_head ? head : head1;
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
reg        dlv_kick = 0;
reg        dlv_advance = 0;
always @(posedge clk) begin
    dlv_advance <= 0;
    if (reset | ~mcd_rst_n) begin
        dlv_st <= 0;
        cdc_dat_wr <= 0;
    end else case (dlv_st)
    2'd0: if (dlv_kick && !want_head) begin
        dlv_w  <= 0;
        dlv_st <= 2'd1;
    end
    2'd1: begin // present address, wait RAM latency
        cd_buf_addr <= {head[0], dlv_w[10:1]};
        dlv_ph <= 0;
        dlv_st <= 2'd2;
    end
    2'd2: begin // latch word, pulse wr 8 high / 8 low
        dlv_ph <= dlv_ph + 1'b1;
        if (dlv_ph == 1) cdc_data <= dlv_w[0] ? cd_buf_q[31:16] : cd_buf_q[15:0];
        if (dlv_ph == 2) cdc_dat_wr <= 1;
        if (dlv_ph == 10) cdc_dat_wr <= 0;
        if (dlv_ph == 15) begin
            if (dlv_w == 11'd1175) begin
                dlv_advance <= 1;   // sector fully delivered
                dlv_st <= 2'd0;
            end else begin
                dlv_w  <= dlv_w + 1'b1;
                dlv_st <= 2'd1;
            end
        end
    end
    default: dlv_st <= 0;
    endcase
end

///////////////////////////////////////////////
// report builder: on each beat rebuild n2..n8 for the latched report
// type, then emit the frame
///////////////////////////////////////////////
reg  [2:0] rpt_st = 0;
reg        frame_go = 0;

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
        rpt_st   <= 0;
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
            if (drv_status == STAT_SEEK) begin
                if (seek_cnt != 0) seek_cnt <= seek_cnt - 1'b1;
                else begin
                    head <= seek_target;
                    drv_status <= seek_to_play ? STAT_PLAY : STAT_PAUSE;
                end
            end
            if (drv_status == STAT_PLAY && disc_present) begin
                cdd_dm <= 1;                    // data track (v1: all data)
                if (head[31]) head <= head + 1'b1;  // pregap: roll forward, no data
                else dlv_kick <= 1;             // deliver current sector
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
            4'h1: begin msf_lba <= head[31] ? (~head + 1'b1) : head; msf_start <= 1; rpt_st <= 3'd2; end
            4'h3: begin msf_lba <= leadout_lba + 32'd150; msf_start <= 1; rpt_st <= 3'd2; end
            4'h2: begin n1 <= 4'h2; n2 <= 0; n3 <= 1; n4 <= 0; n5 <= 0; n6 <= 0; n7 <= 0; n8 <= 0; rpt_st <= 3'd4; end
            4'h4: begin n1 <= 4'h4; n2 <= 0; n3 <= 1; n4 <= 0; n5 <= 1; n6 <= 0; n7 <= 0; n8 <= 0; rpt_st <= 3'd4; end
            4'h5: begin msf_lba <= 32'd150; msf_start <= 1; rpt_st <= 3'd3; end
            default: rpt_st <= 3'd4; // keep last payload
            endcase
        end
        3'd2: if (msf_done) begin // MSF payload (types 0/1/3)
            n1 <= rs_type;
            n2 <= msf_m10; n3 <= msf_m1;
            n4 <= msf_s10; n5 <= msf_s1;
            n6 <= msf_f10; n7 <= msf_f1;
            n8 <= (rs_type == 4'h0 && disc_present) ? 4'h4 : 4'h0; // data-track flag
            rpt_st <= 3'd4;
        end
        3'd3: if (msf_done) begin // track-1 start (type 5): data flag in n6 bit3
            n1 <= 4'h5;
            n2 <= msf_m10; n3 <= msf_m1;
            n4 <= msf_s10; n5 <= msf_s1;
            n6 <= msf_f10 | 4'h8; n7 <= msf_f1;
            n8 <= 4'h1;   // track number (BCD units)
            rpt_st <= 3'd4;
        end
        3'd4: begin frame_go <= 1; rpt_st <= 3'd0; end
        default: ;
        endcase

        // command handling: immediate reply nibbles per megacdd.cpp/GPGX
        if (cdd_send & ~send_d) begin
            case (c0)
                4'h0: begin                   // DRIVE STATUS
                    n0 <= drv_status;
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
                        n0 <= STAT_SEEK; n1 <= 0; zeros;
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
                        n0 <= STAT_SEEK; n1 <= 0; zeros;
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
