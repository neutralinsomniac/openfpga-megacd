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
        auto* r = dut->rootp;
        // ring buffer of last distinct main address-bus values (execution trail)
        static uint32_t trail[32]; static int ti=0; static uint32_t tlast=0xFFFFFFFF;
        if(mpc!=tlast){ trail[ti&31]=mpc; ti++; tlast=mpc; }
        static uint32_t last=0xFFFFFFFF; static long stuck=0;
        static int vint_prev=0; static long vint_cnt=0, cepix_cnt=0, vbl_cnt=0;
        static int cepix_prev=0, vbl_prev=0;
        int vint = r->core_top__DOT__gen__DOT__M68K_VINT;
        int cepix = r->core_top__DOT__ce_pix;
        int vbl = r->core_top__DOT__vblank_sys;
        if(vint && !vint_prev) vint_cnt++;
        if(cepix && !cepix_prev) cepix_cnt++;
        if(vbl && !vbl_prev) vbl_cnt++;
        vint_prev=vint; cepix_prev=cepix; vbl_prev=vbl;
        if(mpc==last) stuck++; else { stuck=0; last=mpc; }
        if(stuck==500000){
            printf("[%ld] main STUCK at %06X: mstate=%X dtack_n=%d "
                   "VINT_now=%d VINT=%ld CE_PIX=%ld VBL=%ld IE0=%d PENDING=%d\n", c, mpc,
                   r->core_top__DOT__gen__DOT__mstate,
                   r->core_top__DOT__gen__DOT__M68K_MBUS_DTACK_N,
                   vint, vint_cnt, cepix_cnt, vbl_cnt,
                   r->core_top__DOT__gen__DOT__vdp__DOT__ie0,
                   r->core_top__DOT__gen__DOT__vdp__DOT__vint_tg68_pending);
            printf("  VDP DMA: in_dma=%d fill=%d vbus=%d copy=%d\n",
                   r->core_top__DOT__gen__DOT__vdp__DOT__in_dma,
                   r->core_top__DOT__gen__DOT__vdp__DOT__dma_fill,
                   r->core_top__DOT__gen__DOT__vdp__DOT__dma_vbus,
                   r->core_top__DOT__gen__DOT__vdp__DOT__dma_copy);
            printf("  exec trail (last distinct main addrs): ");
            for(int k=0;k<32;k++){ int idx=(ti-32+k); if(idx>=0) printf("%06X ", trail[idx&31]); }
            printf("\n");
        }
        if((c%2000000)==0) printf("[%ld] main=%06X sub=%06X VINT=%ld VBL=%ld  in_dma=%d fill=%d vbus=%d copy=%d\n",
                                  c, mpc, spc, vint_cnt, vbl_cnt,
                                  r->core_top__DOT__gen__DOT__vdp__DOT__in_dma,
                                  r->core_top__DOT__gen__DOT__vdp__DOT__dma_fill,
                                  r->core_top__DOT__gen__DOT__vdp__DOT__dma_vbus,
                                  r->core_top__DOT__gen__DOT__vdp__DOT__dma_copy);
        static long slot_edges=0; static int se_prev=0;
        { int se=r->core_top__DOT__gen__DOT__vdp__DOT__slot_en; if(se&&!se_prev)slot_edges++; se_prev=se; }
        static long fe_edges=0; static int fe_prev=0;
        { int fe=r->core_top__DOT__gen__DOT__vdp__DOT__fifo_en; if(fe&&!fe_prev)fe_edges++; fe_prev=fe; }
        if((c%2000000)==0){
            printf("      dmac=%d slot_en=%d dt_vram_sel=%d\n",
                   r->core_top__DOT__gen__DOT__vdp__DOT__dmac,
                   r->core_top__DOT__gen__DOT__vdp__DOT__slot_en,
                   r->core_top__DOT__gen__DOT__vdp__DOT__dt_vram_sel);
            printf("      slot_en_edges=%ld fifo_empty=%d dmaf_set_req=%d\n", slot_edges,
                   r->core_top__DOT__gen__DOT__vdp__DOT__fifo_empty,
                   r->core_top__DOT__gen__DOT__vdp__DOT__dmaf_set_req);
            printf("      dtc=%d fifo_queue=? (dtc: 0=IDLE 1=FIFO_RD 2=VRAM_WR1 3=VRAM_WR2 7=VRAM_RD1 8=VRAM_RD2)\n",
                   r->core_top__DOT__gen__DOT__vdp__DOT__dtc);
            printf("      fifo_queue=%d fifo_partial=%d fifo_en_edges=%ld\n",
                   r->core_top__DOT__gen__DOT__vdp__DOT__fifo_queue,
                   r->core_top__DOT__gen__DOT__vdp__DOT__fifo_partial,
                   fe_edges);
            int fd = r->core_top__DOT__gen__DOT__vdp__DOT__fifo_delay;
            printf("      fifo_delay={%d,%d,%d,%d} rd_pos=%d wr_pos=%d refresh_flag=%d\n",
                   fd&3,(fd>>2)&3,(fd>>4)&3,(fd>>6)&3,
                   r->core_top__DOT__gen__DOT__vdp__DOT__fifo_rd_pos,
                   r->core_top__DOT__gen__DOT__vdp__DOT__fifo_wr_pos,
                   r->core_top__DOT__gen__DOT__vdp__DOT__refresh_flag);
        }
    }
    // dump work-RAM code around the STOP site $FF00F0.. (SDRAM word $400078..)
    printf("work-RAM $FF00F0..$FF0120:\n");
    for(uint32_t w=0x400078; w<0x400091; w++)
        printf("%04X ", dut->rootp->core_top__DOT__sdram__DOT__mem[w] & 0xFFFF);
    printf("\n");
    dut->final(); delete dut;
    printf("done\n");
    return 0;
}
