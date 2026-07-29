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
localparam [3:0] DLY_REF = 4'd8;  // AUTO_REFRESH recovery (tRFC)

// CAS -> data latch. Reads now land in the IOE capture register dq_in one
// RAM edge before the FSM consumes it (see dq_in below), so DLY_CL is one
// higher than it used to be purely to keep the *pin* sampling edge where it
// already was -- effective read latency at the pad is unchanged, the extra
// count just pays for the added pipeline stage. Writes keep the old count;
// they never look at the DQ bus on the way back.
// DLY_CL is 5, not 4: with the interface finally constrained, STA measured
// the read capture short by 7.515ns against a 9.312ns period -- i.e. by
// exactly one RAM cycle. The controller had been latching DQ one edge before
// the SDRAM reliably drives it (CL3 plus the off-chip clock round trip), on
// every read since the open-row engine landed. Works on a fast part at room
// temperature, corrupts otherwise.
localparam [3:0] DLY_CL  = 4'd5;  // CAS -> data latch (read)
localparam [3:0] DLY_WR  = 4'd3;  // CAS -> done (write), unchanged

localparam [2:0] FSM_IDLE = 3'd0;
localparam [2:0] FSM_PRE  = 3'd1;
localparam [2:0] FSM_ACT  = 3'd2;
localparam [2:0] FSM_CAS  = 3'd3;
localparam [2:0] FSM_PALL = 3'd4;
localparam [2:0] FSM_REF  = 3'd5;
localparam [2:0] FSM_GRANT= 3'd6;

// init-sequence cycle counter. One command is issued per 9-cycle step, at
// STATE_START; the step boundary (STATE_LAST) is where the init sequencer
// advances. 9 cycles @107.4MHz = 84ns per step, which covers tRP (20ns) and
// tRFC (66ns) between consecutive init commands with margin.
localparam STATE_IDLE  = 4'd0;
localparam STATE_START = 4'd1;
localparam STATE_LAST  = 4'd8;

reg  [3:0] state = STATE_IDLE;
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

// row decision for the pending grant, resolved a cycle early so it does not
// sit in the DQ tristate-enable cone -- see grant()
reg        row_hit  = 0;
reg        row_busy = 0;

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

// IOE read-capture stage. The three dout*_r latches above are *conditional*
// (if(ram_req[n])), so none of them can pack into the single IOE input
// register — which meant the FAST_INPUT_REGISTER ON -to dram_dq[*] in the
// qsf had never actually taken effect, and the DQ pins reached the fabric
// through 6.474ns of interconnect (measured: dram_dq[9] -> dout2_r[9]).
// That, plus the -4.0ns skew inherent to clocking the SDRAM off-chip, is
// why the read path missed the default capture edge by 13.5ns once the
// interface was finally constrained.
//
// A single unconditional register can pack into the IOE, so DQ now lands
// one edge early right at the pad and the FSM selects from it. Must stay
// unconditional and reset-free — adding an enable or a clear pushes it back
// into the fabric and silently undoes this.
reg [15:0] dq_in;
always @(posedge clk) dq_in <= SDRAM_DQ;

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
//
// mode MUST have a power-up value, and the sequencer MUST be able to run
// while it reads MODE_NORMAL. The two blocks are mutually gating: `mode` is
// only ever written from `state == STATE_LAST` below, and `state` only
// advances while the main block is in its init branch. With `mode`
// uninitialized it powers up 2'b00 == MODE_NORMAL on Cyclone V, state stays
// pinned at STATE_IDLE, STATE_LAST never arrives, and mode is never
// written -- the whole init sequence is dead and no PRECHARGE, AUTO_REFRESH
// or LOAD_MODE is ever issued. The chip then runs on whatever its mode
// register powered up with, which JEDEC leaves undefined.
//
// That is not academic: the mode register survives an FPGA reconfiguration
// (the Pocket keeps the SDRAM powered between core loads), so the core
// inherits a valid CL3 mode register from whatever core ran before it. That
// is the "load a different core first, then MegaCD boots" report.
//
// The fix is init_active: a single flop that powers up set and owns the bus
// until the sequence has actually run, so the sequencer no longer depends on
// mode to bootstrap itself. It also replaces the `mode != MODE_NORMAL`
// compare in the main block's branch select, so that select gets cheaper,
// not more expensive -- this file's command path is pin-bound and was
// already at 9.470ns against a 9.312ns period (see grant() above).
reg [1:0] mode = MODE_NORMAL;
reg [4:0] reset=5'h1f;
reg       init_active = 1;

// JEDEC power-up: at least 100us of stable clock with NOPs on the bus before
// the first command. clk is the 107.386MHz RAM clock, so 100us is 10739
// cycles; 2^14 gives ~153us. Timed from the deassertion of `init`
// (~pll_core_locked) rather than from configuration, because the PLL output
// is not a stable clock until it locks. Costs 153us once at boot, against a
// BIOS download that does not start for tens of ms.
reg [13:0] pwrup = 0;
reg        pwrup_done = 0;

// Command-issue enable, registered so neither the 14-input AND above nor the
// mode compare lands in the SDRAM_nRAS/nCAS/nWE cone. Being a cycle late is
// exactly right: mode is written on the STATE_LAST edge, so this settles
// during STATE_IDLE and is stable by STATE_START, where commands issue.
reg cmd_en = 0;

