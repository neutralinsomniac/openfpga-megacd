//
// sdram.v
//
// sdram controller implementation
// Copyright (c) 2018 Sorgelig
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//

module sdram
(

	// interface to the MT48LC16M16 chip
	inout  reg [15:0] SDRAM_DQ,   // 16 bit bidirectional data bus
	output reg [12:0] SDRAM_A,    // 13 bit multiplexed address bus
	output reg        SDRAM_DQML, // byte mask
	output reg        SDRAM_DQMH, // byte mask
	output reg  [1:0] SDRAM_BA,   // two banks
	output            SDRAM_nCS,  // a single chip select
	output reg        SDRAM_nWE,  // write enable
	output reg        SDRAM_nRAS, // row address select
	output reg        SDRAM_nCAS, // columns address select
	output            SDRAM_CLK,
	output            SDRAM_CKE,

	// cpu/chipset interface
	input             init,			// init signal after FPGA config to initialize RAM
	input             clk,			// sdram is accessed at up to 128MHz

	input      [24:1] addr0,
	input             rd0,
	input             wrl0,
	input             wrh0,
	input      [15:0] din0,
	output     [15:0] dout0,
	output            busy0,
	
	input      [24:1] addr1,
	input             rd1,
	input             wrl1,
	input             wrh1,
	input      [15:0] din1,
	output     [15:0] dout1,
	output            busy1,
	
	input      [24:1] addr2,
	input             rd2,
	input             wrl2,
	input             wrh2,
	input      [15:0] din2,
	output     [15:0] dout2,
	output            busy2
);

assign SDRAM_nCS = 0;
assign SDRAM_CKE = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];

localparam RASCAS_DELAY   = 3'd3; // Pocket SDRAM needs tRCD=3 cycles @107MHz (matches the Genesis core's tuned controller)
localparam BURST_LENGTH   = 3'd0; // 0=1, 1=2, 2=4, 3=8, 7=full page
localparam ACCESS_TYPE    = 1'd0; // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd3; // CL3 @107MHz on the Pocket (matches the Genesis core's tuned controller)
localparam OP_MODE        = 2'd0; // only 0 (standard operation) allowed
localparam NO_WRITE_BURST = 1'd1; // 0=write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH}; 

// Open-row (page-mode) access engine. The original controller issued
// ACTIVATE + auto-precharge around every single access (~9 cycles flat);
// boot profiling showed the MCD word-RAM/GFX path paying ~150 clk_sys per
// word and the sub-CPU ~50 per fetch, throttling the BIOS boot animations
// to a ~7fps render rate. Rows now stay open per bank and row hits issue
// CAS only; refresh precharges all banks first. Timing @107MHz: tRCD=3,
// CL=3, tRP=3, tRFC via DLY_REF.
localparam [3:0] DLY_RP  = 4'd2;  // PRECHARGE -> ACTIVATE
localparam [3:0] DLY_RCD = 4'd2;  // ACTIVATE -> CAS
localparam [3:0] DLY_CL  = 4'd3;  // CAS -> data latch
localparam [3:0] DLY_REF = 4'd8;  // AUTO_REFRESH recovery (tRFC)

localparam [2:0] FSM_IDLE = 3'd0;
localparam [2:0] FSM_PRE  = 3'd1;
localparam [2:0] FSM_ACT  = 3'd2;
localparam [2:0] FSM_CAS  = 3'd3;
localparam [2:0] FSM_PALL = 3'd4;
localparam [2:0] FSM_REF  = 3'd5;
localparam [2:0] FSM_GRANT= 3'd6;

// init-sequence cycle counter (MODE_RESET/LDM/PRE phases only)
localparam STATE_IDLE  = 4'd0;
localparam STATE_START = 4'd1;
localparam STATE_LAST  = 4'd8;

reg  [3:0] state;
reg  [2:0] fsm = FSM_IDLE;
reg  [3:0] dly;
reg [22:1] a;
reg [15:0] data;
reg        we;
reg  [1:0] ba = 0;
reg  [1:0] dqm;
reg  [2:0] ram_req = 0;

