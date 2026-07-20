// CDD (CD-drive microcontroller) stand-in for an empty drive, modeled on
// MiSTer Main's megacdd.cpp with no disc loaded. Fixed 75Hz status beat
// (immediate replies chain with the BIOS INT4 handler into a kHz storm);
// commands update state only. Full 9-nibble payloads with a checksum over
// n0..n8 — the BIOS validates TOC replies and spins on its busy flag if
// they are malformed (found via live PRG-RAM disassembly of the wait loop).
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
localparam [3:0] STAT_TOC     = 4'h9;
localparam [3:0] STAT_NO_DISC = 4'hB;

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

// empty-disc MSF for lba 150 = 00:02:00
task abs150; begin
    n2 <= 0; n3 <= 0; n4 <= 0; n5 <= 4'd2; n6 <= 0; n7 <= 0;
end endtask
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

        // empty tray: every state drains to NO_DISC after its latency
        if (drv_status != STAT_NO_DISC) begin
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
                4'h0: begin                   // IDLE: refresh current report
                    n0 <= drv_status;
                    case (n1)
                        4'h0: begin abs150; n8 <= 0; end
                        4'h1: zeros;
                        4'h2: begin n2 <= 4'hA; n3 <= 4'hA; n4 <= 0; n5 <= 0;
                                    n6 <= 0; n7 <= 0; n8 <= 0; end
                        default: ;
                    endcase
                end
                4'h1: begin                   // STOP
                    drv_status <= STAT_STOP;
                    latency <= 4'd0;
                    n0 <= STAT_STOP; n1 <= 0; zeros;
                end
                4'h2: begin                   // Read TOC, format in comm n3
                    if (drv_status == STAT_STOP) begin
                        drv_status <= STAT_TOC;
                        latency <= 4'd2;
                        n0 <= STAT_TOC;
                    end else begin
                        n0 <= drv_status;
                    end
                    n1 <= cdd_comm[15:12];
                    case (cdd_comm[15:12])
                        4'h0: begin abs150; n8 <= 0; end                  // abs position
                        4'h1: zeros;                                       // rel position
                        4'h2: begin n2 <= 4'hA; n3 <= 4'hA; n4 <= 0;       // track: lead-out
                                    n5 <= 0; n6 <= 0; n7 <= 0; n8 <= 0; end
                        4'h3: begin abs150; n8 <= 0; end                  // disc length
                        4'h4: begin n2 <= 0; n3 <= 4'd1; n4 <= 0; n5 <= 0; // first=01 last=00
                                    n6 <= 0; n7 <= 0; n8 <= 0; end
                        4'h5: begin abs150; n8 <= cdd_comm[23:20]; end     // track start
                        default: zeros;
                    endcase
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
