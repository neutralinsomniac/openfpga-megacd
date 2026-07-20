// Behavioral SDRAM for the full-system co-sim: same 3-port word interface
// as core/rtl/megacd/sdram.sv, backed by a plain memory (no dram pins /
// JEDEC protocol). ~10-cycle latency handshake (busyN low->high per access,
// matching the req/complete protocol the core expects). Preloadable via
// $readmemh(SDRAM_INIT) — load the BIOS at word $780000 (byte $F00000).
module sdram #(parameter INIT="") (
    inout  [15:0] SDRAM_DQ, output [12:0] SDRAM_A, output SDRAM_DQML,
    output SDRAM_DQMH, output [1:0] SDRAM_BA, output SDRAM_nCS,
    output SDRAM_nWE, output SDRAM_nRAS, output SDRAM_nCAS,
    output SDRAM_CLK, output SDRAM_CKE,
    input init, input clk,
    input [24:1] addr0, input rd0, input wrl0, input wrh0, input [15:0] din0,
    output reg [15:0] dout0, output busy0,
    input [24:1] addr1, input rd1, input wrl1, input wrh1, input [15:0] din1,
    output reg [15:0] dout1, output busy1,
    input [24:1] addr2, input rd2, input wrl2, input wrh2, input [15:0] din2,
    output reg [15:0] dout2, output busy2
);
    assign {SDRAM_DQ,SDRAM_A,SDRAM_DQML,SDRAM_DQMH,SDRAM_BA,SDRAM_nCS,
            SDRAM_nWE,SDRAM_nRAS,SDRAM_nCAS,SDRAM_CLK,SDRAM_CKE} = 0;

    // 32Mword (64MB) address space, word-addressed
    reg [15:0] mem [0:(1<<24)-1];
    initial if (INIT!="") $readmemh(INIT, mem);

    localparam LAT = 10;
    reg [3:0] b0=0,b1=0,b2=0;
    reg r0=0,r1=0,r2=0;

    // per-port edge-triggered access with latency
    task do_port(input [24:1] a, input rd, input wrl, input wrh,
                 input [15:0] din, inout reg act, inout reg [3:0] busy,
                 output reg [15:0] dout, input do_edge);
    begin end endtask

    reg pr0=0,pr1=0,pr2=0; // prior request level

    always @(posedge clk) begin
        // port 0
        if (!b0 && !r0 && (rd0|wrl0|wrh0) && !(pr0)) begin
            r0<=1; b0<=LAT;
            if (wrl0) mem[addr0][7:0]  <= din0[7:0];
            if (wrh0) mem[addr0][15:8] <= din0[15:8];
        end else if (r0) begin
            if (b0>1) b0<=b0-1; else begin r0<=0; b0<=0; dout0<=mem[addr0]; end
        end
        pr0 <= (rd0|wrl0|wrh0);

        if (!b1 && !r1 && (rd1|wrl1|wrh1) && !pr1) begin
            r1<=1; b1<=LAT;
            if (wrl1) mem[addr1][7:0]  <= din1[7:0];
            if (wrh1) mem[addr1][15:8] <= din1[15:8];
        end else if (r1) begin
            if (b1>1) b1<=b1-1; else begin r1<=0; b1<=0; dout1<=mem[addr1]; end
        end
        pr1 <= (rd1|wrl1|wrh1);

        if (!b2 && !r2 && (rd2|wrl2|wrh2) && !pr2) begin
            r2<=1; b2<=LAT;
            if (wrl2) mem[addr2][7:0]  <= din2[7:0];
            if (wrh2) mem[addr2][15:8] <= din2[15:8];
        end else if (r2) begin
            if (b2>1) b2<=b2-1; else begin r2<=0; b2<=0; dout2<=mem[addr2]; end
        end
        pr2 <= (rd2|wrl2|wrh2);
    end
    assign busy0 = r0, busy1 = r1, busy2 = r2;
endmodule
