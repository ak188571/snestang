#ifdef TC_ROM_SPI_TEST
#include "Vtb_rom_core_spi.h"
using Model=Vtb_rom_core_spi;
#else
#include "Vtb_rom_core.h"
using Model=Vtb_rom_core;
#endif
#include "verilated.h"
#include "tc_rom_protocol.h"
#include <algorithm>
#include <array>
#include <cassert>
#include <cstdio>
#include <deque>
#include <memory>
#include <set>
#include <vector>
using namespace TcRom;
double sc_time_stamp(){return 0;}
struct Test {
    Model dut;
    std::deque<std::uint8_t> received;
    unsigned phase=0,body_size=0;
    bool seen_progress[24]{};
    bool lose=false,damage=false,damage_ack=false;
    std::set<std::pair<unsigned,std::uint32_t>> dropped;
    Test(){dut.clk=0;dut.mem_clk=0;dut.resetn=0;dut.rx_valid=0;dut.tx_ready=1;dut.fault=0;dut.link_at_base=1;dut.stall_memory=0;dut.corrupt_read=0;step(40);dut.resetn=1;step(40);}
    void step(unsigned n=1){
        while(n--){
            dut.clk=0;dut.eval();
            if(dut.tx_valid&&dut.tx_ready)received.push_back(dut.tx_data);
            phase+=42968000;if(phase>=96000000){phase-=96000000;dut.mem_clk=!dut.mem_clk;}
            dut.clk=1;dut.eval();assert(dut.display_status<24);seen_progress[dut.display_status]=true;
        }
    }
    static bool exchange(void *p,const std::uint8_t *request,std::size_t size,std::uint8_t *reply,std::size_t *reply_size,
                         std::uint32_t timeout,void (*pump)(void *),void *ctx){
        auto &s=*static_cast<Test*>(p);s.received.clear();
        std::vector<std::uint8_t> frame(request,request+size);
        if(s.damage&&request[5]==2){frame[20]^=1;s.damage=false;}
        // Exercise the documented minimum: one idle clock between bytes.
        for(auto byte:frame){s.dut.rx_data=byte;s.dut.rx_valid=1;s.step();s.dut.rx_valid=0;s.step();}
        if(pump)pump(ctx);
        // Byte-transport tests accelerate wall time only. The real UART adapter
        // is independently tested at serial bit timing in the system test.
        const unsigned limit=timeout==10000?400000000:2500000;
        for(unsigned i=0;i<limit&&s.received.size()<25;++i)s.step();
        if(s.received.size()!=25)return false;
        assert(*reply_size>=25);for(unsigned i=0;i<25;++i){reply[i]=s.received.front();s.received.pop_front();}*reply_size=25;
        s.step(4);
        if (s.body_size && request[5]==2 && reply[20]==0 && s.body_size>=2097152){
            const auto offset=get32(reply+14);
            const unsigned step=offset>64?std::uint64_t(offset-64)*20/s.body_size:0;
            assert(s.dut.display_status==2+step);
        }
        const auto key=std::make_pair(unsigned(request[5]),get32(request+10));
        if(s.lose&&s.dropped.insert(key).second)return false;
        if(s.damage_ack){reply[24]^=1;s.damage_ack=false;}
        return true;
    }
};
struct SourceData {
    std::vector<std::uint8_t> bytes;
    unsigned chunk=MaxData;
    explicit SourceData(unsigned n){
        bytes.resize(n+64);std::uint32_t x=0x1749ab53;
        for(auto &b:bytes){x^=x<<13;x^=x>>17;x^=x<<5;b=std::uint8_t(x>>24);}
    }
    static bool read(void *p,std::uint32_t offset,std::uint8_t *out,std::uint16_t maximum,std::uint16_t *count){
        auto &s=*static_cast<SourceData*>(p);*count=std::uint16_t(std::min<std::size_t>(std::min<unsigned>(maximum,s.chunk),s.bytes.size()-offset));
        std::copy_n(s.bytes.data()+offset,*count,out);return true;
    }
};
static Status raw(Test &t,Op op,unsigned id,unsigned seq,unsigned at,const std::uint8_t *bytes,unsigned count){
    std::array<std::uint8_t,MaxFrame> frame{};std::array<std::uint8_t,25> response{};std::size_t size=response.size();
    auto n=encode(frame.data(),frame.size(),{Request,op,id,seq,at,bytes,std::uint16_t(count)});assert(n);
    assert(Test::exchange(&t,frame.data(),n,response.data(),&size,50,nullptr,nullptr));
    View answer;assert(decode(response.data(),size,answer));return static_cast<Status>(answer.data[0]);
}
int main(int argc,char **argv){
    Verilated::commandArgs(argc,argv);
    for(unsigned bytes:{1024u,4096u,2u*1024*1024,4u*1024*1024}){
        auto t=std::make_unique<Test>();SourceData input(bytes);std::array<std::uint8_t,MaxFrame> buffer{};
        t->body_size=bytes;t->lose=bytes==4096;t->damage=bytes==1024;t->damage_ack=true;
        Session s({t.get(),Test::exchange},7,buffer.data(),buffer.size());
        assert(s.begin(input.bytes.size()));assert(t->dut.held);
        assert(s.stream({&input,SourceData::read,nullptr}));assert(s.finish());assert(t->dut.held);
        assert(s.start());assert(!t->dut.held);
        if(bytes>=2097152){for(unsigned i=0;i<=23;++i)assert(t->seen_progress[i]);}
        assert(t->dut.writes==bytes/2&&t->dut.headers==64);
        assert(t->dut.first_word==((unsigned(input.bytes[65])<<8)|input.bytes[64]));
        std::printf("Actual receiver + SNES sink + firmware Session: %u bytes, writes=%u passed\n",bytes,t->dut.writes);std::fflush(stdout);
    }
    {
        auto t=std::make_unique<Test>();SourceData input(4096);std::array<std::uint8_t,MaxFrame> buffer{};
        Session s({t.get(),Test::exchange},12,buffer.data(),buffer.size());assert(s.begin(input.bytes.size()));
        assert(s.stream({&input,SourceData::read,nullptr}));t->dut.corrupt_read=1;
        assert(!s.finish()&&!s.start()&&t->dut.held);s.abort();assert(t->dut.held);
    }
    {
        auto t=std::make_unique<Test>();SourceData input(1024);std::array<std::uint8_t,MaxFrame> buffer{};
        Session s({t.get(),Test::exchange},13,buffer.data(),buffer.size());assert(s.begin(input.bytes.size()));
        assert(s.stream({&input,SourceData::read,nullptr}));assert(s.finish());
        t->dut.link_at_base=0;assert(!s.start()&&t->dut.held);
    }
    {
        auto t=std::make_unique<Test>();SourceData input(4096);input.chunk=65;std::array<std::uint8_t,MaxFrame> buffer{};
        Session s({t.get(),Test::exchange},14,buffer.data(),buffer.size());assert(s.begin(input.bytes.size()));
#ifdef TC_ROM_SPI_TEST
        std::uint8_t baud[4];put32(baud,8000000);
        assert(raw(*t,Op::LinkRate,14,0,0,baud,4)==Status::Format);
#endif
        assert(raw(*t,Op::Data,99,0,0,input.bytes.data(),65)==Status::Session);
        assert(raw(*t,Op::Data,14,1,0,input.bytes.data(),65)==Status::Order);
        assert(raw(*t,Op::Start,14,0,0,nullptr,0)==Status::State);
        assert(s.stream({&input,SourceData::read,nullptr}));
        const unsigned seq=(input.bytes.size()-1)/65,at=seq*65,n=input.bytes.size()-at;
        std::vector<std::uint8_t> changed(input.bytes.begin()+at,input.bytes.end());changed[0]^=1;
        assert(raw(*t,Op::Data,14,seq,at,changed.data(),n)==Status::Order);
        assert(raw(*t,Op::Data,14,seq,at,input.bytes.data()+at,n)==Status::Ok);
        assert(t->dut.writes==2048&&t->dut.headers==64);assert(s.finish()&&s.start());
        std::puts("Odd 65-byte blocks, header/word splits, wrong session/order and changed duplicate payload rejected without extra writes");
    }
    {
        auto t=std::make_unique<Test>();SourceData input(1024);std::array<std::uint8_t,MaxFrame> buffer{};
        Session s({t.get(),Test::exchange},15,buffer.data(),buffer.size());assert(s.begin(input.bytes.size()));
        t->dut.stall_memory=1;assert(!s.stream({&input,SourceData::read,nullptr}));assert(!s.start()&&t->dut.held);
        t->dut.stall_memory=0;s.abort();assert(t->dut.held);
        std::puts("SDRAM acknowledgement timeout rejects transaction and retains reset");
    }
    std::puts("Readback corruption and start-at-fast-rate were rejected; game reset retained");
}
