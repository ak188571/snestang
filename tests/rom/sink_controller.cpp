#include "Vtb_sink_controller.h"
#include "verilated.h"
#include "tc_rom_protocol.h"
#include <algorithm>
#include <array>
#include <cassert>
#include <cstdio>
#include <cstdlib>
double sc_time_stamp(){return 0;}
struct Test {
    Vtb_sink_controller d;
    unsigned phase=0;
    std::array<unsigned long long,16> states{};
    void step(){
        d.fclk=0;d.eval();
        phase=(phase+1)%6;
        if(phase==0){states[d.sink_state]++;d.mclk=1;}
        if(phase==3)d.mclk=0;
        d.fclk=1;d.eval();
    }
    void command(unsigned op,unsigned offset,unsigned n,unsigned total,unsigned digest=0){
        d.op=op;d.offset=offset;d.count=n;d.total=total;d.digest=digest;d.req=!d.req;
        unsigned limit=200000000;
        while(d.done!=d.req&&--limit)step();
        assert(limit&&d.ok);
    }
    Test(){d.resetn=0;d.fclk=0;d.mclk=0;d.req=0;d.corrupt_read=0;d.ack_delay=0;
        for(unsigned i=0;i<60;++i)step();d.resetn=1;
        do step();while(d.busy);for(unsigned i=0;i<60;++i)step();states.fill(0);}
};
int main(int argc,char **argv){
    Verilated::commandArgs(argc,argv);
    const unsigned bytes=argc>1?std::strtoul(argv[1],nullptr,0):65536;
    const unsigned chunk=argc>2?std::strtoul(argv[2],nullptr,0):1024;
    assert(chunk>0&&chunk<=1024);
    Test t;unsigned total=bytes+64,crc=~0u;
    t.d.ack_delay=argc>3?std::strtoul(argv[3],nullptr,0):0;
    for(unsigned at=0;at<total;++at){const unsigned char b=(at*73)^(at>>8)^0x5a;crc=TcRom::crc_update(crc,&b,1);}
    t.command(1,0,0,total);t.states.fill(0);
    for(unsigned at=0;at<total;at+=chunk){
        const unsigned end=at+std::min(chunk,total-at);
        t.command(2,at,end-at,total);
        assert(t.d.writes==(end>64?(end-64)/2:0));
        assert(t.d.headers==std::min(64u,end));
    }
    const auto data=t.states;t.states.fill(0);assert(t.d.writes==bytes/2&&t.d.headers==64);
    assert(t.d.header_finished&&t.d.rom_type==3&&t.d.rom_size==5&&t.d.ram_size==2);
    t.command(3,0,0,total,crc^~0u);assert(t.d.reads==bytes/2);
    const auto end=t.states;t.command(4,0,0,total);assert(!t.d.owner);
    std::printf("{\"bytes\":%u,\"chunk\":%u,\"ack_delay\":%u,\"writes\":%u,\"reads\":%u,\"refreshes\":%u,\"data_states\":[",bytes,chunk,t.d.ack_delay,t.d.writes,t.d.reads,t.d.refreshes);
    for(unsigned i=0;i<16;++i)std::printf("%s%llu",i?",":"",data[i]);
    std::printf("],\"end_states\":[");for(unsigned i=0;i<16;++i)std::printf("%s%llu",i?",":"",end[i]);std::puts("]}");
}
