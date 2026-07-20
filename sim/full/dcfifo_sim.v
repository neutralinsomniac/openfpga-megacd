// Behavioral dual-clock FIFO replacing the Altera dcfifo megafunction for
// the full-system co-sim. Parameters are passed via defparam (lpm_width,
// lpm_numwords); a generous fixed depth covers all instances. Simplified:
// treats rd/wr on their respective clocks with a shared memory (adequate
// for the bridge glue, which the sim mostly bypasses by preloading SDRAM).
module dcfifo #(parameter lpm_width=32, parameter lpm_widthu=8,
                parameter lpm_numwords=256, parameter lpm_showahead="OFF",
  parameter lpm_type="dcfifo", parameter overflow_checking="ON",
  parameter underflow_checking="ON", parameter use_eab="ON",
  parameter rdsync_delaypipe=5, parameter wrsync_delaypipe=5,
  parameter intended_device_family="Cyclone V", parameter clocks_are_synchronized="FALSE",
  parameter add_usedw_msb_bit="OFF", parameter read_aclr_synch="OFF",
  parameter write_aclr_synch="OFF") (
    input wire [lpm_width-1:0] data,
    input wire rdclk, input wire rdreq,
    input wire wrclk, input wire wrreq,
    input wire aclr,
    output reg [lpm_width-1:0] q,
    output wire rdempty, output wire rdfull, output wire wrempty, output wire wrfull,
    output wire [lpm_widthu-1:0] rdusedw, output wire [lpm_widthu-1:0] wrusedw,
    output wire [1:0] eccstatus
);
    localparam DEPTH = 4096;
    reg [lpm_width-1:0] mem [0:DEPTH-1];
    integer wr=0, rd=0, cnt=0;
    always @(posedge wrclk) if (wrreq && cnt<DEPTH) begin mem[wr%DEPTH]<=data; wr<=wr+1; cnt<=cnt+1; end
    always @(posedge rdclk) if (rdreq && cnt>0) begin q<=mem[rd%DEPTH]; rd<=rd+1; cnt<=cnt-1; end
    assign rdempty = (cnt==0);
    assign wrfull  = (cnt>=DEPTH);
    assign rdfull=0; assign wrempty=(cnt==0); assign rdusedw=cnt; assign wrusedw=cnt; assign eccstatus=0;
endmodule
