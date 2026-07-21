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
        // scripted controller input (cont1_key active-high):
        // START (bit15) after the intro starts -> should skip to the player
        // screen; d-pad RIGHT (bit3) twice later -> cursor must move.
        {
            uint16_t k=0;
            if(c>=750000000 && c<775000000) k |= 1u<<15;   // START (title up ~frame 200)
            if(c>=1150000000 && c<1165000000) k |= 1u<<3;  // RIGHT on player screen
            if(c>=1230000000 && c<1245000000) k |= 1u<<1;  // DOWN too
            if(c>=1400000000 && c<1415000000) k |= 1u<<3;  // RIGHT (post-auto-open)
            dut->cont1_key = k;
        }
        dut->eval(); t++;

        // ---- video frame capture (PPM dumps), all in clk_sys domain ----
        {
            static const uint8_t lut[16]={0,27,49,71,87,103,119,130,146,157,174,190,206,228,255,255};
            static int vclk_prev=0, vb_prev=0, hb_prev=0;
            static int fx=0, fy=0, maxx=0, maxy=0; static long frame=0;
            static uint8_t fb[300][512][3];
            int vclk = dut->rootp->core_top__DOT__ce_pix;
            if(vclk && !vclk_prev){
                int vb=dut->rootp->core_top__DOT__vblank_sys;
                int hb=dut->rootp->core_top__DOT__hblank;
                if(vb && !vb_prev){
                    bool press_win = (c>=1140000000 && c<1200000000) ||
                                     (c>=1220000000 && c<1280000000) ||
                                     (c>=1390000000 && c<1450000000);
                    static long fevery = getenv("FRAME_EVERY")?atol(getenv("FRAME_EVERY")):100;
                    static long fw0=-1, fw1=-1;
                    { static bool fwi=false; if(!fwi){ fwi=true; const char* e=getenv("FRAMEWIN");
                      if(e) sscanf(e,"%ld,%ld",&fw0,&fw1); } }
                    if(fw0>=0 && c>=fw0 && c<fw1) press_win = true;
                    if(frame>0 && maxx>0 && ((frame%fevery)==0 || press_win)){
                        char fn[64]; snprintf(fn,sizeof fn,"frames/f%05ld.ppm",frame);
                        FILE*fp=fopen(fn,"wb");
                        if(fp){ fprintf(fp,"P6\n%d %d\n255\n",maxx,maxy);
                            for(int y=0;y<maxy;y++) fwrite(fb[y],1,(size_t)maxx*3,fp);
                            fclose(fp);
                            printf("[%ld] wrote %s (%dx%d)\n",c,fn,maxx,maxy);
                        }
                    }
                    frame++; fy=0; fx=0; maxx=0; maxy=0;
                }
                if(hb && !hb_prev){ if(fx>maxx)maxx=fx; if(fx>0)fy++; if(fy>maxy)maxy=fy; fx=0; }
                if(!hb && !vb && fy<300 && fx<512){
                    fb[fy][fx][0]=lut[dut->rootp->core_top__DOT__r & 15];
                    fb[fy][fx][1]=lut[dut->rootp->core_top__DOT__g & 15];
                    fb[fy][fx][2]=lut[dut->rootp->core_top__DOT__b & 15];
                    fx++;
                }
                vb_prev=vb; hb_prev=hb;
            }
            vclk_prev=vclk;
        }

        uint32_t mpc = dut->rootp->core_top__DOT__dbg_m68k_a & 0xFFFFFF;
        uint32_t spc = dut->rootp->core_top__DOT__dbg_s68k_a & 0xFFFFFF;
        auto* r = dut->rootp;
        // ring buffer of last distinct main address-bus values (execution trail)
        static uint32_t trail[32]; static int ti=0; static uint32_t tlast=0xFFFFFFFF;
        if(mpc!=tlast){ trail[ti&31]=mpc; ti++; tlast=mpc;
            static bool exc_seen=false;
            if(!exc_seen && c>1000000 && mpc>=0x000008 && mpc<=0x0000FF){ exc_seen=true;
                printf("[%ld] MAIN EXCEPTION VECTOR FETCH (%06X)! trail: ",c,mpc);
                for(int k=0;k<32;k++){ int idx=(ti-32+k); if(idx>=0) printf("%06X ", trail[idx&31]); }
                printf("\n");
            }
        }
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
        { static bool gw_on = getenv("GATEWATCH")!=nullptr;
          static uint32_t gw_prev=0;
          if(gw_on && mpc!=gw_prev && c>1140000000 && c<1160000000){
            switch(mpc){
              case 0x32DC: case 0x32EE: case 0x32F8: case 0x3300: case 0x3306:
              case 0x331A: case 0x331E: case 0x3342: case 0x3448: case 0x3470:
              case 0x3654: case 0x3710: case 0x3A46: case 0x3A40: case 0x3ABC:
              case 0x3AE4: case 0x34DA: case 0x34A2: case 0x4054: case 0x3BD8:
              case 0x35CA: case 0x34F2:
                printf("GW %ld pc=%04X\n", c, mpc); break;
              default: break;
            }
            gw_prev=mpc;
          } }
        { static int sd_prev=0; static unsigned long long lastcomm=~0ULL;
          int sd_now = r->core_top__DOT__cdd_send;
          if(sd_now && !sd_prev){
            unsigned long long cm = r->core_top__DOT__cdd_comm;
            if(cm!=lastcomm){ printf("CDDCMD [%ld] %010llX\n", c, cm); lastcomm=cm; }
          }
          sd_prev=sd_now; }
        static long padvar_rd=0, padport_rd=0;
        { static uint32_t pv=0; if(mpc!=pv){ if(mpc==0xFFFE20||mpc==0xFFFE21) padvar_rd++;
          if(mpc==0xA10003) padport_rd++; pv=mpc; } }
        if((c%50000000)==0 && c) printf("PADCNT [%ld] padvar=%ld padport=%ld\n",c,padvar_rd,padport_rd);
        static bool sub_started=false;
        if(!sub_started && spc!=0){ sub_started=true; printf("[%ld] SUB RELEASED: first sub addr=%06X\n",c,spc); }
        static uint32_t sub_last=0; static long sub_stuck=0;
        if(spc==sub_last) sub_stuck++; else { sub_stuck=0; sub_last=spc; }
        if(sub_stuck==2000000){ printf("[%ld] sub parked at %06X (main=%06X)\n",c,spc,mpc); }
        // word-RAM arbiter wedge watch (hardware red block = dbg_wr_stuck)
        static int wrstuck_prev=0;
        int wrstuck = r->core_top__DOT__dbg_wr_stuck;
        if(wrstuck && !wrstuck_prev){
            printf("[%ld] *** WR_STUCK LATCHED: req(rd0,wr0,rd1,wr1)=%d%d%d%d "
                   "rdy(0,1)=%d%d act=%d hold(r0,w0,r1,w1)=%d%d%d%d dtack_stuck=%d main=%06X sub=%06X\n",
                   c,
                   r->core_top__DOT__WR0_RD, r->core_top__DOT__WR0_WR,
                   r->core_top__DOT__WR1_RD, r->core_top__DOT__WR1_WR,
                   r->core_top__DOT__WR0_RDY, r->core_top__DOT__WR1_RDY,
                   r->core_top__DOT__wr_active,
                   r->core_top__DOT__wr0_rd_hold, r->core_top__DOT__wr0_wr_hold,
                   r->core_top__DOT__wr1_rd_hold, r->core_top__DOT__wr1_wr_hold,
                   r->core_top__DOT__dbg_dtack_stuck, mpc, spc);
        }
        wrstuck_prev=wrstuck;
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
        static long tw0=-1, tw1=-1;
        { static bool twinit=false;
          if(!twinit){ twinit=true; const char* e=getenv("TRACEWIN");
            if(e){ sscanf(e,"%ld,%ld",&tw0,&tw1); } } }
        if(tw0>=0 && c>=tw0 && c<tw1 && (c%2)==0){
            printf("TW %ld m=%06X st=%X dt=%d ce(ram,rom)=%d%d oe=%d wr=%d%d p1(a,o,rb,ob)=%d%d%d%d busy1=%d dout=%04X\n",
                c, mpc, r->core_top__DOT__gen__DOT__mstate,
                r->core_top__DOT__gen__DOT__M68K_MBUS_DTACK_N,
                r->core_top__DOT__GEN_RAM_CE_N, r->core_top__DOT__GEN_ROM_CE_N,
                r->core_top__DOT__GEN_OE_N,
                r->core_top__DOT__GEN_WRL_N, r->core_top__DOT__GEN_WRH_N,
                r->core_top__DOT__p1_act, r->core_top__DOT__p1_owner,
                r->core_top__DOT__p1_ram_busy, r->core_top__DOT__p1_rom_busy,
                r->core_top__DOT__GEN_MEM_BUSY, r->core_top__DOT__p1_dout);
        }
