// Behavioral Verilog RAM models matching the yosys-mangled blackbox names,
// for the M2 Verilator co-sim. Registered read, write-through on port A.

module dpram_Bsim_16_8_b858cb282617fb0956d960215c8e84d1ccf909c6
(
    input             clock,
    input      [15:0] address_a,
    input      [7:0]  data_a,
    input             enable_a,
    input             wren_a,
    input             cs_a,
    input      [15:0] address_b,
    input      [7:0]  data_b,
    input             enable_b,
    input             wren_b,
    input             cs_b,
    output reg [7:0]  q_a,
    output reg [7:0]  q_b
);
    reg [7:0] mem [0:65535];
    always @(posedge clock) if (enable_a) begin
        if (wren_a) mem[address_a] <= data_a;
        q_a <= mem[address_a];
    end
    always @(posedge clock) if (enable_b) begin
        if (wren_b) mem[address_b] <= data_b;
        q_b <= mem[address_b];
    end
endmodule

// CDC buffer: port A 14-bit addr / 8-bit, port B 13-bit addr / 16-bit
module dpram_dif_Bsim_14_8_13_16_b858cb282617fb0956d960215c8e84d1ccf909c6
(
    input             clock,
    input      [13:0] address_a,
    input      [7:0]  data_a,
    input             enable_a,
    input             wren_a,
    input             cs_a,
    input      [12:0] address_b,
    input      [15:0] data_b,
    input             enable_b,
    input             wren_b,
    input             cs_b,
    output reg [7:0]  q_a,
    output reg [15:0] q_b
);
    reg [7:0] mem [0:16383];
    always @(posedge clock) if (enable_a) begin
        if (wren_a) mem[address_a] <= data_a;
        q_a <= mem[address_a];
    end
    // port B big-endian word view over two bytes
    always @(posedge clock) if (enable_b) begin
        if (wren_b) begin
            mem[{address_b,1'b0}] <= data_b[15:8];
            mem[{address_b,1'b1}] <= data_b[7:0];
        end
        q_b <= {mem[{address_b,1'b0}], mem[{address_b,1'b1}]};
    end
endmodule