always @(posedge clk) begin
	cmd_en <= pwrup_done && (mode != MODE_NORMAL);

	if(init) begin
		// held while the PLL is unlocked: no counting, no commands
		reset       <= 5'h1f;
		pwrup       <= 0;
		pwrup_done  <= 0;
		init_active <= 1;
		mode        <= MODE_NORMAL;
	end
	else if(~pwrup_done) begin
		pwrup <= pwrup + 1'd1;
		if(&pwrup) pwrup_done <= 1;
	end
	else if(state == STATE_LAST) begin
		if(reset != 0) begin
			reset <= reset - 5'd1;
			// PRECHARGE ALL first, then 27 AUTO_REFRESH, then LOAD_MODE --
			// JEDEC order. It used to be 17 refreshes, PRECHARGE, 10
			// refreshes, LOAD_MODE; refreshing a chip that has never been
			// precharged is out of spec, and the whole point of this block
			// is to stop depending on undefined power-up behaviour.
			// reset == 31 is the bootstrap step: mode still reads
			// MODE_NORMAL there and cmd_en is low, so it issues NOPs and
			// exists only to select MODE_PRE for the step after it.
			if(reset == 31)     mode <= MODE_PRE;
			else if(reset == 3) mode <= MODE_LDM;
			else                mode <= MODE_RESET;
		end
		else begin
			mode        <= MODE_NORMAL;
			init_active <= 0;
		end
	end
end

// access manager + command generator (single engine)
//
// ROW/COLUMN SPLIT. The row is the HIGH address bits and the column the LOW
// ones, so a row is 512 consecutive words (1KB) and a sequential stream --
// which is what every client here does: 68000 instruction fetch, PRG-RAM
// fetch, blits -- stays inside one open row and issues CAS only.
//
// It used to be the other way round (row = ta[13:1], column = ta[22:14]).
// That is a valid bijection, so nothing malfunctioned, but it put CONSECUTIVE
// words in DIFFERENT rows of the same bank: every sequential access found the
// bank open on the wrong row and paid PRECHARGE + ACTIVATE + CAS (~13 cycles)
// instead of CAS (~8). The open-row engine could therefore never hit for the
// access pattern it was written for. Measured on the main 68000's word-RAM
// path, which is where it hurts most -- Sonic CD executes its entire game
// loop out of word RAM, ~19.4k fetches a frame, and was spending 82% of the
// CPU's frame budget on them.
task do_cas(input [1:0] tba, input [22:1] ta, input [15:0] tdin, input twe, input [1:0] tdqm);
begin
	{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= twe ? CMD_WRITE : CMD_READ;
	if (twe) SDRAM_DQ <= tdin;
	SDRAM_BA <= tba;
	SDRAM_A  <= {tdqm, 2'b00, ta[9:1]};
	dly <= twe ? DLY_WR : DLY_CL;
	fsm <= FSM_CAS;
end
endtask

task do_act(input [1:0] tba, input [22:1] ta);
begin
	{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_ACTIVE;
	SDRAM_BA <= tba;
	SDRAM_A  <= ta[22:10];
	open_row[tba] <= ta[22:10];
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
// the strobe edge-detect + 3-port priority + command mux out of a single
// cycle is what closes timing to the pin-bound IOE registers at high
// device utilization (was -0.45ns reg->pin).
//
// The row compare now lives here too, which reverses part of that split on
// purpose. It used to sit in FSM_GRANT, where it landed in the cone of the
// DQ tristate enable: a 4-entry x 13-bit array read indexed by ba, plus a
// 13-bit comparator, feeding SDRAM_DQ[*]~en. That was the single worst path
// in the whole design (ba[0] -> SDRAM_DQ[5]~en, 9.470ns against a 9.312ns
// period) and it gates bus turnaround -- late OE means the FPGA fights the
// SDRAM on a read or misses the window on a write, either of which reads
// back as garbage.
//
// Precomputing it into row_hit/row_busy leaves FSM_GRANT driven entirely by
// registers, so the enable cone collapses to we & fsm & row_hit. The cost
// is that this cycle gains the array read + comparator -- but it terminates
// in fabric here, versus terminating at a pin there, which is the trade
// that matters. Safe because FSM_IDLE's refresh branch and its grant
// branches are mutually exclusive: nothing writes row_open/open_row on the
// cycle grant() runs, nor between here and FSM_GRANT.
task grant(input [2:0] idx, input [24:1] taddr, input [15:0] tdin, input twr, input [1:0] tmask);
begin
	{ba, a} <= taddr;
	data <= tdin;
	we   <= twr;
	dqm  <= twr ? ~tmask : 2'b00;
	ram_req <= idx;
	row_hit  <= row_open[taddr[24:23]] && (open_row[taddr[24:23]] == taddr[22:10]);
	row_busy <= row_open[taddr[24:23]];
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

	// init_active, not `mode != MODE_NORMAL`: mode reads MODE_NORMAL both at
	// power-up and after every `init` pulse, and gating on it meant state
	// never advanced, so the sequencer above never got a STATE_LAST to write
	// mode from. See the long note there -- that deadlock is what left the
	// chip's mode register unprogrammed.
	if (init_active) begin
		// init sequencer
		state <= state + 1'd1;
		if(state == STATE_LAST) state <= STATE_IDLE;
		row_open <= 0;
		fsm <= FSM_IDLE;
		ram_req <= 0;
		// cmd_en holds commands off until the 100us power-up window closes
		// and a real init phase is selected, so the first command the chip
		// ever sees is PRECHARGE ALL.
		if (state == STATE_START && cmd_en) begin
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
			// register-only decision; see grant() for why it is precomputed
			if (row_hit)
				do_cas(ba, a[22:1], data, we, dqm);
			else if (row_busy)
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
				// dq_in holds the pad value sampled on the previous RAM
				// edge; DLY_CL absorbs that stage, so this lands on the
				// same edge as ram_req clears — the "requesters sample
				// 1-2 clocks after busy falls" contract above is unchanged.
				if(ram_req[0]) dout0_r <= dq_in;
				if(ram_req[1]) dout1_r <= dq_in;
				if(ram_req[2]) dout2_r <= dq_in;
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
