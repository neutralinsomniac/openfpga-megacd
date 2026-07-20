// Behavioral PLL for the full-system co-sim. The testbench drives outclk_0
// (clk_sys, 53.69MHz) and outclk_1 (clk_ram, 107.4MHz = 2x) directly on
// `refclk` — here we just pass clk_sys through and derive clk_ram by using
// refclk as the fast clock. In the sim the tb drives refclk at clk_ram rate
// and we divide for clk_sys; the video clocks are unused by the MCD path.
module mf_pllbase (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,  // clk_sys
    output wire outclk_1,  // clk_ram (== refclk here)
    output wire outclk_2,
    output wire outclk_3,
    output wire outclk_4,
    output wire outclk_5,
    output reg  locked
);
    // refclk is driven at clk_ram rate (2x clk_sys) by the tb.
    reg div=0;
    always @(posedge refclk) div <= ~div;
    assign outclk_1 = refclk;   // clk_ram
    assign outclk_0 = div;      // clk_sys = refclk/2
    assign outclk_2 = div;
    assign outclk_3 = div;
    assign outclk_4 = div;
    assign outclk_5 = div;
    initial locked = 0;
    always @(posedge refclk) if (!rst) locked <= 1;
endmodule
