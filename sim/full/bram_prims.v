// Parameterized Verilog RAM primitives for the SV-side instantiations
// (gen.sv, megacd_top.sv) that Verilator sees directly. VHDL port defaults
// (enable=1, cs=1) don't exist in Verilog, and the SV never drives them, so
// these models ignore enable/cs (always enabled). Registered read.

module dpram #(parameter addr_width=8, parameter data_width=8, parameter mem_init_file="") (
    input wire clock,
    input wire [addr_width-1:0] address_a,
    input wire [data_width-1:0] data_a,
    input wire enable_a, input wire wren_a, input wire cs_a,
    output reg [data_width-1:0] q_a,
    input wire [addr_width-1:0] address_b,
    input wire [data_width-1:0] data_b,
    input wire enable_b, input wire wren_b, input wire cs_b,
    output reg [data_width-1:0] q_b
);
    reg [data_width-1:0] mem [0:(1<<addr_width)-1];
    always @(posedge clock) begin
        if (wren_a) mem[address_a] <= data_a;
        q_a <= mem[address_a];
    end
    always @(posedge clock) begin
        if (wren_b) mem[address_b] <= data_b;
        q_b <= mem[address_b];
    end
endmodule

module dpram_dif #(parameter addr_width_a=8, parameter data_width_a=8,
                   parameter addr_width_b=8, parameter data_width_b=8,
                   parameter mem_init_file="") (
    input wire clock,
    input wire [addr_width_a-1:0] address_a,
    input wire [data_width_a-1:0] data_a,
    input wire enable_a, input wire wren_a, input wire cs_a,
    output reg [data_width_a-1:0] q_a,
    input wire [addr_width_b-1:0] address_b,
    input wire [data_width_b-1:0] data_b,
    input wire enable_b, input wire wren_b, input wire cs_b,
    output reg [data_width_b-1:0] q_b
);
    // model as a byte-granular store sized by the narrow (A) view
    localparam RATIO = data_width_b / data_width_a;
    reg [data_width_a-1:0] mem [0:(1<<addr_width_a)-1];
    integer i;

    // +brm=<file> preloads the 8KB internal backup RAM (the only dpram_dif
    // with this shape -- see megacd_top's `backup_ram`). Games that keep save
    // data refuse to run past their title/BRAM-check screen against an
    // unformatted one, so the co-sim cannot reach in-game content without it.
    // Sim-only: this file is not synthesised.
    reg [1023:0] brm_file;
    initial begin
        if (addr_width_a == 13 && data_width_a == 8 &&
            addr_width_b == 12 && data_width_b == 16) begin
            if ($value$plusargs("brm=%s", brm_file)) begin
                $readmemh(brm_file, mem);
                $display("[bram] preloaded backup RAM from +brm");
            end
        end
    end
    always @(posedge clock) begin
        if (wren_a) mem[address_a] <= data_a;
        q_a <= mem[address_a];
    end
    always @(posedge clock) begin
        for (i=0;i<RATIO;i=i+1) begin
            if (wren_b) mem[address_b*RATIO + i] <= data_b[(RATIO-1-i)*data_width_a +: data_width_a];
            q_b[(RATIO-1-i)*data_width_a +: data_width_a] <= mem[address_b*RATIO + i];
        end
    end
endmodule

module spram #(parameter addr_width=8, parameter data_width=8,
               parameter mem_init_file="", parameter mem_name="MEM") (
    input wire clock,
    input wire [addr_width-1:0] address,
    input wire [data_width-1:0] data,
    input wire enable, input wire wren,
    output reg [data_width-1:0] q,
    input wire cs
);
    reg [data_width-1:0] mem [0:(1<<addr_width)-1];
    always @(posedge clock) begin
        if (wren) mem[address] <= data;
        q <= mem[address];
    end
endmodule