#ifndef REALSD
        { static bool ssinit=false; static long ss0=-1;
          if(!ssinit){ ssinit=true; const char* e=getenv("SUBSTATE"); if(e) ss0=atol(e); }
          if(ss0>=0 && c>=ss0 && (c%100000)==0){
            unsigned mw = r->core_top__DOT__sdram__DOT__mem[0x80419E];
            unsigned ab = r->core_top__DOT__sdram__DOT__mem[0x80419F];
            unsigned sx = r->core_top__DOT__sdram__DOT__mem[0x8041A1];
            unsigned pad = r->core_top__DOT__sdram__DOT__mem[0x407F10];
            unsigned s44 = r->core_top__DOT__sdram__DOT__mem[0x8041C0];
            unsigned s58 = r->core_top__DOT__sdram__DOT__mem[0x8041CA];
            unsigned d008 = r->core_top__DOT__sdram__DOT__mem[0x406804];
            unsigned d060 = r->core_top__DOT__sdram__DOT__mem[0x406830];
            unsigned d002 = r->core_top__DOT__sdram__DOT__mem[0x406801];
            unsigned d024 = r->core_top__DOT__sdram__DOT__mem[0x406812];
            unsigned fddc = r->core_top__DOT__sdram__DOT__mem[0x407EEE];
            unsigned fdf0 = r->core_top__DOT__sdram__DOT__mem[0x407EF8];
            unsigned fdf2 = r->core_top__DOT__sdram__DOT__mem[0x407EF9];
            printf("SS %ld m=%06X s=%06X mode=%04X pad=%04X st44=%04X st58=%02X D008=%02X sub24=%04X FDDC=%02X FDF0=%04X FDF2=%04X\n",
                   c, mpc, spc, mw, pad, s44, (s58>>8)&0xFF,
                   (d008>>8)&0xFF, d024, (fddc>>8)&0xFF, fdf0, fdf2);
          } }
