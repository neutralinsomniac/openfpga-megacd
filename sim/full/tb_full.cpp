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
#include <deque>
#include <vector>
#include <string>
#include <dirent.h>
#include <strings.h>

// FAT-style case-insensitive open: exact first, then scan the directory
static FILE* fopen_fat(const char* path){
    FILE* f = fopen(path, "rb");
    if(f) return f;
    const char* slash = strrchr(path, '/');
    if(!slash) return nullptr;
    std::string dir(path, slash - path), want(slash + 1);
    DIR* d = opendir(dir.c_str());
    if(!d) return nullptr;
    while(struct dirent* e = readdir(d)){
        if(!strcasecmp(e->d_name, want.c_str())){
            std::string full = dir + "/" + e->d_name;
            f = fopen(full.c_str(), "rb");
            break;
        }
    }
    closedir(d);
    return f;
}
static vluint64_t t=0; double sc_time_stamp(){return t;}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    long maxc = 40000000;
    for(int i=1;i<argc;i++) if(!strcmp(argv[i],"--cycles")&&i+1<argc) maxc=atol(argv[++i]);

    Vcore_top* dut = new Vcore_top;
    // (BIOS cache needs no preload: misses fill from the SDRAM +bios= image)
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
            // The canned button script below was written for the cursor
            // soft-lock investigation and PRESSES START ~5s in, which skips a
            // game's intro movie -- exactly what a run investigating the intro
            // needs to keep. Opt in with SCRIPTED_INPUT=1.
            static bool scripted = getenv("SCRIPTED_INPUT") != nullptr;
            if(scripted){
            if(c>=750000000 && c<775000000) k |= 1u<<15;   // START (title up ~frame 200)
            if(c>=1150000000 && c<1165000000) k |= 1u<<3;  // RIGHT on player screen
            if(c>=1230000000 && c<1245000000) k |= 1u<<1;  // DOWN too
            if(c>=1400000000 && c<1415000000) k |= 1u<<3;  // RIGHT (post-auto-open)
            }
            // PRESS_START=start,end : extra scripted START window (e.g. to
            // skip the game intro movie like a real player would)
            { static long ps0=-1, ps1=-1; static bool psi=false;
              if(!psi){ psi=true; const char* e=getenv("PRESS_START");
                        if(e) sscanf(e,"%ld,%ld",&ps0,&ps1); }
              if(ps0>=0 && c>=ps0 && c<ps1) k |= 1u<<15; }
            dut->cont1_key = k;
        }

        // ---- APF host: CD-image dataslot server (--cd <file>) ----
        // Emulates the Pocket host: advertises the image size in the data
        // table (slot index 2), acks Ready-To-Run, and serves target
        // command 0x0180 (dataslot read) by writing the requested bytes
        // through the bridge into the sector buffer.
        {
            static FILE* f1=nullptr;      // slot 1: mounted file (cue or bin)
            static FILE* f2=nullptr;      // slot 2: bin opened via 0x0192
            static char  f1path[512];
            static uint32_t size1=0; static bool cdinit=false;
            static bool table_written=false;
            struct W { uint32_t a,d; };
            static std::deque<W> q; static int ph=0;
            if(!cdinit){ cdinit=true;
                for(int i=1;i<argc;i++) if(!strcmp(argv[i],"--cd")&&i+1<argc){
                    snprintf(f1path,sizeof f1path,"%s",argv[i+1]);
                    f1=fopen(f1path,"rb");
                    if(f1){ fseek(f1,0,SEEK_END); size1=(uint32_t)ftell(f1); }
                    printf("CD slot 1: %s (%u bytes)%s\n", f1path, size1,
                           f1?"":" -- OPEN FAILED");
                }
            }
            // TOCPOST_AT=<cycle>: extra TOC snapshot once the mount is done
            static long tocpost_at = -1;
            { static bool tpi=false; if(!tpi){ tpi=true;
                const char* e=getenv("TOCPOST_AT"); if(e) tocpost_at=atol(e); } }
            if(c==tocpost_at){
                for(int t=1;t<=30;t++){
                    auto& w=dut->rootp->core_top__DOT__toc_ram_b[t];
                    uint64_t lo=((uint64_t)w[1]<<32)|w[0]; uint32_t hi=w[2];
                    printf("  TOCAT[%d]: audio=%d pgap=%d pre01=%d file=%d delta=%d disc_lba=%d\n",
                           t,(int)((hi>>1)&1),(int)((((uint64_t)(hi&1)<<7)|(lo>>57))&0xFF),
                           (int)((lo>>47)&0x3FF),(int)((lo>>40)&0x7F),
                           (int)((lo>>20)&0xFFFFF),(int)(lo&0xFFFFF));
                }
            }
            if(c==60000){   // post-layout TOC snapshot
                for(int t=1;t<=4;t++){
                    auto& w=dut->rootp->core_top__DOT__toc_ram_b[t];
                    uint64_t lo=((uint64_t)w[1]<<32)|w[0]; uint32_t hi=w[2];
                    printf("  TOCPOST[%d]: audio=%d pgap=%d pre01=%d file=%d delta=%d disc_lba=%d\n",
                           t,(int)((hi>>1)&1),(int)((((uint64_t)(hi&1)<<7)|(lo>>57))&0xFF),
                           (int)((lo>>47)&0x3FF),(int)((lo>>40)&0x7F),
                           (int)((lo>>20)&0xFFFFF),(int)(lo&0xFFFFF));
                }
            }
            // toc_final edge: the drive may only report "disc ready" (9) once
            // this is high, so it must not rise until the refine layout pass
            // has retired and mount_eff_size holds the true leadout.
            { static int tf_prev=-1;
              int tf = dut->rootp->core_top__DOT__toc_final_sys;
              if(tf!=tf_prev){
                  printf("TOCFINAL [%ld] toc_final=%d mount_eff_size=%u (%u sectors)\n",
                         c, tf, dut->rootp->core_top__DOT__mount_eff_size,
                         dut->rootp->core_top__DOT__mount_eff_size/2352);
                  tf_prev=tf;
              } }
            // the size the DRIVE sees: must stay 0 (= no disc, drive drains to
            // NO_DISC and the BIOS idles untimed) until the TOC is final
            { static uint32_t is_prev=0xFFFFFFFFu;
              uint32_t is = dut->rootp->core_top__DOT__cd_img_size_sys;
              if(is!=is_prev){
                  printf("DISCSIZE [%ld] drive img_size=%u (%u sectors) present=%d\n",
                         c, is, is/2352, is>=2352);
                  is_prev=is;
              } }
            // ---- APF data-slot table model ----
            // The real table is {id, size} word PAIRS; datatable word W lives
            // at bridge addr 0xF8002000 + W*4. Row order is firmware-defined,
            // so DT_ORDER models both: "json" (default) = our data.json
            // declaration order 0,10,1,2 -- the layout the old fixed-index
            // reads assumed; "id" = sorted by slot id 0,1,2,10, which moves CD
            // Data's size from word 7 to word 5 and breaks those reads.
            // Previously this tb only ever wrote SIZE words at fixed indices
            // and never wrote an id at all, so it could not exercise a lookup.
            static bool dt_by_id = [](){ const char* e=getenv("DT_ORDER");
                                         return e && !strcmp(e,"id"); }();
            auto write_dtable = [&](uint32_t cue_sz, uint32_t bin_sz){
                const uint32_t ids_json[4] = {0, 10, 1, 2};
                const uint32_t ids_byid[4] = {0, 1, 2, 10};
                const uint32_t* ids = dt_by_id ? ids_byid : ids_json;
                for(int i=0;i<4;i++){
                    uint32_t id = ids[i], sz;
                    switch(id){ case 0:  sz = 0x20000; break;   // BIOS
                                case 10: sz = 8192;    break;   // Save
                                case 1:  sz = cue_sz;  break;   // CD Image
                                default: sz = bin_sz;  break; } // CD Data
                    q.push_back({0xF8002000u + (uint32_t)(i*2)  *4u, id});
                    q.push_back({0xF8002000u + (uint32_t)(i*2+1)*4u, sz});
                }
            };
            // MOUNT_AT=<cycle>: delay the mount to model a user browsing
            // the menu mid-session (the default mounts at boot)
            static long mount_at = 5001;
            { static bool mi=false; if(!mi){ mi=true;
                const char* e=getenv("MOUNT_AT"); if(e) mount_at=atol(e); } }
            if(did_reset_exit && c>5000){
                if(f1 && !table_written && c>mount_at){ table_written=true;
                    printf("[%ld] mounting CD (008A)\n", c);
                    write_dtable(size1, 0);             // CD Image sized; no bin open yet
                    // deferload mount notification (host cmd 0x008A):
                    // params first, then the command word
                    q.push_back({0xF8000020u, 1u});      // slot id
                    q.push_back({0xF8000024u, size1});   // size
                    q.push_back({0xF8000000u, 0x434D008Au});
                }
                if(q.empty() && (c&63)==0){
                    uint32_t t0 = dut->rootp->core_top__DOT__icb__DOT__target_0;
                    // HOST_LATENCY=<half-cycles>: hold every pending target
                    // command for this long before serving it, modeling the
                    // real Pocket host's SD-card latency (instant by default).
                    // ~150K half-cycles = 1ms of emulated time.
                    { static long host_lat = getenv("HOST_LATENCY")?atol(getenv("HOST_LATENCY")):0;
                      static long cmd_seen = -1;
                      bool is_cmd = t0==0x636D0140u || t0==0x636D0180u ||
                                    t0==0x636D0190u || t0==0x636D0192u;
                      if(is_cmd && host_lat>0){
                          if(cmd_seen<0) cmd_seen=c;
                          if(c-cmd_seen<host_lat) t0=0;   // still "in flight"
                          else cmd_seen=-1;               // serve it now
                      } }
                    if(t0==0x636D0140u){                  // Ready To Run
                        q.push_back({0xF8001000u,0x6F6B0000u});
                    } else if(t0==0x636D0180u){           // dataslot read
                        uint32_t id =dut->rootp->core_top__DOT__icb__DOT__target_20&0xFFFF;
                        uint32_t off=dut->rootp->core_top__DOT__icb__DOT__target_24;
                        uint32_t dst=dut->rootp->core_top__DOT__icb__DOT__target_28;
                        uint32_t len=dut->rootp->core_top__DOT__icb__DOT__target_2C;
                        FILE* f = (id==2) ? f2 : f1;
                        static long nserved=0;
                        if(nserved<8 || (nserved&511)==0)
                            printf("[%ld] CD read #%ld: slot=%u off=%u len=%u dst=%08X\n",
                                   c,nserved,id,off,len,dst);
                        nserved++;
                        // model firmware semantics: reads past EOF are an
                        // "out of range" error and deliver NO data
                        uint32_t fsz=0;
                        if(f){ fseek(f,0,SEEK_END); fsz=(uint32_t)ftell(f); }
                        bool ok = f && (uint64_t)off+len <= fsz;
                        if(ok){
                            std::vector<uint8_t> buf(((size_t)len+3)&~(size_t)3,0);
                            fseek(f,off,SEEK_SET);
                            size_t got=fread(buf.data(),1,len,f); (void)got;
                            for(uint32_t i=0;i<len;i+=4)
                                q.push_back({dst+i,(uint32_t)((buf[i]<<24)|(buf[i+1]<<16)|
                                                              (buf[i+2]<<8)|buf[i+3])});
                        } else if(nserved<20 || (nserved&255)==0)
                            printf("[%ld] CD read ERR: slot=%u off=%u len=%u fsz=%u\n",
                                   c,id,off,len,fsz);
                        q.push_back({0xF8001000u,(uint32_t)(ok?0x6F6B0000u:0x6F6B0002u)});
                    } else if(t0==0x636D0190u){           // getfile: write slot path
                        uint32_t ptr=dut->rootp->core_top__DOT__icb__DOT__target_24;
                        printf("[%ld] CD getfile -> %08X ('%s')\n",c,ptr,f1path);
                        size_t n=strlen(f1path)+1;
                        for(size_t i=0;i<n;i+=4){
                            uint8_t b[4]={0,0,0,0};
                            for(int k=0;k<4&&i+k<n;k++) b[k]=(uint8_t)f1path[i+k];
                            q.push_back({(uint32_t)(ptr+i),
                                (uint32_t)((b[0]<<24)|(b[1]<<16)|(b[2]<<8)|b[3])});
                        }
                        q.push_back({0xF8001000u,0x6F6B0000u});
                    } else if(t0==0x636D0192u){           // openfile: read param path
                        char path[257];
                        for(int i=0;i<64;i++){
                            uint32_t w=dut->rootp->core_top__DOT__icb__DOT__fbuf_ram_b[128+i];
                            path[i*4+0]=(char)(w>>24); path[i*4+1]=(char)(w>>16);
                            path[i*4+2]=(char)(w>>8);  path[i*4+3]=(char)w;
                        }
                        path[256]=0;
                        printf("[%ld] fbuf[0]=%08X fbuf[1]=%08X fbuf[128]=%08X fbuf[129]=%08X\n",
                               c, dut->rootp->core_top__DOT__icb__DOT__fbuf_ram_b[0],
                               dut->rootp->core_top__DOT__icb__DOT__fbuf_ram_b[1],
                               dut->rootp->core_top__DOT__icb__DOT__fbuf_ram_b[128],
                               dut->rootp->core_top__DOT__icb__DOT__fbuf_ram_b[129]);
                        if(f2) fclose(f2);
                        f2=fopen_fat(path);
                        uint32_t size2=0;
                        if(f2){ fseek(f2,0,SEEK_END); size2=(uint32_t)ftell(f2); }
                        printf("[%ld] CD openfile slot2: '%s' (%u bytes)%s\n",
                               c,path,size2,f2?"":" -- OPEN FAILED");

                        // NO_DTABLE=1: model a firmware whose datatable row
                        // order differs from our guess (the real-hardware
                        // failure mode) — only the 008A path carries the size
                        static bool no_dtable = getenv("NO_DTABLE")!=nullptr;
                        // firmware refreshes the table after the openfile:
                        // the CD Data row (id 2) now carries this bin's size
                        if(f2 && !no_dtable) write_dtable(size1, size2);
                        q.push_back({0xF8001000u,(uint32_t)(f2?0x6F6B0000u:0x6F6B0003u)});
                        // user-reloadable slot: firmware follows the openfile
                        // with a 008A "slot updated" notification carrying the
                        // new size (this is the layout-independent size path
                        // the core prefers; the datatable write above is the
                        // row-order-dependent fallback)
                        // NO_008A=1: real firmware (observed): core-initiated
                        // openfile produces NO size notification at all
                        static bool no_008a = getenv("NO_008A")!=nullptr;
                        if(f2 && !no_008a){
                            q.push_back({0xF8000020u, 2u});
                            q.push_back({0xF8000024u, size2});
                            q.push_back({0xF8000000u, 0x434D008Au});
                        }
                    }
                }
                if(!q.empty()){
                    // 6 half-cycle write: asserted across >=2 rising edges, then idle
                    if(ph==0){ dut->bridge_addr=q.front().a;
                               dut->bridge_wr_data=q.front().d; dut->bridge_wr=1; }
                    if(ph==4){ dut->bridge_wr=0; }
                    ph++;
                    if(ph==6){ ph=0; q.pop_front(); }
                }
            }
        }
        dut->eval(); t++;

        // ---- reset-with-disc-mounted investigation ----
        // RESET_AT=<cycle>: issue the APF "Reset Core" bridge write ($70)
        // mid-run, reproducing the hardware repro (mount a disc, then reset).
        { static long rst_at=-1; static bool rsti=false; static int rst_ph=0;
          if(!rsti){ rsti=true; const char* e=getenv("RESET_AT"); if(e) rst_at=atol(e); }
          if(rst_at>0 && rst_ph<2){
              if(c==rst_at){ dut->bridge_addr=0x00000070; dut->bridge_wr_data=1;
                             dut->bridge_wr=1; rst_ph=1;
                             printf("[%ld] >>> Reset Core\n", c); fflush(stdout); }
              else if(c==rst_at+10){ dut->bridge_wr=0; rst_ph=2; }
          } }
        // COMMTRACE=1: main/sub handshake. CFM is written by the MAIN CPU,
        // CFS by the SUB; the hardware hang parks the main CPU polling
        // $A1200E with CFS never changing. SRES=0 means the sub is HELD in
        // reset, which is what we cannot tell apart on hardware.
        // NB: these are yosys-mangled net names from mcd.v (cfs=_1459_,
        // cfm=_1461_, sres=_1421_, sbrq=_1423_); re-converting mcd.v will
        // renumber them -- re-derive from the "assign cfs = _NNNN_;" lines.
        { static bool cti=false, ct=false; static int lcfm=-1,lcfs=-1,lsres=-1,lsbrq=-1;
          static long ncfm=0, ncfs=0;
          if(!cti){ cti=true; const char* e=getenv("COMMTRACE"); ct = e && *e=='1'; }
          if(ct){
              int cfm = dut->rootp->core_top__DOT__MCD__DOT__asic__DOT___1489_/*sig:cfm*/;
              int cfs = dut->rootp->core_top__DOT__MCD__DOT__asic__DOT___1486_/*sig:cfs*/;
              int sres= dut->rootp->core_top__DOT__MCD__DOT__asic__DOT___1449_/*sig:sres*/;
              int sbrq= dut->rootp->core_top__DOT__MCD__DOT__asic__DOT___1451_/*sig:sbrq*/;
              // INT_PEND(2) = int_pend[1] = _1543_; IEN(2) = ien[1] of _1471_.
              // With the IEN gate removed from the latch, INT_PEND(2) staying
              // 0 means the MAIN CPU never requests INT2 at all.
              int ip2 = dut->rootp->core_top__DOT__MCD__DOT__asic__DOT___1572_/*sig:int_pend2*/ & 1;
              int ie2 = (dut->rootp->core_top__DOT__MCD__DOT__asic__DOT___1500_/*sig:ien*/ >> 1) & 1;
              static int lip2=-1, lie2=-1; static long nip2=0;
              if(ip2!=lip2 && ip2) nip2++;
              if(cfm!=lcfm) ncfm++;
              if(cfs!=lcfs) ncfs++;
              if(cfm!=lcfm||cfs!=lcfs||sres!=lsres||sbrq!=lsbrq||ip2!=lip2||ie2!=lie2){
                  printf("[%ld] CFM=%02X CFS=%02X SRES=%d SBRQ=%d IPEND2=%d IEN2=%d"
                         " (chg m=%ld s=%ld int2req=%ld)\n",
                         c, cfm, cfs, sres, sbrq, ip2, ie2, ncfm, ncfs, nip2); fflush(stdout);
                  lcfm=cfm; lcfs=cfs; lsres=sres; lsbrq=sbrq; lip2=ip2; lie2=ie2;
              }
          } }