reg [12:0] open_row [0:3];
reg  [3:0] row_open = 0;

// Strobe retiming: the request strobes come from the half-rate system
// clock and are edge-detected here; the address/data they qualify launch
// in the same system cycle, so grant() must never fire off the very first
// RAM-clock edge after a strobe changes (the address may still be in
// flight — this was a real -1.9ns setup violation and the source of the
// random boot-time corruption). One capture stage delays edge detection a
// full RAM cycle; addr/din stay direct and are covered by the sys->ram
// multicycle-2 constraint in core_constraints.sdc.
reg [2:0] rd_q = 0, wrl_q = 0, wrh_q = 0;
always @(posedge clk) begin
	rd_q  <= {rd2,  rd1,  rd0};
	wrl_q <= {wrl2, wrl1, wrl0};
	wrh_q <= {wrh2, wrh1, wrh0};
end
wire [2:0] wr = wrl_q | wrh_q;
wire [2:0] rd = rd_q;

// per-port read-data latches: a single shared dout register let any later
// port's completion clobber a value before its requester consumed it
// (requesters sample 1-2 clocks after busy falls) — random corruption
// under concurrent load. Latch each port's data at its own completion.
reg [15:0] dout0_r, dout1_r, dout2_r;

assign dout0 = dout0_r;
assign dout1 = dout1_r;
assign dout2 = dout2_r;

localparam [9:0] RFS_CNT = 766;

localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

localparam MODE_NORMAL = 2'b00;
localparam MODE_RESET  = 2'b01;
localparam MODE_LDM    = 2'b10;
localparam MODE_PRE    = 2'b11;

// initialization
reg [1:0] mode;
reg [4:0] reset=5'h1f;
always @(posedge clk) begin
	reg init_old=0;
	init_old <= init;

	if(init_old & ~init) reset <= 5'h1f;
	else if(state == STATE_LAST) begin
		if(reset != 0) begin
			reset <= reset - 5'd1;
			if(reset == 14)     mode <= MODE_PRE;
			else if(reset == 3) mode <= MODE_LDM;
			else                mode <= MODE_RESET;
		end
		else mode <= MODE_NORMAL;
	end
end

