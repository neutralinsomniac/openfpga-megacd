// Minimal CDD (CD-drive microcontroller) stand-in for M1 bring-up.
// Reports "no disc" status so the BIOS can boot to its menu without a drive.
// Replaced by the real drive-emulation MPU in M2.
//
// CDD status packet: 10 nibbles n0..n9, n0 = status code (0xB = no disc),
// n9 = checksum = ~(n0+..+n8) & 0xF. Nibble n0 sits in bits [3:0].
module megacd_cdd_stub
(
    input             clk,
    input             reset,
    input             mcd_rst_n,    // ERES_N from MCD; low re-arms the initial packet
    input      [39:0] cdd_comm,
    input             cdd_send,
    output reg [39:0] cdd_stat,
    output reg        cdd_rec,
    output reg        cdd_dm
);

localparam [3:0] STAT_NODISC = 4'hB;
wire [3:0] csum = ~STAT_NODISC & 4'hF;
wire [39:0] STAT_PACKET = {csum, 32'h0, STAT_NODISC};

// 53.693175 MHz / 715909 ~= 75 Hz periodic status refresh
localparam [19:0] TICK_75HZ = 20'd715908;

reg [19:0] tick = 0;
reg        send_d = 0;
reg  [3:0] rec_cnt = 0;

always @(posedge clk) begin
    if (reset | ~mcd_rst_n) begin
        cdd_stat <= 40'hFFFFFFFFFF;
        cdd_dm   <= 0;
        cdd_rec  <= 0;
        tick     <= 0;
        rec_cnt  <= 0;
        send_d   <= 0;
    end else begin
        send_d <= cdd_send;
        tick   <= (tick == TICK_75HZ) ? 20'd0 : tick + 1'b1;

        if ((cdd_send & ~send_d) || tick == TICK_75HZ) begin
            cdd_stat <= STAT_PACKET;
            cdd_rec  <= 1;
            rec_cnt  <= 4'd8;
        end else if (rec_cnt != 0) begin
            rec_cnt <= rec_cnt - 1'b1;
        end else begin
            cdd_rec <= 0;
        end
    end
end

endmodule
