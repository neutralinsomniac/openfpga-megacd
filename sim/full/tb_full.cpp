// Full-system co-sim testbench (skeleton). Drives clocks + minimal bridge,
// traces both CPU PCs. To be fleshed out once elaboration is clean.
#include "Vcore_top.h"
#include "verilated.h"
#include <cstdio>
static vluint64_t t=0; double sc_time_stamp(){return t;}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    Vcore_top*dut=new Vcore_top;
    for(long c=0;c<1000;c++){ dut->clk_74a=!dut->clk_74a; dut->eval(); t++; }
    dut->final(); delete dut; printf("elaborated+ticked OK\n"); return 0;
}