// access manager + command generator (single engine)
task do_cas(input [1:0] tba, input [22:1] ta, input [15:0] tdin, input twe, input [1:0] tdqm);
begin
	{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= twe ? CMD_WRITE : CMD_READ;
	if (twe) SDRAM_DQ <= tdin;
	SDRAM_BA <= tba;
	SDRAM_A  <= {tdqm, 2'b00, ta[22:14]};
	dly <= DLY_CL;
	fsm <= FSM_CAS;
end
endtask

task do_act(input [1:0] tba, input [22:1] ta);
begin
	{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_ACTIVE;
	SDRAM_BA <= tba;
	SDRAM_A  <= ta[13:1];
	open_row[tba] <= ta[13:1];
	row_open[tba] <= 1'b1;
	dly <= DLY_RCD;
	fsm <= FSM_ACT;
end
endtask

task do_pre(input [1:0] tba);
begin
	{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;
	SDRAM_BA <= tba;
	SDRAM_A  <= 13'b0000000000000;
	dly <= DLY_RP;
	fsm <= FSM_PRE;
end
endtask

// grant only LATCHES the winning request; the first SDRAM command is
// issued from the registered copy one cycle later (FSM_GRANT). Keeping
// the strobe edge-detect + 3-port priority + row compare + command mux
// out of a single cycle is what closes timing to the pin-bound IOE
// registers at high device utilization (was -0.45ns reg->pin).
task grant(input [2:0] idx, input [24:1] taddr, input [15:0] tdin, input twr, input [1:0] tmask);
begin
	{ba, a} <= taddr;
	data <= tdin;
	we   <= twr;
	dqm  <= twr ? ~tmask : 2'b00;
	ram_req <= idx;
	fsm <= FSM_GRANT;
end
endtask

always @(posedge clk) begin
	reg [9:0] rfs_timer = 0;
	reg [2:0] old_rd, old_wr;

	old_rd <= old_rd & rd;
	old_wr <= old_wr & wr;

	if(rfs_timer) rfs_timer <= rfs_timer - 1'd1;

	SDRAM_DQ <= 'Z;
	{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_NOP;

	if (mode != MODE_NORMAL) begin
		// init sequencer (original command pattern)
		state <= state + 1'd1;
		if(state == STATE_LAST) state <= STATE_IDLE;
		row_open <= 0;
		fsm <= FSM_IDLE;
		ram_req <= 0;
		if (state == STATE_START) begin
			SDRAM_BA <= 2'b00;
			if (mode == MODE_LDM) begin
				{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_LOAD_MODE;
				SDRAM_A <= MODE;
			end
			else if (mode == MODE_PRE) begin
				{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;
				SDRAM_A <= 13'b0010000000000;
			end
			else begin
				{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_AUTO_REFRESH;
				SDRAM_A <= 0;
			end
		end
		else SDRAM_A <= 0;
	end
	else begin
		state <= STATE_IDLE;
		case (fsm)
		FSM_IDLE: begin
			if (!rfs_timer) begin
				rfs_timer <= RFS_CNT;
				if (|row_open) begin
					{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;
					SDRAM_A <= 13'b0010000000000; // A10 = all banks
					row_open <= 0;
					dly <= DLY_RP;
					fsm <= FSM_PALL;
				end
				else begin
					{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_AUTO_REFRESH;
					dly <= DLY_REF;
					fsm <= FSM_REF;
				end
			end
			else if ((~old_rd[0] && rd[0]) || (~old_wr[0] && wr[0])) begin
				old_rd[0] <= rd[0];
				old_wr[0] <= wr[0];
				grant(3'b001, addr0, din0, wr[0], {wrh_q[0],wrl_q[0]});
			end
			else if ((~old_rd[1] && rd[1]) || (~old_wr[1] && wr[1])) begin
				old_rd[1] <= rd[1];
				old_wr[1] <= wr[1];
				grant(3'b010, addr1, din1, wr[1], {wrh_q[1],wrl_q[1]});
			end
			else if ((~old_rd[2] && rd[2]) || (~old_wr[2] && wr[2])) begin
				old_rd[2] <= rd[2];
				old_wr[2] <= wr[2];
				grant(3'b100, addr2, din2, wr[2], {wrh_q[2],wrl_q[2]});
			end
		end

		FSM_GRANT:
			if (row_open[ba] && open_row[ba] == a[13:1])
				do_cas(ba, a[22:1], data, we, dqm);
			else if (row_open[ba])
				do_pre(ba);
			else
				do_act(ba, a[22:1]);

		FSM_PRE:
			if (dly) dly <= dly - 1'd1;
			else do_act(ba, a);

		FSM_ACT:
			if (dly) dly <= dly - 1'd1;
			else do_cas(ba, a, data, we, dqm);

		FSM_CAS:
			if (dly) dly <= dly - 1'd1;
			else begin
				if(ram_req[0]) dout0_r <= SDRAM_DQ;
				if(ram_req[1]) dout1_r <= SDRAM_DQ;
				if(ram_req[2]) dout2_r <= SDRAM_DQ;
				ram_req <= 0;
				fsm <= FSM_IDLE;
			end

		FSM_PALL:
			if (dly) dly <= dly - 1'd1;
			else begin
				{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_AUTO_REFRESH;
				dly <= DLY_REF;
				fsm <= FSM_REF;
			end

		FSM_REF:
			if (dly) dly <= dly - 1'd1;
			else fsm <= FSM_IDLE;
		endcase
	end
end

assign busy0 = ram_req[0];
assign busy1 = ram_req[1];
assign busy2 = ram_req[2];

altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

endmodule
