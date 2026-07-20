// Full-system co-sim: boots the entire MegaCD core (main+sub 68000, VDP,
// Z80, FM/PSG, MCD) with the BIOS preloaded into the sim SDRAM (+bios=).
// Releases the core from reset via the APF "Reset Exit" bridge command,
// then runs so the CD-player freeze can be observed with the real main
// CPU driving the sub.
#include "Vcore_top.h"
#include "Vcore_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
static vluint64_t t=0; double sc_time_stamp(){return t;}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    long maxc = 40000000;
    for(int i=1;i<argc;i++) if(!strcmp(argv[i],"--cycles")&&i+1<argc) maxc=atol(argv[++i]);

    Vcore_top* dut = new Vcore_top;
    dut->clk_74a=0; dut->clk_74b=0;
    dut->bridge_addr=0; dut->bridge_rd=0; dut->bridge_wr=0; dut->bridge_wr_data=0;
    dut->bridge_endian_little=0;
    dut->cont1_key=0; dut->cont2_key=0; dut->cont3_key=0; dut->cont4_key=0;
    dut->cont1_joy=0; dut->cont2_joy=0; dut->cont3_joy=0; dut->cont4_joy=0;
    dut->cont1_trig=0; dut->cont2_trig=0; dut->cont3_trig=0; dut->cont4_trig=0;
    dut->vblank=0; dut->port_ir_rx=0; dut->port_tran_si=0; dut->port_tran_so=0;
    dut->port_tran_sck=0; dut->port_tran_sd=0; dut->dbg_rx=0; dut->user2=0;

    bool did_reset_exit=false;
    for(long c=0;c<maxc;c++){
        dut->clk_74a = !dut->clk_74a;
        // once PLL is locked + SDRAM preloaded, APF "Reset Exit" -> reset_n=1
        if(!did_reset_exit && c==4000){
            dut->bridge_addr = 0xF8000000;
            dut->bridge_wr_data = 0x434D0011; // 'CM' + Reset Exit
            dut->bridge_wr = 1;
        } else if(!did_reset_exit && c==4010){
            dut->bridge_wr = 0; did_reset_exit=true;
            printf("[%ld] sent Reset Exit\n", c);
        }
        dut->eval(); t++;

        uint32_t mpc = dut->rootp->core_top__DOT__dbg_m68k_a & 0xFFFFFF;
        uint32_t spc = dut->rootp->core_top__DOT__dbg_s68k_a & 0xFFFFFF;
        static uint32_t mlo=0xFFFFFF, mhi=0; static long win=0;
        if(mpc<mlo)mlo=mpc; if(mpc>mhi)mhi=mpc;
        if((c%1000000)==0){
            printf("[%ld] main=%06X sub=%06X  (main range last win: %06X..%06X)\n", c, mpc, spc, mlo,mhi);
            mlo=0xFFFFFF; mhi=0;
        }
    }
    dut->final(); delete dut;
    printf("done\n");
    return 0;
}