#if 0   // CDC trace disabled (see #endif below)
        // ---- CDC instrumentation ----
        // CDCTRACE=start[,end]: log the sub<->CDC register dialogue (AR
        // shadow mirrors the LC8951 auto-increment) + host-read bursts +
        // DTEN/INT edges. CDCRAMDUMP=iter: dump the 16KB CDC buffer RAM.
        {
            static long ct0=-1, ct1=(1L<<62); static long crd=-1;
            static bool ci=false;
            if(!ci){ ci=true;
                const char* e=getenv("CDCTRACE");
                if(e) sscanf(e,"%ld,%ld",&ct0,&ct1);
                e=getenv("CDCRAMDUMP");
                if(e) crd=atol(e);
            }
            auto* rr = dut->rootp;
            static const char* wrn[16]={"SBOUT","IFCTRL","DBCL","DBCH","DACL","DACH","DTTRG","DTACK","WAL","WAH","CTRL0","CTRL1","PTL","PTH","CTRL2","RESET"};
            static const char* rdn[16]={"COMIN","IFSTAT","DBCL","DBCH","HEAD0","HEAD1","HEAD2","HEAD3","PTL","PTH","WAL","WAH","STAT0","STAT1","STAT2","STAT3"};
            static int ar=0, wr_p=1, rd_p=1, hrd_p=1, dten_p=1, int_p=1;
            static int rd_ar=-1;
            static long hn=0; static uint8_t hfirst[32]; static long hlast=0;
            int cs  = rr->core_top__DOT__MCD__DOT__cdc_n;
            int wr  = rr->core_top__DOT__MCD__DOT__clwe_n;
            int rd  = rr->core_top__DOT__MCD__DOT__coe_n;
            int rs  = rr->core_top__DOT__MCD__DOT__s68k_a & 1;
            int di  = rr->core_top__DOT__MCD__DOT__s68k_do & 0xFF;
            int dob = rr->core_top__DOT__MCD__DOT__cdc_do;
            int hrd = rr->core_top__DOT__MCD__DOT__cdc_hrd_n;
            int hdo = rr->core_top__DOT__MCD__DOT__cdc_hdo;
            int dten= rr->core_top__DOT__MCD__DOT__cdc_dten_n;
            int intn= rr->core_top__DOT__MCD__DOT__cdc_int_n;
            bool on = (c>=ct0 && c<ct1);
            auto hflush=[&](){ if(hn){
                printf("CDC [%ld] HOST burst %ld bytes:",hlast,hn);
                for(int i=0;i<(hn<32?hn:32);i++) printf(" %02X",hfirst[i]);
                printf("%s\n", hn>32?" ...":"");
                hn=0; } };
            if(!cs && !wr && wr_p){          // register write strobe
                if(!rs){ if(on){hflush();printf("CDC [%ld] AR <= %X\n",c,di&15);} ar=di&15; }
                else {
                    if(on){hflush();printf("CDC [%ld] WR %-6s <= %02X\n",c,wrn[ar],di);}
                    if(ar) ar=(ar+1)&15;
                }
            }
            if(!cs && !rd && rd_p) rd_ar = rs ? ar : 16;   // read begins
            if(rd && !rd_p && rd_ar>=0){     // read strobe released: DO valid
                static int lrep_reg=-1, lrep_val=-1; static long lrep_n=0;
                if(rd_ar==16){ if(on){hflush();printf("CDC [%ld] RD AR = %02X\n",c,dob);} }
                else {
                    if(on){
                        if(rd_ar==lrep_reg && dob==lrep_val) lrep_n++;  // poll dedupe
                        else {
                            hflush();
                            if(lrep_n) printf("CDC ... RD %s repeated x%ld\n",rdn[lrep_reg],lrep_n);
                            printf("CDC [%ld] RD %-6s = %02X\n",c,rdn[rd_ar],dob);
                            lrep_reg=rd_ar; lrep_val=dob; lrep_n=0;
                        }
                    }
                    if(ar) ar=(ar+1)&15;
                }
                rd_ar=-1;
            }
            if(hrd && !hrd_p){               // host byte consumed
                if(hn<32) hfirst[hn]=hdo;
                hn++; hlast=c;
            }
            if(on && dten!=dten_p){ hflush(); printf("CDC [%ld] DTEN_N=%d\n",c,dten); }
            if(on && intn!=int_p){ printf("CDC [%ld] INT_N=%d\n",c,intn); }
            if(on && hn && c-hlast>400000) hflush();
            wr_p=wr; rd_p=rd; hrd_p=hrd; dten_p=dten; int_p=intn;
            if(c==crd){
                // cdc_ram dump retired: its mem is a converted-VHDL inferred
                // RAM with no public handle after core_top stopped inlining
                // into the root. Reinstate by annotating the dpram mem in
                // mcd.v with /*verilator public_flat_rd*/ if needed again.
                printf("[%ld] cdcram_dump skipped (see tb note)\n",c);
            }
        }
