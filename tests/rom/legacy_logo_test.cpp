#include "Vtb_legacy_logo.h"
#include <cassert>
#include <vector>
double sc_time_stamp(){return 0;}
int main(){
    Vtb_legacy_logo dut;
    auto tick=[&](){dut.clk=0;dut.eval();dut.clk=1;dut.eval();};
    dut.resetn=0;dut.write_enable=0;tick();dut.resetn=1;
    auto write=[&](int x,int y,int value){
        dut.write_data=(x<<16)|(y<<8)|value;dut.write_enable=1;tick();dut.write_enable=0;
    };
    for(int row=0;row<28;++row)for(int col=0;col<32;++col)write(col,row,' ');
    const char *text="Preparing SNES core";
    for(int col=0;text[col];++col)write(col+1,27,text[col]);
    auto raster=[&](){
        std::vector<int> pixels;
        for(int y=200;y<224;++y)for(int x=0;x<256;++x){
            dut.x=x;dut.y=y;
            for(int cycle=0;cycle<4;++cycle)tick();
            pixels.push_back(dut.color);
        }
        return pixels;
    };
    auto before=raster();
    int logo=0;for(int y=201;y<215;++y)for(int x=92;x<164;++x)logo+=before[(y-200)*256+x]!=0;
    assert(logo>0);
    for(int row=28;row<32;++row)for(int col=0;col<32;++col)write(col,row,0);
    auto after=raster();
    int text_pixels=0;
    for(int y=201;y<215;++y)for(int x=92;x<164;++x)assert(after[(y-200)*256+x]==0);
    for(int y=216;y<224;++y)for(int x=0;x<256;++x){
        auto index=(y-200)*256+x;
        assert(before[index]==after[index]);
        text_pixels+=after[index]!=0;
    }
    assert(text_pixels>0);
}
