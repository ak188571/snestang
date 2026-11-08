#include "Vtb_load_row.h"
#include <cassert>
#include <string>

double sc_time_stamp(){ return 0; }

int main(){
    Vtb_load_row dut;
    auto tick=[&](){ dut.clk=0; dut.eval(); dut.clk=1; dut.eval(); };
    dut.resetn=0; dut.status=0; dut.frame_start=0; tick(); dut.resetn=1;
    auto write=[&](int col,int row,char c,bool both){
        dut.write_data=(col<<16)|(row<<8)|static_cast<unsigned char>(c);
        dut.write_ref=1; dut.write_actual=both; tick();
        dut.write_ref=dut.write_actual=0;
    };
    // Distinct nonblank underlying text exposes leaks and accidental RAM writes.
    for(int row=0;row<28;++row) for(int col=0;col<32;++col) write(col,row,'W',true);
    auto check=[&](int request,int visible){
        std::string line(32,visible?' ':'W');
        if(visible){
            std::string text=visible==1?"Preparing SNES core":
                visible==23?"Verifying ROM":"ROM transfer "+std::to_string((visible-2)*5)+"%";
            line.replace(1,text.size(),text);
        }
        for(int col=0;col<32;++col) write(col,27,line[col],false);
        dut.status=request; dut.frame_start=1; tick();
        dut.frame_start=0; dut.status=0; // No visible mid-frame changes.
        int yellow=0;
        for(int y=208;y<224;++y){
            dut.y=y;
            for(int x=0;x<256;++x){
                dut.x=x;
                for(int cycle=0;cycle<4;++cycle){
                    tick();
                    assert(dut.actual==dut.expected_color);
                    assert(bool(dut.load_row)==bool(visible && y>=216));
                    if(dut.load_row){
                        assert(dut.load_char==line[x/8]);
                        if(dut.actual==0x43ff) ++yellow;
                    }
                }
            }
        }
        assert(!visible || yellow>0);
    };
    check(0,0);
    for(int i=1;i<=21;++i) check(i,i);
    check(23,22); check(23,23); check(0,0);
    check(2,2); check(22,22); check(23,23); check(0,0);
}
