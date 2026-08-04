#include "Vddr_publish_job_tb_top.h"
#include "verilated.h"
#include <cstdio>
static int fails;
#define CHECK(c,m) do{if(!(c)){std::fprintf(stderr,"FAIL %s\n",m);++fails;}}while(0)
int main(int argc,char**argv){
	Verilated::commandArgs(argc,argv);
	Vddr_publish_job_tb_top top; top.eval();
	CHECK(top.p480_fb==449280u,"480p bytes");
	CHECK(top.p480_dst0==0x30000000u,"480p bank0");
	CHECK(top.p480_dst1==0x30080000u,"480p bank1");
	CHECK(top.p480_legal,"480p legal");
	CHECK(top.p720_fb==1382400u,"720p bytes");
	CHECK(top.p720_dst0==0x30180000u,"720p bank0");
	CHECK(top.p720_legal,"720p legal");
	CHECK(top.p720_src_aligned,"staging src aligned");
	CHECK(!top.neg_legal,"NEGATIVE 720p-on-480p stride illegal");
	if(fails){std::printf("ddr_publish_job: %d FAIL\n",fails);return 1;}
	std::printf("ddr_publish_job: OK geom→job; neg rejected\n");
	return 0;
}
