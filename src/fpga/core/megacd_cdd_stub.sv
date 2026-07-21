// CDD (CD-drive microcontroller) stand-in for an empty drive. Fixed 75Hz
// status beat (immediate replies chain with the BIOS INT4 handler into a
// kHz storm); commands update state only. Full 9-nibble payloads with a
// checksum over n0..n8.
//
// No-disc model (GPGX cdd.c, verified in sim/m2 cosim): status drains
// STOP->NO_DISC(B) once and STAYS there. ReadTOC must NOT switch to TOC(9)
// or fabricate TOC entries — a fake TOC makes the BIOS front end believe a
// disc is present and command play (player mode 8), which parks the sub in
// the $7302 subcode-wait retry loop = the CD-player freeze. With status B
// and zeroed TOC payloads the sub BIOS boots clean and reports NO_DISC in
// its CDBSTAT block for the front end to display.
//
// Packet: nibbles n0..n9; n0 = status in bits [3:0]; n9 = ~(sum n0..n8)&F.
module megacd_cdd_stub
(
    input             clk,
    input             reset,
    input             mcd_rst_n,
    input      [39:0] cdd_comm,
    input             cdd_send,
    output reg [39:0] cdd_stat,
    output reg        cdd_rec,
    output reg        cdd_dm
);

localparam [3:0] STAT_STOP    = 4'h0;
localparam [3:0] STAT_NO_DISC = 4'hB;
localparam [3:0] STAT_OPEN    = 4'h5;

localparam [25:0] BEAT = 26'd715909;      // 13.3ms @ 53.693175MHz
localparam [19:0] TICK_13MS = 20'd698010; // drain-to-NO_DISC tick

reg [19:0] ms_tick = 0;
reg  [3:0] latency = 4'd10;

reg  [3:0] drv_status = STAT_STOP;
reg  [3:0] n0, n1, n2, n3, n4, n5, n6, n7, n8;
wire [3:0] csum = ~(n0 + n1 + n2 + n3 + n4 + n5 + n6 + n7 + n8) & 4'hF;

reg [25:0] wdog = 0;
reg        send_d = 0;
reg  [3:0] rec_cnt = 0;

task zeros; begin
    n2 <= 0; n3 <= 0; n4 <= 0; n5 <= 0; n6 <= 0; n7 <= 0; n8 <= 0;
end endtask

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
    end else begin
        send_d <= cdd_send;
        wdog   <= wdog + 1'b1;

        // STOP/OPEN/TRAY drain to NO_DISC after the latency ticks run out
        // (megacdd.cpp Update() semantics — the door-open report is a
        // transient reply, not a resting state).
        if (drv_status == STAT_STOP || drv_status == STAT_OPEN) begin
            if (ms_tick == TICK_13MS) begin
                ms_tick <= 0;
                if (latency != 0) latency <= latency - 1'b1;
                else drv_status <= STAT_NO_DISC;
            end else begin
                ms_tick <= ms_tick + 1'b1;
            end
        end

        if (cdd_send & ~send_d) begin
            case (cdd_comm[3:0])
                // Exact megacdd.cpp reply semantics: the kernel keys on each
                // command's IMMEDIATE reply nibble; internal state drains to
                // NO_DISC on later ticks. STOP must reply STOP, not NO_DISC —
                // an unexpected reply reads as a failed drive op and restarts
                // the kernel STOP/OPEN churn that gates all player-screen
                // input ("operation in progress").
                4'h1: begin                   // STOP: reply STOP
                    drv_status <= STAT_STOP;
                    latency <= 4'd0;
                    n0 <= STAT_STOP; n1 <= 0; zeros;
                end
                4'h2: begin                   // Read TOC: status only, no data
                    n0 <= drv_status;
                    n1 <= cdd_comm[15:12];
                    zeros;
                end
                // OPEN TRAY: the no-disc player parks in "door open, waiting
                // for a disc" — without this reply the kernel drive task
                // retries OPEN/STOP forever, CDBSTAT never settles out of
                // "operation in progress" ($40xx oscillating), and the UI
                // (correctly) ignores all input = the dead-cursor bug.
                4'hD: begin                   // OPEN TRAY: reply OPEN
                    drv_status <= STAT_OPEN;
                    latency <= 4'd0;
                    n0 <= STAT_OPEN; n1 <= 0; zeros;
                end
                4'hC: begin                   // CLOSE TRAY: reply STOP, no disc
                    drv_status <= STAT_NO_DISC;
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
        end else if (rec_cnt != 0) begin
            rec_cnt <= rec_cnt - 1'b1;
        end else begin
            cdd_rec <= 0;
        end
    end
end

endmodule
