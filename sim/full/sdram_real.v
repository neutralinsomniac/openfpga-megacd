// Real-controller SDRAM simulation: wraps the actual rtl/megacd/sdram.sv
// (sed-renamed to sdram_ctrl, altddio stripped) around a behavioral
// MT48LC16M16-style chip model, so the true 3-port arbitration, refresh
// timing, and request handshake run in simulation. Drop-in replacement for
// sdram_sim.v (same `sdram` module interface); select with REALSD=1 in
// build.sh. Preload with +bios=<hex> ($readmemh, linear word addresses).

module sdram
(
    inout      [15:0] SDRAM_DQ,
    output     [12:0] SDRAM_A,
    output            SDRAM_DQML,
    output            SDRAM_DQMH,
    output      [1:0] SDRAM_BA,
    output            SDRAM_nCS,
    output            SDRAM_nWE,
    output            SDRAM_nRAS,
    output            SDRAM_nCAS,
    output            SDRAM_CLK,
    output            SDRAM_CKE,

    input             init,
    input             clk,

    input      [24:1] addr0,
    input             rd0, wrl0, wrh0,
    input      [15:0] din0,
    output     [15:0] dout0,
    output            busy0,

    input      [24:1] addr1,
    input             rd1, wrl1, wrh1,
    input      [15:0] din1,
    output     [15:0] dout1,
    output            busy1,

    input      [24:1] addr2,
    input             rd2, wrl2, wrh2,
    input      [15:0] din2,
    output     [15:0] dout2,
    output            busy2
);

wire [15:0] dq_c2m;   // controller -> memory (write data)
wire [15:0] dq_m2c;   // memory -> controller (read data)

sdram_ctrl ctrl
(
    .SDRAM_DQ(dq_c2m), .SDRAM_DQ_IN(dq_m2c), .SDRAM_DQ_OE(), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML),
    .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
    .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_CLK(), .SDRAM_CKE(SDRAM_CKE),
    .init(init), .clk(clk),
    .addr0(addr0), .rd0(rd0), .wrl0(wrl0), .wrh0(wrh0), .din0(din0), .dout0(dout0), .busy0(busy0),
    .addr1(addr1), .rd1(rd1), .wrl1(wrl1), .wrh1(wrh1), .din1(din1), .dout1(dout1), .busy1(busy1),
    .addr2(addr2), .rd2(rd2), .wrl2(wrl2), .wrh2(wrh2), .din2(din2), .dout2(dout2), .busy2(busy2)
);

sdram_chip chip
(
    .clk(clk), .dq_i(dq_c2m), .dq_o(dq_m2c), .a(SDRAM_A), .ba(SDRAM_BA),
    .ncs(SDRAM_nCS), .nras(SDRAM_nRAS), .ncas(SDRAM_nCAS), .nwe(SDRAM_nWE),
    .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH)
);

assign SDRAM_CLK = clk;
assign SDRAM_DQ = dq_c2m;

endmodule

// Behavioral SDRAM device: single-clock, CL=3, burst length 1, honors
// ACTIVE/READ/WRITE/DQM; refresh and precharge are accepted as no-ops.
module sdram_chip
(
    input             clk,
    input      [15:0] dq_i,
    output     [15:0] dq_o,
    input      [12:0] a,
    input       [1:0] ba,
    input             ncs, nras, ncas, nwe,
    input             dqml, dqmh
);

// 2^24 x 16 = 32MB
reg [15:0] mem [0:16777215];
initial begin : preload
    reg [1023:0] biosf;
    if ($value$plusargs("bios=%s", biosf)) $readmemh(biosf, mem);
end

localparam CMD_ACTIVE = 3'b011;
localparam CMD_READ   = 3'b101;
localparam CMD_WRITE  = 3'b100;

wire [2:0] cmd = {nras, ncas, nwe};

// +sdlog=<start_cycle>: dump commands from that chip-clock cycle on
integer cyc = 0;
integer logfrom = -1;
initial begin : logarg
    reg [63:0] v;
    if ($value$plusargs("sdlog=%d", v)) logfrom = v;
end

reg [12:0] row [0:3];

// linear word address = {ba, col[8:0], row[12:0]} (matches the controller's
// {ba,a}<=addr split: row=a[13:1], col=a[22:14])
wire [23:0] rd_word = {ba, a[8:0], row[ba]};
wire [23:0] wr_word = {ba, a[8:0], row[ba]};

// CL=3: READ sampled at edge N -> drive data during cycle N+2 -> controller
// (whose state counter is 3 ahead of our sampling) latches it at STATE_READY
reg [15:0] pipe_d0, pipe_d1;
reg        pipe_v0, pipe_v1, drive;
reg [15:0] dout;

always @(posedge clk) begin
    cyc <= cyc + 1;
    if (!ncs) begin
        case (cmd)
            CMD_ACTIVE: row[ba] <= a;
            CMD_READ:   begin pipe_d0 <= mem[rd_word]; pipe_v0 <= 1; end
            CMD_WRITE:  begin
                if (!dqml) mem[wr_word][7:0]  <= dq_i[7:0];
                if (!dqmh) mem[wr_word][15:8] <= dq_i[15:8];
            end
            default: ;
        endcase
        if (logfrom >= 0 && cyc >= logfrom && cyc < logfrom + 4000) begin
            case (cmd)
                CMD_ACTIVE: $display("SD[%0d] ACT  ba=%0d row=%03x", cyc, ba, a);
                CMD_READ:   $display("SD[%0d] RD   ba=%0d col=%03x word=%06x -> %04x", cyc, ba, a[8:0], rd_word, mem[rd_word]);
                CMD_WRITE:  $display("SD[%0d] WR   ba=%0d col=%03x word=%06x <= %04x dqm=%b%b", cyc, ba, a[8:0], wr_word, dq_i, dqmh, dqml);
                default: ;
            endcase
        end
    end
    if (cmd != CMD_READ || ncs) pipe_v0 <= 0;
    pipe_d1 <= pipe_d0; pipe_v1 <= pipe_v0;
    dout    <= pipe_d1; drive   <= pipe_v1;
end

assign dq_o = dout;

endmodule