#endif
        if((c%2000000)==0) printf("[%ld] main=%06X sub=%06X VINT=%ld VBL=%ld  in_dma=%d fill=%d vbus=%d copy=%d\n",
                                  c, mpc, spc, vint_cnt, vbl_cnt,
                                  r->core_top__DOT__gen__DOT__vdp__DOT__in_dma,
                                  r->core_top__DOT__gen__DOT__vdp__DOT__dma_fill,
                                  r->core_top__DOT__gen__DOT__vdp__DOT__dma_vbus,
                                  r->core_top__DOT__gen__DOT__vdp__DOT__dma_copy);
        static long slot_edges=0; static int se_prev=0;
        { int se=r->core_top__DOT__gen__DOT__vdp__DOT__slot_en; if(se&&!se_prev)slot_edges++; se_prev=se; }
        static long wr_acc=0, prg_acc=0;
        { static int w_prev=0, p_prev=0;
          int w = r->core_top__DOT__WR0_RD | r->core_top__DOT__WR0_WR |
                  r->core_top__DOT__WR1_RD | r->core_top__DOT__WR1_WR;
          int p = !r->core_top__DOT__MCD_PRG_OE_N;
          if(w && !w_prev) wr_acc++;
          if(p && !p_prev) prg_acc++;
          w_prev=w; p_prev=p; }
        if((c%2000000)==0 && c){ printf("TRAF [%ld] wram_acc=%ld prg_rd=%ld\n",c,wr_acc,prg_acc); wr_acc=0; prg_acc=0; }
        // WR0 request lifecycle: req rise -> grant (RDY fall) -> done (RDY
        // rise) -> req fall -> next req rise
        { static int rq_p=0, rdy_p=1; static long t_rise=0, t_grant=0, t_done=0, t_fall=0;
          static long s_wait=0, s_serv=0, s_drop=0, s_gap=0, n_cyc=0;
          int rq = r->core_top__DOT__WR0_RD | r->core_top__DOT__WR0_WR;
          int rdy = r->core_top__DOT__WR0_RDY;
          if(rq && !rq_p){ if(t_fall) s_gap += c-t_fall; t_rise=c; }
          if(!rdy && rdy_p && rq){ t_grant=c; s_wait += c-t_rise; }
          if(rdy && !rdy_p && rq){ t_done=c; s_serv += c-t_grant; }
          if(!rq && rq_p){ t_fall=c; s_drop += c-t_done; n_cyc++; }
          rq_p=rq; rdy_p=rdy;
          static int prq_p=0, pb_p=0; static long p_rise=0, p_busy=0, p_fall=0;
          static long p_wait=0, p_serv=0, p_gap=0, p_n=0;
          int prq = !r->core_top__DOT__MCD_PRG_OE_N;
          int pb  = r->core_top__DOT__dbg_prg_busy;
          if(prq && !prq_p){ if(p_fall) p_gap += c-p_fall; p_rise=c; }
          if(pb && !pb_p && prq){ p_busy=c; p_wait += c-p_rise; }
          if(!pb && pb_p && prq){ p_serv += c-p_busy; }
          if(!prq && prq_p){ p_fall=c; p_n++; }
          prq_p=prq; pb_p=pb;
          static int vb_p=0; static long vb_start=0, vb_sum=0, vb_n=0, vb_max=0;
          { int vb = r->core_top__DOT__gen__DOT__vdp__DOT__dma_vbus;
            if(vb && !vb_p) vb_start=c;
            if(!vb && vb_p){ long d=c-vb_start; vb_sum+=d; vb_n++; if(d>vb_max)vb_max=d; }
            vb_p=vb; }
          static int g1_p=0; static long g1_rise=0, g1_serv=0, g1_gap=0, g1_fall=0, g1_n=0;
          { int g1 = r->core_top__DOT__p1_act;
            if(g1 && !g1_p){ if(g1_fall) g1_gap += c-g1_fall; g1_rise=c; }
            if(!g1 && g1_p){ g1_fall=c; g1_serv += c-g1_rise; g1_n++; }
            g1_p=g1; }
          if((c%2000000)==0 && c){
            if(vb_n) printf("VBUS [%ld] n=%ld avg=%.0f max=%ld\n",c,vb_n,(double)vb_sum/vb_n,vb_max);
            if(g1_n) printf("P1 [%ld] n=%ld serv=%.1f gap=%.1f\n",c,g1_n,(double)g1_serv/g1_n,(double)g1_gap/g1_n);
            vb_sum=0; vb_n=0; vb_max=0; g1_serv=0; g1_gap=0; g1_n=0; }
          static int r0_p=0,r1_p=0,d0_p=0,d1_p=0; static long swp[4]={0,0,0,0};
          { int r0=r->core_top__DOT__MCD__DOT__asic__DOT__ret0, r1=r->core_top__DOT__MCD__DOT__asic__DOT__ret1;
            int d0=r->core_top__DOT__MCD__DOT__asic__DOT__dmna0, d1=r->core_top__DOT__MCD__DOT__asic__DOT__dmna1;
            if(r0!=r0_p) swp[0]++; if(r1!=r1_p) swp[1]++;
            if(d0!=d0_p) swp[2]++; if(d1!=d1_p) swp[3]++;
            r0_p=r0; r1_p=r1; d0_p=d0; d1_p=d1; }
          if((c%2000000)==0 && c){
            printf("SWAP [%ld] ret0=%ld ret1=%ld dmna0=%ld dmna1=%ld\n",c,swp[0],swp[1],swp[2],swp[3]);
            swp[0]=swp[1]=swp[2]=swp[3]=0; }
          static long mshist[16]={0};
          mshist[r->core_top__DOT__gen__DOT__mstate & 15]++;
          if((c%2000000)==0 && c){
            printf("MST [%ld]",c);
            for(int i=0;i<16;i++){ if(mshist[i]) printf(" %d:%ld",i,mshist[i]); mshist[i]=0; }
            printf("\n"); }
          if((c%2000000)==0 && c && p_n){
            printf("PLIFE [%ld] n=%ld wait=%.1f serv=%.1f gap=%.1f\n",
                   c, p_n, (double)p_wait/p_n, (double)p_serv/p_n, (double)p_gap/p_n);
            p_wait=p_serv=p_gap=0; p_n=0; }
          if((c%2000000)==0 && c && n_cyc){
            printf("LIFE [%ld] n=%ld wait=%.1f serv=%.1f drop=%.1f gap=%.1f (iters)\n",
                   c, n_cyc, (double)s_wait/n_cyc, (double)s_serv/n_cyc,
                   (double)s_drop/n_cyc, (double)s_gap/n_cyc);
            s_wait=s_serv=s_drop=s_gap=0; n_cyc=0; }
        }
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
#ifdef REALSD
    printf("work-RAM $FF00F0..$FF0120 (chip model):\n");
    for(uint32_t w=0x400078; w<0x400091; w++)
        printf("%04X ", dut->rootp->core_top__DOT__sdram__DOT__chip__DOT__mem[w] & 0xFFFF);
#else
    printf("work-RAM $FF00F0..$FF0120:\n");
    for(uint32_t w=0x400078; w<0x400091; w++)
        printf("%04X ", dut->rootp->core_top__DOT__sdram__DOT__mem[w] & 0xFFFF);
#endif
    printf("\n");
    dut->final(); delete dut;
    printf("done\n");
    return 0;
}
