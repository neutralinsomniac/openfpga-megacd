// Minimal CDD (CD-drive microcontroller) stand-in for M1 bring-up.
// Models MiSTer Main's megacdd.cpp behavior with no disc mounted:
//  - after the MCD resets, the drive reports STOP (packet {0,..,0, csum F})
//  - each command from the gate array gets one status reply
//  - IDLE echoes the current drive status; TOC commands answer with the
//    requested format echoed in n1 and status TOC; everything else zeroes
// Replaced by the real drive-emulation MPU in M2.
//
// Packet layout (matches ASIC.vhd and megacdd.cpp GetStatus): ten nibbles
// n0..n9, n0 = drive status in bits [3:0], n9 = checksum in bits [39:36],
// checksum n9 = ~(n0+..+n8) & 0xF.
module megacd_cdd_stub
(
    input             clk,
    input             reset,
    input             mcd_rst_n,    // ERES_N from MCD; low re-arms
    input      [39:0] cdd_comm,
    input             cdd_send,
    output reg [39:0] cdd_stat,
    output reg        cdd_rec,
    output reg        cdd_dm
);

localparam [3:0] STAT_STOP = 4'h0;
localparam [3:0] STAT_TOC  = 4'h9;

reg  [3:0] drv_status = STAT_STOP;
reg  [3:0] n0, n1;
wire [3:0] csum = ~(n0 + n1) & 4'hF;   // n2..n8 are always 0 in this stub

// ~100ms watchdog: if the BIOS<->CDD interrupt loop stalls, re-send the
// current status to fire INT4 again (real drives stream at 75Hz anyway)
localparam [22:0] WDOG = 23'd5369317;

reg [22:0] wdog = 0;
reg [12:0] delay = 0;      // ~150us command-to-reply latency
reg        pending = 0;
reg        send_d = 0;
reg  [3:0] rec_cnt = 0;

always @(posedge clk) begin
    if (reset | ~mcd_rst_n) begin
        drv_status <= STAT_STOP;
        n0 <= STAT_STOP;
        n1 <= 4'h0;
        cdd_stat <= {4'hF, 36'h0};   // STOP packet, checksum F
        cdd_dm   <= 0;
        cdd_rec  <= 0;
        wdog     <= 0;
        delay    <= 0;
        pending  <= 0;
        rec_cnt  <= 0;
        send_d   <= 0;
    end else begin
        send_d <= cdd_send;
        wdog   <= wdog + 1'b1;

        if (cdd_send & ~send_d) begin
            // command nibble c0 in bits [3:0], TOC format c3 in bits [15:12]
            case (cdd_comm[3:0])
                4'h0: begin                   // IDLE: report current status
                    n0 <= drv_status;
                    n1 <= 4'h0;
                end
                4'h1: begin                   // STOP
                    drv_status <= STAT_STOP;
                    n0 <= STAT_STOP;
                    n1 <= 4'h0;
                end
                4'h2: begin                   // Read TOC: echo format, go TOC
                    drv_status <= STAT_TOC;
                    n0 <= STAT_TOC;
                    n1 <= cdd_comm[15:12];
                end
                default: begin
                    n0 <= drv_status;
                    n1 <= 4'h0;
                end
            endcase
            pending <= 1;
            delay   <= 13'd8000;
        end

        if (pending) begin
            if (delay != 0) begin
                delay <= delay - 1'b1;
            end else begin
                cdd_stat <= {csum, 20'h0, 8'h0, n1, n0};
                cdd_rec  <= 1;
                rec_cnt  <= 4'd8;
                pending  <= 0;
                wdog     <= 0;
            end
        end else if (wdog == WDOG) begin
            cdd_stat <= {csum, 20'h0, 8'h0, n1, n0};
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

endmodule
