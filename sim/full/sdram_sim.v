// Behavioral SDRAM for the full-system co-sim: same 3-port word interface as
// core/rtl/megacd/sdram.sv, backed by a plain memory (no dram pins / JEDEC
// protocol) -- but with the REAL controller's timing behaviour.
//
// The previous model gave every port its own private server with a flat
// 10-cycle latency and no refresh. Hardware has ONE chip: a single engine
// serves the three ports in strict priority 0 > 1 > 2, refresh preempts
// everything, and an access costs CAS-only / +ACTIVATE / +PRECHARGE+ACTIVATE
// depending on whether its row is already open in its bank. That gap is not a
// detail -- it is exactly the load-dependent latency the main 68000 pays for
// word RAM (port 2, the LOWEST priority) while the sub CPU streams from
// PRG-RAM (port 0), so the idealised model renders scenes the hardware
// cannot. Sonic CD's Palmtree Panic ramp came out clean under the old model
// and is the scene the slowdown was reported in.
//
// Mirrors core/rtl/megacd/sdram.sv: DLY_RP/RCD/CL/WR, RFS_CNT, the one-cycle
// strobe recapture, the grant -> FSM_GRANT split, and the SAME address map
// (bank = a[24:23], row = a[22:10], column = a[9:1]).
//
// Plusargs:
//   +sdideal=1   restore the old contention-free flat-latency model
//   +sdlat=N     ideal model: per-access latency (default 10).
//                faithful model: extra CAS cycles added to every access
//                (default 0), for margin sweeps
//   +sdlat0/1/2  per-port variant of the above
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
    reg [15:0] mem [0:(1<<24)-1] /* verilator public_flat_rd */;
    // preload via +bios=<hexfile> ($readmemh with @word-address offset)
    reg [1023:0] biosf;
    initial if ($value$plusargs("bios=%s", biosf)) $readmemh(biosf, mem);

    integer LAT, LAT0, LAT1, LAT2, IDEAL, MAP;
    initial begin
        if (!$value$plusargs("sdideal=%d", IDEAL)) IDEAL = 0;
        // +sdmap=0 restores the original row/column split (row = the LOW
        // address bits), so a mapping change can be A/B'd in one build
        if (!$value$plusargs("sdmap=%d", MAP)) MAP = 1;
        if (!$value$plusargs("sdlat=%d", LAT)) LAT = IDEAL ? 10 : 0;
        if (!$value$plusargs("sdlat0=%d", LAT0)) LAT0 = LAT;
        if (!$value$plusargs("sdlat1=%d", LAT1)) LAT1 = LAT;
        if (!$value$plusargs("sdlat2=%d", LAT2)) LAT2 = LAT;
    end

    // ---------------- ideal model (legacy, +sdideal=1) ----------------
    reg [7:0] b0=0,b1=0,b2=0;
    reg r0=0,r1=0,r2=0;
    reg pr0=0,pr1=0,pr2=0;

    // ---------------- faithful model (default) ------------------------
    localparam [3:0] DLY_RP  = 4'd2;   // PRECHARGE -> ACTIVATE
    localparam [3:0] DLY_RCD = 4'd2;   // ACTIVATE  -> CAS
    localparam [3:0] DLY_CL  = 4'd5;   // CAS -> data latch (read)
    localparam [3:0] DLY_WR  = 4'd3;   // CAS -> done (write)
    localparam [3:0] DLY_REF = 4'd8;   // AUTO_REFRESH recovery (tRFC)
    localparam [9:0] RFS_CNT = 766;

    localparam [2:0] FSM_IDLE = 3'd0, FSM_PRE  = 3'd1, FSM_ACT = 3'd2,
                     FSM_CAS  = 3'd3, FSM_PALL = 3'd4, FSM_REF = 3'd5,
                     FSM_GRANT= 3'd6;

    reg [12:0] open_row [0:3];
    reg  [3:0] row_open = 0;
    reg  [2:0] fsm = FSM_IDLE;
    reg  [4:0] dly = 0;
    reg  [2:0] ram_req = 0;
    reg [24:1] a_r;
    reg [15:0] d_r;
    reg        we_r;
    reg  [1:0] msk_r;          // {wrh, wrl} of the granted access
    reg  [4:0] extra;          // +sdlat* padding for the granted access
    reg        row_hit = 0, row_busy = 0;
    reg  [9:0] rfs_timer = 0;
    reg  [2:0] rd_q = 0, wrl_q = 0, wrh_q = 0;   // one-cycle strobe recapture
    reg  [2:0] old_rd = 0, old_wr = 0;
    wire [2:0] wq = wrl_q | wrh_q;

    // Per-port cost accounting, read per frame by the testbench. Splits every
    // access into what it actually cost at the chip -- CAS-only row hit,
    // ACTIVATE (bank idle), or PRECHARGE+ACTIVATE (bank open on another row)
    // -- plus the cycles the port sat waiting for the single engine to become
    // free (queueing behind the higher-priority ports and refresh). This is
    // what tells a row/column or bank-assignment change apart from a
    // contention problem instead of guessing at it.
    reg [31:0] dbg_hit0 /* verilator public_flat_rd */ = 0;
    reg [31:0] dbg_hit1 /* verilator public_flat_rd */ = 0;
    reg [31:0] dbg_hit2 /* verilator public_flat_rd */ = 0;
    reg [31:0] dbg_act0 /* verilator public_flat_rd */ = 0;
    reg [31:0] dbg_act1 /* verilator public_flat_rd */ = 0;
    reg [31:0] dbg_act2 /* verilator public_flat_rd */ = 0;
    reg [31:0] dbg_pre0 /* verilator public_flat_rd */ = 0;
    reg [31:0] dbg_pre1 /* verilator public_flat_rd */ = 0;
    reg [31:0] dbg_pre2 /* verilator public_flat_rd */ = 0;
    reg [31:0] dbg_wait0 /* verilator public_flat_rd */ = 0;
    reg [31:0] dbg_wait1 /* verilator public_flat_rd */ = 0;
    reg [31:0] dbg_wait2 /* verilator public_flat_rd */ = 0;
    reg [31:0] dbg_ref  /* verilator public_flat_rd */ = 0;
    wire [2:0] pend = (~old_rd & rd_q) | (~old_wr & wq);   // requested, not yet granted

    function [12:0] rowof(input [24:1] ta);
        rowof = MAP ? ta[22:10] : ta[13:1];
    endfunction

    // latch the winning request, exactly as the real grant() task does
    task do_grant(input [2:0] idx, input [24:1] ta, input [15:0] td,
                  input tw, input [1:0] tmask, input [4:0] tex);
    begin
        a_r <= ta; d_r <= td; we_r <= tw; msk_r <= tmask;
        ram_req <= idx; extra <= tex;
        row_hit  <= row_open[ta[24:23]] && (open_row[ta[24:23]] == rowof(ta));
        row_busy <= row_open[ta[24:23]];
        fsm <= FSM_GRANT;
    end
    endtask

    always @(posedge clk) begin
      if (IDEAL) begin
        // ---- legacy contention-free model ----
        if (!b0 && !r0 && (rd0|wrl0|wrh0) && !(pr0)) begin
            r0<=1; b0<=LAT0[7:0];
            if (wrl0) mem[addr0][7:0]  <= din0[7:0];
            if (wrh0) mem[addr0][15:8] <= din0[15:8];
        end else if (r0) begin
            if (b0>1) b0<=b0-1; else begin r0<=0; b0<=0; dout0<=mem[addr0]; end
        end
        pr0 <= (rd0|wrl0|wrh0);
        if (!b1 && !r1 && (rd1|wrl1|wrh1) && !pr1) begin
            r1<=1; b1<=LAT1[7:0];
            if (wrl1) mem[addr1][7:0]  <= din1[7:0];
            if (wrh1) mem[addr1][15:8] <= din1[15:8];
        end else if (r1) begin
            if (b1>1) b1<=b1-1; else begin r1<=0; b1<=0; dout1<=mem[addr1]; end
        end
        pr1 <= (rd1|wrl1|wrh1);
        if (!b2 && !r2 && (rd2|wrl2|wrh2) && !pr2) begin
            r2<=1; b2<=LAT2[7:0];
            if (wrl2) mem[addr2][7:0]  <= din2[7:0];
            if (wrh2) mem[addr2][15:8] <= din2[15:8];
        end else if (r2) begin
            if (b2>1) b2<=b2-1; else begin r2<=0; b2<=0; dout2<=mem[addr2]; end
        end
        pr2 <= (rd2|wrl2|wrh2);
      end else begin
        // ---- faithful single-engine model ----
        rd_q  <= {rd2,  rd1,  rd0};
        wrl_q <= {wrl2, wrl1, wrl0};
        wrh_q <= {wrh2, wrh1, wrh0};
        old_rd <= old_rd & rd_q;
        old_wr <= old_wr & wq;
        if (rfs_timer) rfs_timer <= rfs_timer - 1'd1;
        if (pend[0]) dbg_wait0 <= dbg_wait0 + 1'd1;
        if (pend[1]) dbg_wait1 <= dbg_wait1 + 1'd1;
        if (pend[2]) dbg_wait2 <= dbg_wait2 + 1'd1;

        case (fsm)
        FSM_IDLE: begin
            if (!rfs_timer) begin
                rfs_timer <= RFS_CNT;
                dbg_ref <= dbg_ref + 1'd1;
                if (|row_open) begin
                    row_open <= 0; dly <= DLY_RP; fsm <= FSM_PALL;
                end else begin
                    dly <= DLY_REF; fsm <= FSM_REF;
                end
            end
            else if ((~old_rd[0] && rd_q[0]) || (~old_wr[0] && wq[0])) begin
                old_rd[0] <= rd_q[0]; old_wr[0] <= wq[0];
                do_grant(3'b001, addr0, din0, wq[0], {wrh_q[0],wrl_q[0]}, LAT0[4:0]);
            end
            else if ((~old_rd[1] && rd_q[1]) || (~old_wr[1] && wq[1])) begin
                old_rd[1] <= rd_q[1]; old_wr[1] <= wq[1];
                do_grant(3'b010, addr1, din1, wq[1], {wrh_q[1],wrl_q[1]}, LAT1[4:0]);
            end
            else if ((~old_rd[2] && rd_q[2]) || (~old_wr[2] && wq[2])) begin
                old_rd[2] <= rd_q[2]; old_wr[2] <= wq[2];
                do_grant(3'b100, addr2, din2, wq[2], {wrh_q[2],wrl_q[2]}, LAT2[4:0]);
            end
        end

        FSM_GRANT:
            if (row_hit) begin
                if (ram_req[0]) dbg_hit0 <= dbg_hit0 + 1'd1;
                if (ram_req[1]) dbg_hit1 <= dbg_hit1 + 1'd1;
                if (ram_req[2]) dbg_hit2 <= dbg_hit2 + 1'd1;
                dly <= (we_r ? DLY_WR : DLY_CL) + extra; fsm <= FSM_CAS;
            end else if (row_busy) begin
                if (ram_req[0]) dbg_pre0 <= dbg_pre0 + 1'd1;
                if (ram_req[1]) dbg_pre1 <= dbg_pre1 + 1'd1;
                if (ram_req[2]) dbg_pre2 <= dbg_pre2 + 1'd1;
                dly <= DLY_RP; fsm <= FSM_PRE;
            end else begin
                if (ram_req[0]) dbg_act0 <= dbg_act0 + 1'd1;
                if (ram_req[1]) dbg_act1 <= dbg_act1 + 1'd1;
                if (ram_req[2]) dbg_act2 <= dbg_act2 + 1'd1;
                open_row[a_r[24:23]] <= rowof(a_r);
                row_open[a_r[24:23]] <= 1'b1;
                dly <= DLY_RCD; fsm <= FSM_ACT;
            end

        FSM_PRE:
            if (dly) dly <= dly - 1'd1;
            else begin
                open_row[a_r[24:23]] <= rowof(a_r);
                row_open[a_r[24:23]] <= 1'b1;
                dly <= DLY_RCD; fsm <= FSM_ACT;
            end

        FSM_ACT:
            if (dly) dly <= dly - 1'd1;
            else begin dly <= (we_r ? DLY_WR : DLY_CL) + extra; fsm <= FSM_CAS; end

        FSM_CAS:
            if (dly) dly <= dly - 1'd1;
            else begin
                if (we_r) begin
                    if (msk_r[0]) mem[a_r][7:0]  <= d_r[7:0];
                    if (msk_r[1]) mem[a_r][15:8] <= d_r[15:8];
                end else begin
                    if (ram_req[0]) dout0 <= mem[a_r];
                    if (ram_req[1]) dout1 <= mem[a_r];
                    if (ram_req[2]) dout2 <= mem[a_r];
                end
                ram_req <= 0;
                fsm <= FSM_IDLE;
            end

        FSM_PALL:
            if (dly) dly <= dly - 1'd1;
            else begin dly <= DLY_REF; fsm <= FSM_REF; end

        FSM_REF:
            if (dly) dly <= dly - 1'd1;
            else fsm <= FSM_IDLE;
        endcase
      end
    end

    assign busy0 = IDEAL ? r0 : ram_req[0];
    assign busy1 = IDEAL ? r1 : ram_req[1];
    assign busy2 = IDEAL ? r2 : ram_req[2];
endmodule
