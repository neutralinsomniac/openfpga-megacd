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
    .datatable_q            ( datatable_q )

);

////////////////////////////////////////////////////////////////////////////////////////
// Core Settings
///////////////////////////////////////////////

// System
reg [11:0] reset_counter 		 = 0;
reg [15:0] reset_delay			 = 0;
reg [1:0] cs_cpu_turbo			 = 0;
reg cs_multitap_enable			 = 0;
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

always @(posedge clk_74a) begin
    reset_counter = reset_counter + 1;
    if (~osnotify_inmenu && reset_delay > 0) begin
      reset_delay <= reset_delay - 1;
    end

	if (bridge_wr) begin
      casex (bridge_addr)
        32'h00F00000: cs_audio_filter			<= bridge_wr_data[1:0];
        32'h00A00000: cs_fm_chip                <= bridge_wr_data[0];
        32'h00C00000: cs_cpu_turbo				<= bridge_wr_data[1:0];
        32'h00000000: cs_multitap_enable 	    <= bridge_wr_data[0];
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
            if (bridge_wr_data[31:0] > 0) reset_delay <= {reset_counter, 4'b1111};
          end
		32'h00000080: cs_m30_map_enable         <= bridge_wr_data[0];
		32'h00000090: cs_menu_pause_enable      <= bridge_wr_data[0];
        32'h00000100: lightgun_enabled          <= bridge_wr_data[0];
        32'h00000104: show_crosshair            <= bridge_wr_data[0];
        32'h00000108: dpad_aim_speed            <= bridge_wr_data[7:0];
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

reg [ 2:0] datatable_div = 0;
reg [31:0] rom_file_size = 0;

always @(posedge clk_74a or negedge pll_core_locked) begin
	if (~pll_core_locked) begin
		datatable_addr <= 0;
		datatable_data <= 0;
		datatable_wren <= 0;
	end else begin
		if (datatable_div > 4) begin
			// DEBUG DUMP: advertise the save slot as 512KB = full PRG-RAM
			datatable_wren <= 1;
			datatable_data <= 32'd524288;
			// Data slot index 1, not id 1
			datatable_addr <= 1 * 2 + 1;
		end else begin
			datatable_wren <= 0;
			// Read ROM size rest of the time
			datatable_addr <= 1;

			if (datatable_div == 4) begin
				rom_file_size <= datatable_q;
			end
		end

		datatable_div <= datatable_div + 1;
	end
end

// DEBUG DUMP: 512KB save slot sourced from PRG-RAM via SDRAM port 2.
// On exit the Pocket reads all 512KB and writes it to the .sav — a dump
// of the decompressed sub-BIOS for the M2 co-sim.
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
reg [18:1] dump_word;
reg        dump_active = 0;
reg        dump_pend = 0;
reg        dump_rd = 0;
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
		dump_word <= dump_addr_out[18:1];
		dump_pend <= 1;
	end
	if (dump_pend && !dump_active && !wr_active && !dbg_prg_active
	    && !(grant0_rd | grant0_wr | grant1_rd | grant1_wr)) begin
		dump_pend   <= 0;
		dump_active <= 1;
		dump_rd     <= 1;
	end else if (dump_active) begin
		if (dump_rd && old_busy_d && ~sdld_busy) begin
			dump_data <= sdwr_do;
			dump_rd   <= 0;
			dump_active <= 0;
		end
	end
end
assign sd_buff_din = dump_data;

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

reg current_pix_clk;
reg current_pix_clk_90;

always @(*) begin
    if(resolution == 2'b00) begin
        current_pix_clk <= clk_vid_256;
        current_pix_clk_90 <= clk_vid_256_90deg;
    end else begin
        current_pix_clk <= clk_vid_320;
        current_pix_clk_90 <= clk_vid_320_90deg;
    end
end

assign video_rgb_clock = current_pix_clk;
assign video_rgb_clock_90 = current_pix_clk_90;

assign video_de = video_de_reg;
assign video_hs = video_hs_reg;
assign video_vs = video_vs_reg;
assign video_rgb = video_rgb_reg;
assign video_skip = 0;

reg hs_prev;
reg vs_prev;

reg [9:0] dbg_x, dbg_y;
reg       dbg_de_line;

// hex readout: II 44 P2 P1 JJ (INT2 acks/s, INT4 acks/s, duties, live joypad byte)
wire [31:0] dbg_hexval = {dbg_ack2_rate, dbg_ack4_rate,
                          1'b0, dbg_pend_duty[2], 1'b0, dbg_pend_duty[1],
                          joystick_0[7:0]};
wire [31:0] dbg_hexrow = (dbg_y < 10'd42) ? dbg_hexval :
                         (dbg_y < 10'd54) ? {8'h00, dbg_m68k_smp} :
                         (dbg_y < 10'd66) ? {8'h00, dbg_s68k_smp} :
                         (dbg_y < 10'd78) ? dbg_prg_data[255:224] :
                         (dbg_y < 10'd90) ? dbg_prg_data[223:192] :
                         (dbg_y < 10'd102) ? dbg_prg_data[191:160] :
                         (dbg_y < 10'd114) ? dbg_prg_data[159:128] :
                         (dbg_y < 10'd126) ? dbg_prg_data[127:96] :
                         (dbg_y < 10'd138) ? dbg_prg_data[95:64] :
                         (dbg_y < 10'd150) ? dbg_prg_data[63:32] :
                                             dbg_prg_data[31:0];
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
        video_rgb_reg[23:16] <= (lg_target && lightgun_enabled && show_crosshair) ? {8{lg_target[0]}} : red;
        video_rgb_reg[15:8]  <= (lg_target && lightgun_enabled && show_crosshair) ? {8{lg_target[1]}} : green;
        video_rgb_reg[7:0]   <= (lg_target && lightgun_enabled && show_crosshair) ? {8{lg_target[2]}} : blue;

        // bring-up debug: 4 blocks top-left — sub-CPU alive, CDD command
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
        end else if (dbg_y >= 10'd30 && dbg_y < 10'd162) begin
            // numeric readout rows: stats / M68K addr sample / S68K addr sample
            if (dbg_x[9:4] < 6'd8) begin
                if (~dbg_x[3])
                    video_rgb_reg <= dbg_grow[2'd3 - dbg_x[2:1]] ? 24'hFFFFFF : 24'h000000;
                else
                    video_rgb_reg <= 24'h000000;
            end
        end
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
assign MCD_PRG_DI   = sdr_do;

wire [15:0] GEN_MEM_DO;
wire        GEN_MEM_BUSY /* verilator public_flat_rd */;

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
reg         p1_ram_busy /* verilator public_flat_rd */ = 0, p1_rom_busy /* verilator public_flat_rd */ = 0;
reg         p1_rd = 0, p1_wrl = 0, p1_wrh = 0;
reg  [24:1] p1_addr;
reg  [15:0] p1_din;
reg  [15:0] p1_dout /* verilator public_flat_rd */;

wire p1_ram_acc = ~GEN_RAM_CE_N & (~GEN_OE_N | ~GEN_WRL_N | ~GEN_WRH_N);
wire p1_rom_acc = ~GEN_ROM_CE_N & ~GEN_OE_N;

always @(posedge clk_sys) begin
	reg old_b1;
	old_b1 <= GEN_MEM_BUSY;
	if (~p1_ram_acc) p1_ram_hold <= 0;
	if (~p1_rom_acc) p1_rom_hold <= 0;
	if (reset | bios_download) begin
		p1_act <= 0; p1_started <= 0;
		p1_rd <= 0; p1_wrl <= 0; p1_wrh <= 0;
		p1_ram_busy <= 0; p1_rom_busy <= 0;
		p1_ram_hold <= 0; p1_rom_hold <= 0;
	end else if (!p1_act) begin
		if (p1_ram_acc & ~p1_ram_hold) begin
			p1_act  <= 1; p1_started <= 0; p1_owner <= 0;
			p1_addr <= {9'b010000000, GEN_VA[15:1]};
			p1_din  <= GEN_VDO;
			p1_rd   <= ~GEN_OE_N;
			p1_wrl  <= ~GEN_WRL_N;
			p1_wrh  <= ~GEN_WRH_N;
			p1_ram_busy <= 1;
		end else if (p1_rom_acc & ~p1_rom_hold) begin
			p1_act  <= 1; p1_started <= 0; p1_owner <= 1;
			p1_addr <= {8'b01111000, GEN_VA[16:1]};
			p1_rd   <= 1; p1_wrl <= 0; p1_wrh <= 0;
			p1_rom_busy <= 1;
		end
	end else begin
		if (GEN_MEM_BUSY) p1_started <= 1;
		if (p1_started & old_b1 & ~GEN_MEM_BUSY) begin
			p1_dout <= GEN_MEM_DO;
			if (!p1_owner) begin p1_ram_busy <= 0; p1_ram_hold <= 1; end
			else          begin p1_rom_busy <= 0; p1_rom_hold <= 1; end
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
	                        {7'b0110000, wr_owner, wr_addr}),
	.din2(bios_download ? {ioctl_data[7:0], ioctl_data[15:8]} : wr_din),
	.dout2(sdwr_do),
	.rd2(~bios_download & (dump_active ? dump_rd : dbg_prg_active ? dbg_prg_req : wr_rd_r)),
	.wrl2(bios_download ? ioctl_wait : wr_wr_r),
	.wrh2(bios_download ? ioctl_wait : wr_wr_r),
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
		wr0_rd_hold <= 0;
		wr0_wr_hold <= 0;
		wr1_rd_hold <= 0;
		wr1_wr_hold <= 0;
	end else if (!wr_active && !dbg_prg_active && !dump_active) begin
		if (grant0_rd | grant0_wr) begin
			wr_active <= 1;
			wr_owner  <= 0;
			wr_addr   <= WR0_A;
			wr_din    <= WR0_DO;
			wr_rd_r   <= grant0_rd;
			wr_wr_r   <= grant0_wr & ~grant0_rd;
			WR0_RDY   <= 0;
		end else if (grant1_rd | grant1_wr) begin
			wr_active <= 1;
			wr_owner  <= 1;
			wr_addr   <= WR1_A;
			wr_din    <= WR1_DO;
			wr_rd_r   <= grant1_rd;
			wr_wr_r   <= grant1_wr & ~grant1_rd;
			WR1_RDY   <= 0;
		end
	end else if (old_busy & ~sdld_busy) begin
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
		wr_active <= 0;
		wr_rd_r   <= 0;
		wr_wr_r   <= 0;
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
reg  [1:0] st2_ph = 0;          // 0 wait, 1 RMW pass, 2 verify pass, 3 done
reg  [2:0] st2_s0 = 0, st2_s1 = 0;
reg  [9:0] st2_idx0 = 0, st2_idx1 = 0;
reg        st2_d0 = 0, st2_d1 = 0;   // bank finished current pass
reg [15:0] st2_err = 0;
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
    cont1_key_s[4],  // B
    cont1_key_s[5],  // C
    cont1_key_s[7],  // A
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
    cont2_key_s[4],  // B
    cont2_key_s[5],  // C
    cont2_key_s[7],  // A
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
    cont3_key_s[4],  // B
    cont3_key_s[5],  // C
    cont3_key_s[7],  // A
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
    cont4_key_s[4],  // B
    cont4_key_s[5],  // C
    cont4_key_s[7],  // A
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

wire reset = ~reset_n | cart_download | region_set;

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
	.RESET_N(~reset && !reset_delay),
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

	// 3-button pad (MiSTer default): the model-2 BIOS mishandles 6-button
	// probing in the CD player (cursor won't move)
	.J3BUT(1'b1),
	// MiSTer gen.sv expects bit6=C/bit5=B; the Pocket builder packs bit6=B/bit5=C
	.JOY_1({joystick_0[11:7], joystick_0[5], joystick_0[6], joystick_0[4:0]}),
	.JOY_2({joystick_1[11:7], joystick_1[5], joystick_1[6], joystick_1[4:0]}),
	.JOY_3({joystick_2[11:7], joystick_2[5], joystick_2[6], joystick_2[4:0]}),
	.JOY_4({joystick_3[11:7], joystick_3[5], joystick_3[6], joystick_3[4:0]}),
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
	.RAM_RDY(~p1_ram_busy),
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
	old_bsy <= p1_ram_busy;
	if(old_bsy & ~p1_ram_busy) GEN_MEM_DO_R <= p1_dout;
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
wire        MCD_PRG_OE_N, MCD_PRG_WRL_N, MCD_PRG_WRH_N, MCD_PRG_BUSY;
wire [13:1] MCD_BRAM_ADDR;
wire  [7:0] MCD_BRAM_DO, MCD_BRAM_DI;
wire        MCD_BRAM_WE;
wire        MCD_RST_N;

MCD MCD
(
	// keep gen/MCD/CART reset release aligned: reset_delay applied to all
	.RST_N(~(reset | bios_download) && !reset_delay),
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

	.ROM_DI(p1_dout),
	.ROM_CE_N(GEN_ROM_CE_N),
	.ROM_RDY(~p1_rom_busy),

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

	.CDC_DATA(16'h0000),
	.CDC_DAT_WR(1'b0),
	.CDC_SC_WR(1'b0),
	.CDC_CDDA_WR(1'b0),
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
);

wire [2:0] dbg_s68k_ipl_n;
wire [6:1] dbg_int_pend, dbg_int_ack;
wire dbg_gron;

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
			dbg_gron_duty <= dbg_gron_cnt[25:23];
			dbg_gron_cnt <= 0;
			dbg_m68k_smp <= dbg_m68k_a;
			dbg_s68k_smp <= dbg_s68k_a;
		end else begin
			dbg_sec <= dbg_sec + 1'b1;
			if (dbg_s68k_a != dbg_s68k_a_d && ~&dbg_rate_cnt)
				dbg_rate_cnt <= dbg_rate_cnt + 1'b1;
			if (dbg_s68k_ipl_n != 3'b111)
				dbg_ipl_cnt <= dbg_ipl_cnt + 1'b1;
			for (di = 1; di < 7; di = di + 1)
				if (dbg_int_pend[di]) dbg_pend_cnt[di] <= dbg_pend_cnt[di] + 1'b1;
			if (dbg_int_ack[2] & ~dbg_ack_d[2] & ~&dbg_ack2_cnt) dbg_ack2_cnt <= dbg_ack2_cnt + 1'b1;
			if (dbg_int_ack[4] & ~dbg_ack_d[4] & ~&dbg_ack4_cnt) dbg_ack4_cnt <= dbg_ack4_cnt + 1'b1;
			if (dbg_gron) dbg_gron_cnt <= dbg_gron_cnt + 1'b1;
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
reg [25:0] dbg_gron_cnt = 0;
reg [2:0]  dbg_gron_duty = 0;    // GFX op in-flight duty (/8)
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
wire [39:0] cdd_stat, cdd_comm;
wire        cdd_send, cdd_rec, cdd_dm;
megacd_cdd_stub cdd_stub
(
	.clk(clk_sys),
	.reset(reset),
	.mcd_rst_n(MCD_RST_N),
	.cdd_comm(cdd_comm),
	.cdd_send(cdd_send),
	.cdd_stat(cdd_stat),
	.cdd_rec(cdd_rec),
	.cdd_dm(cdd_dm)
);

///////////////////////////////////////////////
// Cart slot: empty (MegaCD boot mode)
///////////////////////////////////////////////

wire [15:0] CART_DO;
wire        CART_DTACK_N, CART_CART_N;
wire        CART_ROM_CE_N, CART_RAM_CE_N;

CART CART
(
	.RST_N(~(reset | bios_download) && !reset_delay),
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
// sd_buff_din is driven by the PRG-RAM dump reader (debug), not backup RAM

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