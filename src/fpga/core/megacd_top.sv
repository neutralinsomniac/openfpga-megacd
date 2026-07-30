//
// User core top-level
//
// Instantiated by the real top-level: apf_top
//

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1 

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable, 

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,
 
///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus 

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,
    
output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
// 
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [15:0]  cont1_key,
input   wire    [15:0]  cont2_key,
input   wire    [15:0]  cont3_key,
input   wire    [15:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig
    
);

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// link port is input only
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

// tie off the rest of the pins we are not using
assign cram0_a = 'h0;
assign cram0_dq = {16{1'bZ}};
assign cram0_clk = 0;
assign cram0_adv_n = 1;
assign cram0_cre = 0;
assign cram0_ce0_n = 1;
assign cram0_ce1_n = 1;
assign cram0_oe_n = 1;
assign cram0_we_n = 1;
assign cram0_ub_n = 1;
assign cram0_lb_n = 1;

assign cram1_a = 'h0;
assign cram1_dq = {16{1'bZ}};
assign cram1_clk = 0;
assign cram1_adv_n = 1;
assign cram1_cre = 0;
assign cram1_ce0_n = 1;
assign cram1_ce1_n = 1;
assign cram1_oe_n = 1;
assign cram1_we_n = 1;
assign cram1_ub_n = 1;
assign cram1_lb_n = 1;

assign sram_a = 'h0;
assign sram_dq = {16{1'bZ}};
assign sram_oe_n  = 1;
assign sram_we_n  = 1;
assign sram_ub_n  = 1;
assign sram_lb_n  = 1;

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;


// for bridge write data, we just broadcast it to all bus devices
// for bridge read data, we have to mux it
// add your own devices here
always @(*) begin
    casex(bridge_addr)
    default: begin
        bridge_rd_data <= 0;
    end
	32'h00E00000: begin
        bridge_rd_data <= region_req;
    end
    32'hF8xxxxxx: begin
        bridge_rd_data <= cmd_bridge_rd_data;
    end
    endcase

	if (bridge_addr[31:28] == 4'h6) begin
      bridge_rd_data <= sd_read_data;
    end
end


//
// host/target command handler
//
    wire            reset_n;                // driven by host commands, can be used as core-wide reset
    wire    [31:0]  cmd_bridge_rd_data;
    
// bridge host commands
// synchronous to clk_74a
    wire            status_boot_done = pll_core_locked; 
    wire            status_setup_done = pll_core_locked; // rising edge triggers a target command
    wire            status_running = reset_n; // we are running as soon as reset_n goes high

    wire            dataslot_requestread;
    wire    [15:0]  dataslot_requestread_id;
    wire            dataslot_requestread_ack = 1;
    wire            dataslot_requestread_ok = 1;

    wire            dataslot_requestwrite;
    wire    [15:0]  dataslot_requestwrite_id;
    wire            dataslot_requestwrite_ack = 1;
    wire            dataslot_requestwrite_ok = 1;

    wire            dataslot_allcomplete;
    wire            dataslot_update;
    wire    [15:0]  dataslot_update_id;
    wire    [31:0]  dataslot_update_size;

    wire            savestate_supported;
    wire    [31:0]  savestate_addr;
    wire    [31:0]  savestate_size;
    wire    [31:0]  savestate_maxloadsize;

    wire            savestate_start;
    wire            savestate_start_ack;
    wire            savestate_start_busy;
    wire            savestate_start_ok;
    wire            savestate_start_err;

    wire            savestate_load;
    wire            savestate_load_ack;
    wire            savestate_load_busy;
    wire            savestate_load_ok;
    wire            savestate_load_err;
    
    wire            osnotify_inmenu;

// bridge target commands
// synchronous to clk_74a


// bridge data slot access

    wire    [9:0]   datatable_addr;
    wire            datatable_wren;
    wire    [31:0]  datatable_data;
    wire    [31:0]  datatable_q;

core_bridge_cmd icb (

    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),
    
    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .dataslot_update        ( dataslot_update ),
    .dataslot_update_id     ( dataslot_update_id ),
    .dataslot_update_size   ( dataslot_update_size ),

    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),
    
    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q ),

    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),
    .target_dataslot_id         ( tds_id ),
    .target_dataslot_slotoffset ( tds_offset ),
    .target_dataslot_bridgeaddr ( tds_bridgeaddr ),
    .target_dataslot_length     ( tds_length ),

    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),
    .target_dataslot_file_done  ( target_dataslot_file_done ),
    .fbuf_addr                  ( fbuf_addr ),
    .fbuf_wr                    ( fbuf_wr ),
    .fbuf_di                    ( fbuf_di ),
    .fbuf_q                     ( fbuf_q ),

    .dbg_target_0               ( dbg_target_0 ),
    .dbg_tstate                 ( dbg_tstate )

);

    wire    [31:0]  dbg_target_0;
    wire    [3:0]   dbg_tstate;
    wire    [2:0]   target_dataslot_err;
    reg     [15:0]  tds_id;
    reg     [31:0]  tds_offset, tds_bridgeaddr, tds_length;
    reg             target_dataslot_getfile = 0, target_dataslot_openfile = 0;
    wire            target_dataslot_file_done;
    reg     [7:0]   fbuf_addr;
    reg             fbuf_wr = 0;
    reg     [31:0]  fbuf_di;
    wire    [31:0]  fbuf_q;

///////////////////////////////////////////////
// CD sector fetch: the drive (clk_sys) requests a 2352-byte sector; a
// clk_74a FSM turns it into an APF target_dataslot_read whose data the
// host writes through the bridge into the double-buffered sector RAM.
///////////////////////////////////////////////

    reg             target_dataslot_read = 0;
    wire            target_dataslot_ack;
    wire            target_dataslot_done;

    wire        cd_req;             // clk_sys, level-held until cd_ack
    wire [31:0] cd_req_offset;      // stable while cd_req held
    wire  [1:0] cd_req_slot;   // which of the 4 bank slots the drive is filling
    reg         cd_ack = 0;         // clk_74a; synced back inside the drive

    // mount FSM read channel (level-held request, same clk_74a domain)
    reg         mnt_rd = 0;
    reg  [31:0] mnt_offset;
    reg  [31:0] mnt_len;      // clamped to the file: reads past EOF are an
                              // APF "out of range" error on real firmware
    reg         mnt_rd_done = 0;

    reg  [2:0]  cdreq_s = 0;
    reg  [1:0]  cdf_st = 0;
    reg         cdf_src = 0;        // 0 = drive sector fetch, 1 = mount read
    // multi-bin: a fetch whose track lives in another file first asks the
    // mount FSM to openfile it (reopen_req is level-held until the file
    // matches). cd_req_file is clk_sys but stable while cd_req is held.
    reg         reopen_req = 0;
    reg  [6:0]  reopen_file = 0;
    wire [6:0]  cd_req_file;
    // 2FF + stability filter: cur_file comes from the clk_sys track search
    // and can change while a request is pending
    reg  [6:0]  crf_s1, crf_s2, crf_stable;
always @(posedge clk_74a) begin
    cdreq_s <= {cdreq_s[1:0], cd_req};
    crf_s1 <= cd_req_file;
    crf_s2 <= crf_s1;
    if (crf_s1 == crf_s2) crf_stable <= crf_s2;
    if (reopen_req && opened_file == crf_stable) reopen_req <= 0;
    case (cdf_st)
    2'd0: if (cdreq_s[1] && (!mount_use_slot2
                             || crf_stable == opened_file)) begin
        // drive fetch, its bin already open: serve it (top priority)
        tds_offset     <= cd_req_offset;
        tds_bridgeaddr <= {18'h1C000, cd_req_slot, 12'h000}; // 0x7000_{slot}000
        tds_length     <= 32'd2352;
        cdf_src <= 0;
        target_dataslot_read <= 1;
        cdf_st <= 2'd1;
    end else begin
        // drive fetch needs a different bin: flag the reopen — but a
        // BLOCKED fetch must NOT also starve a pending mount (probe) read.
        // Serving the read anyway lets the mount finish and reach M_IDLE,
        // where the reopen is serviced. Without this, the drive-fetch
        // priority above wedged the probe read forever (mnt_rd_done never
        // came) so the mount never serviced the reopen — the CHECKING-DISC
        // deadlock. This makes forward progress structural, not timing-luck.
        if (cdreq_s[1] && mount_use_slot2) begin
            reopen_file <= crf_stable;
            reopen_req <= 1;
        end
        if (mnt_rd && !mnt_rd_done) begin
            tds_offset     <= mnt_offset;
            tds_bridgeaddr <= 32'h7200_0000;     // parse buffer window
            tds_length     <= mnt_len;
            cdf_src <= 1;
            target_dataslot_read <= 1;
            cdf_st <= 2'd1;
        end
    end
    2'd1: if (target_dataslot_ack) begin
        target_dataslot_read <= 0;
        cdf_st <= 2'd2;
    end
    2'd2: if (target_dataslot_done) begin
        if (cdf_src) begin
            mnt_rd_done <= 1;
            mnt_rd_err  <= (target_dataslot_err != 0);
        end else cd_ack <= 1;
        cdf_st <= 2'd3;
    end
    2'd3: begin
        if (cdf_src ? !mnt_rd : !cdreq_s[1]) begin
            cd_ack <= 0;
            mnt_rd_done <= 0;
            cdf_st <= 2'd0;
        end
    end
    endcase
end

// 4-sector prefetch bank: host writes 32-bit words at 0x7000_{0,1,2,3}000
// (one 4KB window per slot), drive reads on clk_sys (contents race-free: only
// read after cd_ack). Normalize packing so file byte 0 always lands in [7:0].
reg [31:0] cd_buf [0:4095];
wire [31:0] cd_buf_wd = bridge_endian_little ? bridge_wr_data :
    {bridge_wr_data[7:0], bridge_wr_data[15:8], bridge_wr_data[23:16], bridge_wr_data[31:24]};
