// M2 co-simulation testbench: the MegaCD subsystem (real fx68k sub-CPU +
// ASIC + CDC + PCM + CDDA) with C++ memory models and a C++ CDD stub, so
// the CD-drive protocol can be observed and iterated in seconds.
//
// PRG-RAM is preloaded from a hardware dump of the decompressed sub-BIOS
// (--prg <file>) since it is compressed in the ROM image. ROM (BIOS) is
// loaded from the raw BIOS (--rom <file>). The EXT (main-CPU) side is
// driven by a scripted gate-array bring-up sequence.

#include "VMCD.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>

static VMCD* dut;
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

// ---- external memories ----
static std::vector<uint8_t> prg(512*1024, 0);   // sub PRG-RAM, byte array
static std::vector<uint8_t> rom(128*1024, 0);   // CD BIOS ROM
static std::vector<uint8_t> wram0(128*1024,0);  // word RAM bank 0
static std::vector<uint8_t> wram1(128*1024,0);  // word RAM bank 1
static std::vector<uint8_t> bram(8*1024, 0);    // backup RAM

static int MEM_LAT = 12; // SDRAM-ish latency, cycles (--memlat)

// generic latency handshake state
struct MemPort {
    int busy = 0; bool active = false; uint16_t rdata = 0;
};

static uint16_t rdw(std::vector<uint8_t>& m, uint32_t byte) {
    if (byte+1 >= m.size()) return 0xFFFF;
    return (m[byte] << 8) | m[byte+1];
}
static void wrw(std::vector<uint8_t>& m, uint32_t byte, uint16_t v, bool hi, bool lo) {
    if (byte+1 >= m.size()) return;
    if (hi) m[byte] = v >> 8;
    if (lo) m[byte+1] = v & 0xFF;
}

