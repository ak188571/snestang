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
    unsigned fault_mode=0,send_calls=0,receive_calls=0;
    bool injected=false;
    std::set<unsigned> lost_ack;
    static bool send_frame(void *p,const std::uint8_t *request,std::size_t size,std::uint32_t,void (*pump)(void *),void *ctx){
        auto &s=*static_cast<Test*>(p);++s.send_calls;
        const std::vector<std::uint8_t> immutable(request,request+size);
        std::vector<std::uint8_t> frame(request,request+size);
        if(s.fault_mode==1&&!s.injected&&get32(request+10)==0){frame[20]^=1;s.injected=true;}
        unsigned i=0;
        for(auto b:frame){s.dut.rx_data=b;s.dut.rx_valid=1;s.step();s.dut.rx_valid=0;s.step();
            if(pump&&++i%16==0){pump(ctx);assert(std::equal(immutable.begin(),immutable.end(),request));}}
        if(pump)pump(ctx);return true;
    }
    static bool poll_frame(void *p,std::uint8_t *reply,std::size_t *size){
        auto &s=*static_cast<Test*>(p);
        while(s.received.size()>=25){
            assert(*size>=25);for(unsigned j=0;j<25;++j){reply[j]=s.received.front();s.received.pop_front();}*size=25;
            const auto seq=get32(reply+10);
            if((s.fault_mode==2&&seq==0)||(s.fault_mode==4&&seq<2)){if(s.lost_ack.insert(seq).second)continue;}
            if(s.fault_mode==3&&!s.injected){reply[24]^=1;s.injected=true;}
            if(s.fault_mode==5)continue;
            return true;
        }
        return false;
    }
    static bool receive_frame(void *p,std::uint8_t *reply,std::size_t *size,std::uint32_t){
        auto &s=*static_cast<Test*>(p);++s.receive_calls;
        for(unsigned i=0;i<2500000;++i){
            if(poll_frame(p,reply,size))return true;
            s.step();
        }
        return false;
    }
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

    for(unsigned bytes:{1024u,4096u,2u*1024*1024,4u*1024*1024}){
        for(unsigned fault=0;fault<(bytes==4096?6u:1u);++fault){
            auto t=std::make_unique<Test>();SourceData input(bytes);std::array<std::uint8_t,2*MaxFrame> buffer{};
            Session s({t.get(),Test::exchange,Test::send_frame,Test::receive_frame,nullptr,Test::poll_frame},70+fault,buffer.data(),buffer.size());
            assert(s.begin(input.bytes.size()));assert(s.negotiate_window());t->fault_mode=fault;
            if(fault==5){assert(!s.stream({&input,SourceData::read,nullptr}));assert(s.stats().requests<=10);assert(t->dut.held);continue;}
            assert(s.stream({&input,SourceData::read,nullptr}));assert(s.finish()&&s.start());
            assert(t->dut.writes==bytes/2&&t->dut.headers==64&&!t->dut.held);
            assert(s.stats().bytes==input.bytes.size()&&t->send_calls>=2);
            if(fault)assert(s.stats().retries>0);
            std::printf("Window2 actual receiver/sink: %u bytes fault=%u retries=%u passed\n",bytes,fault,s.stats().retries);std::fflush(stdout);
        }
    }
    {
        auto t=std::make_unique<Test>();SourceData input(4096);input.chunk=65;std::array<std::uint8_t,2*MaxFrame> buffer{};
        Session s({t.get(),Test::exchange,Test::send_frame,Test::receive_frame,nullptr,Test::poll_frame},91,buffer.data(),buffer.size());
        assert(s.begin(input.bytes.size())&&s.negotiate_window());assert(s.stream({&input,SourceData::read,nullptr}));
        const unsigned seq=(input.bytes.size()-1)/65-1,at=seq*65;
        auto changed=std::vector<std::uint8_t>(input.bytes.begin()+at,input.bytes.begin()+at+65);changed[0]^=1;
        assert(raw(*t,Op::Data,91,seq,at,changed.data(),65)==Status::Order);
        assert(raw(*t,Op::Data,91,seq,at,input.bytes.data()+at,65)==Status::Ok);
        assert(t->dut.writes==2048&&s.finish()&&s.start());
        std::puts("Window2 odd blocks and exact two-entry replay history passed");
    }
    {
        auto t=std::make_unique<Test>();
        for(auto b:{0xaa,0,3,0x10,0,0}){
            t->dut.rx_data=b;t->dut.rx_valid=1;t->step();assert(!t->dut.owned);
            t->dut.rx_valid=0;t->step(4);assert(!t->dut.owned);
        }
        t->step(100);assert(!t->dut.held&&!t->dut.owned);
        std::puts("Unrelated legacy traffic does not claim the ROM link");
    }
    for(unsigned fault=0;fault<3;++fault){
        auto t=std::make_unique<Test>();SourceData input(4096);std::array<std::uint8_t,2*MaxFrame> buffer{};
        Session s({t.get(),Test::exchange,Test::send_frame,Test::receive_frame,nullptr,Test::poll_frame},95+fault,buffer.data(),buffer.size());
        assert(s.begin(input.bytes.size())&&s.negotiate_window());
        if(fault==0){t->dut.stall_memory=1;assert(!s.stream({&input,SourceData::read,nullptr}));}
        if(fault==1){assert(s.stream({&input,SourceData::read,nullptr}));t->dut.corrupt_read=1;assert(!s.finish());}
        if(fault==2){
            // Block the executor, then deliberately violate the advertised
            // two-request credit bound. Overflow must poison the backend.
            t->dut.stall_memory=1;
            std::array<std::uint8_t,MaxFrame> wire{};
            const auto n=encode(wire.data(),wire.size(),{Request,Op::Data,97,0,0,input.bytes.data(),1024});
            Test::send_frame(t.get(),wire.data(),n,50,nullptr,nullptr);t->step(4000);
            for(unsigned i=0;i<5000;++i){t->dut.rx_data=0;t->dut.rx_valid=1;t->step();t->dut.rx_valid=0;t->step();}
            t->step(5000);std::uint8_t total[4];put32(total,input.bytes.size());
            assert(raw(*t,Op::Begin,98,0,0,total,4)==Status::Backend);
        }
        assert(!s.start()&&t->dut.held);s.abort();assert(t->dut.held);
    }
    std::puts("Window2 SDRAM timeout, readback corruption and ingress overflow retain reset");
    std::puts("Readback corruption and start-at-fast-rate were rejected; game reset retained");
}