#endif  // CDC trace disabled: this yosys conversion drops the MCD-level nets it probes

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

        // PCTRACE=<file>: dump the sub-CPU's distinct-PC sequence once it is
        // out of reset. Diffing this between the disc and no-disc runs finds
        // the exact instruction where the two boots diverge -- every
        // individual signal checked so far reads the SAME in both cases, so
        // the divergence has to be located rather than guessed at.
        { static FILE* pf=NULL; static bool pi=false; static uint32_t pl=0xFFFFFFFF;
          static long n=0;
          if(!pi){ pi=true; const char* e=getenv("PCTRACE"); if(e) pf=fopen(e,"w"); }
          if(pf && spc!=pl && n<4000000){
              if(spc) { fprintf(pf, "%06X\n", spc); n++; }
              pl=spc;
              if(n==4000000){ fclose(pf); pf=NULL; }
          } }

        // CKTRACE=1: the sub-CPU checksum-verify loop.
        //   02E0: ADD.W (A0)+,D0 / DBF D2 / DBF D1     <- sums a region
        //   02EA: MOVE.W $8E(A1),D1 ; CMP.W D1,D0 ; BNE $0206  <- verify
        // The sub cycles between this and the $05E8 INT2 wait and never
        // reaches the code that writes CFS. Log the distinct sub addresses
        // seen while the loop is live: the ascending run IS the region being
        // checksummed, which says whether the disc data arrived at all.
        { static bool cki=false, ck=false; static int armed=0; static long n=0;
          static uint32_t lo=0xFFFFFFFF, hi=0, prev=0xFFFFFFFF; static long nrun=0;
          if(!cki){ cki=true; const char* e=getenv("CKTRACE"); ck = e && *e=='1'; }
          if(ck){
              if(spc>=0x02DE && spc<=0x02E8){ if(!armed){ lo=0xFFFFFFFF; hi=0; nrun=0; } armed=1; }
              if(armed && spc!=prev){
                  if(spc<0x02D0 || spc>0x0300){                 // a data access
                      if(spc<lo) lo=spc;
                      if(spc>hi) hi=spc;
                      nrun++;
                      if(n<40){ printf("CK data addr %06X\n", spc); fflush(stdout); }
                      n++;
                  }
                  prev=spc;
              }
              // capture A1: at 02EA the sub does MOVE.W $8E(A1),D1, so the
              // next data access after that fetch is at A1+$8E. Comparing
              // this between the disc and no-disc runs says whether the two
              // are consulting the same structure for the expected checksum.
              { static int want=0; static uint32_t pv2=0; static long shown=0;
                if(spc!=pv2){
                    if(spc==0x02EA) want=1;
                    else if(want && (spc<0x0200 || spc>0x0320)){
                        if(shown<8){ printf("CK expected-value read at %06X  (A1=%06X)\n",
                                            spc, spc-0x8E); fflush(stdout); shown++; }
                        want=0;
                    }
                    pv2=spc;
                } }
              // which branch does the verify take?
              { static long n2F0=0,n2F6=0,n0206=0; static uint32_t pv=0;
                if(spc!=pv){
                    if(spc==0x02F0) n2F0++;          // CMP executed (expected!=0)
                    if(spc==0x02F6) n2F6++;          // check skipped or passed
                    if(spc==0x0206){ n0206++;        // MISMATCH -> error path
                        printf("CK MISMATCH #%ld: region %06X..%06X (%ld words)\n",
                               n0206, lo, hi, nrun); fflush(stdout); }
                    pv=spc;
                    if(((n2F0+n2F6+n0206)%20)==0 && (n2F0+n2F6+n0206))
                        printf("CK path: cmp-executed=%ld fallthrough=%ld ERROR-PATH=%ld\n",
                               n2F0,n2F6,n0206), fflush(stdout);
                } }
              if(spc>=0x02EA && spc<=0x02F4 && armed){          // reached the compare
                  printf("CK compare reached: summed-region seen %06X..%06X (%ld accesses)\n",
                         lo, hi, nrun); fflush(stdout);
                  armed=0;
              }
          } }

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
        // MOUNT/DRIVE trace: mount_ready, drv_status, door — correlate the
        // moment the disc becomes "present" (mount_ready) and the drive's
        // NO_DISC->OPEN->TOC insertion dance with the main-CPU boot PC. This
        // is what the BIOS watches to decide CHECKING DISC vs its idle panel.
        { static int mr_prev=-1, ds_prev=-1, dr_prev=-1;
          int mr = r->core_top__DOT__mount_ready;
          int ds = r->core_top__DOT__cdd_drive__DOT__drv_status;
          int dr = r->core_top__DOT__cdd_drive__DOT__door;
          if(mr!=mr_prev || ds!=ds_prev || dr!=dr_prev){
              printf("MNT [%ld] mount_ready=%d drv_status=%d door=%d main=%06X\n",
                     c, mr, ds, dr, mpc);
              mr_prev=mr; ds_prev=ds; dr_prev=dr;
          } }
        // CDDATRACE=1: during CDDA playback, log every CDD command the game
        // issues (skipping the frequent DRIVE STATUS poll c0=0) and flag any
        // stall in head advancement (a delivery hitch). This is to catch the
        // deterministic Sonic-CD intro skip.
        { static bool on = getenv("CDDATRACE")!=nullptr;
          if(on){
            int ca  = r->core_top__DOT__cdd_drive__DOT__cur_audio;
            int ds2 = r->core_top__DOT__cdd_drive__DOT__drv_status;
            unsigned head = r->core_top__DOT__cdd_drive__DOT__head;
            // dbg_cmd_cnt was retired from the overlay packing (it wrapped ~3x/s
            // and could not say which command changed state); trigger off the
            // latched command word itself instead.
            static unsigned long long cmd_prev=~0ULL;
            unsigned long long cm = r->core_top__DOT__cdd_drive__DOT__dbg_last_comm;
            if(cm != cmd_prev){
              cmd_prev = cm;
              int c0 = cm & 0xF;
              if(c0!=0)   // non-poll command
                printf("CDD [%ld] comm=%010llX c0=%d status=%d audio=%d head=%u\n",
                       c, cm, c0, ds2, ca, head&0xFFFFF);
            }
            // head-stall detector during PLAY on an audio track
            static unsigned head_prev=0; static long head_last_move=0;
            if(head!=head_prev){ head_prev=head; head_last_move=c; }
            static long last_report=0;
            if(ca && ds2==1 && (c-head_last_move)>1500000 && (c-last_report)>500000){
              printf("CDDA-STALL [%ld] head frozen at %u for %ld cyc\n",
                     c, head&0xFFFFF, c-head_last_move);
              last_report=c;
            }
          } }
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
        { static int rc_prev=0; static unsigned long long laststat=~0ULL;
          int rc_now = r->core_top__DOT__cdd_rec;
          if(rc_now && !rc_prev){
            unsigned long long st = r->core_top__DOT__cdd_stat;
            if(st!=laststat){ printf("CDDSTAT [%ld] %010llX\n", c, st); laststat=st; }
          }
          rc_prev=rc_now; }
        static long padvar_rd=0, padport_rd=0;
        { static uint32_t pv=0; if(mpc!=pv){ if(mpc==0xFFFE20||mpc==0xFFFE21) padvar_rd++;
          if(mpc==0xA10003) padport_rd++; pv=mpc; } }
        if((c%50000000)==0 && c) printf("PADCNT [%ld] padvar=%ld padport=%ld\n",c,padvar_rd,padport_rd);
        static bool sub_started=false;
        if(!sub_started && spc!=0){ sub_started=true; printf("[%ld] SUB RELEASED: first sub addr=%06X\n",c,spc); }
        // MCD_RST_N (= ASIC ERES_N) holds the whole sub system -- sub 68000 and
        // the CDD drive -- in reset. ASIC.vhd reloads RST_CNT and drops it on
        // every MAIN_RST_EXEC/SUB_RST_EXEC, so a main that keeps pulsing the
        // reset register can starve the sub of any window to run in. Report
        // edges plus a duty summary: if it is mostly HIGH the sub is out of
        // reset and stuck for some other reason, if it is toggling the main is
        // resetting it in a loop, if it never rises the release never happens.
        { static int rst_prev=-1; static long rst_hi=0, edges=0;
          int rn = dut->rootp->core_top__DOT__MCD_RST_N;
          if(rn) rst_hi++;
          if(rn!=rst_prev){
              if(rst_prev>=0 && edges<20)
                  printf("[%ld] MCD_RST_N %d -> %d (main=%06X sub=%06X)\n",c,rst_prev,rn,mpc,spc);
              edges++; rst_prev=rn; }
          if((c%2000000)==0 && c)
              printf("MCDRST [%ld] high=%.1f%% edges=%ld now=%d sbrq=%d\n",
                     c, 100.0*rst_hi/2000000.0, edges, rn,
                     dut->rootp->core_top__DOT__MCD__DOT__asic__DOT___1451_/*sig:sbrq*/), rst_hi=0; }
        // SBRQ is the main's bus request for the sub. ASIC.vhd:2631/2638 make it
        // halt the sub 68000 outright (GEN_S68K_HALT <= SBRQ), and it RESETS TO
        // '1' -- so the sub is born halted and only runs once the main writes
        // $A12001 with bit1 clear. If this never falls, the sub can be fully out
        // of reset and still never fetch an instruction.
        { static int sb_prev=-1; static long sb_edges=0;
          int sb = dut->rootp->core_top__DOT__MCD__DOT__asic__DOT___1451_/*sig:sbrq*/;
          if(sb!=sb_prev){
              if(sb_edges<12)
                  printf("[%ld] SBRQ %d -> %d (main=%06X sub=%06X)\n",c,sb_prev,sb,mpc,spc);
              sb_edges++; sb_prev=sb; } }
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
          { int r0=r->core_top__DOT__MCD__DOT__asic__DOT___1458_/*sig:ret0*/, r1=r->core_top__DOT__MCD__DOT__asic__DOT___1460_/*sig:ret1*/;
            int d0=r->core_top__DOT__MCD__DOT__asic__DOT___1456_/*sig:dmna0*/, d1=r->core_top__DOT__MCD__DOT__asic__DOT___1457_/*sig:dmna1*/;
            if(r0!=r0_p) swp[0]++; if(r1!=r1_p) swp[1]++;
            if(d0!=d0_p) swp[2]++; if(d1!=d1_p) swp[3]++;
            r0_p=r0; r1_p=r1; d0_p=d0; d1_p=d1; }
          if((c%2000000)==0 && c){
            printf("SWAP [%ld] ret0=%ld ret1=%ld dmna0=%ld dmna1=%ld\n",c,swp[0],swp[1],swp[2],swp[3]);
            swp[0]=swp[1]=swp[2]=swp[3]=0; }
          // CPU CLOCKS PER MAIN BUS CYCLE. The bus machine leaves MBUS_IDLE
          // when the 68000 starts a cycle and returns to it only once the CPU
          // has released AS, so an out-of-IDLE excursion IS one bus cycle.
          // Counting M68K_CLKENp pulses across it (one pulse per full 7.67MHz
          // CPU clock, gen.sv:163) measures the cost of a bus cycle.
          //
          // READ THIS AS A COMPARISON BETWEEN SLAVES, NOT AN ABSOLUTE. Every
          // slave measures ~8.0 here -- work RAM (3/4), expansion window (5),
          // VDP (6) alike -- and plain Genesis carts and other Sega CD titles
          // run at full speed on this core, so 8.0 is simply what a correct bus
          // cycle costs through an MCLK-domain FSM feeding a clock-enabled CPU.
          // A naive "4 clocks = zero wait states" reading of this number sent
          // one investigation chasing a 2x main-CPU slowdown that does not
          // exist. What it IS good for: a slave that is genuinely slow shows up
          // as its state costing more than the others.
          { static int prev=-1; static long clks=0; static int via=0;
            static long n[16]={0}, sum[16]={0};
            int ms = r->core_top__DOT__gen__DOT__mstate & 15;
            if(prev==0 && ms!=0){ clks=0; via=ms; }          // cycle start
            if(ms!=0){ if(ms!=14) via=ms; if(r->core_top__DOT__gen__DOT__M68K_CLKENp) clks++; }
            if(prev!=0 && ms==0 && via){ n[via]++; sum[via]+=clks; via=0; }
            prev=ms;
            if((c%2000000)==0 && c){
              printf("BUSCYC [%ld]",c);
              for(int i=0;i<16;i++) if(n[i]>16)
                printf("  st%d: n=%ld %.1f cpuclk", i, n[i], (double)sum[i]/n[i]);
              printf("   (compare slaves, not absolutes)\n");
              for(int i=0;i<16;i++){ n[i]=0; sum[i]=0; } } }
          // ---- CD pipeline snapshot (CDTRACE=1) ----------------------
          // One line per 2M cycles carrying what the hardware overlay shows:
          // drive state + head, the CDC decode path (DECEN/WRRQ, the mm:ss it
          // framed, decode + DTTRG counters) and the seek/backseek counters.
          // The stall shows up as head frozen with drv_status=4 while the
          // seek counters stop and the framed header stops tracking head.
          { static bool on = getenv("CDTRACE")!=nullptr;
            if(on && (c%2000000)==0 && c){
              auto& R = *r;
              unsigned dec = R.core_top__DOT__dbg_dec;
              unsigned head = R.core_top__DOT__cdd_drive__DOT__head & 0xFFFFF;
              printf("CD [%ld] st=%u head=%u aud=%u | DECEN=%u WRRQ=%u "
                     "hdr=%02X:%02X trg=%u dec=%u | seek=%u back=%u bad=%u lastc0=%X\n",
                     c,
                     R.core_top__DOT__cdd_drive__DOT__drv_status, head,
                     R.core_top__DOT__cdd_drive__DOT__cur_audio,
                     (dec>>31)&1, (dec>>30)&1,
                     (dec>>16)&0xFF, (dec>>8)&0xFF,
                     (dec>>4)&0xF, dec&0xF,
                     R.core_top__DOT__cdd_drive__DOT__dbg_seek_cnt,
                     R.core_top__DOT__cdd_drive__DOT__dbg_backseek_cnt,
                     R.core_top__DOT__cdd_drive__DOT__dbg_badsync_cnt,
                     R.core_top__DOT__cdd_drive__DOT__dbg_last_real_c0);
            } }
          static long mshist[16]={0};
          mshist[r->core_top__DOT__gen__DOT__mstate & 15]++;
          if((c%2000000)==0 && c){
            printf("MST [%ld]",c);
            for(int i=0;i<16;i++){ if(mshist[i]) printf(" %d:%ld",i,mshist[i]); mshist[i]=0; }
            printf("\n"); }
          // MBUS_ROM_READ (state 5) is the whole 000000-7FFFFF expansion window,
          // which on MCD includes the word-RAM view the main blits FMV frames
          // from. Break its cost down: how many accesses, how long each, and how
          // much of that is spent before exp_dtack_armed (i.e. waiting for the
          // slave to RELEASE a stale DTACK) versus waiting for the real answer.
          // ...and split it by WHICH slave answered. The ASIC ORs four DTACK
          // sources (ASIC.vhd: EXT_DTACK_N <= REG and PRGRAM and WORDRAM and
          // ROM), and they are not equally fast -- but only the word-RAM one is
          // on the FMV blit path, so a per-slave split says whether optimising
          // the ROM window (the BIOS-in-BRAM idea) would touch decoding at all.
          // Classified by the latched MBUS address rather than by tapping the
          // yosys-converted VHDL, using the main-CPU map:
          //   000000-01FFFF BIOS ROM   020000-03FFFF PRG-RAM window
          //   200000-23FFFF word RAM   400000-7FFFFF cartridge
          { enum { S_ROM=0, S_PRG, S_WRAM, S_CART, S_OTHER, S_N };
            static const char* nm[S_N] = {"bios","prgram","wordram","cart","other"};
            static long n[S_N]={0}, cyc[S_N]={0};
            static int prev_ms=-1; static int cur=S_OTHER;
            int ms = r->core_top__DOT__gen__DOT__mstate & 15;
            if(ms==5){
              if(prev_ms!=5){
                uint32_t a = ((uint32_t)r->core_top__DOT__gen__DOT__MBUS_A) << 1;
                cur = (a < 0x020000) ? S_ROM  : (a < 0x040000) ? S_PRG :
                      (a >= 0x200000 && a < 0x240000) ? S_WRAM :
                      (a >= 0x400000) ? S_CART : S_OTHER;
                n[cur]++;
              }
              cyc[cur]++;
            }
            prev_ms = ms;
            if((c%2000000)==0 && c){
              long tn=0, tc=0; for(int i=0;i<S_N;i++){ tn+=n[i]; tc+=cyc[i]; }
              if(tn){
                printf("ROMRD [%ld] n=%ld cyc/access=%.1f |", c, tn, (double)tc/tn);
                for(int i=0;i<S_N;i++) if(n[i])
                  printf("  %s: n=%ld %.1f clk", nm[i], n[i], (double)cyc[i]/n[i]);
                printf("\n");
              }
              for(int i=0;i<S_N;i++){ n[i]=0; cyc[i]=0; } } }
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
    {   // end-of-run PRG RAM dump for offline inspection (cdc_ram dump
        // retired — see the CDCRAMDUMP note above)
        FILE*fp;
#ifndef REALSD
        fp=fopen("prgram_end.bin","wb");
        if(fp){ for(uint32_t w=0x800000;w<0x840000;w++){
                    uint16_t v=dut->rootp->core_top__DOT__sdram__DOT__mem[w];
                    fputc(v>>8,fp); fputc(v&0xFF,fp); }
                fclose(fp); }
#endif
        printf("wrote prgram_end.bin\n");
    }
    printf("ST2 word-RAM selftest: ph=%d err=%d\n",
           dut->rootp->core_top__DOT__st2_ph, dut->rootp->core_top__DOT__st2_err);
    dut->final(); delete dut;
    printf("done\n");
    return 0;
}