// ---- C++ CDD stub (empty drive), faithful to megacdd.cpp no-disc paths ----
struct Cdd {
    int status = 0;          // 0=STOP
    int latency = 10;
    uint8_t n[9] = {0};
    int beat = 0;
    bool rec = false; int reccnt = 0;
    int ms = 0;
    int lastN1 = 0;
    void reset() { status=0; latency=10; memset(n,0,9); n[0]=0; beat=0; rec=false; reccnt=0; ms=0; }
    uint64_t pack() {
        int cs = (~(n[0]+n[1]+n[2]+n[3]+n[4]+n[5]+n[6]+n[7]+n[8])) & 0xF;
        uint64_t s=0; for(int i=0;i<9;i++) s |= (uint64_t)(n[i]&0xF) << (i*4);
        s |= (uint64_t)cs << 36; return s;
    }
    // Empty drive, GPGX cdd.c no-disc model: status drains STOP->NO_DISC(B)
    // and STAYS there. ReadTOC must NOT flip to TOC(9) or fabricate TOC
    // entries — a fake TOC makes the front end believe a disc is present and
    // command play (mode 8) -> the $7302 subcode-wait freeze.
    void command(uint64_t comm) {
        int c0 = comm & 0xF, fmt = (comm>>12)&0xF;
        if (c0==1) { latency=0; status=0xB; n[0]=status; memset(n+1,0,8); } // STOP
        else if (c0==2) { n[0]=status; n[1]=fmt; memset(n+2,0,7); }        // ReadTOC: no data
        else { n[0]=status; }
    }
};
static Cdd cdd;

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* prgf=nullptr; const char* romf=nullptr;
    long maxc = 5000000; bool trace_pc = true;
    long cddphase=0, int2phase=0; int memlat=12; bool inject=true; int injmode=8;
    for (int i=1;i<argc;i++){
        if(!strcmp(argv[i],"--prg")&&i+1<argc) prgf=argv[++i];
        else if(!strcmp(argv[i],"--rom")&&i+1<argc) romf=argv[++i];
        else if(!strcmp(argv[i],"--cycles")&&i+1<argc) maxc=atol(argv[++i]);
        else if(!strcmp(argv[i],"--cddphase")&&i+1<argc) cddphase=atol(argv[++i]);
        else if(!strcmp(argv[i],"--int2phase")&&i+1<argc) int2phase=atol(argv[++i]);
        else if(!strcmp(argv[i],"--memlat")&&i+1<argc) memlat=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--noinject")) inject=false;
        else if(!strcmp(argv[i],"--mode")&&i+1<argc) injmode=atoi(argv[++i]);
    }
    if (romf){ FILE*f=fopen(romf,"rb"); if(f){fread(rom.data(),1,rom.size(),f);fclose(f);printf("loaded ROM %s\n",romf);} }
    if (prgf){ FILE*f=fopen(prgf,"rb"); if(f){fread(prg.data(),1,prg.size(),f);fclose(f);printf("loaded PRG %s\n",prgf);} }

    MEM_LAT = memlat;
    cdd.beat = (int)cddphase;
    dut = new VMCD;
    dut->CLK=0; dut->RST_N=0; dut->ENABLE=1; dut->PALSW=0;
    dut->PRG_RDY=1; dut->ROM_RDY=1; dut->WORDRAM0_RDY=1; dut->WORDRAM1_RDY=1;
    dut->EXT_AS_N=1; dut->EXT_RNW=1; dut->EXT_LDS_N=1; dut->EXT_UDS_N=1;
    dut->EXT_ASEL_N=1; dut->EXT_RAS2_N=1; dut->EXT_ROM_N=1; dut->EXT_FDC_N=1;
    dut->CDD_REC=0; dut->CDD_DM=0; dut->CDC_DATA=0; dut->CDC_DAT_WR=0;
    dut->CDC_SC_WR=0; dut->CDC_CDDA_WR=0; dut->GG_EN=0; dut->GG_RESET=0;

    MemPort prgp, romp, w0, w1;
    uint32_t last_pc=0xFFFFFFFF; int idlepc=0;
    int vclk=0;

    // EXT-bus gate-array writer (emulating the main CPU). A scripted queue of
    // register writes: {reg_offset (word), value}. reg 0=$A12000, 7=$A1200E
    // (comm flag), 8..15=$A12010.. (comm command CC0..7).
    struct Wr { uint32_t at; int off; uint16_t val; bool rd=false; };
    std::vector<Wr> script = {
        {2000, 0, 0x0001},   // SRES=1: release the sub
    };
    // main->sub command injection: write CC0..7 then raise the comm flag.
    // Decoded protocol ($6296/$71E6/$6142 disasm): CC2 word = action code
    // (1 = set mode via $6142, param in CC3; 2 = set replay flag $BFC),
    // CC0:CC1 long = track/position arg latched to $2E(a6). Mode 8 makes the
    // sub main loop ($610A, table $6118) jump to $7302 = drive-read retry
    // loop -> the freeze. CC0 hi-byte codes (old sweep) were the wrong slot.
    long INJ = 3500000;
    if (inject) {
        for (int i=0;i<8;i++) script.push_back({INJ + i*400, 8+i, 0x0000});
        long t = INJ + 10000;
        script.push_back({t,       8, 0x0001});  // CC0 = track 1 arg
        script.push_back({t+400,  10, 0x0001});  // CC2 = action 1: set mode
        script.push_back({t+800,  11, (uint16_t)injmode});  // CC3 = player mode (--mode)
        script.push_back({t+2000,  7, 0x0400});  // raise CFM bit2
        script.push_back({t+1200000,7,0x0000});  // lower after >1 INT2 frame
        if (getenv("ABORT7")) {
            script.push_back({9000000, 7, 0x8000});
            // read back $A1200E (CFM|CFS) while abort held: sub ack = CFS bit7
            script.push_back({9500000, 7, 0, true});
            script.push_back({9700000, 7, 0, true});
            script.push_back({11000000,7, 0x0000});
            script.push_back({11500000,7, 0, true});
        }
    }

    size_t sp=0;
    enum { EXT_IDLE, EXT_DRIVE } ext_st = EXT_IDLE;
    long ext_wait=0; uint16_t ext_val=0; int ext_off=0; bool sres_done=false, ext_rd=false;
    const long FRAME = 895000;
    bool seen_cmd=false, seen_616a=false;
    bool seen_726e=false, seen_7302=false, seen_7350=false;
    long loop_iters=0, q_checks=0;
    long busyres=0, wedge_at=0; bool wedged=false;

    for (long c=0; c<maxc; c++) {
        if (c==20) dut->RST_N=1;

        if (ext_st==EXT_IDLE) {
            bool go=false;
            // scripted writes
            if (sp<script.size() && (long)script[sp].at<=c) {
                ext_off=script[sp].off; ext_val=script[sp].val; ext_rd=script[sp].rd; sp++; go=true;
                if (!ext_rd && ext_off==0 && ext_val==1) sres_done=true;
            }
            // periodic INT2 heartbeat (IFL2|SRES) once released
            else if (sres_done && ((c+int2phase) % FRAME)==0) { ext_off=0; ext_val=0x0101; go=true; }
            if (go) {
                dut->EXT_FDC_N=0; dut->EXT_ASEL_N=0; dut->EXT_RNW=ext_rd?1:0;
                dut->EXT_LDS_N=0; dut->EXT_UDS_N=0; dut->EXT_VA=ext_off;
                dut->EXT_VDI=ext_val; dut->EXT_AS_N=0;
                ext_st=EXT_DRIVE; ext_wait=0;
            }
        } else {
            if (!dut->EXT_DTACK_N || ++ext_wait>200) {
                if (ext_rd) printf("EXTRD [%ld] off=%d -> %04X (dtack=%d)\n",
                                   c, ext_off, dut->EXT_VDO, !dut->EXT_DTACK_N);
                dut->EXT_FDC_N=1; dut->EXT_ASEL_N=1; dut->EXT_RNW=1;
                dut->EXT_LDS_N=1; dut->EXT_UDS_N=1; dut->EXT_AS_N=1;
                ext_st=EXT_IDLE;
            }
        }

        // ---- CLK high edge ----
        dut->CLK=1; dut->eval();

        // EXT VCLK CE (main-CPU phase enable), ~1/7
        vclk=(vclk+1)%7; dut->EXT_VCLK_CE = (vclk==0);

        // ---- PRG-RAM handshake (ASIC drives OE_N/WRx_N/RFS, waits on RDY) ----
        bool prg_rd = !dut->PRG_OE_N;
        bool prg_wr = !dut->PRG_WRL_N || !dut->PRG_WRH_N;
        bool prg_rfs = dut->PRG_RFS;
        if (!prgp.active && (prg_rd||prg_wr||prg_rfs)) {
            prgp.active=true; prgp.busy=MEM_LAT; dut->PRG_RDY=0;
            uint32_t ba = (dut->PRG_A & 0x3FFFF)*2;
            if (prg_wr) wrw(prg, ba, dut->PRG_DO, !dut->PRG_WRH_N, !dut->PRG_WRL_N);
            prgp.rdata = rdw(prg, ba);
        } else if (prgp.active) {
            if (--prgp.busy<=0){ prgp.active=false; dut->PRG_DI=prgp.rdata; dut->PRG_RDY=1; }
        } else dut->PRG_RDY=1;

        // ---- ROM (BIOS) handshake ----
        bool rom_ce = !dut->ROM_CE_N;
        if (!romp.active && rom_ce) {
            romp.active=true; romp.busy=MEM_LAT; dut->ROM_RDY=0;
            // ROM_DI fed by EXT/ASIC ROM window; the ASIC drives ROM_CE_N and
            // the byte addr comes via EXT_VA / S68K; approximate with EXT_VA
            uint32_t ba = (dut->EXT_VA & 0xFFFF)*2;
            romp.rdata = rdw(rom, ba & 0x1FFFF);
        } else if (romp.active) {
            if(--romp.busy<=0){ romp.active=false; dut->ROM_DI=romp.rdata; dut->ROM_RDY=1; }
        } else dut->ROM_RDY=1;

        // ---- word RAM banks ----
        auto wram=[&](MemPort&p,std::vector<uint8_t>&m,uint8_t rd,uint8_t wr,
                      uint16_t addr,uint16_t wdata,uint16_t&di,uint8_t&rdy){
            if(!p.active && (rd||wr)){ p.active=true; p.busy=MEM_LAT; rdy=0;
                uint32_t ba=(addr&0xFFFF)*2;
                if(wr) wrw(m,ba,wdata,true,true);
                p.rdata=rdw(m,ba);
            } else if(p.active){ if(--p.busy<=0){p.active=false; di=p.rdata; rdy=1;} }
            else rdy=1;
        };
        uint16_t w0di=dut->WORDRAM0_DI, w1di=dut->WORDRAM1_DI;
        uint8_t w0rdy=dut->WORDRAM0_RDY, w1rdy=dut->WORDRAM1_RDY;
        wram(w0,wram0,dut->WORDRAM0_RD,dut->WORDRAM0_WR,dut->WORDRAM0_A,dut->WORDRAM0_DO,w0di,w0rdy);
        wram(w1,wram1,dut->WORDRAM1_RD,dut->WORDRAM1_WR,dut->WORDRAM1_A,dut->WORDRAM1_DO,w1di,w1rdy);
        dut->WORDRAM0_DI=w0di; dut->WORDRAM1_DI=w1di;
        dut->WORDRAM0_RDY=w0rdy; dut->WORDRAM1_RDY=w1rdy;

        // ---- backup RAM (single-cycle) ----
        {
            uint32_t a=(dut->BRAM_A & 0x1FFF);
            if(dut->BRAM_WE) bram[a & 0x1FFF]=dut->BRAM_DO;
            dut->BRAM_DI=bram[a & 0x1FFF];
        }

        // ---- CDD exchange (75Hz beat modeled at ~clk/715909) ----
        if(!dut->MCD_RST_N) cdd.reset();
        // drain STOP->NO_DISC
        if(cdd.status==0){ if(++cdd.ms>=698010){cdd.ms=0; if(cdd.latency)cdd.latency--; else cdd.status=0xB;} }
        static int sd=0;
        if(dut->CDD_SEND && !sd) cdd.command(((uint64_t)dut->CDD_COMM));
        sd=dut->CDD_SEND;
        if(++cdd.beat>=715909){ cdd.beat=0;
            uint64_t p=cdd.pack();
            dut->CDD_STAT = p & 0xFFFFFFFFFFULL; dut->CDD_DM=0;
            dut->CDD_REC=1; cdd.reccnt=8;
        } else if(cdd.reccnt){ cdd.reccnt--; } else dut->CDD_REC=0;

        dut->eval();

        // ---- CLK low edge ----
        dut->CLK=0; dut->eval();
        main_time++;

        // ---- trace sub-CPU PC (address bus) ----
        uint32_t pc = dut->DBG_S68K_A & 0xFFFFFF;
        if (pc>=0x6178 && pc<=0x6190 && c>INJ && !seen_cmd){ seen_cmd=true; printf("[%ld] sub entered COMMAND HANDLER AFTER INJECTION (pc=%06X)\n",c,pc);
            // real main clears the comm command regs after the sub acks;
            // stale CC2 would re-fire the action each INT2 and set the abort
            // flag $833E -> premature $7350 loop exit. Clear before next INT2.
            script.push_back({(uint32_t)(c+100000), 8, 0x0000});
            script.push_back({(uint32_t)(c+100400),10, 0x0000});
            script.push_back({(uint32_t)(c+100800),11, 0x0000});
        }
        if (pc>=0x616A && pc<=0x6170 && c>INJ && !seen_616a){ seen_616a=true; printf("[%ld] sub reached BUSY-WAIT $616A AFTER INJECTION (the hang!)\n",c); }
        if (pc>=0x726E && pc<=0x7300 && c>INJ && !seen_726e){ seen_726e=true; printf("[%ld] sub in READ-LOOP INIT $726E (mode 8 accepted)\n",c); }
        if (pc==0x7302 && c>INJ && !seen_7302){ seen_7302=true; printf("[%ld] sub ENTERED DRIVE-READ LOOP $7302 (freeze reproduced?)\n",c); }
        static uint32_t prev_pc2=0;
        if (pc==0x730A && prev_pc2!=0x730A && c>INJ) loop_iters++;
        if (pc==0x77D8 && prev_pc2!=0x77D8 && c>INJ) q_checks++;
        prev_pc2=pc;
        if (pc==0x7350 && c>INJ && !seen_7350){ seen_7350=true; printf("[%ld] sub EXITED loop via $7350\n",c); }
        // wedge detector: bus parked in the $616A busy-wait / $833F flag
        // region continuously for >1.5 INT2 frames = the hardware freeze
        bool inwait = (pc>=0x6168 && pc<=0x6172) || (pc>=0x833C && pc<=0x8340);
        if (inwait) busyres++; else busyres=0;
        if (busyres==1342500 && !wedged){ wedged=true; wedge_at=c;
            printf("[%ld] WEDGE: sub parked in busy-wait (busy=%02X mode=%04X)\n",
                   c, prg[0x833F], (prg[0x833C]<<8)|prg[0x833D]); }
        if (pc==last_pc){ if(++idlepc==200000){ printf("[%ld] sub STUCK at %06X ipl=%X pend=%02X gron=%d\n",
                             c,pc,dut->DBG_S68K_IPL_N,dut->DBG_INT_PEND,dut->DBG_GRON); idlepc=0; } }
        else { idlepc=0; last_pc=pc; }

        if (c>8500000 && (c%100000)==0)
            printf("ST [%ld] mode=%04X abort=%02X busy=%02X six=%02X pc=%06X\n",
                   c,(prg[0x833C]<<8)|prg[0x833D],prg[0x833E],prg[0x833F],prg[0x8342],pc);
        if ((c % 500000)==0)
            printf("[%ld] pc=%06X ipl=%X pend=%02X ack=%02X gron=%d cdd_st=%X iters=%ld qchk=%ld\n",
                   c, pc, dut->DBG_S68K_IPL_N, dut->DBG_INT_PEND, dut->DBG_INT_ACK,
                   dut->DBG_GRON, cdd.status, loop_iters, q_checks);
    }
    printf("RESULT cddphase=%ld int2phase=%ld memlat=%d wedge=%d wedge_at=%ld\n",
           cddphase, int2phase, memlat, wedged?1:0, wedge_at);
    printf("end: mode=%04X abort=%02X busy=%02X state44=%04X drvstat58=%02X %02X\n",
           (prg[0x833C]<<8)|prg[0x833D], prg[0x833E], prg[0x833F],
           (prg[0x8380]<<8)|prg[0x8381], prg[0x8394], prg[0x8395]);
    dut->final(); delete dut;
    return 0;
}
