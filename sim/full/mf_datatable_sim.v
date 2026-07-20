// Behavioral stub for the APF data-slot table (256 x 32 dual-port BRAM),
// replacing the Altera altsyncram-backed apf/mf_datatable.v. The full-system
// sim preloads SDRAM directly and does not depend on the slot table.
module mf_datatable (
    input  [7:0]  address_a, input [7:0] address_b,
    input         clock_a, input clock_b,
    input  [31:0] data_a,  input [31:0] data_b,
    input         wren_a,  input wren_b,
    output reg [31:0] q_a, output reg [31:0] q_b
);
    reg [31:0] mem [0:255];
    always @(posedge clock_a) begin if(wren_a) mem[address_a]<=data_a; q_a<=mem[address_a]; end
    always @(posedge clock_b) begin if(wren_b) mem[address_b]<=data_b; q_b<=mem[address_b]; end
endmodule