always @(posedge clk_74a) begin
    if (bridge_wr && bridge_addr[31:24] == 8'h70)
        cd_buf[bridge_addr[13:2]] <= cd_buf_wd;   // {slot[1:0], word[9:0]}
end

// mount parse buffer: 16KB at bridge 0x7200_0000, raw big-endian packing
// (byte 0 of the file in bits [31:24]); written by the host during the
// mount sniff read, read by the cue parser. 16KB because a cue references
// one FILE per track and a Red Book disc allows 99 tracks: Lunar's 52-FILE
// cue is 6.5KB, which the old 4KB buffer silently truncated at ~track 33 —
// every later track fell off the disc and the game hung mid-intro waiting
// for track 52 to play.
reg [31:0] parse_buf [0:4095];
always @(posedge clk_74a) begin
    if (bridge_wr && bridge_addr[31:24] == 8'h72)
        parse_buf[bridge_addr[13:2]] <= bridge_endian_little ?
            {bridge_wr_data[7:0], bridge_wr_data[15:8], bridge_wr_data[23:16], bridge_wr_data[31:24]} :
            bridge_wr_data;
end
reg [11:0] pbuf_addr;
reg [31:0] pbuf_q;
always @(posedge clk_74a) pbuf_q <= parse_buf[pbuf_addr];

///////////////////////////////////////////////
// CD mount controller + cue parser (clk_74a)
//
// On a CD-slot mount: sniff the file. Raw MODE1 sector sync -> direct BIN
// (single data track, as before). ASCII -> cue sheet: parse TRACK/INDEX
// lines into the track table, getfile the cue's path, swap the extension
// to .bin/.BIN (same-basename convention), openfile it into slot 2 and
// stream sectors from there.
///////////////////////////////////////////////
reg        mount_ready /*verilator public_flat_rd*/ = 0;
// 1 from the moment a .cue/.bin is picked until its TOC is final. Drives the
// CDD's tray-open-while-loading state, so the BIOS shows a drive busy with a
// disc for the whole load instead of NO DISC. Starts 0, so a boot with nothing
// mounted never shows a tray.
reg        mount_loading /* verilator public_flat_rd */ = 0;
reg        mount_use_slot2 = 0;
reg [31:0] mount_eff_size /* verilator public_flat_rd */ = 0;
reg [31:0] mounted_size = 0;
reg [6:0]  toc_track_count = 0;

// track table: written by the mount FSM (74a), read by the drive
// (clk_sys) and by the layout pass (74a) — duplicated RAMs, one write.
// Entry [55:0] = {audio(1), pregap[7:0], file[6:0], delta[19:0],
// disc_start[19:0]}: disc_start is INDEX 01 in DISC LBAs; delta maps a
// disc LBA back to a file LBA (disc - delta = file); pregap is the
// virtual (not-in-file) gap length before this track's INDEX 01.
reg [65:0] toc_ram_a [0:127];                              // rd: layout
reg [65:0] toc_ram_b [0:127] /* verilator public_flat_rd */; // rd: drive
reg  [6:0]  toc_wr_addr;
reg  [65:0] toc_wr_data;
reg         toc_wr_en = 0;
reg  [6:0]  toc_a_addr;
reg  [65:0] toc_a_q;
always @(posedge clk_74a) begin
    if (toc_wr_en) begin
        toc_ram_a[toc_wr_addr] <= toc_wr_data;
        toc_ram_b[toc_wr_addr] <= toc_wr_data;
    end
    toc_a_q <= toc_ram_a[toc_a_addr];
end
wire [6:0]  toc_rd_addr;
reg  [65:0] toc_rd_q;
always @(posedge clk_sys) toc_rd_q <= toc_ram_b[toc_rd_addr];

// file table: up to 128 FILE entries per cue (a Red Book disc allows 99
// tracks, one FILE each). Names live in parse_buf (resident after mount)
// as {offset, length} pointers.
reg [21:0] files_nm  [0:127];  // {name_off[13:0], name_len[7:0]}
reg [19:0] files_secs[0:127];  // file length in 2352-byte sectors
reg [6:0]  files_addr;
reg [21:0] files_nm_q;
reg [19:0] files_secs_q;
// Two-phase mount: the per-file size probe is ~30 host round-trips per
// file, so on real hardware a multi-bin cue takes seconds before the
// whole TOC is known. Disc-present must NOT wait for all of that or the
// BIOS boots to its no-disc idle panel ("PRESS START") before the disc
// appears, and only sees it via the late-insertion path. Instead: probe
// only file 0 (track 1 / the data track the boot reads), lay out a
// PRELIMINARY TOC (file 0 exact, the rest fallback) and assert the disc
// present-at-boot; then probe files 1..N-1 in the background and refine
// the TOC. Background probing yields slot 2 to drive fetches via M_IDLE
// (reopen_req has priority), so track-1 reads are never starved.
reg [127:0] fsecs_valid = 0;   // per-file "size probed" mask (else fallback)
reg        lay_prelim = 0;     // current layout is preliminary (more to come)
reg        pb_active = 0;      // background phase-2 probe running
reg [6:0]  pb_next = 0;        // next file index to background-probe
// Background probing must never starve the drive: the BIOS reads track 1
// (file 0) throughout CHECKING DISC and boot, and openfiling an audio bin
// to probe it swaps file 0 out of the single slot. So phase 2 only starts
// a probe after the drive fetch path has been idle a while (pb_idle), and
// ABORTS instantly (pb_yield) if a real fetch needs a different file — the
// drive then reopens within one openfile instead of stalling a full probe.
//
// The idle gate used to be bit 21 (~28ms). That is longer than the natural
// gaps in the drive's fetch pattern -- the bank fills, the head stops, and
// the next request lands well inside 28ms -- so on a multi-bin cue the
// refine could be deferred indefinitely while the disc was ALREADY
// advertised present carrying the preliminary (fallback) TOC. A BIOS that
// caches track starts in that window then plays every track from a stale
// LBA. Bit 14 (~220us @74MHz) still clears a burst but fits the real gaps.
// Starvation safety does not rest on this number: pb_yield aborts a probe
// the moment a fetch wants another file, and the search is now resumable
// (pr_valid), so a yielded probe resumes instead of restarting from zero.
reg [14:0] pb_idle = 0;        // clk_74a cycles since the last drive fetch
wire       pb_yield = pb_active && reopen_req && (reopen_file != opened_file);
wire       pb_ready = pb_idle[14];   // drive idle long enough to slip a probe in
always @(posedge clk_74a) begin
    files_nm_q   <= files_nm[files_addr];
    files_secs_q <= files_secs[files_addr];
end

localparam M_IDLE     = 5'd0,  M_SNIFF    = 5'd1,  M_SNIFF_W  = 5'd2,
           M_EVAL     = 5'd3,  M_PARSE    = 5'd4,  M_GETFILE  = 5'd5,
           M_DIRSCAN  = 5'd6,  M_BPATH_TAB= 5'd7,  M_BPATH    = 5'd8,
           M_BTAIL    = 5'd9,  M_OPENFILE = 5'd10, M_FSIZE    = 5'd11,
           M_FDIV     = 5'd12, M_LAYOUT   = 5'd13, M_READY    = 5'd14,
           M_FAIL     = 5'd15, M_PROBE_GO = 5'd16, M_PROBE_WT = 5'd17,
           M_PROBE_EV = 5'd18;
reg [4:0]  mnt_st = M_IDLE;
reg [3:0]  mnt_term = 0;   // overlay: 1=started, B=READY reached, C=FAILED
// latched swap request (see the pre-emption block at the end of the mount
// always block): holds the 008A notification until the read channel is quiet
// enough to restart the mount from whatever state the FSM was in.
reg        mount_req = 0;
reg [31:0] mount_req_size = 0;

// cue parser state
localparam CP_FETCH=3'd0, CP_FETCH_W=3'd1, CP_EVAL=3'd2, CP_DONE=3'd3;
reg [2:0]  cp_st;
reg [13:0] cp_p;          // byte pointer into parse_buf
reg [7:0]  cp_ch;
// line scanner: 0=at line start (skip ws, collect 2-char key), then per-key
localparam LN_START=4'd0, LN_KEY2=4'd1, LN_SKIP=4'd2,
           LN_TNUM_WS=4'd3, LN_TNUM=4'd4, LN_TTYPE_WS=4'd5,
           LN_INUM_WS=4'd6, LN_INUM=4'd7, LN_MSF_WS=4'd8, LN_MSF=4'd9,
           LN_PGAP_WS=4'd10, LN_FQUOTE=4'd11, LN_FNAME=4'd12;
reg [3:0]  cp_ln;
reg [7:0]  cp_key0;
reg [6:0]  cp_num;
reg [6:0]  cp_track;      // current TRACK number
reg [6:0]  cp_tmax;       // highest TRACK seen (published at READY)
reg        cp_audio;      // current track type
reg [6:0]  cp_idx;        // INDEX number
reg [6:0]  cp_mm, cp_ss, cp_ff;
reg [1:0]  cp_msf_pos;    // 0=mm 1=ss 2=ff
reg [24:0] mnt_tmo;       // per-file size watchdog (~0.45s @74MHz)
reg        cp_is_pgap;    // current MSF belongs to a PREGAP directive
reg [11:0] cp_pend_pgap;  // PREGAP seen for the current track
reg [7:0]  cp_files;      // FILE entries seen (file index = cp_files-1)
reg [13:0] cp_fname_off;  // name capture: offset of first char
reg [7:0]  cp_fname_len;
reg [19:0] cp_i00;        // INDEX 00 (in-file gap start), file-relative
reg        cp_i00_v;      // INDEX 00 seen for the current track
// path/dir scan shared counters
reg [7:0]  mp_w;
reg [1:0]  mp_ph;
reg [9:0]  mp_nul;        // NUL byte index in the getfile response
reg [9:0]  mp_dirlen;     // bytes of the path up to and incl. last '/'
reg        mp_found;
// path builder
reg [9:0]  bp_o;          // output byte index in the openfile param area
reg [2:0]  bp_ph;
reg [7:0]  bp_src;
reg [6:0]  mnt_file;      // file being opened (phase B / reopen)
reg        mnt_reopen = 0;
reg [6:0]  opened_file = 0;
reg [13:0] bp_nm_off;
reg [7:0]  bp_nm_len;
// per-file size divider + layout pass
reg [31:0] fdiv_in;       // dividend: size from 008A or the datatable
reg [31:0] fdiv_rem;
reg [19:0] fdiv_q;
reg [5:0]  fdiv_bit;
reg [31:0] fsize_prev;
reg [31:0] of_size = 0;   // size from the 008A slot-2 update notification
reg        of_size_new = 0;
// firmware-agnostic size probe: binary-search the opened file's sector
// count with 4-byte reads (reads past EOF fail with a nonzero result
// code on real firmware — the one size signal every firmware provides)
reg [20:0] pr_n, pr_lo, pr_hi;   // sector-count probe cursor / bounds
reg        pr_ok;
// a yielded probe keeps its bounds: pr_valid marks [pr_lo,pr_hi) as a live
// search for pr_file, so re-entering M_FSIZE for that same file resumes
// instead of paying the 2ms size-notification grace and reseeding [0,2^20)
// from scratch. Without this a drive fetch arriving mid-probe costs all the
// round-trips already spent, and a busy drive can starve the refine forever.
reg [6:0]  pr_file;
reg        pr_valid = 0;
reg        mnt_rd_err = 0;       // result of the last mount-channel read
reg [6:0]  lay_t;
reg [2:0]  lay_ph;
reg [19:0] lay_delta, lay_disc_end;
reg [6:0]  lay_prev_file;
reg [65:0] lay_e;

wire [7:0] pbuf_byte = (cp_p[1:0]==2'd0) ? pbuf_q[31:24] :
                       (cp_p[1:0]==2'd1) ? pbuf_q[23:16] :
                       (cp_p[1:0]==2'd2) ? pbuf_q[15:8]  : pbuf_q[7:0];
// parsed MSF as raw sectors. Cue INDEX times are FILE-relative: 00:00:00
// is file offset 0 = LBA 0 (the 150-sector lead-in pregap is NOT included
// in cue times — only REPORTS add it, as +150 when forming disc MSF).
// Flattened from ((mm*60 + ss)*75 + ff) to (mm*4500 + ss*75 + ff). These are
// algebraically identical (60*75 = 4500), but the original chained
// multiply -> add -> multiply -> add into a single combinational path: 12.8ns
// of logic in a 13.468ns clk_74a period, i.e. under 1ns of margin. It sat on
// whichever side of zero the placer happened to land, and blocked a build at
// -0.154ns. This form computes the two constant multiplies INDEPENDENTLY and
// sums once, roughly halving the depth. Both constants are cheap shift-adds
// (4500 = 4096+256+128+16+4, 75 = 64+8+2+1).
//
// Bit-exact: cp_mm/cp_ss/cp_ff are all 7-bit, so the widest term is
// 127*4500 = 571500 and the total cannot exceed 581152 -- no truncation or
// overflow in 32 bits, and no change to the parser state machine or latency.
wire [31:0] cp_raw = {25'd0,cp_mm}*32'd4500
                     + {25'd0,cp_ss}*32'd75
                     + {25'd0,cp_ff};
wire [7:0] cp_pgap8 = (cp_pend_pgap > 12'd255) ? 8'd255 : cp_pend_pgap[7:0];
// in-file gap before INDEX 01 (INDEX 00 region), clamped to 10 bits
wire [19:0] cp_gap_raw = cp_raw[19:0] - cp_i00;
wire [9:0]  cp_pre01 = (!cp_i00_v || cp_raw[19:0] < cp_i00) ? 10'd0 :
                       (cp_gap_raw > 20'd1023) ? 10'd1023 : cp_gap_raw[9:0];

always @(posedge clk_74a) begin
    target_dataslot_getfile <= 0;
    target_dataslot_openfile <= 0;
    fbuf_wr <= 0;
    toc_wr_en <= 0;
    // the load is over once the TOC is final. Cleared HERE, at the top, so the
    // set in the mount-start branch below wins if a new image is picked in the
    // same cycle (the previous disc still reads toc_final at that moment).
    if (toc_final_74) mount_loading <= 0;

    // drive-idle timer for background probing: cleared on every drive fetch
    // request, saturates at bit 14 (~220us @74MHz). pb_idle[14] means the
    // drive has read nothing for a while, so slipping a probe in is unlikely
    // to collide with an active read burst (CHECKING DISC/boot).
    if (cdreq_s[1]) pb_idle <= 0;
    else if (!pb_idle[14]) pb_idle <= pb_idle + 1'b1;

    // slot-2 openfile size: user-reloadable slots (data.json parameters
    // bit 0) get a 008A "slot updated" notification carrying the new size
    // after every openfile — layout-independent, unlike the datatable poll
    // below, which depends on the firmware's table row order. Stale
    // captures are cleared when the next openfile is issued (M_BTAIL).
    if (dataslot_update && dataslot_update_id == 16'd2) begin
        of_size <= dataslot_update_size;
        of_size_new <= 1;
    end

    case (mnt_st)
    M_IDLE: begin
        // tds_id owned here: reads target the mounted data slot; the
        // mount sequence overrides it per-operation below
        tds_id <= mount_use_slot2 ? 16'd2 : 16'd1;
        // the mount itself is started by the swap pre-emption block at the
        // bottom of this always block, not from here -- a new image can be
        // picked while the FSM is anywhere, so sampling it in M_IDLE only
        // dropped the ones that arrived mid-probe or mid-reopen.
        if (reopen_req && mount_ready
                     && reopen_file != opened_file) begin
            // playback crossed into a track stored in another bin: build
            // that file's path and openfile it into slot 2. The
            // opened_file guard kills a one-cycle race that double-ran
            // the reopen (its openfile then collided with the next
            // sector read's handshake). Higher priority than background
            // probing so a real drive fetch is never starved.
            mnt_file <= reopen_file;
            mnt_reopen <= 1;
            files_addr <= reopen_file;
            mnt_st <= M_BPATH_TAB;
        end else if (pb_active && !reopen_req && pb_ready) begin
            // phase-2 background probe: size the next audio-track bin, but
            // only once the drive has been idle a while (pb_idle) so we don't
            // swap file 0 out from under an active read. It opens pb_next
            // into slot 2 (opened_file follows); if the drive then needs
            // file 0 back mid-probe, pb_yield aborts us straight back here
            // and the reopen above wins.
            mnt_file <= pb_next;
            files_addr <= pb_next;
            mnt_reopen <= 0;
            mnt_st <= M_BPATH_TAB;
        end
    end
    M_SNIFF: if (mnt_rd_done) begin
        mnt_rd <= 0;
        pbuf_addr <= 0;
        // The sniff asks for mounted_size bytes -- the size the 008A just
        // reported for the NEW image. If the firmware served that read from
        // the PREVIOUS file and that file is shorter, APF fails the read
        // (past EOF) and parse_buf still holds the old cue. Parsing it
        // anyway mounts the previous disc's TOC under the new disc's name,
        // which is invisible until the CD player lists the wrong tracks.
        // Treat an errored sniff as a failed mount instead.
        mnt_st <= mnt_rd_err ? M_FAIL : M_SNIFF_W;
    end
    M_SNIFF_W: mnt_st <= M_EVAL;   // one cycle for pbuf_q
    M_EVAL: begin
        // raw sector: 00 FF FF FF...; anything printable-ASCII = cue text
        if (pbuf_q[31:24]==8'h00 && pbuf_q[23:16]==8'hFF) begin
            mount_eff_size <= mounted_size;     // direct BIN/ISO mount
            mnt_st <= M_READY;
        end else if (pbuf_q[31:24]>=8'h20 && pbuf_q[31:24]<=8'h7E) begin
            cp_p <= 0; cp_st <= CP_FETCH; cp_ln <= LN_START;
            cp_track <= 0; cp_tmax <= 0; cp_audio <= 0;
            cp_pend_pgap <= 0; cp_is_pgap <= 0; cp_files <= 0;
            mnt_st <= M_PARSE;
        end else begin
            mount_eff_size <= mounted_size;     // unknown: treat as BIN
            mnt_st <= M_READY;
        end
    end
    M_PARSE: begin
        case (cp_st)
        CP_FETCH: begin pbuf_addr <= cp_p[13:2]; cp_st <= CP_FETCH_W; end
        CP_FETCH_W: cp_st <= CP_EVAL;
        CP_EVAL: begin
            if (pbuf_byte==8'h00 || cp_p==14'h3FFF ||
                {18'd0,cp_p} >= mnt_len) cp_st <= CP_DONE;
            else begin
                cp_p <= cp_p + 1'b1;
                cp_st <= CP_FETCH;
                case (cp_ln)
                LN_START:
                    if (pbuf_byte==8'h0A || pbuf_byte==8'h0D ||
                        pbuf_byte==8'h20 || pbuf_byte==8'h09) ; // stay
                    else begin cp_key0 <= pbuf_byte; cp_ln <= LN_KEY2; end
                LN_KEY2: begin
                    if (cp_key0=="T" && pbuf_byte=="R") cp_ln <= LN_TNUM_WS;
                    else if (cp_key0=="I" && pbuf_byte=="N") cp_ln <= LN_INUM_WS;
                    else if (cp_key0=="P" && pbuf_byte=="R") cp_ln <= LN_PGAP_WS;
                    else if (cp_key0=="F" && pbuf_byte=="I") cp_ln <= LN_FQUOTE;
                    else cp_ln <= LN_SKIP;
                end
                // FILE "name.bin" BINARY — record a pointer into parse_buf
                LN_FQUOTE:
                    if (pbuf_byte==8'h22) begin
                        cp_fname_off <= cp_p + 1'b1;
                        cp_fname_len <= 0;
                        cp_ln <= LN_FNAME;
                    end else if (pbuf_byte==8'h0A) cp_ln <= LN_START;
                LN_FNAME:
                    if (pbuf_byte==8'h22) begin
                        if (cp_files < 8'd128) begin
                            files_nm[cp_files[6:0]] <= {cp_fname_off, cp_fname_len};
                            cp_files <= cp_files + 1'b1;
                        end
                        cp_ln <= LN_SKIP;
                    end else if (pbuf_byte==8'h0A) cp_ln <= LN_START;
                    else cp_fname_len <= cp_fname_len + 1'b1;
                // PREGAP mm:ss:ff — skip to the first digit, then MSF
                LN_PGAP_WS:
                    if (pbuf_byte>=8'h30 && pbuf_byte<=8'h39) begin
                        cp_mm <= pbuf_byte[6:0]-7'h30;
                        cp_ss <= 0; cp_ff <= 0; cp_msf_pos <= 0;
                        cp_is_pgap <= 1;
                        cp_ln <= LN_MSF;
                    end else if (pbuf_byte==8'h0A) cp_ln <= LN_START;
                LN_SKIP: if (pbuf_byte==8'h0A) cp_ln <= LN_START;
                // TRACK nn TYPE
                LN_TNUM_WS:
                    if (pbuf_byte>=8'h30 && pbuf_byte<=8'h39) begin
                        cp_num <= pbuf_byte[6:0]-7'h30; cp_ln <= LN_TNUM;
                    end else if (pbuf_byte==8'h0A) cp_ln <= LN_START;
                LN_TNUM:
                    if (pbuf_byte>=8'h30 && pbuf_byte<=8'h39)
                        cp_num <= cp_num*7'd10 + (pbuf_byte[6:0]-7'h30);
                    else begin
                        cp_track <= cp_num;
                        cp_i00_v <= 0;           // fresh track: no INDEX 00 yet
                        cp_ln <= LN_TTYPE_WS;
                    end
                LN_TTYPE_WS:
                    if (pbuf_byte=="A") begin cp_audio <= 1; cp_ln <= LN_SKIP; end
                    else if (pbuf_byte=="M") begin cp_audio <= 0; cp_ln <= LN_SKIP; end
                    else if (pbuf_byte==8'h0A) cp_ln <= LN_START;
                // INDEX nn mm:ss:ff
                LN_INUM_WS:
                    if (pbuf_byte>=8'h30 && pbuf_byte<=8'h39) begin
                        cp_num <= pbuf_byte[6:0]-7'h30; cp_ln <= LN_INUM;
                    end else if (pbuf_byte==8'h0A) cp_ln <= LN_START;
                LN_INUM:
                    if (pbuf_byte>=8'h30 && pbuf_byte<=8'h39)
                        cp_num <= cp_num*7'd10 + (pbuf_byte[6:0]-7'h30);
                    else begin
                        cp_idx <= cp_num;
                        cp_mm <= 0; cp_ss <= 0; cp_ff <= 0; cp_msf_pos <= 0;
                        cp_ln <= LN_MSF;
                    end
                LN_MSF: begin
                    if (pbuf_byte>=8'h30 && pbuf_byte<=8'h39) begin
                        case (cp_msf_pos)
                        2'd0: cp_mm <= cp_mm*7'd10 + (pbuf_byte[6:0]-7'h30);
                        2'd1: cp_ss <= cp_ss*7'd10 + (pbuf_byte[6:0]-7'h30);
                        default: cp_ff <= cp_ff*7'd10 + (pbuf_byte[6:0]-7'h30);
                        endcase
                    end else if (pbuf_byte==":") begin
                        cp_msf_pos <= cp_msf_pos + 1'b1;
                    end else begin
                        // end of MSF
                        if (cp_is_pgap) begin
                            // PREGAP: virtual sectors, accumulate only
                            cp_pend_pgap <= cp_pend_pgap + cp_raw[11:0];
                        end else if (cp_idx==7'd0 && cp_track!=0) begin
                            // INDEX 00: remember the in-file gap start
                            cp_i00 <= cp_raw[19:0];
                            cp_i00_v <= 1;
                        end else if (cp_idx==7'd1 && cp_track!=0
                                     && cp_files!=0) begin
                            // INDEX 01: store a PRE-LAYOUT entry — the
                            // disc field temporarily holds the FILE lba;
                            // M_LAYOUT rewrites it once sizes are known
                            toc_wr_addr <= cp_track;
                            toc_wr_data <= {cp_audio, cp_pgap8, cp_pre01,
                                            cp_files[6:0]-7'd1,
                                            20'd0, cp_raw[19:0]};
                            toc_wr_en <= 1;
                            cp_pend_pgap <= 0;
                            cp_i00_v <= 0;
                            if (cp_track > cp_tmax) cp_tmax <= cp_track;
                        end
                        cp_is_pgap <= 0;
                        cp_ln <= (pbuf_byte==8'h0A) ? LN_START : LN_SKIP;
                    end
                end
                default: cp_ln <= LN_SKIP;
                endcase
            end
        end
        CP_DONE: begin
            if (cp_tmax == 0 || cp_files == 0) begin
                mount_eff_size <= mounted_size; // not a usable cue: raw mount
                mnt_st <= M_READY;
            end else begin
                tds_id <= 16'd1;
                target_dataslot_getfile <= 1;
                mnt_st <= M_GETFILE;
            end
        end
        endcase
    end
    M_GETFILE: if (target_dataslot_file_done) begin
        // scan the returned path: find the NUL and the last '/' — the
        // directory prefix is reused for every bin the cue references
        mp_w <= 0; mp_ph <= 0; mp_found <= 0; mp_dirlen <= 0;
        mnt_st <= M_DIRSCAN;
    end
    M_DIRSCAN: begin
        case (mp_ph)
        2'd0: begin fbuf_addr <= {2'd0, mp_w[7:2]}; mp_ph <= 2'd1; end
        2'd1: mp_ph <= 2'd2;
        2'd2: begin : dirscan
            reg [7:0] b;
            b = (mp_w[1:0]==2'd0) ? fbuf_q[31:24] :
                (mp_w[1:0]==2'd1) ? fbuf_q[23:16] :
                (mp_w[1:0]==2'd2) ? fbuf_q[15:8]  : fbuf_q[7:0];
            if (b == 8'h00) begin
                // no separator at all -> dirlen 0: pass bare names and let
                // the firmware resolve them (fails at openfile if it can't)
                mp_found <= 1;
                mnt_file <= 0;
                files_addr <= 0;
                // mp_ph is 2 right now, and M_BPATH_TAB latches the name
                // pointer on mp_ph == 2 -- so without this reset it fires on
                // its FIRST cycle, one edge after files_addr changed, while
                // files_nm_q still holds the entry for the PREVIOUS
                // files_addr. Its whole reason to exist is to cover that
                // read latency. Rewinding to 0 restores the 3-cycle wait.
                //
                // This was masked at power-up (files_addr is 0, so the stale
                // entry happened to be the right one) and masked whenever the
                // drive last touched file 0, but on a disc SWAP files_addr
                // still points wherever the previous image left it -- the
                // last background probe or reopen. Phase 1 then sized the
                // wrong bin as file 0, so the new disc mounted with a TOC
                // short (or long) by the difference between that bin and the
                // real track 1: Sonic CD -> Dark Wizard mid-probe laid out
                // 100911 sectors against a true 257858.
                mp_ph <= 2'd0;
                mnt_st <= M_BPATH_TAB;
            end else begin
                if (b == 8'h2F || b == 8'h5C)            // '/' or '\'
                    mp_dirlen <= {2'd0, mp_w} + 10'd1;
                if (mp_w == 8'd255) mnt_st <= M_FAIL;    // no NUL: malformed
                mp_w <= mp_w + 1'b1;
                mp_ph <= 2'd0;
            end
        end
        default: mp_ph <= 0;
        endcase
    end
    M_BPATH_TAB: begin
        // files_nm_q latency, then latch the name pointer
        mp_ph <= mp_ph + 1'b1;
        if (mp_ph == 2'd2) begin
            bp_nm_off <= files_nm_q[21:8];
            bp_nm_len <= files_nm_q[7:0];
            bp_o <= 0; bp_ph <= 0;
            mp_ph <= 0;
            mnt_st <= M_BPATH;
        end
    end
    M_BPATH: begin
        // build "<dir><name>\0" into the openfile param area, byte-serial:
        // fetch source byte (dir from fbuf, name from parse_buf), then RMW
        // it into the destination fbuf word
        case (bp_ph)
        3'd0: begin
            if (bp_o >= mp_dirlen + {2'd0, bp_nm_len} + 10'd1) begin
                bp_ph <= 0; mp_w <= 0;
                mnt_st <= M_BTAIL;
            end else begin
                fbuf_addr <= {2'd0, bp_o[7:2]};           // dir source word
                pbuf_addr <= (bp_nm_off + {4'd0, bp_o - mp_dirlen}) >> 2;
                bp_ph <= 3'd1;
            end
        end
        3'd1: bp_ph <= 3'd2;
        3'd2: begin : bpsrc
            reg [13:0] nidx;
            nidx = bp_nm_off + {4'd0, bp_o - mp_dirlen};
            if (bp_o >= mp_dirlen + {2'd0, bp_nm_len})
                bp_src <= 8'h00;                          // terminator
            else if (bp_o < mp_dirlen)
                bp_src <= (bp_o[1:0]==2'd0) ? fbuf_q[31:24] :
                          (bp_o[1:0]==2'd1) ? fbuf_q[23:16] :
                          (bp_o[1:0]==2'd2) ? fbuf_q[15:8]  : fbuf_q[7:0];
            else
                bp_src <= (nidx[1:0]==2'd0) ? pbuf_q[31:24] :
                          (nidx[1:0]==2'd1) ? pbuf_q[23:16] :
                          (nidx[1:0]==2'd2) ? pbuf_q[15:8]  : pbuf_q[7:0];
            fbuf_addr <= 8'd128 + {1'd0, bp_o[8:2]};      // dest word
            bp_ph <= 3'd3;
        end
        3'd3: bp_ph <= 3'd4;
        3'd4: begin : bpdst
            reg [31:0] w;
            w = fbuf_q;
            case (bp_o[1:0])
            2'd0: w[31:24] = bp_src;
            2'd1: w[23:16] = bp_src;
            2'd2: w[15:8]  = bp_src;
            2'd3: w[7:0]   = bp_src;
            endcase
            fbuf_di <= w;
            fbuf_wr <= 1;
            bp_o <= bp_o + 1'b1;
            bp_ph <= 3'd0;
        end
        default: bp_ph <= 0;
        endcase
    end
    M_BTAIL: begin
        // flags (word 192) = 0, then size (word 193) = 0, then openfile
        fbuf_addr <= 8'd192 + {7'd0, mp_w[0]};
        fbuf_di <= 32'd0;
        fbuf_wr <= 1;
        if (mp_w[0]) begin
            mp_w <= 0;
            tds_id <= 16'd2;
            fsize_prev <= cd_bin_size;
            of_size_new <= 0;
            target_dataslot_openfile <= 1;
            mnt_st <= M_OPENFILE;
        end else mp_w <= 8'd1;
    end
    M_OPENFILE: if (target_dataslot_file_done) begin
        // result 0 = opened, 1 = created(+opened); anything else = missing bin
        if (target_dataslot_err <= 3'd1) begin
            if (mnt_reopen) begin
                opened_file <= mnt_file;
                mnt_reopen <= 0;
                mnt_st <= M_IDLE;
            end else begin
                // slot 2 now physically holds this file; keep opened_file
                // in step so the drive's reopen logic is accurate even
                // while we probe in the background (mount_ready already up)
                opened_file <= mnt_file;
                mnt_tmo <= 25'd1;
                mnt_st <= M_FSIZE;
            end
        end else begin
            mnt_reopen <= 0;
            mnt_st <= M_FAIL;
        end
    end
    M_FSIZE: if (pb_yield) mnt_st <= M_IDLE;
    // resume a probe this file already started (see pr_valid): its bounds
    // are still live, so skip the grace + reseed and issue the next read
    else if (pr_valid && pr_file == mnt_file) mnt_st <= M_PROBE_GO;
    else begin
        // learn the opened file's size. Primary: the 008A notification
        // captured above (of_size_new) — real firmware sends it for
        // user-reloadable slots and it carries the size directly.
        // Secondary: the datatable poll (word 7 = slot 2's row in our
        // data.json order). On timeout accept an unchanged value
        // (equal-size files) if sane, else mark the size unknown (0) —
        // the layout pass falls back to "last track's file lba + margin"
        // so the mount NEVER hard-fails just because the firmware's
        // table layout differs.
        mnt_tmo <= mnt_tmo + 1'b1;
        if (of_size_new && of_size >= 32'd2352) begin
            fdiv_in <= of_size;
            fdiv_rem <= 0; fdiv_q <= 0; fdiv_bit <= 6'd32;
            mnt_st <= M_FDIV;
        end else if (cd_bin_size >= 32'd2352 && cd_bin_size != fsize_prev) begin
            fdiv_in <= cd_bin_size;
            fdiv_rem <= 0; fdiv_q <= 0; fdiv_bit <= 6'd32;
            mnt_st <= M_FDIV;
        end else if (mnt_tmo == 25'd150000) begin
            // ~2ms grace passed with no size notification: real firmware
            // does not publish sizes for core-initiated openfiles (verified
            // on hardware — not even with the slot user-reloadable). Probe
            // the sector count directly: a 4-byte read at n*2352-4 succeeds
            // iff the file holds >= n whole sectors. The upper bound is known
            // a priori (a Red Book CD can't reach 2^20 sectors), so seed
            // [floor, ceiling] and binary-search from the start — the old
            // exponential-doubling phase to discover a ceiling was pure
            // overhead. ~20 host round-trips/file, constant regardless of
            // size, vs ~30 that grew with it. (MiSTer skips this probe
            // entirely by stat()ing the bin on its Linux host; APF exposes no
            // file size for core openfiles, so read-past-EOF is all we have.)
            pr_lo <= 21'd0;              // known-good floor (>=0 sectors; never tested)
            pr_hi <= 21'h100000;         // known-bad ceiling: no CD reaches 2^20 sectors
            pr_n  <= 21'h080000;         // first probe = midpoint of [0, 2^20]
            pr_file <= mnt_file;         // bounds now belong to this file...
            pr_valid <= 1;               // ...and survive a pb_yield abort
            mnt_st <= M_PROBE_GO;
        end
    end
    M_PROBE_GO: if (pb_yield) mnt_st <= M_IDLE;
        else if (!mnt_rd_done) begin
        mnt_offset <= ({11'd0, pr_n} << 11) + ({11'd0, pr_n} << 8)
                    + ({11'd0, pr_n} << 5)  + ({11'd0, pr_n} << 4) - 32'd4;
        mnt_len <= 32'd4;
        mnt_rd <= 1;
        mnt_st <= M_PROBE_WT;
    end
    M_PROBE_WT: if (mnt_rd_done) begin
        mnt_rd <= 0;
        pr_ok  <= !mnt_rd_err;
        mnt_st <= M_PROBE_EV;
    end else if (pb_yield) begin
        // THE deadlock: the drive needs file 0 but a probe opened another
        // bin, so the cdf arbiter (drive-fetch priority) refuses to serve
        // our probe read while the drive's blocked fetch is pending —
        // mnt_rd_done never comes and we'd wait here forever, never
        // reaching M_IDLE to service the reopen. Drop the probe read and
        // bail so the reopen runs and the drive gets file 0 back; retry
        // pb_next later.
        mnt_rd <= 0;
        mnt_st <= M_IDLE;
    end
    M_PROBE_EV: if (pb_yield) mnt_st <= M_IDLE; else begin : probe_ev
        // pr_lo = largest sector count known to fit; pr_hi = smallest known
        // NOT to fit. Both seeded in M_FSIZE, so pr_hi is never 0 and this is
        // a pure binary search (no ceiling-discovery branch). A file that
        // actually reaches 2^20 sectors converges to nlo == 0xFFFFF — the
        // same clamp the old exponential path applied at its 2^20 ceiling.
        reg [20:0] nlo, nhi;
        nlo = pr_ok ? pr_n : pr_lo;
        nhi = pr_ok ? pr_hi : pr_n;
        pr_lo <= nlo; pr_hi <= nhi;
        if (nhi - nlo <= 21'd1) begin
            // fdiv_bit==0 drops straight into M_FDIV's store+advance.
            fdiv_q <= nlo[19:0]; fdiv_bit <= 0; mnt_st <= M_FDIV;
        end else begin
            pr_n <= (nlo + nhi) >> 1; mnt_st <= M_PROBE_GO;
        end
    end
    M_FDIV: begin : fdiv
        // sectors = size / 2352, restoring divider
        reg [31:0] r;
        if (fdiv_bit == 0) begin
            files_secs[mnt_file] <= fdiv_q;
            fsecs_valid[mnt_file] <= 1'b1;
            pr_valid <= 0;             // this file is sized; bounds retired
            if (!mount_ready) begin
                // PHASE 1: file 0 (track 1 / the data track boot reads) is
                // now sized. Lay out a preliminary TOC — file 0 exact, the
                // rest fallback — and assert the disc present-at-boot. If
                // this is the only file, the preliminary layout is final.
                lay_prelim <= (cp_files > 8'd1);
                lay_t <= 7'd1; lay_ph <= 0;
                lay_delta <= 0; lay_disc_end <= 0;
                lay_prev_file <= 7'h7F;
                mnt_st <= M_LAYOUT;
            end else if ({1'b0, pb_next} + 8'd1 < cp_files) begin
                // PHASE 2: more audio bins to size — yield through M_IDLE
                pb_next <= pb_next + 1'b1;
                mnt_st <= M_IDLE;
            end else begin
                // PHASE 2 done: refine the TOC now every file size is known
                pb_active <= 0;
                lay_prelim <= 0;
                lay_t <= 7'd1; lay_ph <= 0;
                lay_delta <= 0; lay_disc_end <= 0;
                lay_prev_file <= 7'h7F;
                mnt_st <= M_LAYOUT;
            end
        end else begin
            r = {fdiv_rem[30:0], fdiv_in[fdiv_bit-1]};
            if (r >= 32'd2352) begin
                fdiv_rem <= r - 32'd2352;
                fdiv_q   <= {fdiv_q[18:0], 1'b1};
            end else begin
                fdiv_rem <= r;
                fdiv_q   <= {fdiv_q[18:0], 1'b0};
            end
            fdiv_bit <= fdiv_bit - 1'b1;
        end
    end
    M_LAYOUT: begin
        // place every track on the disc now that file sizes are known:
        // delta(t) = disc base of its file + accumulated pregaps; the
        // final cursor is the true disc leadout
        case (lay_ph)
        3'd0: begin toc_a_addr <= lay_t; lay_ph <= 3'd1; end
        3'd1: lay_ph <= 3'd2;
        3'd2: begin
            lay_e <= toc_a_q;
            files_addr <= toc_a_q[46:40];
            lay_ph <= 3'd3;
        end
        3'd3: lay_ph <= 3'd4;
        3'd4: begin : layw
            reg [19:0] d, foff;
            d = (lay_e[46:40] != lay_prev_file) ? lay_disc_end : lay_delta;
            d = d + {12'd0, lay_e[64:57]};        // + this track's pregap
            // recover the in-FILE lba (disc - delta) so this pass is
            // idempotent: the two-phase mount lays the TOC out twice (a
            // preliminary pass to make the disc present-at-boot, then a
            // refine once every bin's size is probed), and the disc field
            // holds the absolute lba after the first pass, not the file lba
            foff = lay_e[19:0] - lay_e[39:20];
            toc_wr_addr <= lay_t;
            toc_wr_data <= {lay_e[65:40], d, foff + d};
            toc_wr_en <= 1;
            lay_delta <= d;
            // unknown file size (0): approximate its extent as the last
            // track's start + ~6 minutes, recomputed each track so the
            // value consumed at the next file boundary uses the file's
            // final track
            // exact size once the file is probed; until then (preliminary
            // layout, or a background-probe still pending) fall back to
            // "this track's start + ~6 min" so the disc has a usable extent
            lay_disc_end <= d + (fsecs_valid[lay_e[46:40]] ? files_secs_q
                                 : (lay_e[19:0] + 20'd27000));
            lay_prev_file <= lay_e[46:40];
            if (lay_t == cp_tmax) lay_ph <= 3'd5;
            else begin
                lay_t <= lay_t + 1'b1;
                lay_ph <= 3'd0;
            end
        end
        3'd5: begin
            mount_eff_size <= {12'd0, lay_disc_end} * 32'd2352;
            toc_track_count <= cp_tmax;
            mount_use_slot2 <= 1;
            opened_file <= mnt_file;   // file open in slot 2 right now
            mount_ready <= 1;          // present-at-boot: disc appears now
            mnt_term <= 4'hB;
            if (lay_prelim) begin
                // preliminary layout done — boot can read track 1; size
                // the remaining bins in the background and refine later
                pb_active <= 1;
                pb_next  <= 6'd1;
            end
            mnt_st <= M_IDLE;
        end
        default: lay_ph <= 0;
        endcase
    end
    M_READY: begin
        mount_ready <= 1;
        mnt_term <= 4'hB;
        mnt_st <= M_IDLE;
    end
    M_FAIL: begin
        // leave unmounted (drive keeps reporting NO_DISC).
        // mount_loading MUST be dropped here: it is otherwise only cleared by
        // toc_final_74, which needs mount_ready, which a failed mount never
        // sets. Left up, the drive holds the tray open forever (the
        // disc_loading branch in the CDD) and the BIOS sits on CLOSE THE CD
        // DOOR with no way out. Clearing it lets the drive's "loading done
        // with no media" path retire to NO_DISC and the BIOS return to its
        // idle panel. The common trigger is a cue whose bin lives outside
        // /Assets/megacd/ or /Saves/megacd/: APF refuses the openfile (0192
        // only resolves paths under the platforms the core declares), so any
        // cue/bin picked from elsewhere on the card lands here.
        mount_loading <= 0;
        mnt_term <= 4'hC;
        mnt_st <= M_IDLE;
    end
    endcase

    ///////////////////////////////////////////////
    // swap pre-emption -- MUST stay after the case: its assignments
    // deliberately override whatever state the FSM just scheduled.
    //
    // A new image can be picked at ANY moment. dataslot_update (host command
    // 0x008A, the firmware's deferload notification carrying slot id + size)
    // is a ~2-cycle pulse, and it used to be sampled only in the M_IDLE arm
    // above. Every swap that landed while the FSM was elsewhere was dropped
    // outright -- and the FSM is elsewhere for a LONG time: phase-2
    // background probing walks files 1..N-1 at ~20 host round-trips each
    // (seconds on a 50-file cue, exactly when a disc gets swapped), and
    // every CD-audio track crossing into another bin runs a reopen. A
    // dropped swap leaves the PREVIOUS image mounted, so the BIOS and the
    // CD player go on showing the old disc's TOC until the slot is picked
    // again. Latch it instead, and let it pre-empt: a user swap always wins.
    //
    // Aborting mid-flight is safe as long as the host read channel is left
    // alone to drain. Dropping mnt_rd does not disturb a transaction already
    // handed to the bridge (tds_* are latched), so the abort just releases
    // the request and waits for the arbiter to retire it: cdf_st back to 0
    // with mnt_rd_done low. Restarting before that would re-raise mnt_rd
    // while the arbiter still sat in its state 3 -- it would never observe
    // mnt_rd low, never clear mnt_rd_done, and the fresh M_SNIFF would
    // accept that stale done and parse the PREVIOUS disc's cue text out of
    // parse_buf. Whatever data the aborted read lands in parse_buf is
    // harmless; the new sniff overwrites it. The getfile/openfile channel
    // needs no such guard: core_bridge_cmd serialises those, so a new
    // request cannot issue until the aborted one has completed.
    ///////////////////////////////////////////////
    if (dataslot_update && dataslot_update_id == 16'd1
        && dataslot_update_size != 32'd0) begin
        mount_req      <= 1;
        mount_req_size <= dataslot_update_size;
    end
    if (mount_req) begin
        mnt_rd <= 0;                 // release the channel so it can drain
        if (cdf_st == 2'd0 && !mnt_rd_done) begin
            mounted_size <= mount_req_size;
            mount_ready <= 0;
            mount_loading <= 1;  // tray opens now; closes when the TOC lands
            mount_use_slot2 <= 0;
            toc_track_count <= 0;
            mnt_offset <= 0;
            // round DOWN to a whole word: a read past EOF (even one byte,
            // from rounding up an unaligned cue size) is a firmware error
            mnt_len <= (mount_req_size < 32'd16384)
                       ? {mount_req_size[31:2], 2'b00} : 32'd16384;
            mnt_rd <= 1;
            tds_id <= 16'd1;         // sniff reads the CD slot itself
            mnt_term <= 4'h1;
            mnt_reopen <= 0;
            pb_active <= 0;          // cancel any prior background probe
            pr_valid <= 0;           // and any partial probe bounds with it
            lay_prelim <= 0;
            fsecs_valid <= 0;        // all file sizes unknown until probed
            mount_req <= 0;
            mnt_st <= M_SNIFF;
        end
    end
end
wire [11:0] cd_buf_addr;    // clk_sys ({slot[1:0], word[9:0]})
reg  [31:0] cd_buf_q;
always @(posedge clk_sys) cd_buf_q <= cd_buf[cd_buf_addr];

// overlay debug shadow: sector-buffer word 4 = file bytes 16..19; for a
// data sector 0 this is "SEGA" -> shows 41474553 when byte order is right
reg [31:0] dbg_cd_word4 = 0;
always @(posedge clk_74a)
    if (bridge_wr && bridge_addr == 32'h70000010) dbg_cd_word4 <= cd_buf_wd;

////////////////////////////////////////////////////////////////////////////////////////
// Core Settings
///////////////////////////////////////////////

// System
reg [11:0] reset_counter 		 = 0;
reg [15:0] reset_delay			 = 0;
// Registered zero-detect for reset_delay. reset_delay lives in clk_74a but
// gates the reset release of gen/MCD/CART, all of which run on clk_sys -- a
// different, asynchronous domain. Letting the raw 16-bit compare cross meant
// (a) the combinational zero-detect could glitch mid-decrement, when many
// bits flip at once (0x0100 -> 0x00FF), and (b) with no synchronizer, the
// destination flops could latch the release on different clk_sys edges, so
// parts of the design left reset a cycle before others. Reduce it to one
// registered bit here, then synchronize it once (reset_delay_done below).
reg        reset_delay_zero	 = 1;
// CD access time (menu). 0 = accurate seek timing (default), 1 = fast.
reg       cs_cd_fast             = 0;
reg cs_menu_pause_enable		 = 0;

// Video 
reg cs_obj_limit_high_enable  	 = 1;
reg cs_ar_correction_enable   	 = 0;
reg cs_composite_enable       	 = 0;
reg cs_auto_composite_enable  	 = 0;

// Audio
reg cs_fm_enable 			     = 1;
reg cs_psg_enable             	 = 1;
reg cs_hifi_pcm_enable	         = 1;
reg [1:0] cs_audio_filter	 	 = 0;
reg cs_fm_chip	 		 		 = 0;

// Input
reg cs_m30_map_enable            = 0;
reg lightgun_enabled             = 0;
reg show_crosshair               = 1;
reg [7:0] dpad_aim_speed         = 4;
reg cs_debug_overlay             = 0;

always @(posedge clk_74a) begin
    reset_counter = reset_counter + 1;
    if (~osnotify_inmenu && reset_delay > 0) begin
      reset_delay <= reset_delay - 1;
      if (reset_delay == 1) reset_delay_zero <= 1;
    end

	if (bridge_wr) begin
      casex (bridge_addr)
        32'h00F00000: cs_audio_filter			<= bridge_wr_data[1:0];
        32'h00A00000: cs_fm_chip                <= bridge_wr_data[0];
        // 0x00C00000 (CPU Turbo) intentionally absent: this core has no
        // turbo. gen.sv hardcodes the 68000 divider (/7) and has no TURBO
        // port -- the Genesis core's system.sv is what uses it, for
        // VCLKMAX/VCLKMID. The register here was written and never read, so
        // the menu entry accepted a setting the hardware ignored. Removed
        // from interact.json too; do not re-add without wiring gen.sv.
        32'h00000120: cs_cd_fast                <= bridge_wr_data[0];
        // 0x00000000 (Multitap) intentionally absent, same story as turbo:
        // MULTITAP is tied to 3'b000 at the gen instance below, so the
        // register was written and never read and teamplayer/fourway were
        // synthesized away. Removed from interact.json too; do not re-add
        // without also driving MULTITAP.
        32'h00000010: cs_ar_correction_enable 	<= bridge_wr_data[0];
        32'h00000020: begin
          cs_composite_enable <= bridge_wr_data[0];
          cs_auto_composite_enable <= bridge_wr_data[1];
        end
        32'h00000030: cs_obj_limit_high_enable	<= bridge_wr_data[0];
        32'h00000040: cs_fm_enable 				<= bridge_wr_data[0];
        32'h00000050: cs_psg_enable 			<= bridge_wr_data[0];
        32'h00000060: cs_hifi_pcm_enable 		<= bridge_wr_data[0];
        32'h00000070: begin
            if (bridge_wr_data[31:0] > 0) begin
              reset_delay <= {reset_counter, 4'b1111};
              reset_delay_zero <= 0;   // assert immediately; this branch wins over the decrement above
            end
          end
		32'h00000080: cs_m30_map_enable         <= bridge_wr_data[0];
		32'h00000090: cs_menu_pause_enable      <= bridge_wr_data[0];
        32'h00000100: lightgun_enabled          <= bridge_wr_data[0];
        32'h00000104: show_crosshair            <= bridge_wr_data[0];
        32'h00000108: dpad_aim_speed            <= bridge_wr_data[7:0];
        32'h00000110: cs_debug_overlay          <= bridge_wr_data[0];
      endcase
    end
end

///////////////////////////////////////////////
// Save/Load
///////////////////////////////////////////////

wire [31:0] sd_read_data;

wire sd_rd;
wire sd_wr;

wire [16:0] sd_buff_addr_in;
wire [16:0] sd_buff_addr_out;

// Lowest bit is for byte addressing
wire [15:0] sd_buff_addr = sd_wr ? sd_buff_addr_in[16:1] : sd_buff_addr_out[16:1];

wire [15:0] sd_buff_din;
wire [15:0] sd_buff_dout;

reg [31:0] cd_bin_size = 0;   // CD Data slot (id 2) size after openfile
// Data-slot table scan.
//
// The table is a list of {id, size} word PAIRS, and its ROW ORDER is
// firmware-defined -- it is NOT guaranteed to follow our data.json order.
// This scan used to hardcode the positions (word 5 = CD Image, word 7 = CD
// Data) on the assumption that it did. A firmware that orders rows any other
// way (sorting by id, say -- our data.json declares 0, 10, 1, 2, so sorted
// order alone moves CD Data's size from word 7 to word 5) then silently
// yields some other slot's size. That is the most likely reason "the
// firmware never publishes a size for a core-initiated openfile" looked true
// and motivated the ~21-round-trip binary-search probe in M_FSIZE.
//
// So match on the slot ID and take the NEXT word, exactly as the PC Engine
// CD core's MPU firmware does (dataslot_search_id + dataslot_size in its
// drivers/apf/apf.cpp). The probe remains the fallback: M_FSIZE only
// believes cd_bin_size once it is >= one sector, so a miss still degrades to
// probing rather than to a wrong size.
//
// NOTE: the Save-slot size write below still targets a fixed row (index 1).
// If row order really does vary, that write has the same latent bug -- left
// alone here because it is a separate function and saves are working.
localparam [4:0] DT_WORDS = 5'd16;      // 8 {id,size} pairs; we declare 4 slots
reg [ 5:0] dt_scan = 0;                 // 2 clk_74a per word
wire [4:0] dt_w    = dt_scan[5:1];      // word index being presented
wire [4:0] dt_prev = dt_w - 5'd1;       // word index datatable_q reflects
reg [31:0] dt_id = 32'hFFFFFFFF;        // id word of the pair in flight
reg [31:0] dbg_dtable [0:7];
always @(posedge clk_74a or negedge pll_core_locked) begin
	if (~pll_core_locked) begin
		datatable_addr <= 0;
		datatable_data <= 0;
		datatable_wren <= 0;
		dt_scan <= 0;
		dt_id <= 32'hFFFFFFFF;
	end else begin
		if (dt_w <= DT_WORDS) begin
			datatable_wren <= 0;
			datatable_addr <= {5'd0, dt_w};
			if (dt_scan[0] && dt_w != 0) begin
				// q now reflects the PREVIOUS address (held 2 cycles)
				if (dt_prev < 5'd8) dbg_dtable[dt_prev[2:0]] <= datatable_q;
				if (!dt_prev[0]) dt_id <= datatable_q;   // even word = slot id
				// odd word = that slot's size. Only id 2 (CD Data) has a
				// consumer; the BIOS and CD Image sizes reach the mount FSM
				// through the 008A notification instead.
				else if (dt_id == 32'd2) cd_bin_size <= datatable_q;
			end
		end else begin
			// sweep done: advertise the Save slot size, then restart
			datatable_wren <= 1;
`ifdef MCD_SAVE_DUMP
			// DEBUG: advertise the save slot as 512KB = full PRG-RAM dump
			datatable_data <= 32'd524288;
`else
			// advertise the Save slot as the 8KB internal backup RAM
			datatable_data <= 32'd8192;
`endif
			datatable_addr <= 1 * 2 + 1;          // data slot index 1, not id 1
		end

		dt_scan <= (dt_scan == 6'd35) ? 6'd0 : dt_scan + 1'b1;
	end
end

// Save-slot readback. Default: the 8KB internal backup RAM, read back on exit
// so the Pocket writes it to the .sav (read_data <- backup_ram.q_b via
// sd_buff_din, assigned near backup_ram). With MCD_SAVE_DUMP defined: a 512KB
// PRG-RAM dump for the M2 co-sim instead. dump_* feed the SDRAM port-2
// arbiter below; tied off (pruned) in the default build.
wire        dump_active;
wire        dump_rd;
wire [18:1] dump_word;
`ifdef MCD_SAVE_DUMP
// ---- DEBUG: 512KB save slot sourced from PRG-RAM via SDRAM port 2 ----
// On exit the Pocket reads all 512KB and writes it to the .sav — a dump of
// the decompressed sub-BIOS for the M2 co-sim.
wire [18:0] dump_addr_out;
data_unloader #(
	.ADDRESS_MASK_UPPER_4(4'h6),
	.ADDRESS_SIZE(19),
	.READ_MEM_CLOCK_DELAY(48),
	.INPUT_WORD_SIZE(2)
) save_data_unloader (
	.clk_74a(clk_74a),
	.clk_memory(clk_sys),

	.bridge_rd(bridge_rd),
	.bridge_endian_little(bridge_endian_little),
	.bridge_addr(bridge_addr),
	.bridge_rd_data(sd_read_data),

	.read_en  (sd_rd),
	.read_addr(dump_addr_out),
	.read_data(sd_buff_din)
);
assign sd_buff_addr_out = {dump_addr_out[16:0]};

// PRG-RAM dump reader: each save read triggers an SDRAM port-2 read of the
// PRG word; result held until the unloader latches it (delay 48).
reg [18:1] dump_word_r;
reg        dump_active_r = 0;
reg        dump_pend = 0;
reg        dump_rd_r = 0;
reg [15:0] dump_data = 0;
reg        sd_rd_d = 0;
always @(posedge clk_sys) begin
	reg old_busy_d;
	old_busy_d <= sdld_busy;
	sd_rd_d <= sd_rd;
	// never hijack the shared SDRAM port mid-transaction: queue the dump
	// request and start it only when the word-RAM arbiter and the debug
	// sampler are idle (they in turn hold off while dump_active)
	if (sd_rd & ~sd_rd_d) begin
		dump_word_r <= dump_addr_out[18:1];
		dump_pend <= 1;
	end
	if (dump_pend && !dump_active_r && !wr_active && !dbg_prg_active
	    && !(grant0_rd | grant0_wr | grant1_rd | grant1_wr)) begin
		dump_pend     <= 0;
		dump_active_r <= 1;
		dump_rd_r     <= 1;
	end else if (dump_active_r) begin
		if (dump_rd_r && old_busy_d && ~sdld_busy) begin
			dump_data     <= sdwr_do;
			dump_rd_r     <= 0;
			dump_active_r <= 0;
		end
	end
end
assign sd_buff_din = dump_data;
assign dump_active = dump_active_r;
assign dump_rd     = dump_rd_r;
assign dump_word   = dump_word_r;
`else
// ---- default: 8KB internal backup RAM (sd_buff_din <- bram_sd_q below) ----
data_unloader #(
	.ADDRESS_MASK_UPPER_4(4'h6),
	.ADDRESS_SIZE(17),
	.READ_MEM_CLOCK_DELAY(7),
	.INPUT_WORD_SIZE(2)
) save_data_unloader (
	.clk_74a(clk_74a),
	.clk_memory(clk_sys),

	.bridge_rd(bridge_rd),
	.bridge_endian_little(bridge_endian_little),
	.bridge_addr(bridge_addr),
	.bridge_rd_data(sd_read_data),

	.read_en  (sd_rd),
	.read_addr(sd_buff_addr_out),
	.read_data(sd_buff_din)
);
assign dump_active = 1'b0;
assign dump_rd     = 1'b0;
assign dump_word   = 18'd0;
`endif

data_loader #(
      .ADDRESS_MASK_UPPER_4(4'h6),
      .ADDRESS_SIZE(17),
      .WRITE_MEM_CLOCK_DELAY(7),
      .OUTPUT_WORD_SIZE(2)
) save_data_loader (
      .clk_74a(clk_74a),
      .clk_memory(clk_sys),

      .bridge_wr(bridge_wr),
      .bridge_endian_little(bridge_endian_little),
      .bridge_addr(bridge_addr),
      .bridge_wr_data(bridge_wr_data),

      .write_en  (sd_wr),
      .write_addr(sd_buff_addr_in),
      .write_data(sd_buff_dout)
);

///////////////////////////////////////////////
// ROM
///////////////////////////////////////////////

reg         ioctl_download = 0;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire [15:0] ioctl_data;
reg         ioctl_wait;

wire 		cart_download;

synch_3 cart_download_s (
	ioctl_download & bridge_addr[31:28] == 4'h1,
	cart_download,
	clk_sys
);

always @(posedge clk_74a) begin
    if (dataslot_requestwrite) ioctl_download <= 1;
    else if (dataslot_allcomplete) ioctl_download <= 0;
end

wire sdrom_wrack;
reg  [1:0] region_req;
reg        region_set = 0;
always @(posedge clk_sys) begin
	reg old_ready = 0;

	old_ready <= cart_hdr_ready;
	if(~old_ready & cart_hdr_ready) begin
			region_set <= 1;
			if(hdr_u) region_req <= 1;
			else if(hdr_e) region_req <= 2;
			else if(hdr_j) region_req <= 0;
			else region_req <= 1;
	end

	if(old_ready & ~cart_hdr_ready) region_set <= 0;
end

wire [3:0] hrgn = ioctl_data[3:0] - 4'd7;

reg cart_hdr_ready = 0;
reg hdr_j=0,hdr_u=0,hdr_e=0;
always @(posedge clk_sys) begin
	reg old_download;
	old_download <= cart_download;

	if(~old_download && cart_download) {hdr_j,hdr_u,hdr_e} <= 0;
	if(old_download && ~cart_download) cart_hdr_ready <= 0;

	if(ioctl_wr & cart_download) begin
		if(ioctl_addr == 'h1F0) begin
			if(ioctl_data[7:0] == "J") hdr_j <= 1;
			else if(ioctl_data[7:0] == "U") hdr_u <= 1;
			else if(ioctl_data[7:0] == "E") hdr_e <= 1;
			else if(ioctl_data[7:0] >= "0" && ioctl_data[7:0] <= "9") {hdr_e, hdr_u, hdr_j} <= {ioctl_data[3], ioctl_data[2], ioctl_data[0]};
			else if(ioctl_data[7:0] >= "A" && ioctl_data[7:0] <= "F") {hdr_e, hdr_u, hdr_j} <= {      hrgn[3],       hrgn[2],       hrgn[0]};
		end
		if(ioctl_addr == 'h1F2) begin
			if(ioctl_data[7:0] == "J") hdr_j <= 1;
			else if(ioctl_data[7:0] == "U") hdr_u <= 1;
			else if(ioctl_data[7:0] == "E") hdr_e <= 1;
		end
		if(ioctl_addr == 'h1F0) begin
			if(ioctl_data[15:8] == "J") hdr_j <= 1;
			else if(ioctl_data[15:8] == "U") hdr_u <= 1;
			else if(ioctl_data[15:8] == "E") hdr_e <= 1;
		end
		if(ioctl_addr == 'h200) cart_hdr_ready <= 1;
	end
end

data_loader #(
	.ADDRESS_MASK_UPPER_4(4'h1),
    .ADDRESS_SIZE(25),
	.WRITE_MEM_CLOCK_DELAY(12),
	.WRITE_MEM_EN_CYCLE_LENGTH(2),
	.OUTPUT_WORD_SIZE(2)
) rom_loader (
    .clk_74a(clk_74a),
    .clk_memory(clk_sys),

    .bridge_wr(bridge_wr),
    .bridge_endian_little(bridge_endian_little),
    .bridge_addr(bridge_addr),
    .bridge_wr_data(bridge_wr_data),

    .write_en(ioctl_wr),
    .write_addr(ioctl_addr),
    .write_data(ioctl_data)
);

///////////////////////////////////////////////
// Audio
///////////////////////////////////////////////

sound_i2s #(
    .CHANNEL_WIDTH(16),
    .SIGNED_INPUT (1)
) sound_i2s (
    .clk_74a(clk_74a),
    .clk_audio(clk_sys),

    .audio_l(GEN_AUDL),
    .audio_r(GEN_AUDR),

    .audio_mclk(audio_mclk),
    .audio_lrck(audio_lrck),
    .audio_dac(audio_dac)
);

///////////////////////////////////////////////
// Video
///////////////////////////////////////////////

wire [7:0] color_lut[16] = '{
	8'd0,   8'd27,  8'd49,  8'd71,
	8'd87,  8'd103, 8'd119, 8'd130,
	8'd146, 8'd157, 8'd174, 8'd190,
	8'd206, 8'd228, 8'd255, 8'd255
};

wire [3:0] r /* verilator public_flat_rd */, g /* verilator public_flat_rd */, b /* verilator public_flat_rd */;
wire vs /* verilator public_flat_rd */, hs /* verilator public_flat_rd */;
wire ce_pix /* verilator public_flat_rd */;
wire hblank /* verilator public_flat_rd */, vblank_sys /* verilator public_flat_rd */;

reg video_de_reg;
reg video_hs_reg;
reg video_vs_reg;
reg [23:0] video_rgb_reg;

wire current_pix_clk;
wire current_pix_clk_90;

// Pixel clock: pinned, deliberately NOT multiplexed.
//
// This used to be a combinational mux in soft logic, selected directly by
// `resolution` -- an unsynchronized 2-bit signal from the VDP in clk_sys:
//
//     always @(*) if (resolution == 2'b00) current_pix_clk = clk_vid_256;
//                 else                     current_pix_clk = clk_vid_320;
//
// current_pix_clk_90 is forwarded straight out as scal_clk, the clock the
// Pocket's scaler uses to latch our video (apf_top.v:271-277). So when the
// two select bits failed to settle together, the comparator could chatter
// and put a RUNT PULSE on the scaler's own clock input. The scaler loses
// lock and holds its last frame -- the observed failure: frozen picture and
// frozen debug overlay, while audio and input keep working because the VDP
// and clk_sys are entirely healthy. It fires at boot because the Mega CD
// BIOS changes resolution between the boot animation and the CD player.
//
// The pixel clock is therefore PINNED and never switches. Measured on
// hardware, in this order:
//
//   original combinational mux  -- switches with runt pulses  -> ~1/3 boots freeze
//   pinned to the 320 clock     -- never switches             -> stable
//   cross-inhibited glitch-free -- clean switch, brief stop   -> glitches on reset
//
// The third result is the important one: a textbook glitch-free mux, whose
// whole purpose is to make runt pulses unconstructible, still fails. Any
// handover between two asynchronous clocks costs either a runt pulse or a
// momentary stop, and the scaler tolerates neither. So the answer is not a
// better mux -- scal_clk simply has to be free-running.
//
// Consequence: 256-wide modes are clocked at the 320 rate. The correct way
// to reconcile that is video_skip, which the APF interface provides for
// exactly this purpose and which is currently hardwired to 0 (see
// `assign video_skip = 0;` below) -- run permanently at the 320 clock and
// skip every 5th pixel for an effective 256 rate, with a clock that never
// switches. Until that is done the pinned clock is the stable option.
assign current_pix_clk    = clk_vid_320;
assign current_pix_clk_90 = clk_vid_320_90deg;

assign video_rgb_clock = current_pix_clk;
assign video_rgb_clock_90 = current_pix_clk_90;

assign video_de = video_de_reg;
assign video_hs = video_hs_reg;
assign video_vs = video_vs_reg;
assign video_rgb = video_rgb_reg;

// video_skip: reconciles the pinned 320 pixel clock with 256-wide modes.
//
// The pixel clock no longer switches (see above), so a 256-wide mode is
// sampled at the 320 rate -- clk_sys/8 sampling a VDP emitting one pixel
// every clk_sys/10, i.e. 5 samples per 4 real pixels, every 5th sample a
// duplicate of the one before it. Without this the scaler latched all 320
// samples and the picture came out horizontally stretched.
//
// APF provides SKIP for exactly this case: it "may be asserted while DE is
// high to prevent latching the pixel for that cycle". Marking the duplicates
// delivers 256 real pixels from a clock that never switches, which is what
// the scaler needs (see the pinned-clock note above for why any clock
// handover is fatal).
//
// Alignment is taken from the VDP's own pixel enable rather than a fixed 5:4
// pattern, because the phase of the duplicate within each group of five
// depends on where the active region starts relative to a clk_sys/8 boundary
// and is not statically known -- guessing it would drop real pixels and keep
// duplicates. ce_pix toggles vdp_pix_tog once per emitted pixel, and the
// video block samples that toggle on the SAME edge that latches
// red/green/blue, so "toggle unchanged this cycle" is precisely "this sample
// is a duplicate". In 320-wide modes ce_pix runs at the pixel-clock rate, so
// nothing is ever skipped and behaviour is unchanged.
//
// vdp_pix_tog crosses clk_sys -> pixel clock exactly as red/green/blue
// already do in that block; the two are integer-related outputs of one PLL
// (clk_vid_320 = clk_sys/8), and the toggle runs at most half the sample
// rate, so each state is sampled at least twice.
reg vdp_pix_tog = 0;
always @(posedge clk_sys) if (ce_pix) vdp_pix_tog <= ~vdp_pix_tog;

reg vdp_pix_tog_d = 0;
reg video_skip_reg = 0;
assign video_skip = video_skip_reg;

reg hs_prev;
reg vs_prev;

reg [9:0] dbg_x, dbg_y;
reg       dbg_de_line;

// hex readout row 1: GG LL MM SS
//   GG = GFX-engine ops completed/s (3C = one op per frame, 00 = unused)
//   LL = longest GFX op this second, clk_sys cycles >>13 (153.5us units;
//        one NTSC frame ~0x6D, so >0x36 means two ops can't fit a frame)
//   MM = main-CPU bus-cycle rate >>13 (ideal ~E8, starved ~74)
//   SS = sub-CPU addr-change rate >>14 (ideal ~BE, starved lower)
wire [31:0] dbg_hexval = {dbg_gfx_rate, dbg_glen,
                          dbg_bus_rate,
                          dbg_sub_rate};
wire [31:0] dbg_hexrow = (dbg_y < 10'd42) ? dbg_hexval :
                         (dbg_y < 10'd54) ? {dbg_wracc_rate, dbg_m68k_smp} :
                         (dbg_y < 10'd66) ? {dbg_wrbusy_duty, dbg_s68k_smp} :
                         // row 4: FMV/decode pipeline rates. These counters
                         // were already computed but never displayed, and they
                         // are the whole path a decoded frame takes: sub writes
                         // word RAM -> banks hand over -> main reads word RAM
                         // -> main writes VDP.
                         //   VV = VDP writes/s >>13   (blit destination)
                         //   RR = word-RAM reads/s >>13 (blit source)
                         //   DD = DMNA assertions/s   (bank handovers; ~3C =
                         //        one per frame, 00 = no double-buffering)
                         //   G  = GFX-engine in-flight duty /8 (7 = pegged)
                         // Replaces the APF datatable word-0 dump, which was
                         // for diagnosing the mount and is now solved (and the
                         // scan matches on slot id, so a raw word is moot).
                         (dbg_y < 10'd78)  ? {dbg_vdpw_rate, dbg_wrrd_rate,
                                              dbg_dmna_rate, 5'd0, dbg_gron_duty} :
                         // CDC decode + host transfer: F G MMSS T C
                         //   F = {DECEN, WRRQ, DECI, DTEI}; DECI/DTEI ACTIVE
                         //       LOW, so 8 = decoder on, nothing pending
                         //   G = {DOUTEN, DTEN, DTBSY, 0} -- host-transfer
                         //       enable and state
                         //   MMSS = mm:ss BCD of the sector last latched;
                         //       compare against head+150 from row 8
                         //   T = DTTRG writes, wraps -- the sub ASKING for a
                         //       host transfer. FROZEN means the sub never
                         //       requests the data it is buffering, which is
                         //       the one thing measured on hardware that is
                         //       still unexplained: the transfer counter sat
                         //       still for the whole intro.
                         //   C = decoded-sector counter, wraps at 75Hz
                         // Replaces an APF datatable dump kept from the mount
                         // bring-up, which is long solved.
                         (dbg_y < 10'd90)  ? dbg_dec :
                         // sub interrupt service: P AA Q BB CC
                         //   P  = INT5 (CDC) pending duty /8, 7 = asserted the
                         //        whole second
                         //   AA = INT5 acks/sec -- 00 with P high means the sub
                         //        NEVER takes the CDC interrupt, so it cannot
                         //        be reading sector headers at all
                         //   Q  = INT4 (CDD) pending duty /8
                         //   BB = INT4 (CDD) acks/sec  (healthy ~4B = 75/sec)
                         //   CC = INT2 (main->sub) acks/sec
                         // INT4 is the control channel we know works, so it is
                         // the reference: if BB spins and AA is stuck at 00,
                         // the sub is alive and servicing interrupts generally
                         // but not this one.
                         (dbg_y < 10'd102) ? {1'b0, dbg_pend_duty[5], dbg_ack5_rate,
                                              1'b0, dbg_pend_duty[4], dbg_ack4_rate,
                                              dbg_ack2_rate} :
                         // sector integrity: NN LLLLL F
                         //   NN = data sectors delivered with a BROKEN MODE1
                         //        sync -- i.e. not data sectors at all. 00 =
                         //        the stream we hand the CDC is clean.
                         //   LLLLL = LBA of the FIRST one; compare against the
                         //        track layout to see where the disc stops
                         //        being what we think it is
                         //   F  = {cur_audio, in_pregap, 0, 0}
                         // Replaces the last APF datatable dump from the mount
                         // bring-up, which is long solved.
                         (dbg_y < 10'd114) ? cdd_dbg_integ :
                         // CD-path debug: drive/fetch state, bridge FSMs,
                         // host round-trip counters (see dbg_cdpath packing)
                         (dbg_y < 10'd126) ? cdd_dbg_state :
                         (dbg_y < 10'd138) ? dbg_cdpath :
                         (dbg_y < 10'd150) ? dbg_cdcnt :
                         // audio diagnostics: R P SS BB C D
                         //   R  = last STATE-CHANGING command (polls filtered):
                         //        1 STOP, 3 SEEK+PLAY, 4 SEEK+PAUSE, 6 PAUSE,
                         //        7 RESUME, C close tray, D open tray, F none,
                         //        E = auto-PAUSEd on the leadout (no command)
                         //   P  = time paused SO FAR (live, not a max), ~107ms
                         //        per count, F = >= 1.6s, 0 when not paused
                         //   SS = SEEK commands, BB = of those, backwards
                         //   C  = last command incl. polls, D = drive status
                         // With the drive parked in a state, R says who put it
                         // there -- C only ever shows the 0/2 poll traffic.
                         (dbg_y < 10'd162) ? cdd_dbg_cmds :
                         // position/reporting: T F TT LLLLL
                         //   T  = report type the host last asked for:
                         //        0 absolute, 1 relative, 2 track, 3 leadout,
                         //        4 first/last, 5 track start, F busy
                         //   F  = {cur_audio, in_pregap, cur_track[5:4]};
                         //        in_pregap set means we are feeding SILENCE
                         //        rather than file data
                         //   TT = cur_track (low digit is cur_track[3:0])
                         //   LLLLL = target LBA of the last SEEK
                         // Read against head in row 8: a host re-seeking to the
                         // SAME LBA while head walks past it is correcting our
                         // reported position, not streaming.
                         //
                         // Replaces the CDC transfer row, which answered its
                         // question outright -- it read 50077000 for the whole
                         // intro: transfer FSM idle, counter frozen, i.e. NO CD
                         // data is read during this sequence at all. The disc is
                         // doing nothing but CDDA here.
                                             cdd_dbg_pos;
wire [3:0] dbg_dv = dbg_hexrow[((3'd7 - dbg_x[6:4])*4) +: 4];
reg [23:0] dbg_glyph;
always @* case (dbg_dv)
	4'h0: dbg_glyph = 24'h699996;  4'h1: dbg_glyph = 24'h262227;
	4'h2: dbg_glyph = 24'h69168F;  4'h3: dbg_glyph = 24'hE1611E;
	4'h4: dbg_glyph = 24'h99F111;  4'h5: dbg_glyph = 24'hF8E11E;
	4'h6: dbg_glyph = 24'h68E996;  4'h7: dbg_glyph = 24'hF12244;
	4'h8: dbg_glyph = 24'h696996;  4'h9: dbg_glyph = 24'h699716;
	4'hA: dbg_glyph = 24'h699F99;  4'hB: dbg_glyph = 24'hE9E99E;
	4'hC: dbg_glyph = 24'h698896;  4'hD: dbg_glyph = 24'hE9999E;
	4'hE: dbg_glyph = 24'hF8E88F;  default: dbg_glyph = 24'hF8E888;
endcase
wire [9:0] dbg_band = dbg_y - ((dbg_y >= 10'd150) ? 10'd150 :
                               (dbg_y >= 10'd138) ? 10'd138 :
                               (dbg_y >= 10'd126) ? 10'd126 :
                               (dbg_y >= 10'd114) ? 10'd114 :
                               (dbg_y >= 10'd102) ? 10'd102 :
                               (dbg_y >= 10'd90) ? 10'd90 :
                               (dbg_y >= 10'd78) ? 10'd78 :
                               (dbg_y >= 10'd66) ? 10'd66 :
                               (dbg_y >= 10'd54) ? 10'd54 :
                               (dbg_y >= 10'd42) ? 10'd42 : 10'd30);
wire [2:0] dbg_frow = dbg_band[3:1];
wire [3:0] dbg_grow = dbg_glyph[((3'd5 - dbg_frow)*4) +: 4];

reg         field;
wire        field_s;

reg         interlaced;
wire        interlaced_s;

reg   [1:0] resolution;
wire  [1:0] resolution_s;

synch_3 #(.WIDTH(2)) sv2(resolution, resolution_s, current_pix_clk);
synch_3 sv3(interlaced, interlaced_s, current_pix_clk);
synch_3 sv4(field, field_s, current_pix_clk);

always @(posedge current_pix_clk) begin
    reg vblank_line = 0;
    video_de_reg <= 0;
    video_skip_reg <= 0;
    // sampled on the same edge that latches red/green/blue below, so the
    // comparison against the previous cycle identifies duplicate samples
    vdp_pix_tog_d <= vdp_pix_tog;

	if (vs_c) begin
		video_rgb_reg[23:3] <= 'd0;
		video_rgb_reg[3] <= ~field_s;
		video_rgb_reg[2] <= field_s;
		video_rgb_reg[1] <= interlaced_s;
		video_rgb_reg[0] <= 0;
	end

    // Set Video Mode by Index
    case(resolution_s)
        2'b00: begin video_rgb_reg <= 24'h0;                end              							// [0] 256 x 224
        2'b01: begin video_rgb_reg <= {cs_ar_correction_enable ? 11'd4 : 11'd1, 10'b0, 3'b0}; end		// [1] 320 x 224
        2'b10: begin video_rgb_reg <= {11'd2, 10'b0, 3'b0}; end               							// [2] 256 x 240
        2'b11: begin video_rgb_reg <= {cs_ar_correction_enable ? 11'd5 : 11'd3, 10'b0, 3'b0}; end     // [3] 320 x 240
    endcase


    if (~(vblank_line || hblank_c)) begin
        video_de_reg <= 1;
        // no new VDP pixel since the last sample => this one repeats the
        // previous pixel; tell the scaler not to latch it
        video_skip_reg <= (vdp_pix_tog == vdp_pix_tog_d);
        video_rgb_reg[23:16] <= (lg_target && lightgun_enabled && show_crosshair) ? {8{lg_target[0]}} : red;
        video_rgb_reg[15:8]  <= (lg_target && lightgun_enabled && show_crosshair) ? {8{lg_target[1]}} : green;
        video_rgb_reg[7:0]   <= (lg_target && lightgun_enabled && show_crosshair) ? {8{lg_target[2]}} : blue;

        // bring-up debug overlay, gated behind the "Debug Overlay" core
        // setting (0x110); quasi-static config bit, safe to sample here.
        // Excluded from synthesis (EWJ-SE fix): the work-RAM read cache
        // needs the ~LABs this renderer and its feeder counters cost; the
        // overlay remains available in Verilator builds.
`ifdef VERILATOR
        if (cs_debug_overlay) begin
        // 4 blocks top-left — sub-CPU alive, CDD command
        // seen, word-RAM requested, word-RAM completed (green=yes, red=no)
        if (dbg_y < 10'd10) begin
            case (dbg_x[9:4])
                6'd0: video_rgb_reg <= dbg_sub_alive   ? 24'h00FF00 : 24'hFF0000;
                6'd1: video_rgb_reg <= dbg_cdd_seen    ? 24'h00FF00 : 24'hFF0000;
                6'd2: video_rgb_reg <= dbg_wr_req      ? 24'h00FF00 : 24'hFF0000;
                6'd3: video_rgb_reg <= dbg_wr_done     ? 24'h00FF00 : 24'hFF0000;
                6'd4: video_rgb_reg <= dbg_wr_stuck    ? 24'hFF0000 : 24'h00FF00;
                6'd5: video_rgb_reg <= dbg_dtack_stuck ? 24'hFF0000 : 24'h00FF00;
                6'd6: video_rgb_reg <= ~st_done ? 24'h0000FF : st_pass ? 24'h00FF00 : 24'hFF0000;
                // IRQ-pending duty: green <25%, yellow <75%, red = storm
                6'd7: video_rgb_reg <= (dbg_ipl_duty >= 3'd6) ? 24'hFF0000 :
                                       (dbg_ipl_duty >= 3'd2) ? 24'hFFFF00 : 24'h00FF00;
                // GFX-engine busy duty: gray = idle all second, green <25%,
                // yellow <75%, red = saturated (producer-bound)
                6'd8: video_rgb_reg <= (dbg_gron_duty >= 3'd6) ? 24'hFF0000 :
                                       (dbg_gron_duty >= 3'd2) ? 24'hFFFF00 :
                                       (dbg_gron_duty != 0 || dbg_gfx_rate != 0) ? 24'h00FF00 : 24'h404040;
                default: ;
            endcase
        end else if (dbg_y < 10'd20) begin
            // sub-CPU speedometer, log scale: block k lit if rate > 2^(2k+8)
            // (256, 1k, 4k, 16k, 65k, 262k, 1M, 4M changes/sec); healthy sub
            // lights ~7-8 blocks, a ~200x-slow sub only ~4
            if (dbg_x[9:4] < 6'd8) begin
                video_rgb_reg <= (dbg_rate > (23'd1 << (dbg_x[7:4]*2 + 8))) ? 24'hFFFF00 : 24'h404040;
            end
        end else if (dbg_y < 10'd30) begin
            // interrupt panel: blocks 1-6 = pend duty per level (green/yellow/red),
            // block 7 = INT2 ack rate (green >=30/s), block 8 = INT4 ack rate
            case (dbg_x[9:4])
                6'd0, 6'd1, 6'd2, 6'd3, 6'd4, 6'd5:
                    video_rgb_reg <= (dbg_pend_duty[dbg_x[7:4] + 1] >= 3'd6) ? 24'hFF0000 :
                                     (dbg_pend_duty[dbg_x[7:4] + 1] >= 3'd1) ? 24'hFFFF00 : 24'h004000;
                6'd6: video_rgb_reg <= (dbg_ack2_rate >= 8'd30) ? 24'h00FF00 :
                                       (dbg_ack2_rate != 0)     ? 24'hFFFF00 : 24'hFF0000;
                6'd7: video_rgb_reg <= (dbg_ack4_rate >= 8'd30) ? 24'h00FF00 :
                                       (dbg_ack4_rate != 0)     ? 24'hFFFF00 : 24'hFF0000;
                default: ;
            endcase
        end else if (dbg_y >= 10'd30 && dbg_y < 10'd174) begin
            // numeric readout rows: stats / [frames-with-blit, M68K addr] / [frames-with-GFX-op, S68K addr]
            if (dbg_x[9:4] < 6'd8) begin
                if (~dbg_x[3])
                    video_rgb_reg <= dbg_grow[2'd3 - dbg_x[2:1]] ? 24'hFFFFFF : 24'h000000;
                else
                    video_rgb_reg <= 24'h000000;
            end
        end
        end // cs_debug_overlay
`endif
    end

    // count ACTIVE lines only — dbg_y counted blanking lines before, which
    // parked the overlay inside the vertical porch where it was never visible
    if (~hs_prev && hs_c) begin
        dbg_x <= 0;
        if (dbg_de_line) dbg_y <= dbg_y + 1'b1;
        dbg_de_line <= 0;
    end else if (video_de_reg) begin
        dbg_x <= dbg_x + 1'b1;
        dbg_de_line <= 1;
    end
    if (~vs_prev && vs_c) dbg_y <= 0;

    video_hs_reg <= ~hs_prev && hs_c;
    video_vs_reg <= ~vs_prev && vs_c;
    hs_prev <= hs_c;
    vs_prev <= vs_c;

    // the vblank signal starts and stops a bit before the end of the visible
    // portion of the line. if used to gate pixel output, this means the last
    // visible line gets truncated and the last blank line is partially shown,
    // producing garbage on the screen. capture and use vblank's value at hsync
    // to avoid this; hsync starts a line so that's when we care whether or not
    // the line is visible.
    if (~hs_prev && hs_c) begin
        vblank_line <= vblank_c;
    end
end

wire TRANSP_DETECT;
wire cofi_enable = cs_composite_enable || (cs_auto_composite_enable && TRANSP_DETECT);
wire hs_c, vs_c, hblank_c, vblank_c;
wire [7:0] red, green, blue;

cofi coffee (
	.clk(clk_sys),
	.pix_ce(ce_pix),
	.enable(cofi_enable),

	.hblank(hblank),
	.vblank(vblank_sys),
	.hs(hs),
	.vs(vs),
	.red(color_lut[r]),
	.green(color_lut[g]),
	.blue(color_lut[b]),

	.hblank_out(hblank_c),
	.vblank_out(vblank_c),
	.hs_out(hs_c),
	.vs_out(vs_c),
	.red_out(red),
	.green_out(green),
	.blue_out(blue)
);

///////////////////////////////////////////////
// RAM
///////////////////////////////////////////////

// Memory map (16-bit word addresses [24:1], byte addresses in comments):
//   port 0: MCD PRG-RAM  512KB  @ 0x1000000
//   port 1: Genesis work RAM 64KB @ 0x0800000, CD BIOS 128KB @ 0x0F00000
//   port 2: BIOS load (download-time only)
wire        sdr_busy;
wire [15:0] sdr_do;
assign MCD_PRG_BUSY = sdr_busy;
wire dbg_prg_busy /* verilator public_flat_rd */ = sdr_busy;
assign MCD_PRG_DI   = sdr_do;

wire [15:0] GEN_MEM_DO;
wire        GEN_MEM_BUSY /* verilator public_flat_rd */;

// ---- BIOS ROM window: plain SDRAM pass-through ----------------------------
// This used to be an 8K-entry direct-mapped cache (the boot-animation fix).
// Its M10K went to double the word-RAM read cache instead: Sonic CD's
// gameplay slowdown traced to main-68K word-RAM latency (probe build
// confirmed on hardware), and during gameplay the ROM window carries ~2
// reads per frame — the cache was earning nothing where it hurts. The BIOS
// boot animations drop back to SDRAM speed (they were time-locked anyway;
// they render at a reduced rate as they did before the cache existed).
// The state machine shape is kept: every read is now a "miss" through the
// serialized port-1 front-end (bc_miss_req / p1_rom_done).
reg        brom_busy /* verilator public_flat_rd */ = 0;
reg        brom_hold = 0;
reg        bc_st = 0;
reg [15:0] brom_dout;
reg [15:0] bc_addr;
reg        bc_miss_req = 0;
wire brom_acc = ~GEN_ROM_CE_N & ~GEN_OE_N;

always @(posedge clk_sys) begin
	if (~brom_acc) brom_hold <= 0;
	if (reset | bios_download) begin
		brom_busy <= 0; brom_hold <= 0; bc_st <= 0; bc_miss_req <= 0;
	end else begin
		case (bc_st)
		1'd0: if (brom_acc & ~brom_hold) begin
			brom_busy   <= 1;
			bc_addr     <= GEN_VA[16:1];
			bc_miss_req <= 1;
			bc_st       <= 1'd1;
		end
		1'd1: if (p1_rom_done) begin
			bc_miss_req <= 0;
			brom_dout   <= p1_dout;
			brom_busy   <= 0;
			brom_hold   <= 1;
			bc_st       <= 1'd0;
		end
		endcase
	end
end

// ---- Genesis work-RAM read cache (32KB, direct-mapped) -------------------
// EWJ-SE investigation: the game's 68K code executes from work RAM, and its
// per-frame sound service collapses when the average access cost rises by
// ~2-3 SDRAM clocks over the port-1 baseline (sim cliff between +sdlat1=12
// and 14; on hardware, refresh + cross-port contention during CD loads push
// past it — jingles crawl, notes stick keyed-on). A full 64KB BRAM copy
// needs 64 M10K (8Kx1 mode) and overflows the device (fitter: 315/308 even
// at 16K entries); this 8Kx19 cache (16 data + 2 tag + 1 valid, 19 M10K)
// serves read hits in 3 cycles.
// Write-through: writes go to SDRAM port 1 as before and update a matching
// entry in place (byte-merged); misses fall through to port 1 and fill.
// Index = word addr [13:1], tag = addr[15:14].
reg [18:0] gwc [0:8191];
reg        gwc_flushing = 1;
reg [12:0] gwc_flush_a = 0;
reg [18:0] gwc_q;
reg        gwc_busy /* verilator public_flat_rd */ = 0;
reg        gwc_hold = 0;
reg [15:0] gwc_dout;
reg [14:0] gwc_a;
reg  [1:0] gwc_st = 0;
reg        gwc_fill_pend = 0;    // miss fill when port-1 read completes

wire gw_acc = ~GEN_RAM_CE_N & (~GEN_OE_N | ~GEN_WRL_N | ~GEN_WRH_N);
wire gw_rd  = ~GEN_RAM_CE_N & ~GEN_OE_N;

localparam GWC_CHECK = 2'd1, GWC_MISS = 2'd2;

always @(posedge clk_sys) begin
	if (~gw_acc) gwc_hold <= 0;
	if (reset | bios_download) begin
		gwc_busy <= 0; gwc_hold <= 0; gwc_st <= 0;
		gwc_fill_pend <= 0;
		gwc_flushing <= 1; gwc_flush_a <= 0;
	end else if (gwc_flushing) begin
		gwc[gwc_flush_a] <= 19'd0;
		{gwc_flushing, gwc_flush_a} <= {1'b1, gwc_flush_a} + 1'b1;
	end else begin
		case (gwc_st)
		2'd0: begin
			if (gw_acc & ~gwc_hold) begin
				gwc_a <= GEN_VA[15:1];
				gwc_q <= gwc[GEN_VA[13:1]];
				if (gw_rd) begin
					gwc_busy <= 1;         // read: lookup, decide next cycle
					gwc_st   <= GWC_CHECK;
				end else begin
					// write: port 1 carries it (RDY comes from there). Cache
					// policy kept mux-free for area: a full-word write
					// allocates the slot outright, a byte write invalidates
					// it (no read-merge datapath).
					gwc_hold <= 1;
					if (GEN_WRL_N | GEN_WRH_N)
						gwc[GEN_VA[13:1]] <= 19'd0;
					else
						gwc[GEN_VA[13:1]] <= {1'b1, GEN_VA[15:14], GEN_VDO};
				end
			end
		end
		GWC_CHECK: begin
			if (gwc_q[18] && gwc_q[17:16] == gwc_a[14:13]) begin
				gwc_dout <= gwc_q[15:0];
				gwc_busy <= 0;
				gwc_hold <= 1;
				gwc_st   <= 0;
			end else begin
				gwc_fill_pend <= 1;        // ask port 1 to fetch it
				gwc_st        <= GWC_MISS;
			end
		end
		GWC_MISS: if (p1_ram_done) begin
			gwc_fill_pend <= 0;
			gwc_dout <= p1_dout;
			gwc[gwc_a[12:0]] <= {1'b1, gwc_a[14:13], p1_dout};
			gwc_busy <= 0;
			gwc_hold <= 1;
			gwc_st   <= 0;
		end
		default: gwc_st <= 0;
		endcase
	end
end

// ---- SDRAM port-1 front-end ----------------------------------------------
// Port 1 is shared by two independent state machines: gen's work-RAM path
// (RAM_CE) and the MCD ASIC's CD-BIOS ROM window (ROM_CE). Both used the raw
// shared busy1 as their RDY, and rd1 was the OR of both CE decodes. Proven
// failure modes under concurrent load (real-SDRAM cosim, sdlog trace):
// (1) a machine starting while the other's access was still draining took
//     that busy as its own start and latched foreign dout as its data —
//     random main-CPU corruption (BIOS boot crash into the address-error
//     vector once word-RAM traffic delays the drain);
// (2) a back-to-back user switch with no gap on rd1 left the controller's
//     old_rd edge latch stale, making the second request invisible — a
//     permanent wedge (the hardware dbg_wr/dtack stuck class).
// The front-end serializes the users: one latched request at a time, clean
// gaps on the request lines, a private RDY per user, data latched at
// completion.
reg         p1_act /* verilator public_flat_rd */ = 0, p1_started = 0, p1_owner /* verilator public_flat_rd */ = 0; // 0=gen-RAM 1=MCD-ROM
reg         p1_ram_hold = 0, p1_rom_hold = 0;
reg         p1_rom_done = 0;
reg         p1_ram_busy /* verilator public_flat_rd */ = 0, p1_rom_busy /* verilator public_flat_rd */ = 0;
reg         p1_rd = 0, p1_wrl = 0, p1_wrh = 0;
reg  [24:1] p1_addr;
reg  [15:0] p1_din;
reg  [15:0] p1_dout /* verilator public_flat_rd */;

wire p1_ram_acc = ~GEN_RAM_CE_N & (~GEN_OE_N | ~GEN_WRL_N | ~GEN_WRH_N);
wire p1_wr_acc  = ~GEN_RAM_CE_N & (~GEN_WRL_N | ~GEN_WRH_N);
reg  gw_wr_ack = 0;
reg  p1_ram_done = 0;
wire p1_rom_acc = ~GEN_ROM_CE_N & ~GEN_OE_N;

always @(posedge clk_sys) begin
	reg old_b1;
	old_b1 <= GEN_MEM_BUSY;
	p1_rom_done <= 0;  // one-cycle completion pulse to the ROM cache
	if (~p1_ram_acc) p1_ram_hold <= 0;
	if (~p1_wr_acc)  gw_wr_ack <= 0;
	p1_ram_done <= 0;
	if (~bc_miss_req) p1_rom_hold <= 0;
	if (reset | bios_download) begin
		p1_act <= 0; p1_started <= 0;
		p1_rd <= 0; p1_wrl <= 0; p1_wrh <= 0;
		p1_ram_busy <= 0; p1_rom_busy <= 0;
		p1_ram_hold <= 0; p1_rom_hold <= 0;
	end else if (!p1_act) begin
		// Work-RAM traffic: writes (write-through) and read-cache misses.
		// wr_ack tracks acceptance of the CURRENT bus write so RDY can no
		// longer alias a previous access's drain (see hazard note above the
		// cache: a >28clk drain overlapping the 68K's next access previously
		// false-accepted it — stale read data / lost writes at high SDRAM
		// latency).
		if ((p1_wr_acc & ~gw_wr_ack | gwc_fill_pend) & ~p1_ram_hold) begin
			p1_act  <= 1; p1_started <= 0; p1_owner <= 0;
			p1_addr <= {9'b010000000, GEN_VA[15:1]};
			p1_din  <= GEN_VDO;
			p1_rd   <= ~p1_wr_acc;
			p1_wrl  <= ~GEN_WRL_N;
			p1_wrh  <= ~GEN_WRH_N;
			p1_ram_busy <= 1;
			if (p1_wr_acc) gw_wr_ack <= 1;
		end else if (bc_miss_req & ~p1_rom_hold) begin
			p1_act  <= 1; p1_started <= 0; p1_owner <= 1;
			p1_addr <= {8'b01111000, bc_addr};
			p1_rd   <= 1; p1_wrl <= 0; p1_wrh <= 0;
		end
	end else begin
		if (GEN_MEM_BUSY) p1_started <= 1;
		if (p1_started & old_b1 & ~GEN_MEM_BUSY) begin
			p1_dout <= GEN_MEM_DO;
			if (!p1_owner) begin p1_ram_busy <= 0; p1_ram_hold <= 1; p1_ram_done <= 1; end
			else          begin p1_rom_done <= 1; p1_rom_hold <= 1; end
			p1_act <= 0; p1_rd <= 0; p1_wrl <= 0; p1_wrh <= 0;
		end
	end
end
wire        sdld_busy;

always @(posedge clk_sys) begin
	reg old_busy;
	old_busy <= sdld_busy;
	if (bios_download & ioctl_wr) ioctl_wait <= 1;
	if (old_busy & ~sdld_busy) ioctl_wait <= 0;
end

sdram sdram
(
	.init(~pll_core_locked),
	.clk(clk_ram),

	// MCD Sub-CPU PRG-RAM
	.addr0({6'b100000, MCD_PRG_ADDR}),
	.din0(MCD_PRG_DO),
	.dout0(sdr_do),
	.rd0(~MCD_PRG_OE_N),
	.wrl0(~MCD_PRG_WRL_N),
	.wrh0(~MCD_PRG_WRH_N),
	.busy0(sdr_busy),

	// Genesis work RAM + CD BIOS window (serialized by the port-1 front-end)
	.addr1(p1_addr),
	.din1(p1_din),
	.dout1(GEN_MEM_DO),
	.rd1(p1_rd),
	.wrl1(p1_wrl),
	.wrh1(p1_wrh),
	.busy1(GEN_MEM_BUSY),

	// word RAM (runtime + boot self-test via arbiter) / BIOS load / PRG peek
	.addr2(bios_download ? {6'b011110, ioctl_addr[18:1]} :
	       dump_active    ? {6'b100000, dump_word} :
	       dbg_prg_active ? {6'b100000, dbg_prg_addr} :
	                        // Word RAM: its own SDRAM bank (3), and wr_owner
	                        // placed inside the COLUMN, not the row. In 2M
	                        // mode the ASIC interleaves the two word-RAM banks
	                        // by EXT_VA(1) (ASIC.vhd WRA_IDLE), so a plain
	                        // sequential stream alternates wr_owner on every
	                        // access. With the owner bit in the row that made
	                        // every access a PRECHARGE+ACTIVATE; here both
	                        // halves of an interleaved pair share one open row.
	                        {7'b1100000, wr_addr[15:8], wr_owner, wr_addr[7:0]}),
	.din2(bios_download ? {ioctl_data[7:0], ioctl_data[15:8]} : wr_din),
	.dout2(sdwr_do),
	.rd2(~bios_download & (dump_active ? dump_rd : dbg_prg_active ? dbg_prg_req : wr_rd_r & wr_probe_go)),
	.wrl2(bios_download ? ioctl_wait : wr_wr_r & wr_probe_go),
	.wrh2(bios_download ? ioctl_wait : wr_wr_r & wr_probe_go),
	.busy2(sdld_busy),

	.SDRAM_DQ(dram_dq),         // 16 bit bidirectional data bus
	.SDRAM_A(dram_a),           // 13 bit multiplexed address bus
	.SDRAM_DQML(dram_dqm[0]),   // byte mask
	.SDRAM_DQMH(dram_dqm[1]),   // byte mask
	.SDRAM_BA(dram_ba),         // two banks
	.SDRAM_nCS(),               // a single chip select
	.SDRAM_nWE(dram_we_n),      // write enable
	.SDRAM_nRAS(dram_ras_n),    // row address select
	.SDRAM_nCAS(dram_cas_n),    // columns address select
	.SDRAM_CLK(dram_clk),
	.SDRAM_CKE(dram_cke)
);

///////////////////////////////////////////////
// Word RAM arbiter: 2 banks x 128KB in SDRAM @ 0x0C00000, shared port 2
///////////////////////////////////////////////

wire [15:0] MWR0_A, MWR1_A, MWR0_DO, MWR1_DO;
wire        MWR0_RD, MWR0_WR, MWR1_RD, MWR1_WR;
reg  [15:0] WR0_DI, WR1_DI;
reg         WR0_RDY /* verilator public_flat_rd */ = 1, WR1_RDY /* verilator public_flat_rd */ = 1;

// arbiter inputs: MCD normally; the boot self-test drives them during reset
wire [15:0] WR0_A  = st2_active ? {6'b0, st2_idx0} : MWR0_A;
wire [15:0] WR1_A  = st2_active ? {6'b0, st2_idx1} : MWR1_A;
wire [15:0] WR0_DO = st2_active ? st2_pat0 : MWR0_DO;
wire [15:0] WR1_DO = st2_active ? st2_pat1 : MWR1_DO;
wire        WR0_RD /* verilator public_flat_rd */ = st2_active ? st2_rd0 : MWR0_RD;
wire        WR0_WR /* verilator public_flat_rd */ = st2_active ? st2_wr0 : MWR0_WR;
wire        WR1_RD /* verilator public_flat_rd */ = st2_active ? st2_rd1 : MWR1_RD;
wire        WR1_WR /* verilator public_flat_rd */ = st2_active ? st2_wr1 : MWR1_WR;

wire [15:0] sdwr_do;
reg         wr_owner;
reg         wr_active /* verilator public_flat_rd */ = 0;
reg         wr_rd_r = 0, wr_wr_r = 0;
reg  [15:0] wr_addr;
reg  [15:0] wr_din;

// ---- word-RAM read cache (32KB, direct-mapped) ---------------------------
// After the RMW phase-skip, GFX op time is dominated by per-access overhead,
// not SDRAM busy time (~133ns of a ~580ns access): the ASIC engine
// requantizes every access to its 12.5MHz enable, so shaving the arbiter
// round trip below one 12.5MHz period is what shortens an op. Hits complete
// in 2 arbiter cycles. Coherence is exact: every word-RAM write (either
// bank, any client) is granted through this same arbiter and updates the
// cached entry in place.
// Doubled to 16K entries with the M10K reclaimed from the BIOS-window cache:
// Sonic CD runs its whole main-CPU game loop from word RAM and the gameplay
// hit rate at 8K entries was 16-29% — the latency this cache fails to hide
// is the confirmed cause of the sprite-spike slowdown (hardware probe).
// Key = {bank, word addr} = 17 bits. The bank bit lives in the INDEX, not
// the tag: 2M mode interleaves the banks by VA(1), so consecutive CPU
// fetches alternate banks and must not thrash one entry.
// Index = {bank, addr[12:0]} (14 bits), tag = addr[15:13] (3 bits),
// entry = {valid, tag[2:0], data[15:0]} = 20 bits.
reg [19:0] wrc [0:16383];
reg [19:0] wrc_q;
reg        wrc_flushing = 1;
reg [13:0] wrc_flush_a = 0;
reg        wrc_busy_d = 0;
reg        wr_chk = 0;
reg  [2:0] wr_tag;
reg [13:0] wr_idx;

wire        wrc_sel0  = grant0_rd | grant0_wr;
wire        wrc_gsel  = !wr_active && !wrc_flushing && !dbg_prg_active && !dump_active &&
                        !((reset & ~st2_active) | bios_download) &&
                        (wrc_sel0 | grant1_rd | grant1_wr);
wire        wrc_gisrd = wrc_sel0 ? grant0_rd : grant1_rd;
wire [16:0] wrc_gkey  = wrc_sel0 ? {1'b0, WR0_A} : {1'b1, WR1_A};
wire [15:0] wrc_gdin  = wrc_sel0 ? WR0_DO : WR1_DO;

always @(posedge clk_sys) begin
	// grant cycle: look up the live key; afterwards hold the latched index
	// (the live key can switch to the other bank's request mid-transaction,
	// which must not reload wrc_q under the pending compare)
	wrc_q <= wrc[wrc_gsel ? {wrc_gkey[16], wrc_gkey[12:0]} : wr_idx];
	wrc_busy_d <= sdld_busy;
	if ((reset & ~st2_active) | bios_download) begin
		wrc_flushing <= 1;
		wrc_flush_a  <= 0;
	end else if (wrc_flushing) begin
		wrc[wrc_flush_a] <= 20'd0;
		{wrc_flushing, wrc_flush_a} <= {1'b1, wrc_flush_a} + 1'b1;
	end else if (wrc_gsel && !wrc_gisrd) begin
		wrc[{wrc_gkey[16], wrc_gkey[12:0]}] <= {1'b1, wrc_gkey[15:13], wrc_gdin};   // write-update
	end else if (wr_active && wr_rd_r && wrc_busy_d && ~sdld_busy) begin
		wrc[wr_idx] <= {1'b1, wr_tag, sdwr_do};                     // miss fill
	end
end
// per-direction re-grant guards: a completed access holds off a new grant
// until its request line drops (RMW flips RD->WR on one edge, so the two
// directions must be tracked independently). The hold must NOT rely on the
// line ever gapping: ASIC engines share a bank's request line, and a
// gapless engine switch leaves the hold set forever (request invisible ->
// sub CPU wedged mid-bus-cycle on word RAM = the CD-player freeze; caught
// live in cosim at the title->player transition). A serviced engine always
// drops its line 1-2 clks after seeing RDY=1, so a line still held
// HOLD_TMO clks after completion is a queued new request: time the hold
// out and re-grant (worst case a harmless repeat of the same access).
localparam [2:0] HOLD_TMO = 3'd4;
reg         wr0_rd_hold /* verilator public_flat_rd */ = 0, wr0_wr_hold /* verilator public_flat_rd */ = 0;
reg         wr1_rd_hold /* verilator public_flat_rd */ = 0, wr1_wr_hold /* verilator public_flat_rd */ = 0;
reg   [2:0] wr0_rd_tmo, wr0_wr_tmo, wr1_rd_tmo, wr1_wr_tmo;

wire grant0_rd = WR0_RD & ~wr0_rd_hold;
wire grant0_wr = WR0_WR & ~wr0_wr_hold;
wire grant1_rd = WR1_RD & ~wr1_rd_hold;
wire grant1_wr = WR1_WR & ~wr1_wr_hold;

// WRAM_PROBE: latency-sensitivity probe build. Adds a fixed stall to EVERY
// word-RAM arbiter transaction (read hit, read miss, write, prefetch step)
// by holding the FSM between grant and service. Used with the user's
// timer-vs-MiSTer fixed-course protocol: if the Pocket's lag deficit scales
// with this stall, main-68K word-RAM latency is confirmed as the operative
// variable on real hardware (and calibrates the co-sim model, which has the
// matching +sdlat2 knob); if the deficit barely moves, the memory-latency
// theory is dead on hardware. NEVER ship a build with this defined.
//`define WRAM_PROBE
`ifdef WRAM_PROBE
localparam [4:0] WRAM_PROBE_STALL = 5'd16;   // clk_sys, ~2.1 68K clocks
reg  [4:0] wr_stall = 0;
// hold the SDRAM strobes off while stalled, or a write completes while the
// FSM isn't looking and its busy edge is lost
wire wr_probe_go = (wr_stall == 0);
`else
wire wr_probe_go = 1'b1;
`endif

// sequential word-RAM prefetch (see the completion branch below)
localparam [2:0] PF_DEPTH = 3'd7;
reg        wr_pf  = 0;      // the in-flight SDRAM access is speculative
reg  [2:0] pf_cnt = 0;      // words still to pull in
reg        pf_gap = 0;      // one-cycle strobe gap between prefetch reads
// a real request is waiting: yield to it (checked in the pf_gap cycle, where
// the just-served port's stale request line is already hold-masked)
wire       wr_pf_stop = grant0_rd | grant0_wr | grant1_rd | grant1_wr;
// next word in the CPU's 2M-mode access order (banks interleave by VA(1))
wire [16:0] pf_next = {wr_addr, wr_owner} + 1'b1;

`ifdef VERILATOR
// word-RAM read-cache hit/miss counters (sim only: the fitter is at 95% ALM,
// nothing measurement-only may reach hardware). Sonic CD executes its whole
// main-CPU game loop out of word RAM, so this ratio is what sets the main
// 68000's speed in gameplay.
reg [31:0] dbg_wrc_hit  /* verilator public_flat_rd */ = 0;
reg [31:0] dbg_wrc_miss /* verilator public_flat_rd */ = 0;
`endif

always @(posedge clk_sys) begin
	reg old_busy;
	old_busy <= sdld_busy;

	if (~WR0_RD) wr0_rd_hold <= 0;
	else if (wr0_rd_hold) begin
		wr0_rd_tmo <= wr0_rd_tmo - 1'b1;
		if (wr0_rd_tmo == 0) wr0_rd_hold <= 0;
	end
	if (~WR0_WR) wr0_wr_hold <= 0;
	else if (wr0_wr_hold) begin
		wr0_wr_tmo <= wr0_wr_tmo - 1'b1;
		if (wr0_wr_tmo == 0) wr0_wr_hold <= 0;
	end
	if (~WR1_RD) wr1_rd_hold <= 0;
	else if (wr1_rd_hold) begin
		wr1_rd_tmo <= wr1_rd_tmo - 1'b1;
		if (wr1_rd_tmo == 0) wr1_rd_hold <= 0;
	end
	if (~WR1_WR) wr1_wr_hold <= 0;
	else if (wr1_wr_hold) begin
		wr1_wr_tmo <= wr1_wr_tmo - 1'b1;
		if (wr1_wr_tmo == 0) wr1_wr_hold <= 0;
	end

	if ((reset & ~st2_active) | bios_download) begin
		wr_active <= 0;
		WR0_RDY <= 1;
		WR1_RDY <= 1;
		wr_rd_r <= 0;
		wr_wr_r <= 0;
		wr_chk  <= 0;
		wr0_rd_hold <= 0;
		wr0_wr_hold <= 0;
		wr1_rd_hold <= 0;
		wr1_wr_hold <= 0;
		wr_pf  <= 0;
		pf_cnt <= 0;
		pf_gap <= 0;
	end else if (!wr_active && !wrc_flushing && !dbg_prg_active && !dump_active) begin
		if (grant0_rd | grant0_wr) begin
			wr_active <= 1;
			wr_owner  <= 0;
			wr_addr   <= WR0_A;
			wr_din    <= WR0_DO;
			// reads take a cache-lookup cycle first (wr_chk); the RAM read
			// for {bank,addr} was issued combinationally this same cycle
			wr_chk    <= grant0_rd;
			{wr_tag, wr_idx} <= {WR0_A[15:13], 1'b0, WR0_A[12:0]};
			wr_rd_r   <= 0;
			wr_wr_r   <= grant0_wr & ~grant0_rd;
			WR0_RDY   <= 0;
		end else if (grant1_rd | grant1_wr) begin
			wr_active <= 1;
			wr_owner  <= 1;
			wr_addr   <= WR1_A;
			wr_din    <= WR1_DO;
			wr_chk    <= grant1_rd;
			{wr_tag, wr_idx} <= {WR1_A[15:13], 1'b1, WR1_A[12:0]};
			wr_rd_r   <= 0;
			wr_wr_r   <= grant1_wr & ~grant1_rd;
			WR1_RDY   <= 0;
		end
`ifdef WRAM_PROBE
		if (grant0_rd | grant0_wr | grant1_rd | grant1_wr)
			wr_stall <= WRAM_PROBE_STALL;
`endif
`ifdef WRAM_PROBE
	end else if (wr_stall != 0) begin
		// probe: hold the whole FSM here so every transaction pays the stall
		wr_stall <= wr_stall - 1'b1;
`endif
	end else if (wr_chk) begin
		wr_chk <= 0;
		if (wrc_q[19] && wrc_q[18:16] == wr_tag) begin
			// hit: complete without touching SDRAM (2-cycle read)
`ifdef VERILATOR
			dbg_wrc_hit <= dbg_wrc_hit + 1'd1;
`endif
			if (!wr_owner) begin
				WR0_DI  <= wrc_q[15:0];
				WR0_RDY <= 1;
				wr0_rd_hold <= 1; wr0_rd_tmo <= HOLD_TMO;
			end else begin
				WR1_DI  <= wrc_q[15:0];
				WR1_RDY <= 1;
				wr1_rd_hold <= 1; wr1_rd_tmo <= HOLD_TMO;
			end
			wr_active <= 0;
		end else begin
			wr_rd_r <= 1;   // miss: start the SDRAM read (fill on completion)
`ifdef VERILATOR
			dbg_wrc_miss <= dbg_wrc_miss + 1'd1;
`endif
		end
	end else if (wr_pf & pf_gap) begin
		// The SDRAM controller starts on a RISING strobe edge, so each
		// prefetch read launches from this one-cycle strobe gap. It is also
		// the only safe place to check for a waiting requester: at the
		// miss-completion edge the just-served port's request line is still
		// up (it drops 1-2 clks after seeing RDY) and its re-grant hold was
		// set on that same edge, so the grant wires only read true there. A
		// cycle later the hold masks the stale line and any grant left
		// pending is real work -- yield to it.
		pf_gap <= 0;
		if (wr_pf_stop) begin
			wr_pf     <= 0;
			wr_active <= 0;
			wr_rd_r   <= 0;
		end else
			wr_rd_r <= 1;
	end else if (old_busy & ~sdld_busy) begin
		if (wr_pf) begin
			// a prefetch completed: the fill happened in the wrc block above,
			// there is no requester to answer. Keep pulling the stream in
			// while nothing else wants the arbiter.
			if (pf_cnt != 0) begin
				pf_cnt <= pf_cnt - 1'b1;
				{wr_addr, wr_owner} <= pf_next;
				{wr_tag, wr_idx}   <= {pf_next[16:14], pf_next[0], pf_next[13:1]};
				wr_rd_r <= 0;
				pf_gap  <= 1;
			end else begin
				wr_pf     <= 0;
				wr_active <= 0;
				wr_rd_r   <= 0;
			end
		end else begin
		if (!wr_owner) begin
			WR0_DI  <= sdwr_do;
			WR0_RDY <= 1;
			if (wr_rd_r) begin wr0_rd_hold <= 1; wr0_rd_tmo <= HOLD_TMO; end
			else         begin wr0_wr_hold <= 1; wr0_wr_tmo <= HOLD_TMO; end
		end else begin
			WR1_DI  <= sdwr_do;
			WR1_RDY <= 1;
			if (wr_rd_r) begin wr1_rd_hold <= 1; wr1_rd_tmo <= HOLD_TMO; end
			else         begin wr1_wr_hold <= 1; wr1_wr_tmo <= HOLD_TMO; end
		end
		// SEQUENTIAL PREFETCH. The dominant word-RAM client is 68000
		// instruction fetch -- Sonic CD runs its entire main-CPU game loop out
		// of word RAM, ~19.4k fetches a frame -- and with one word per cache
		// entry every new word is a compulsory miss (measured hit rate in
		// gameplay: 31%). Behind a read miss, pull in the next PF_DEPTH words
		// in the CPU's OWN access order: in 2M mode the ASIC interleaves the
		// two banks by EXT_VA(1), so consecutive CPU fetches go (bank0,a),
		// (bank1,a),(bank0,a+1)... = the 17-bit counter {addr,owner}+1, NOT
		// addr+1 within one bank. The CPU can't re-request for >= 2 of its
		// own clocks, so the stream turns into cache hits. The pf_gap cycle
		// above aborts the moment a real requester appears: speculative work
		// must never sit in front of real work.
		if (wr_rd_r) begin
			wr_pf     <= 1;
			wr_active <= 1;
			wr_rd_r   <= 0;
			pf_gap    <= 1;
			pf_cnt    <= PF_DEPTH - 1'b1;
			{wr_addr, wr_owner} <= pf_next;
			{wr_tag, wr_idx}   <= {pf_next[16:14], pf_next[0], pf_next[13:1]};
		end else begin
			wr_active <= 0;
			wr_rd_r   <= 0;
			wr_wr_r   <= 0;
		end
		end
	end
end

///////////////////////////////////////////////
// Boot-time word-RAM ARBITER self-test (debug build). Runs once after
// PLL lock while the core is in host reset. Two independent engines do
// concurrent RMW streams on both banks — the exact pattern the ASIC
// generates — through the arbiter's RDY protocol. Block 7 shows the
// result. (The v1 sequential port-level test already passed on HW.)
///////////////////////////////////////////////

localparam ST2_N = 10'd1023;
reg  [1:0] st2_ph /* verilator public_flat_rd */ = 0;  // 0 wait, 1 RMW pass, 2 verify pass, 3 done
reg  [2:0] st2_s0 = 0, st2_s1 = 0;
reg  [9:0] st2_idx0 = 0, st2_idx1 = 0;
reg        st2_d0 = 0, st2_d1 = 0;   // bank finished current pass
reg [15:0] st2_err /* verilator public_flat_rd */ = 0;
reg        st2_rd0 = 0, st2_wr0 = 0, st2_rd1 = 0, st2_wr1 = 0;
reg [19:0] st2_wait = 0;
reg        st_done = 0, st_pass = 0;
wire       st2_active = (st2_ph == 2'd1) || (st2_ph == 2'd2);
wire [15:0] st2_pat0 = {6'b010101, st2_idx0} ^ 16'hC33C;
wire [15:0] st2_pat1 = {6'b101010, st2_idx1} ^ 16'hC33C;

always @(posedge clk_sys) begin
	case (st2_ph)
		2'd0: if (pll_core_locked && ~bios_download) begin
			if (&st2_wait) begin
				st2_ph <= 2'd1;
				{st2_idx0, st2_idx1, st2_s0, st2_s1, st2_d0, st2_d1} <= 0;
			end else begin
				st2_wait <= st2_wait + 1'b1;
			end
		end
		2'd1, 2'd2: begin
			// bank 0 engine
			if (!st2_d0) case (st2_s0)
				3'd0: begin st2_rd0 <= 1; st2_s0 <= 3'd1; end
				3'd1: if (~WR0_RDY) st2_s0 <= 3'd2;
				3'd2: if (WR0_RDY) begin
					st2_rd0 <= 0;
					if (st2_ph == 2'd2) begin
						if (WR0_DI != st2_pat0) st2_err <= st2_err + 1'b1;
						st2_s0 <= 3'd5;
					end else begin
						st2_wr0 <= 1;      // RMW write-back with pattern
						st2_s0 <= 3'd3;
					end
				end
				3'd3: if (~WR0_RDY) st2_s0 <= 3'd4;
				3'd4: if (WR0_RDY) begin st2_wr0 <= 0; st2_s0 <= 3'd5; end
				3'd5: begin
					if (st2_idx0 == ST2_N) st2_d0 <= 1;
					else st2_idx0 <= st2_idx0 + 1'b1;
					st2_s0 <= 3'd0;
				end
				default: ;
			endcase
			// bank 1 engine (independent, concurrent)
			if (!st2_d1) case (st2_s1)
				3'd0: begin st2_rd1 <= 1; st2_s1 <= 3'd1; end
				3'd1: if (~WR1_RDY) st2_s1 <= 3'd2;
				3'd2: if (WR1_RDY) begin
					st2_rd1 <= 0;
					if (st2_ph == 2'd2) begin
						if (WR1_DI != st2_pat1) st2_err <= st2_err + 1'b1;
						st2_s1 <= 3'd5;
					end else begin
						st2_wr1 <= 1;
						st2_s1 <= 3'd3;
					end
				end
				3'd3: if (~WR1_RDY) st2_s1 <= 3'd4;
				3'd4: if (WR1_RDY) begin st2_wr1 <= 0; st2_s1 <= 3'd5; end
				3'd5: begin
					if (st2_idx1 == ST2_N) st2_d1 <= 1;
					else st2_idx1 <= st2_idx1 + 1'b1;
					st2_s1 <= 3'd0;
				end
				default: ;
			endcase

			if (st2_d0 & st2_d1) begin
				if (st2_ph == 2'd1) begin
					st2_ph <= 2'd2;
					{st2_idx0, st2_idx1, st2_s0, st2_s1, st2_d0, st2_d1} <= 0;
				end else begin
					st2_ph  <= 2'd3;
					st_done <= 1;
					st_pass <= (st2_err == 0);
				end
			end
		end
		default: ;
	endcase
end

reg lightgun_type = 0;
reg [7:0] lightgun_sensor_delay = 8'd44;


///////////////////////////////////////////////
// Controls
///////////////////////////////////////////////

wire [15:0] joystick_0, joystick_1, joystick_2, joystick_3;

wire [31:0] cont1_key_s;
wire [31:0] cont2_key_s;
wire [31:0] cont3_key_s;
wire [31:0] cont4_key_s;
wire [31:0] cont1_joy_s;

synch_3 #(
    .WIDTH(32)
) cont1_s (
    cont1_key,
    cont1_key_s,
    clk_sys
);

synch_3 #(
    .WIDTH(32)
) cont2_s (
    cont2_key,
    cont2_key_s,
    clk_sys
);

synch_3 #(
    .WIDTH(32)
) cont3_s (
    cont3_key,
    cont3_key_s,
    clk_sys
);

synch_3 #(
    .WIDTH(32)
) cont4_s (
    cont4_key,
    cont4_key_s,
    clk_sys
);

synch_3 #(
    .WIDTH(32)
) joy1_s (
    cont1_joy,
    cont1_joy_s,
    clk_sys
);

assign joystick_0 = {
    cont1_key_s[9],  // Z
    cont1_key_s[6],  // Y
    cont1_key_s[8],  // X
    cont1_key_s[14], // mode
    lightgun_enabled  ? 1'b0 : cont1_key_s[15], // start
    cont1_key_s[4],  // C (Pocket A)
    cont1_key_s[5],  // B (Pocket B)
    cont1_key_s[7],  // A (Pocket Y)
    cont1_key_s[0],                                        // up
    cont1_key_s[1],                                        // down
    cont1_key_s[2],                                        // left
    cont1_key_s[3]                                        // right
};

assign joystick_1 = {
    cont2_key_s[9],  // Z
    cont2_key_s[6],  // Y
    cont2_key_s[8],  // X
    cont2_key_s[14], // mode
    cont2_key_s[15], // start
    cont2_key_s[4],  // C (Pocket A)
    cont2_key_s[5],  // B (Pocket B)
    cont2_key_s[7],  // A (Pocket Y)
    cont2_key_s[0],  // up
    cont2_key_s[1],  // down
    cont2_key_s[2],  // left
    cont2_key_s[3]  // right
};

assign joystick_2 = {
    cont3_key_s[9],  // Z
    cont3_key_s[6],  // Y
    cont3_key_s[8],  // X
    cont3_key_s[14], // mode
    cont3_key_s[15], // start
    cont3_key_s[4],  // C (Pocket A)
    cont3_key_s[5],  // B (Pocket B)
    cont3_key_s[7],  // A (Pocket Y)
    cont3_key_s[0],  // up
    cont3_key_s[1],  // down
    cont3_key_s[2],  // left
    cont3_key_s[3]  // right
};

assign joystick_3 = {
    cont4_key_s[9],  // Z
    cont4_key_s[6],  // Y
    cont4_key_s[8],  // X
    cont4_key_s[14], // mode
    cont4_key_s[15], // start
    cont4_key_s[4],  // C (Pocket A)
    cont4_key_s[5],  // B (Pocket B)
    cont4_key_s[7],  // A (Pocket Y)
    cont4_key_s[0],  // up
    cont4_key_s[1],  // down
    cont4_key_s[2],  // left
    cont4_key_s[3]  // right
};

///////////////////////////////////////////////
// Lightguns
///////////////////////////////////////////////
wire [2:0] lg_target;
wire       lg_sensor;
wire       lg_a;
wire       lg_b;
wire       lg_c;
wire       lg_start;

lightgun lightgun
(
    .CLK(clk_sys),
    .RESET(reset),

    // .MOUSE(ps2_mouse),
    // .MOUSE_XY(&gun_mode),

    .JOY_X(cont1_joy_s[7:0]),
    .JOY_Y(cont1_joy_s[15:8]),
    .JOY(cont1_key),

    .UP(cont1_key[0]),
    .DOWN(cont1_key[1]),
    .LEFT(cont1_key[2]),
    .RIGHT(cont1_key[3]),
    .DPAD_AIM_SPEED(dpad_aim_speed),

    .RELOAD(lightgun_type),

    .HDE(~hblank_c),
    .VDE(~vblank_c),
    .CE_PIX(ce_pix),
    .H40(resolution[0]),

    .BTN_MODE(0),
    // .SIZE(0),
    .SENSOR_DELAY(lightgun_sensor_delay),

    .TARGET(lg_target),
    .SENSOR(lg_sensor),
    .BTN_A(lg_a),
    .BTN_B(lg_b),
    .BTN_C(lg_c),
    .BTN_START(lg_start)
);

///////////////////////////////////////////////
// Instance
///////////////////////////////////////////////

wire osnotify_inmenu_s;
synch_3 pause_s (
	osnotify_inmenu, 
	osnotify_inmenu_s, 
	clk_sys
);

// Both of these cross clk_74a -> clk_sys and were previously consumed raw.
// reset_n comes straight from the APF host; reset_delay_zero is the
// registered zero-detect built above. Synchronizing them makes the reset
// release atomic across the emulated system -- every clk_sys flop now sees
// the same edge, instead of the release rippling out unsynchronized over a
// high-fanout net on a 99%-full die.
//
// This matters because the reset duration is deliberately randomized at
// megacd_top.sv:1353 ({reset_counter, 4'b1111}, reset_counter free-running),
// so the phase between release and clk_sys was a fresh dice roll on every
// boot -- which is why "Reset Core until it boots clean" worked at all.
wire reset_n_sync;
synch_3 reset_n_s (reset_n, reset_n_sync, clk_sys);

wire reset_delay_done;
synch_3 reset_delay_done_s (reset_delay_zero, reset_delay_done, clk_sys);

// cart_download is already synchronized (synch_3 cart_download_s) and
// region_set is generated in clk_sys, so both are safe to use directly.
wire reset = ~reset_n_sync | cart_download | region_set;

wire bios_download = cart_download;

///////////////////////////////////////////////
// Genesis (gen) — expansion bus exported
///////////////////////////////////////////////

wire [23:1] GEN_VA;
wire [15:0] GEN_VDI, GEN_VDO;
wire        GEN_RNW, GEN_LDS_N, GEN_UDS_N;
wire        GEN_AS_N, GEN_DTACK_N, GEN_ASEL_N;
wire        GEN_RAS2_N, EXT_ROM_N, EXT_FDC_N;
wire        GEN_VCLK_CE, GEN_CE0_N;
wire        GEN_WRL_N /* verilator public_flat_rd */, GEN_WRH_N /* verilator public_flat_rd */, GEN_OE_N /* verilator public_flat_rd */;
wire        GEN_ROM_CE_N /* verilator public_flat_rd */, GEN_RAM_CE_N /* verilator public_flat_rd */;
wire [15:0] GEN_AUDL, GEN_AUDR;
wire        GEN_CE;

gen gen
(
	.RESET_N(~reset && reset_delay_done),
	.MCLK(clk_sys),

	.VA(GEN_VA),
	.VDI(GEN_VDI),
	.VDO(GEN_VDO),
	.RNW(GEN_RNW),
	.LDS_N(GEN_LDS_N),
	.UDS_N(GEN_UDS_N),
	.AS_N(GEN_AS_N),
	.DTACK_N(GEN_DTACK_N),
	.ASEL_N(GEN_ASEL_N),
	.VCLK_CE(GEN_VCLK_CE),
	.CE0_N(GEN_CE0_N),
	.RAS2_N(GEN_RAS2_N),
	.ROM_N(EXT_ROM_N),
	.FDC_N(EXT_FDC_N),
	.CART_N(CART_CART_N),
	.DISK_N(1'b0),
	.WRL_N(GEN_WRL_N),
	.WRH_N(GEN_WRH_N),
	.OE_N(GEN_OE_N),

	.TIME_N(),
	.TIME_DI(16'hFFFF),

	.LOADING(bios_download),
	.EXPORT(|region_req),
	.PAL(1'b0),

	.EXT_SL(mcd_l),
	.EXT_SR(mcd_r),
	.EXT_EN(1'b1),

	.DAC_LDATA(GEN_AUDL),
	.DAC_RDATA(GEN_AUDR),
	.DAC_CE(GEN_CE),

	.RED(r),
	.GREEN(g),
	.BLUE(b),
	.VS(vs),
	.HS(hs),
	.HBL(hblank),
	.VBL(vblank_sys),
	.BORDER(1'b0),
	.CRAM_DOTS(1'b0),
	.CE_PIX(ce_pix),
	.FIELD(field),
	.INTERLACE(interlaced),
	.RESOLUTION(resolution),
	.TRANSP_DETECT(TRANSP_DETECT),
	.EN_BGA(1'b1),
	.EN_BGB(1'b1),
	.EN_SPR(1'b1),

	// 0 = 6-button pads (the signal is active-high "three button").
	.J3BUT(1'b0),
	.JOY_1(joystick_0[11:0]),
	.JOY_2(joystick_1[11:0]),
	.JOY_3(joystick_2[11:0]),
	.JOY_4(joystick_3[11:0]),
	.JOY_5(12'h000),
	.MULTITAP(3'b000),

	.MOUSE(25'd0),
	.MOUSE_OPT(3'd0),

	.GUN_OPT(lightgun_enabled),
	.GUN_TYPE(lightgun_type),
	.GUN_SENSOR(lg_sensor),
	.GUN_A(lg_a),
	.GUN_B(lg_b),
	.GUN_C(lg_c),
	.GUN_START(lg_start),

	.SERJOYSTICK_IN(8'h00),
	.SERJOYSTICK_OUT(),
	.SER_OPT(2'b00),

	.ENABLE_FM(cs_fm_enable),
	.ENABLE_PSG(cs_psg_enable),
	.EN_HIFI_PCM(cs_hifi_pcm_enable),
	.LADDER(~cs_fm_chip),
	.LPF_MODE(cs_audio_filter),

	.OBJ_LIMIT_HIGH(cs_obj_limit_high_enable),

	.RAM_CE_N(GEN_RAM_CE_N),
	.RAM_RDY(~(gwc_busy | gw_wr_ack)),
	.RFS(),
	.RFS_RDY(1'b1),

	.GG_RESET(1'b0),
	.GG_EN(1'b0),
	.GG_CODE(129'd0),
	.GG_AVAILABLE(),

	.DBG_M68K_A(dbg_m68k_a),
	.DBG_MBUS_A()
);

wire [23:0] dbg_m68k_a /* verilator public_flat_rd */;

// Expansion-bus read-data / DTACK tie: exactly one slave answers per cycle
assign GEN_VDI = !GEN_RAM_CE_N ? GEN_MEM_DO_R :
                 !CART_DTACK_N ? CART_DO :
                 MCD_DO;
assign GEN_DTACK_N = MCD_DTACK_N & CART_DTACK_N;

// latch gen's read data only on gen-owned completions (a ROM-window
// completion must not clobber it — same aliasing family as the RDY fix)
reg [15:0] GEN_MEM_DO_R;
always @(posedge clk_sys) begin
	reg old_bsy;
	old_bsy <= gwc_busy;
	if(old_bsy & ~gwc_busy) GEN_MEM_DO_R <= gwc_dout;
end

///////////////////////////////////////////////
// MegaCD subsystem
///////////////////////////////////////////////

wire [15:0] MCD_DO;
wire        MCD_DTACK_N;
wire [15:0] MCD_PCM_SL, MCD_PCM_SR, MCD_CDDA_SL, MCD_CDDA_SR;
wire        MCD_CDDA_WR_READY;
wire [17:0] MCD_PRG_ADDR;
wire [15:0] MCD_PRG_DO, MCD_PRG_DI;
wire        MCD_PRG_OE_N /* verilator public_flat_rd */, MCD_PRG_WRL_N, MCD_PRG_WRH_N, MCD_PRG_BUSY;
wire [13:1] MCD_BRAM_ADDR;
wire  [7:0] MCD_BRAM_DO, MCD_BRAM_DI;
wire        MCD_BRAM_WE;
wire        MCD_RST_N /* verilator public_flat_rd */;

MCD MCD
(
	// keep gen/MCD/CART reset release aligned: reset_delay applied to all
	.RST_N(~(reset | bios_download) && reset_delay_done),
	.CLK(clk_sys),
	.ENABLE(1'b1),
	.MCD_RST_N(MCD_RST_N),
	.PALSW(1'b0),

	.EXT_VA(GEN_VA[17:1]),
	.EXT_VDI(GEN_VDO),
	.EXT_VDO(MCD_DO),
	.EXT_AS_N(GEN_AS_N),
	.EXT_RNW(GEN_RNW),
	.EXT_LDS_N(GEN_LDS_N),
	.EXT_UDS_N(GEN_UDS_N),
	.EXT_DTACK_N(MCD_DTACK_N),
	.EXT_ASEL_N(GEN_ASEL_N),
	.EXT_VCLK_CE(GEN_VCLK_CE),
	.EXT_RAS2_N(GEN_RAS2_N),
	.EXT_ROM_N(EXT_ROM_N),
	.EXT_FDC_N(EXT_FDC_N),

	.PRG_A(MCD_PRG_ADDR),
	.PRG_DI(MCD_PRG_DI),
	.PRG_DO(MCD_PRG_DO),
	.PRG_WRL_N(MCD_PRG_WRL_N),
	.PRG_WRH_N(MCD_PRG_WRH_N),
	.PRG_OE_N(MCD_PRG_OE_N),
	.PRG_RFS(),
	.PRG_RDY(~MCD_PRG_BUSY),

	.ROM_DI(brom_dout),
	.ROM_CE_N(GEN_ROM_CE_N),
	.ROM_RDY(~brom_busy),

	.BRAM_A(MCD_BRAM_ADDR),
	.BRAM_DI(MCD_BRAM_DI),
	.BRAM_DO(MCD_BRAM_DO),
	.BRAM_WE(MCD_BRAM_WE),

	.WORDRAM0_A(MWR0_A),
	.WORDRAM0_DI(WR0_DI),
	.WORDRAM0_DO(MWR0_DO),
	.WORDRAM0_RD(MWR0_RD),
	.WORDRAM0_WR(MWR0_WR),
	.WORDRAM0_RDY(WR0_RDY),
	.WORDRAM1_A(MWR1_A),
	.WORDRAM1_DI(WR1_DI),
	.WORDRAM1_DO(MWR1_DO),
	.WORDRAM1_RD(MWR1_RD),
	.WORDRAM1_WR(MWR1_WR),
	.WORDRAM1_RDY(WR1_RDY),

	.CDD_STAT(cdd_stat),
	.CDD_COMM(cdd_comm),
	.CDD_SEND(cdd_send),
	.CDD_REC(cdd_rec),
	.CDD_DM(cdd_dm),

	.CDC_DATA(CD_CDC_DATA),
	.CDC_DAT_WR(CD_CDC_DAT_WR),
	.CDC_DEC_TICK(CD_CDC_DEC_TICK),
	.CDC_SC_WR(1'b0),
	.CDC_CDDA_WR(CD_CDC_CDDA_WR),
	.CDDA_WR_READY(MCD_CDDA_WR_READY),

	.PCM_SL(MCD_PCM_SL),
	.PCM_SR(MCD_PCM_SR),
	.CDDA_SL(MCD_CDDA_SL),
	.CDDA_SR(MCD_CDDA_SR),

	.LED_RED(),
	.LED_GREEN(),

	.GG_RESET(1'b0),
	.GG_EN(1'b0),
	.GG_CODE(129'd0),
	.GG_AVAILABLE(),

	.DBG_S68K_A(dbg_s68k_a),
	.DBG_S68K_IPL_N(dbg_s68k_ipl_n),
	.DBG_INT_PEND(dbg_int_pend),
	.DBG_INT_ACK(dbg_int_ack),
	.DBG_GRON(dbg_gron)
	,.DBG_COMM(dbg_comm)
	,.DBG_CDCX(dbg_cdcx)
	,.DBG_DEC(dbg_dec)
);

wire [2:0] dbg_s68k_ipl_n;
wire [6:1] dbg_int_pend, dbg_int_ack;
wire dbg_gron;
// These were stubbed to 0 under VERILATOR because the co-sim's pre-converted
// mcd.v predated the ports. It has been reconverted and carries them now, so
// the co-sim can read the real values -- which is the whole point of having
// them when chasing something the overlay cannot reach.
wire [15:0] dbg_comm;   // {CFM, CFS} as read at $A1200E
wire [31:0] dbg_cdcx;   // CDC host-transfer state (see ASIC.vhd DBG_CDCX)
wire [31:0] dbg_dec /* verilator public_flat_rd */;  // CDC decode path (CDC.vhd DBG_DEC)

///////////////////////////////////////////////
// Bring-up debug indicators (top-left corner)
///////////////////////////////////////////////

wire [23:0] dbg_s68k_a /* verilator public_flat_rd */;
reg  [23:0] dbg_s68k_a_d;
reg  [9:0]  dbg_sub_cnt = 0;
reg         dbg_sub_alive = 0;   // sub-CPU address bus is moving
reg         dbg_cdd_seen = 0;    // BIOS raised HOCK and sent a CDD command
reg         dbg_wr_req = 0;      // a word RAM access was requested
reg         dbg_wr_started = 0;
reg         dbg_wr_done = 0;     // a word RAM access completed

always @(posedge clk_sys) begin
	dbg_s68k_a_d <= dbg_s68k_a;
	if (reset) begin
		dbg_sub_cnt <= 0;
		dbg_sub_alive <= 0;
		dbg_cdd_seen <= 0;
		dbg_wr_req <= 0;
		dbg_wr_started <= 0;
		dbg_wr_done <= 0;
	end else begin
		if (dbg_s68k_a != dbg_s68k_a_d) begin
			if (&dbg_sub_cnt) dbg_sub_alive <= 1;
			else dbg_sub_cnt <= dbg_sub_cnt + 1'b1;
		end

		// sub-CPU speedometer: address-bus changes per second, log scale
		dbg_ack_d <= dbg_int_ack;
		if (dbg_sec == 26'd53693174) begin
			dbg_sec <= 0;
			dbg_rate <= dbg_rate_cnt;
			dbg_rate_cnt <= 0;
			dbg_ipl_duty <= dbg_ipl_cnt[25:23];   // top 3 bits = duty/8
			dbg_ipl_cnt <= 0;
			for (di = 1; di < 7; di = di + 1) begin
				dbg_pend_duty[di] <= dbg_pend_cnt[di][25:23];
				dbg_pend_cnt[di] <= 0;
			end
			dbg_ack2_rate <= dbg_ack2_cnt;
			dbg_ack2_cnt <= 0;
			dbg_ack4_rate <= dbg_ack4_cnt;
			dbg_ack4_cnt <= 0;
			dbg_ack5_rate <= dbg_ack5_cnt;
			dbg_ack5_cnt <= 0;
			dbg_gron_duty <= dbg_gron_cnt[25:23];
			dbg_gron_cnt <= 0;
			dbg_m68k_smp <= dbg_m68k_a;
			dbg_s68k_smp <= dbg_s68k_a;
			dbg_bus_rate <= dbg_bus_cnt[20:13];
			dbg_bus_cnt <= 0;
			dbg_vdpw_rate <= dbg_vdpw_cnt[20:13];
			dbg_vdpw_cnt <= 0;
			dbg_wrrd_rate <= dbg_wrrd_cnt[20:13];
			dbg_wrrd_cnt <= 0;
			dbg_dmna_rate <= dbg_dmna_cnt;
			dbg_dmna_cnt <= 0;
			dbg_gfx_rate <= dbg_gfx_cnt;
			dbg_gfx_cnt <= 0;
			dbg_sub_rate <= dbg_rate_cnt[22] ? 8'hFF : dbg_rate_cnt[21:14];
			dbg_vdpwf_rate <= dbg_vdpwf_cnt;
			dbg_vdpwf_cnt <= 0;
			dbg_gfxf_rate <= dbg_gfxf_cnt;
			dbg_gfxf_cnt <= 0;
			dbg_glen <= dbg_glen_max;
			dbg_glen_max <= 0;
			dbg_wracc_rate <= dbg_wracc_cnt[20:13];
			dbg_wracc_cnt <= 0;
			dbg_wrbusy_duty <= dbg_wrbusy_cnt[25:18];
			dbg_wrbusy_cnt <= 0;
		end else begin
			dbg_sec <= dbg_sec + 1'b1;
			dbg_as_d <= GEN_AS_N;
			if (dbg_as_d & ~GEN_AS_N) dbg_bus_cnt <= dbg_bus_cnt + 1'b1;
			dbg_vdpw_d <= dbg_vdpw;
			if (~dbg_vdpw_d & dbg_vdpw) dbg_vdpw_cnt <= dbg_vdpw_cnt + 1'b1;
			dbg_wrrd_d <= dbg_wrrd;
			if (~dbg_wrrd_d & dbg_wrrd) dbg_wrrd_cnt <= dbg_wrrd_cnt + 1'b1;
			dbg_dmna_d <= dbg_dmna;
			if (~dbg_dmna_d & dbg_dmna & ~&dbg_dmna_cnt) dbg_dmna_cnt <= dbg_dmna_cnt + 1'b1;
			if (dbg_s68k_a != dbg_s68k_a_d && ~&dbg_rate_cnt)
				dbg_rate_cnt <= dbg_rate_cnt + 1'b1;
			if (dbg_s68k_ipl_n != 3'b111)
				dbg_ipl_cnt <= dbg_ipl_cnt + 1'b1;
			for (di = 1; di < 7; di = di + 1)
				if (dbg_int_pend[di]) dbg_pend_cnt[di] <= dbg_pend_cnt[di] + 1'b1;
			if (dbg_int_ack[2] & ~dbg_ack_d[2] & ~&dbg_ack2_cnt) dbg_ack2_cnt <= dbg_ack2_cnt + 1'b1;
			if (dbg_int_ack[4] & ~dbg_ack_d[4] & ~&dbg_ack4_cnt) dbg_ack4_cnt <= dbg_ack4_cnt + 1'b1;
			if (dbg_int_ack[5] & ~dbg_ack_d[5] & ~&dbg_ack5_cnt) dbg_ack5_cnt <= dbg_ack5_cnt + 1'b1;
			if (dbg_gron) dbg_gron_cnt <= dbg_gron_cnt + 1'b1;
			dbg_gron_d <= dbg_gron;
			if (dbg_gron_d & ~dbg_gron & ~&dbg_gfx_cnt) dbg_gfx_cnt <= dbg_gfx_cnt + 1'b1;
			// GFX op duration: count clk cycles while GRON high; keep the
			// second's max as a saturating >>13 byte
			if (dbg_gron) begin
				if (~&dbg_glen_cnt) dbg_glen_cnt <= dbg_glen_cnt + 1'b1;
			end else if (dbg_gron_d) begin
				if (dbg_glen_byte > dbg_glen_max) dbg_glen_max <= dbg_glen_byte;
				dbg_glen_cnt <= 0;
			end
			// per-frame parity: at each vblank rising edge, count whether the
			// frame just ended saw any data-port write / any GFX-op completion.
			// 3C = the event happens every frame; 1E = bunched in alternate frames.
			dbg_vbl_d <= vblank_sys;
			if (~dbg_vbl_d & vblank_sys) begin
				if (dbg_f_vdpw & ~&dbg_vdpwf_cnt) dbg_vdpwf_cnt <= dbg_vdpwf_cnt + 1'b1;
				if (dbg_f_gfx & ~&dbg_gfxf_cnt) dbg_gfxf_cnt <= dbg_gfxf_cnt + 1'b1;
				dbg_f_vdpw <= 0;
				dbg_f_gfx <= 0;
			end
			if (~dbg_vdpw_d & dbg_vdpw) dbg_f_vdpw <= 1;
			if (dbg_gron_d & ~dbg_gron) dbg_f_gfx <= 1;
			// word-RAM arbiter profile: completed accesses/s + busy duty
			dbg_wract_d <= wr_active;
			if (dbg_wract_d & ~wr_active) dbg_wracc_cnt <= dbg_wracc_cnt + 1'b1;
			if (wr_active) dbg_wrbusy_cnt <= dbg_wrbusy_cnt + 1'b1;
		end
		if (cdd_send) dbg_cdd_seen <= 1;
		if (WR0_RD | WR0_WR | WR1_RD | WR1_WR) dbg_wr_req <= 1;
		if (~WR0_RDY | ~WR1_RDY) dbg_wr_started <= 1;
		if (dbg_wr_started & WR0_RDY & WR1_RDY) dbg_wr_done <= 1;

		// stuck detectors: latch red if a condition persists ~0.6s
		if (WR0_RD | WR0_WR | WR1_RD | WR1_WR) begin
			if (&dbg_wrstuck_cnt) dbg_wr_stuck <= 1;
			else dbg_wrstuck_cnt <= dbg_wrstuck_cnt + 1'b1;
		end else begin
			dbg_wrstuck_cnt <= 0;
		end
		if (~MCD_DTACK_N) begin
			if (&dbg_dtack_cnt) dbg_dtack_stuck <= 1;
			else dbg_dtack_cnt <= dbg_dtack_cnt + 1'b1;
		end else begin
			dbg_dtack_cnt <= 0;
		end
	end
end

reg [24:0] dbg_wrstuck_cnt = 0;
reg        dbg_wr_stuck /* verilator public_flat_rd */ = 0;     // a word-RAM request stayed pending ~0.6s
reg [24:0] dbg_dtack_cnt = 0;
reg        dbg_dtack_stuck /* verilator public_flat_rd */ = 0;  // main CPU wedged on an MCD access ~0.6s
reg [25:0] dbg_sec = 0;
// main-CPU bus cycles per second (GEN_AS_N falling edges); displayed as
// rate>>13 in the overlay so ideal ~1.9M/s reads ~0xE8, half-speed ~0x74
reg [20:0] dbg_bus_cnt = 0;
reg  [7:0] dbg_bus_rate = 0;
reg        dbg_as_d = 1;
// VDP data-port write rate (>>13): how many blit words land per second
reg [20:0] dbg_vdpw_cnt = 0;
reg  [7:0] dbg_vdpw_rate = 0;
reg        dbg_vdpw_d = 0;
wire       dbg_vdpw = ~GEN_AS_N & ~GEN_RNW & (GEN_VA[23:1] >= 23'h600000) & (GEN_VA[23:1] < 23'h600002);
// word-RAM window (200000-23FFFF) read rate (>>13), shown in row 2's pad
// byte. Qualified on ASEL_N, not AS_N, so VDP-DMA reads count too (gen.sv
// only asserts the exported AS_N for CPU-mastered cycles).
reg [20:0] dbg_wrrd_cnt = 0;
reg  [7:0] dbg_wrrd_rate = 0;
reg        dbg_wrrd_d = 0;
wire       dbg_wrrd = ~GEN_ASEL_N & GEN_RNW & (GEN_VA[23:1] >= 23'h100000) & (GEN_VA[23:1] < 23'h120000);
// main-CPU writes to gate-array A12003 (DMNA) per second, shown in row 3's
// pad byte: the word-RAM bank-swap request rate. 3C = 60Hz produce/consume
// loop, 1E = the handshake itself runs at half rate. Saturates at FF.
reg  [7:0] dbg_dmna_cnt = 0;
reg  [7:0] dbg_dmna_rate = 0;
reg        dbg_dmna_d = 0;
wire       dbg_dmna = ~GEN_AS_N & ~GEN_RNW & (GEN_VA[23:1] == 23'h509001);
reg [22:0] dbg_rate_cnt = 0;
reg [22:0] dbg_rate = 0;         // sub address changes in the last second
reg [25:0] dbg_ipl_cnt = 0;
reg [2:0]  dbg_ipl_duty = 0;     // fraction of the second with an IRQ pending (/8)
integer di;
reg [25:0] dbg_pend_cnt [1:6];
reg [2:0]  dbg_pend_duty [1:6];  // per-level pending duty (/8)
reg [6:1]  dbg_ack_d = 0;
reg [7:0]  dbg_ack2_cnt = 0, dbg_ack2_rate = 0;  // INT2 (frame) acks/sec
reg [7:0]  dbg_ack4_cnt = 0, dbg_ack4_rate = 0;  // INT4 (CDD) acks/sec
reg [7:0]  dbg_ack5_cnt = 0, dbg_ack5_rate = 0;  // INT5 (CDC) acks/sec
reg [25:0] dbg_gron_cnt = 0;
reg [2:0]  dbg_gron_duty = 0;    // GFX op in-flight duty (/8)
reg        dbg_gron_d = 0;
reg [7:0]  dbg_gfx_cnt = 0, dbg_gfx_rate = 0;  // GFX ops completed/sec (saturating)
reg [23:0] dbg_glen_cnt = 0;     // clk cycles of the in-flight GFX op
wire [7:0] dbg_glen_byte = |dbg_glen_cnt[23:21] ? 8'hFF : dbg_glen_cnt[20:13];
reg [7:0]  dbg_glen_max = 0, dbg_glen = 0;     // longest op this/last second
reg [7:0]  dbg_sub_rate = 0;     // sub addr-change rate >>14 (ideal ~0xBE)
reg        dbg_vbl_d = 0;
reg        dbg_f_vdpw = 0, dbg_f_gfx = 0;      // event-seen-this-frame flags
reg [7:0]  dbg_vdpwf_cnt = 0, dbg_vdpwf_rate = 0;  // frames/sec with a data-port write
reg [7:0]  dbg_gfxf_cnt = 0, dbg_gfxf_rate = 0;    // frames/sec with a GFX-op completion
// word-RAM arbiter profile (row 2/3 pad bytes): completions/s >>13 and
// wr_active duty in 1/256s units (0xCC = busy the whole second)
reg        dbg_wract_d = 0;
reg [20:0] dbg_wracc_cnt = 0;
reg [7:0]  dbg_wracc_rate = 0;
reg [25:0] dbg_wrbusy_cnt = 0;
reg [7:0]  dbg_wrbusy_duty = 0;
reg [23:0] dbg_m68k_smp = 0;     // 1Hz address-bus samples (crude profiler)
reg [23:0] dbg_s68k_smp = 0;

// PRG-RAM peek: once per second read 8 words at PRG byte $6168 (the sub's
// spin loop) via SDRAM port 2, shown as two hex rows. Bursts only start
// with the word-RAM arbiter idle, and grants are held off during them.
reg        dbg_prg_active = 0;
reg  [3:0] dbg_prg_idx = 0;
reg        dbg_prg_req = 0;
reg        dbg_prg_go = 0;
reg [255:0] dbg_prg_data = 0;
// two windows: PRG bytes $6168.. and $8330..
// bank0: PRG $8390-$839F = CDBSTAT block ($8394 = CDD drive status; $0B =
// NO_DISC expected with empty drive). bank1: PRG $8330-$833F = player mode
// word ($833C), abort ($833E), busy ($833F).
wire [17:0] dbg_prg_addr = dbg_prg_idx[3] ? (18'h4198 + dbg_prg_idx[2:0])
                                          : (18'h41C8 + dbg_prg_idx[2:0]);

always @(posedge clk_sys) begin
	reg old_busy3;
	old_busy3 <= sdld_busy;
	if (dbg_sec == 26'd53693174) dbg_prg_go <= 1;
	// defer to any pending word-RAM grant: both this block and the arbiter
	// fire on the same clk edge, so without this guard both can claim the
	// shared SDRAM port in the same cycle — the mux then serves the debug
	// address while the arbiter falsely completes the word-RAM access with
	// the sampler's data (corrupted RMW read / silently dropped write)
	if (dbg_prg_go && !dbg_prg_active && !wr_active && !bios_download && st_done
	    && !(grant0_rd | grant0_wr | grant1_rd | grant1_wr)) begin
		dbg_prg_active <= 1;
		dbg_prg_go <= 0;
		dbg_prg_idx <= 0;
		dbg_prg_req <= 1;
	end else if (dbg_prg_active) begin
		if (dbg_prg_req && old_busy3 && !sdld_busy) begin
			dbg_prg_data[{~dbg_prg_idx, 4'b0} +: 16] <= sdwr_do;
			dbg_prg_req <= 0;
		end else if (!dbg_prg_req) begin
			if (dbg_prg_idx == 4'd15) dbg_prg_active <= 0;
			else begin
				dbg_prg_idx <= dbg_prg_idx + 1'b1;
				dbg_prg_req <= 1;
			end
		end
	end
end

// CDD drive stub (M1): "no disc" responder; the real drive MPU lands in M2
wire [39:0] cdd_stat /* verilator public_flat_rd */, cdd_comm /* verilator public_flat_rd */;
wire        cdd_send /* verilator public_flat_rd */, cdd_rec /* verilator public_flat_rd */, cdd_dm;
// Effective CD size (bin size for cue mounts, 0 until the mount FSM is
// done) crosses from clk_74a as a quasi-static value: sample through a
// 2FF-deep pipe and only accept when stable. Track count likewise.
// TOC finality: mounted AND no further layout pass pending AND not currently
// mid-layout.
//
// The M_LAYOUT exclusion is load-bearing. lay_prelim is cleared in M_FDIV in
// the SAME cycle that dispatches the refine pass (see "PHASE 2 done"), so
// !lay_prelim alone goes true BEFORE M_LAYOUT rewrites entries 1..N one per
// pass, and before ph5 publishes the true leadout into mount_eff_size.
//
// A raw BIN/ISO mount has no cue and no phase 2, so lay_prelim is 0, the
// single M_LAYOUT pass retires immediately, and this is simply mount_ready.
wire       toc_final_74 = mount_ready && !lay_prelim && (mnt_st != M_LAYOUT);
reg        toc_final_s1 = 0;
reg        toc_final_sys /* verilator public_flat_rd */ = 0;
reg        loading_s1 = 0;
reg        loading_sys /* verilator public_flat_rd */ = 0;
reg        cd_fast_s1 = 0, cd_fast_sys = 0;   // menu bit, clk_74a -> clk_sys
// THE DISC DOES NOT EXIST UNTIL ITS TOC IS FINAL.
//
// A multi-bin cue needs ~21 host round-trips per audio bin to size it (APF
// publishes no size for core-initiated openfiles), so the real TOC is not
// known for hundreds of ms after the mount -- and that scales with track
// count. Publishing the disc before then hands the BIOS a preliminary TOC
// whose tracks past track 2 carry placeholder LBAs minutes off the truth; it
// caches those and every later track plays from the wrong place (the silent
// level music in Terminator).
//
// Holding the DRIVE busy instead (parking it in STOP = CHECKING DISC) does
// not work: the BIOS times that state out and declares NO DISC, and the
// timeout is shorter than the probe on track-heavy discs. So gate the disc's
// EXISTENCE instead. While probing, img_size reads 0, the drive drains to
// NO_DISC exactly as it does with no disc at all, and the BIOS sits in its
// untimed no-disc idle panel. When the TOC lands the disc appears and the
// drive's own proven NO_DISC -> OPEN -> TOC insertion dance runs, unmodified.
// The drive needs no knowledge of any of this.
//
// Bonus: with no disc the drive issues no fetches, so the probe runs
// uncontended and finishes sooner than it would have otherwise.
wire [31:0] cd_mount_size = toc_final_74 ? mount_eff_size : 32'd0;
reg [31:0] cd_img_size_s1;
reg [31:0] cd_img_size_sys /* verilator public_flat_rd */ = 0;
reg [6:0]  toc_count_s1, toc_count_sys = 0;
always @(posedge clk_sys) begin
	cd_img_size_s1 <= cd_mount_size;
	if (cd_img_size_s1 == cd_mount_size) cd_img_size_sys <= cd_img_size_s1;
	toc_count_s1 <= toc_track_count;
	if (toc_count_s1 == toc_track_count) toc_count_sys <= toc_count_s1;
	toc_final_s1 <= toc_final_74;
	toc_final_sys <= toc_final_s1;
	cd_fast_s1  <= cs_cd_fast;
	cd_fast_sys <= cd_fast_s1;
	loading_s1  <= mount_loading;
	loading_sys <= loading_s1;
end

wire [15:0] CD_CDC_DATA;
wire        CD_CDC_DAT_WR;
wire        CD_CDC_DEC_TICK;  // CDC null decoder tick (see the drive)

megacd_cdd_drive cdd_drive
(
	.clk(clk_sys),
	.reset(reset),
	.mcd_rst_n(MCD_RST_N),
	.cdd_comm(cdd_comm),
	.cdd_send(cdd_send),
	.cdd_stat(cdd_stat),
	.cdd_rec(cdd_rec),
	.cdd_dm(cdd_dm),

	.img_size(cd_img_size_sys),

	.cd_req(cd_req),
	.cd_req_offset(cd_req_offset),
	.cd_req_slot(cd_req_slot),
	.cd_ack_74a(cd_ack),

	.cd_buf_addr(cd_buf_addr),
	.cd_buf_q(cd_buf_q),

	.cdc_data(CD_CDC_DATA),
	.cdc_dat_wr(CD_CDC_DAT_WR),
	.cdc_dec_tick(CD_CDC_DEC_TICK),
	.cdc_cdda_wr(CD_CDC_CDDA_WR),
	.cdda_wr_ready(MCD_CDDA_WR_READY),

	.track_count(toc_count_sys),
	.disc_loading(loading_sys),
	.cd_fast_seek(cd_fast_sys),
	.toc_addr(toc_rd_addr),
	.toc_q(toc_rd_q),
	.cd_req_file(cd_req_file),

	.dbg_state(cdd_dbg_state),
	.dbg_sector_done(cdd_dbg_secdone),
	.dbg_cmds(cdd_dbg_cmds),
	.dbg_pos(cdd_dbg_pos),
	.dbg_integ(cdd_dbg_integ)
);
wire [31:0] cdd_dbg_integ; // {bad-sync count, first bad LBA, audio, pregap}
wire [31:0] cdd_dbg_pos;    // {rs_type, cur_audio, cur_track, last seek LBA}
wire [31:0] cdd_dbg_cmds;   // {last_real_c0, pause_run, seek_cnt,
                            //  backseek_cnt, last_c0, status}
wire CD_CDC_CDDA_WR;

// CD fetch-path counters for the hardware overlay (debug only, loose CDC)
wire [31:0] cdd_dbg_state;

// main/sub comm-flag tap. CFM is written by the MAIN CPU, CFS by the SUB,
// and both are read back together at $A1200E -- the register the main CPU
// sits polling when a reset-with-disc-mounted hangs the BIOS. The raw values
// alone cannot distinguish "frozen" from "settled on a value", so count the
// changes on each side too: if the CFM counter climbs while the CFS counter
// stands still, the main CPU is asking and the sub is not answering.
reg  [7:0] dbg_cfm_chg = 0, dbg_cfs_chg = 0;
reg [15:0] dbg_comm_d = 0;
always @(posedge clk_sys) begin
    dbg_comm_d <= dbg_comm;
    if (dbg_comm[15:8] != dbg_comm_d[15:8]) dbg_cfm_chg <= dbg_cfm_chg + 1'b1;
    if (dbg_comm[7:0]  != dbg_comm_d[7:0])  dbg_cfs_chg <= dbg_cfs_chg + 1'b1;
end
// CFM CFS <cfm changes> <cfs changes>
wire [31:0] dbg_commrow = {dbg_comm, dbg_cfm_chg, dbg_cfs_chg};

// CD-path debug counters for the overlay (clk_74a): every host round-trip
// and error, plus a snapshot of the fetch/reopen/mount state machines
reg [15:0] dbg_rd_cnt = 0;   // dataslot reads completed
reg  [7:0] dbg_of_cnt = 0;   // openfile round-trips completed
reg  [7:0] dbg_err_cnt = 0;  // reads/openfiles that returned err != 0
reg        tds_done_d = 0, tds_fdone_d = 0;
always @(posedge clk_74a) begin
    tds_done_d  <= target_dataslot_done;
    tds_fdone_d <= target_dataslot_file_done;
    if (target_dataslot_done & ~tds_done_d) begin
        dbg_rd_cnt <= dbg_rd_cnt + 1'b1;
        if (target_dataslot_err != 0) dbg_err_cnt <= dbg_err_cnt + 1'b1;
    end
    if (target_dataslot_file_done & ~tds_fdone_d) begin
        dbg_of_cnt <= dbg_of_cnt + 1'b1;
        if (target_dataslot_err != 0) dbg_err_cnt <= dbg_err_cnt + 1'b1;
    end
end
wire [31:0] dbg_cdpath = {2'b0, cdf_st, 3'b0, reopen_req,
                          mnt_st[3:0], dbg_tstate,
                          3'b0, opened_file, 1'b0, crf_stable};
wire [31:0] dbg_cdcnt  = {dbg_of_cnt, dbg_err_cnt, dbg_rd_cnt};
wire        cdd_dbg_secdone;
reg  [7:0]  dbg_cdreq_cnt = 0, dbg_cdack_cnt = 0;
// last CDD command word + counter (rightmost hex digit of the low word is
// c0, the command nibble — e.g. xxxxxxxD = OPEN TRAY)
reg [39:0]  dbg_cdd_lastcomm = 0;
reg  [7:0]  dbg_cdd_cmd_cnt = 0;
always @(posedge clk_sys) begin : cddcmdcnt
	reg send_d;
	send_d <= cdd_send;
	if (cdd_send && !send_d) begin
		dbg_cdd_lastcomm <= cdd_comm;
		dbg_cdd_cmd_cnt  <= dbg_cdd_cmd_cnt + 1'b1;
	end
end
always @(posedge clk_sys) begin : cdreqcnt
	reg req_d;
	req_d <= cd_req;
	if (cd_req && !req_d) dbg_cdreq_cnt <= dbg_cdreq_cnt + 1'b1;
end
always @(posedge clk_74a) begin : cdackcnt
	reg ack_d;
	ack_d <= cd_ack;
	if (cd_ack && !ack_d) dbg_cdack_cnt <= dbg_cdack_cnt + 1'b1;
end

///////////////////////////////////////////////
// Cart slot: empty (MegaCD boot mode)
///////////////////////////////////////////////

wire [15:0] CART_DO;
wire        CART_DTACK_N, CART_CART_N;
wire        CART_ROM_CE_N, CART_RAM_CE_N;

CART CART
(
	.RST_N(~(reset | bios_download) && reset_delay_done),
	.CLK(clk_sys),
	.ENABLE(1'b1),

	.ROM_MODE(1'b0),   // no cartridge inserted: BIOS boots from expansion
	.RAM_ID(8'd255),   // no RAM cart in M1

	.VA(GEN_VA),
	.VDI(GEN_VDO),
	.VDO(CART_DO),
	.AS_N(GEN_AS_N),
	.RNW(GEN_RNW),
	.LDS_N(GEN_LDS_N),
	.UDS_N(GEN_UDS_N),
	.DTACK_N(CART_DTACK_N),
	.ASEL_N(GEN_ASEL_N),
	.VCLK_CE(GEN_VCLK_CE),
	.CE0_N(GEN_CE0_N),
	.CART_N(CART_CART_N),

	.ROM_CE_N(CART_ROM_CE_N),
	.ROM_DI(GEN_MEM_DO),
	.ROM_RDY(~GEN_MEM_BUSY),

	.RAM_CE_N(CART_RAM_CE_N),
	.RAM_DI(GEN_MEM_DO),
	.RAM_RDY(~GEN_MEM_BUSY)
);

///////////////////////////////////////////////
// 8KB internal backup RAM + audio mix
///////////////////////////////////////////////

wire [15:0] bram_sd_q;
dpram_dif #(13,8,12,16) backup_ram
(
	.clock(clk_sys),
	.address_a(MCD_BRAM_ADDR),
	.data_a(MCD_BRAM_DO),
	.wren_a(MCD_BRAM_WE),
	.q_a(MCD_BRAM_DI),

	.address_b(sd_buff_addr[11:0]),
	.data_b(sd_buff_dout),
	.wren_b(sd_wr),
	.q_b(bram_sd_q)
);
`ifndef MCD_SAVE_DUMP
// backup RAM readback -> save unloader, written to the .sav on exit
assign sd_buff_din = bram_sd_q;
`endif

// MCD PCM + CDDA pre-mix, fed into gen's mixer via EXT_SL/SR (EXT_EN=1)
reg [15:0] mcd_l, mcd_r;
always @(posedge clk_sys) begin
	mcd_l <= {MCD_PCM_SL[15],MCD_PCM_SL[15:1]} + {MCD_CDDA_SL[15],MCD_CDDA_SL[15:1]};
	mcd_r <= {MCD_PCM_SR[15],MCD_PCM_SR[15:1]} + {MCD_CDDA_SR[15],MCD_CDDA_SR[15:1]};
end

///////////////////////////////////////////////

    wire    clk_sys;
    wire    clk_ram;
    wire    clk_vid_320;
    wire    clk_vid_320_90deg;
    wire    clk_vid_256;
    wire    clk_vid_256_90deg;
    wire    clk_vid_448i;
    wire    clk_vid_448i_90deg;

    wire    pll_core_locked;

    mf_pllbase
        mp1 (
            .refclk   ( clk_74a            ),
            .rst      ( 0                  ),

            .outclk_0 ( clk_sys            ),
            .outclk_1 ( clk_ram            ),
            .outclk_2 ( clk_vid_320        ),
            .outclk_3 ( clk_vid_320_90deg  ),
            .outclk_4 ( clk_vid_256        ),
            .outclk_5 ( clk_vid_256_90deg  ),

            .locked   ( pll_core_locked    )
        );

endmodule