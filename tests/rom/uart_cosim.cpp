#include "Vtb_rom_uart.h"
#include "verilated.h"
#include "tc_rom_protocol.h"
#include <algorithm>
#include <array>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <vector>
using namespace TcRom;
constexpr unsigned Clock=80000000,SlowPeriod=40,FastPeriod=10;
double sc_time_stamp(){return 0;}
struct Test {
    Vtb_rom_uart dut;
    std::deque<std::uint8_t> received;
    std::vector<std::uint8_t> observed;
    unsigned observed_errors=0;
    std::uint64_t cycles=0,overlap=0;
    // 2.4 GHz time base: 30 ticks per 80 MHz cycle, 16 per 150 MHz
    // cycle, and 75 per 32 MHz SPI period.
    std::uint64_t now=0,next_core=30,next_sample=16;
    unsigned spi_high_ticks=150,spi_low_ticks=150;
    unsigned sender_scale=10000,sender_fraction=0;
    unsigned phase=0,period=SlowPeriod,rx_state=0,rx_left=0,rx_bit=0;
    std::uint8_t rx_byte=0;
    bool damage=false,lose_data=false,lose_end=false,lose_rate=false;
    Test(){dut.spi_cs_n=1;dut.spi_sck=0;dut.spi_mosi=0;dut.clk=0;dut.spi_clk=0;dut.mem_clk=0;dut.resetn=0;dut.uart_rx=1;dut.stall_memory=0;dut.corrupt_read=0;
        step(40);dut.resetn=1;step(40);}
    void advance(std::uint64_t ticks){
        const auto until=now+ticks;
        while(std::min(next_core,next_sample)<=until){
            const auto event=std::min(next_core,next_sample);
            const bool core=event==next_core, sample=event==next_sample;
            if(core)dut.clk=0;
            if(sample)dut.spi_clk=0;
            dut.eval();
            if(core){
                next_core+=30;
                phase+=42968000;if(phase>=Clock){phase-=Clock;dut.mem_clk=!dut.mem_clk;}
                dut.clk=1;
            }
            if(sample){next_sample+=16;dut.spi_clk=1;}
            dut.eval();
            if(!core)continue;
            ++cycles;if(dut.observed_valid&&dut.sink_processing)++overlap;
            if(dut.observed_valid)observed.push_back(dut.observed_byte);
            if(dut.observed_error)++observed_errors;
            if(!rx_state){if(!dut.uart_tx){rx_state=1;rx_left=period+period/2;rx_bit=0;rx_byte=0;}}
            else if(--rx_left==0){
                if(rx_bit<8){rx_byte|=unsigned(dut.uart_tx)<<rx_bit++;rx_left=period;}
                else {assert(dut.uart_tx);received.push_back(rx_byte);rx_state=0;}
            }
        }
        now=until;
    }
    void step(unsigned n=1){advance(std::uint64_t(n)*30);}
    void spi_ownership(bool enable){
        dut.uart_rx=!enable;
        step(960);
        assert(bool(dut.spi_selected)==enable);
    }
    void spi_byte(std::uint8_t byte){
        for(int bit=7;bit>=0;--bit){
            dut.spi_sck=1;dut.spi_mosi=(byte>>bit)&1;advance(spi_high_ticks);
            dut.spi_sck=0;advance(spi_low_ticks);
        }
    }
    void bit(bool value){
        dut.uart_rx=value;sender_fraction+=period*sender_scale;
        const auto cycles=sender_fraction/10000;sender_fraction%=10000;step(cycles);
    }
    void send(std::uint8_t b){
        bit(false);for(unsigned i=0;i<8;++i)bit((b>>i)&1);bit(true);
    }
    static bool exchange(void *p,const std::uint8_t *request,std::size_t size,std::uint8_t *reply,std::size_t *reply_size,
                         std::uint32_t timeout,void (*pump)(void *),void *ctx){
        auto &s=*static_cast<Test*>(p);s.received.clear();s.observed.clear();s.observed_errors=0;
        for(unsigned i=0;i<size;++i){auto b=request[i];if(s.damage&&request[5]==2&&i==23){b^=1;s.damage=false;}s.send(b);}
        if(pump)pump(ctx);
        const auto limit=std::uint64_t(timeout)*(Clock/1000);
        for(std::uint64_t i=0;i<limit&&s.received.size()<25;++i)s.step();
        if(s.received.size()!=25){std::printf("No serial ACK: op=%u baud=%u received=%zu held=%u RX errors=%u decoded=%zu\n",request[5],Clock/s.period,s.received.size(),s.dut.held,s.observed_errors,s.observed.size());
            for(unsigned i=0;i<std::min<std::size_t>(s.observed.size(),32);++i)std::printf("%02x%s",s.observed[i],i<size&&s.observed[i]==request[i]?" ":"! ");std::puts("");return false;}
        assert(*reply_size>=25);for(unsigned i=0;i<25;++i){reply[i]=s.received.front();s.received.pop_front();}*reply_size=25;
        s.step(s.period); // drain the rest of the final stop bit
        if(s.lose_data&&request[5]==2){s.lose_data=false;s.step(timeout*(Clock/1000));return false;}
        if(s.lose_end&&request[5]==3){
            s.lose_end=false;s.step(timeout*(Clock/1000));
            assert(s.dut.at_fast&&s.dut.held);return false;
        }
        if(s.lose_rate&&request[5]==16){s.lose_rate=false;s.step(Clock/20);return false;}
        return true;
    }
    static bool send_frame(void *p,const std::uint8_t *request,std::size_t size,std::uint32_t,void (*pump)(void *),void *ctx){
        auto &s=*static_cast<Test*>(p);
        const bool spi=s.dut.spi_selected;
        if(spi){assert(request[5]==2);s.dut.spi_cs_n=0;s.step(12);}
        const std::vector<std::uint8_t> original(request,request+size);
        for(unsigned i=0;i<size;++i){auto b=request[i];if(s.damage&&i==23){b^=1;s.damage=false;}if(spi)s.spi_byte(b);else s.send(b);
            if(pump&&i%16==15)pump(ctx);assert(std::equal(original.begin(),original.end(),request));}
        if(spi){s.step(12);s.dut.spi_cs_n=1;s.step(12);}
        if(pump)pump(ctx);return true;
    }
    static bool poll_frame(void *p,std::uint8_t *reply,std::size_t *size){
        auto &s=*static_cast<Test*>(p);
        while(s.received.size()>=25){
            assert(*size>=25);for(unsigned j=0;j<25;++j){reply[j]=s.received.front();s.received.pop_front();}*size=25;
            if(s.lose_data&&get32(reply+10)==0){s.lose_data=false;continue;}
            return true;
        }
        return false;
    }
    static bool receive_frame(void *p,std::uint8_t *reply,std::size_t *size,std::uint32_t timeout){
        auto &s=*static_cast<Test*>(p);const auto limit=std::uint64_t(timeout)*(Clock/1000);
        for(std::uint64_t i=0;i<limit;++i){
            if(poll_frame(p,reply,size))return true;
            s.step();
        }
        return false;
    }
    void change(unsigned p){step(Clock*6/1000);period=p;assert(bool(dut.at_fast)==(p==FastPeriod));}
};
struct Input {
    std::vector<std::uint8_t> data;
    explicit Input(unsigned size){
        data.resize(size+64);std::uint32_t x=0x3749ab53;
        for(auto &b:data){x^=x<<13;x^=x>>17;x^=x<<5;b=std::uint8_t(x>>24);}
    }
    static bool read(void *p,std::uint32_t at,std::uint8_t *out,std::uint16_t max,std::uint16_t *n){
        auto &s=*static_cast<Input*>(p);*n=std::min<std::size_t>(max,s.data.size()-at);std::copy_n(s.data.data()+at,*n,out);return true;
    }
};
int main(int argc,char **argv){
    std::setbuf(stdout,nullptr);
    Verilated::commandArgs(argc,argv);
    if(argc>1 && std::strcmp(argv[1],"--spi-ownership")==0){
        Test t;
        // Longest legal low run in a 2 Mbit/s 8N1 frame (start and eight zeros).
        for(int i=0;i<9;++i){t.bit(false);assert(!t.dut.spi_selected);}
        t.bit(true);t.step(960);
        std::array<std::uint8_t,MaxFrame> buffer{};
        Session session({&t,Test::exchange},93,buffer.data(),buffer.size());
        assert(session.begin(2048) && session.link_rate(8000000));
        t.change(FastPeriod);assert(session.link_sync());
        t.spi_ownership(true);t.step(Clock+100);
        assert(!t.dut.at_fast && t.dut.held && t.dut.spi_selected);
        t.spi_ownership(false);t.period=SlowPeriod;session.abort();
        assert(t.dut.held && !t.dut.writes);
        std::puts("PASS legal UART zero byte, SPI pin ownership during idle watchdog, native JTAG after release");
        return 0;
    }
    if (argc > 1 && std::strcmp(argv[1], "--spi32") == 0) {
        struct TestCase { unsigned bytes, scenario, high, low; };
        for (const auto run : {TestCase{2097152,0,30,45}, TestCase{4194304,0,45,30},
                           TestCase{16384,1,30,45}, TestCase{16384,2,45,30}}) {
            const auto scenario=run.scenario;
            Test t;
            t.spi_high_ticks = run.high;
            t.spi_low_ticks = run.low;
            Input input(run.bytes);
            std::array<std::uint8_t,2*MaxFrame> buffer{};
            Session session({&t,Test::exchange,Test::send_frame,Test::receive_frame,nullptr,Test::poll_frame},
                            95,buffer.data(),buffer.size());
            assert(session.begin(input.data.size()) && session.link_rate(8000000));
            t.change(FastPeriod);
            assert(session.link_sync() && session.negotiate_window());
            t.spi_ownership(true);
            t.damage = t.lose_data = scenario == 1;
            const auto start = t.cycles;
            assert(session.stream({&input,Input::read,nullptr}));
            const auto cycles = t.cycles - start;
            assert(t.dut.writes == run.bytes/2 && t.dut.headers == 64);
            assert(scenario == 1 ? session.stats().retries > 0 : session.stats().retries == 0);
            t.spi_ownership(false);
            t.dut.corrupt_read = scenario == 2;
            assert(session.finish() == (scenario != 2));
            if (scenario == 2) {
                assert(!session.start() && t.dut.held);
            } else {
                assert(session.link_rate(2000000));
                t.change(SlowPeriod);
                assert(session.link_sync() && session.start() && !t.dut.held);
            }
            std::printf("PASS 32 MHz, %u bytes, high/low %u/%u, %s, DATA cycles %llu, retries %u\n",
                        run.bytes,run.high,run.low,
                        scenario == 0 ? "clean" : scenario == 1 ? "corrupt DATA and lost ACK" : "corrupt readback blocks START",
                        (unsigned long long)cycles,session.stats().retries);
        }
        return 0;
    }
    if(argc>1 && std::strcmp(argv[1],"--spi-benchmark")==0){
        std::uint64_t elapsed[2]{};
        for(unsigned half:{10u,5u}){
            Test t;t.spi_high_ticks=t.spi_low_ticks=half*30;
            Input input(65536);std::array<std::uint8_t,2*MaxFrame> buffer{};
            Session session({&t,Test::exchange,Test::send_frame,Test::receive_frame,nullptr,Test::poll_frame},95,buffer.data(),buffer.size());
            assert(session.begin(input.data.size()) && session.link_rate(8000000));
            t.change(FastPeriod);assert(session.link_sync() && session.negotiate_window());
            t.spi_ownership(true);
            auto start=t.cycles;
            assert(session.stream({&input,Input::read,nullptr}));
            elapsed[half==5]=t.cycles-start;
            t.spi_ownership(false);
            assert(session.finish() && session.link_rate(2000000));
            t.change(SlowPeriod);assert(session.link_sync() && session.start());
            assert(t.dut.writes==32768 && session.stats().retries==0);
        }
        assert(elapsed[1]<elapsed[0]);
        std::printf("SIMULATED 64KiB DATA/ACK cycles: SPI4=%llu SPI8=%llu reduction=%.2f%%\n",
            (unsigned long long)elapsed[0],(unsigned long long)elapsed[1],
            100.0*(elapsed[0]-elapsed[1])/elapsed[0]);
        return 0;
    }
    if(argc>1 && std::strcmp(argv[1],"--spi")==0){
        for(unsigned bytes:{16384u,2u*1024*1024,4u*1024*1024}){
            const bool corrupt=bytes==16384;
            Test t;
            if(corrupt){t.spi_high_ticks=120;t.spi_low_ticks=180;}
            else if(bytes==2097152){t.spi_high_ticks=180;t.spi_low_ticks=120;}
            Input input(bytes);
            std::array<std::uint8_t,2*MaxFrame> buffer{};
            Session session({&t,Test::exchange,Test::send_frame,Test::receive_frame,nullptr,Test::poll_frame},
                            91,buffer.data(),buffer.size());
            assert(session.begin(input.data.size()) && session.link_rate(8000000));
            t.change(FastPeriod);
            assert(session.link_sync() && session.negotiate_window() && !t.dut.spi_selected);
            t.spi_ownership(true);
            // A deselected byte and a three-bit interrupted transaction must not enter ROM.
            t.spi_byte(0xaa);t.dut.spi_cs_n=0;t.step(12);
            for(int i=0;i<3;++i){t.dut.spi_sck=1;t.step(10);t.dut.spi_sck=0;t.step(10);}
            t.dut.spi_cs_n=1;t.step(12);
            t.damage=t.lose_data=true;
            assert(session.stream({&input,Input::read,nullptr}) && session.stats().retries>0);
            assert(t.dut.writes==bytes/2 && t.dut.headers==64);
            std::printf("SPI pin-level stream %u bytes, writes=%u, retries=%u\n",bytes,unsigned(t.dut.writes),unsigned(session.stats().retries));
            t.spi_ownership(false);t.dut.corrupt_read=corrupt;
            assert(session.finish()!=corrupt);
            if(corrupt){assert(!session.start() && t.dut.held);}
            else{
                assert(session.link_rate(2000000));t.change(SlowPeriod);
                assert(session.link_sync() && session.start() && !t.dut.held);
            }
        }
        std::puts("PASS MODE1 8 MHz SPI DATA (40/60 and 60/40 duty included), UART ACK, CRC retry, lost ACK, partial CS, readback failure and verified START");
        return 0;
    }
    const bool benchmark_only=argc>1&&std::strcmp(argv[1],"--benchmark")==0;
    if(!benchmark_only){
        auto t=std::make_unique<Test>();Input input(16384);std::array<std::uint8_t,MaxFrame> buffer{};
        Session session({t.get(),Test::exchange},17,buffer.data(),buffer.size());
        assert(session.begin(input.data.size()));assert(session.link_rate(8000000));t->change(FastPeriod);assert(session.link_sync());
        t->damage=true;t->lose_data=true;t->lose_end=true;
        assert(session.stream({&input,Input::read,nullptr}));assert(session.finish());assert(t->dut.held);
        assert(session.link_rate(2000000));t->change(SlowPeriod);assert(session.link_sync());
        assert(session.start());assert(!t->dut.held&&t->dut.writes==8192&&t->dut.headers==64);
        std::puts("Serial 2 -> 8 -> 2 Mbit/s: continuous 8N1, 16 KiB, CRC damage, lost DATA/END ACK with full 50 ms/10 s timeout, SDRAM readback and START passed");std::fflush(stdout);
    }

    std::uint64_t elapsed[2]{};
    for(unsigned window=0;window<2;++window){
        auto t=std::make_unique<Test>();Input input(65536);std::array<std::uint8_t,2*MaxFrame> buffer{};
        Session s({t.get(),Test::exchange,Test::send_frame,Test::receive_frame,nullptr,Test::poll_frame},60+window,buffer.data(),buffer.size());
        assert(s.begin(input.data.size())&&s.link_rate(8000000));t->change(FastPeriod);assert(s.link_sync());
        if(window)assert(s.negotiate_window());
        const auto begin=t->cycles;assert(s.stream({&input,Input::read,nullptr}));elapsed[window]=t->cycles-begin;
        if(window)assert(t->overlap>0);
        assert(s.finish()&&s.link_rate(2000000));t->change(SlowPeriod);assert(s.link_sync()&&s.start());
        assert(t->dut.writes==32768&&t->dut.headers==64);
    }
    assert(elapsed[1]<elapsed[0]);
    std::printf("UART8 serial 64KiB DATA-ACK cycles: stop_wait=%llu window2=%llu reduction=%.2f%%\n",
        (unsigned long long)elapsed[0],(unsigned long long)elapsed[1],100.0*(elapsed[0]-elapsed[1])/elapsed[0]);
    if(benchmark_only)return 0;
    {
        auto t=std::make_unique<Test>();Input input(8192);std::array<std::uint8_t,2*MaxFrame> buffer{};
        Session s({t.get(),Test::exchange,Test::send_frame,Test::receive_frame,nullptr,Test::poll_frame},62,buffer.data(),buffer.size());
        assert(s.begin(input.data.size())&&s.link_rate(8000000));t->change(FastPeriod);assert(s.link_sync()&&s.negotiate_window());
        t->damage=t->lose_data=true;assert(s.stream({&input,Input::read,nullptr}));assert(s.stats().retries>0);
        assert(s.finish()&&s.link_rate(2000000));t->change(SlowPeriod);assert(s.link_sync()&&s.start());
        assert(t->dut.writes==4096);std::puts("UART8 window2: damaged DATA plus lost oldest ACK passed");
    }
    {
        auto t=std::make_unique<Test>();Input input(1024);std::array<std::uint8_t,MaxFrame> buffer{};
        Session session({t.get(),Test::exchange},18,buffer.data(),buffer.size());
        assert(session.begin(input.data.size()));t->lose_rate=true;assert(!session.link_rate(8000000));
        t->step(Clock+100); // actual one-second receiver watchdog, not a scaled model
        assert(!t->dut.at_fast&&t->dut.held);t->period=SlowPeriod;
        assert(!session.start());session.abort();assert(t->dut.held);
        std::puts("Lost rate-change ACK: bounded failure, watchdog restored 2 Mbit/s and retained game reset");
    }
    for(unsigned scale:{9800u,10200u}){
        auto t=std::make_unique<Test>();Input input(4096);std::array<std::uint8_t,MaxFrame> buffer{};
        t->sender_scale=scale;t->step(17);
        Session session({t.get(),Test::exchange},20+scale,buffer.data(),buffer.size());
        assert(session.begin(input.data.size()));assert(session.link_rate(8000000));t->change(FastPeriod);assert(session.link_sync());
        assert(session.stream({&input,Input::read,nullptr}));assert(session.finish());
        assert(session.link_rate(2000000));t->change(SlowPeriod);assert(session.link_sync());assert(session.start());
        std::printf("Serial transmitter period %u/10000: 2/8 Mbit/s continuous receive passed\n",scale);
    }
    {
        auto t=std::make_unique<Test>();Input input(1024);std::array<std::uint8_t,MaxFrame> buffer{};
        Session session({t.get(),Test::exchange},44,buffer.data(),buffer.size());
        assert(session.begin(input.data.size()));assert(session.link_rate(8000000));t->change(FastPeriod);assert(session.link_sync());
        assert(session.stream({&input,Input::read,nullptr}));assert(session.finish());
        t->step(Clock*12+100); // actual verified-state watchdog, not a scaled model
        assert(!t->dut.at_fast&&t->dut.held);t->period=SlowPeriod;session.abort();
        std::puts("Verified END without START: twelve-second watchdog restored 2 Mbit/s and retained reset");
    }
}
