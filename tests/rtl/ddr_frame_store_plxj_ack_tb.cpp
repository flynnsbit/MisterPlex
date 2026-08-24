// PLXJ ACK: ioctl index 4 PLXA → ack_toggle → WE 0x3007F130.
// Analog Template: rd_active high (DE) with has_frame=0 must still ACK.
// Wrong index / non-PLXA magic must not WE (RED twin ignores those checks).
#include "Vddr_frame_store_plxj_ack_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static constexpr uint32_t kPlxjPhys = 0x3007F130u;
static constexpr uint32_t kL4PlxjPhys = 0x3047F130u;
static constexpr uint32_t kDoorbellPhys = 0x3001F000u; // TB DOORBELL_PHYS
static constexpr uint32_t kPlxhPhys = 0x3007F138u;
static constexpr uint32_t kMagicJ = 0x504C584Au;
static constexpr uint32_t kMagicA = 0x41584C50u;
static constexpr uint32_t kMagicK = 0x504C584Bu;
static constexpr int kWait = 8000;
// Leftover HDMI-era PLXK: token 3, YUV420P format in token[30:29]=1.
static constexpr uint64_t kLeftoverPlxk =
    (1ull << 61) | (3ull << 32) | static_cast<uint64_t>(kMagicK);

static void tick(Vddr_frame_store_plxj_ack_tb* t) {
	t->clk = 0;
	t->clk_ddr = 0;
	t->eval();
	main_time++;
	t->clk = 1;
	t->clk_ddr = 1;
	t->eval();
	main_time++;
}

static void service_idle_ddr(Vddr_frame_store_plxj_ack_tb* t) {
	t->DDRAM_BUSY = 0;
	t->DDRAM_DOUT_READY = 0;
	t->DDRAM_DOUT = 0;
	if (t->DDRAM_RD && !t->DDRAM_BUSY) {
		const uint32_t phys = ((uint32_t)t->DDRAM_ADDR) << 3;
		t->DDRAM_DOUT_READY = 1;
		if (phys == kDoorbellPhys)
			t->DDRAM_DOUT = kLeftoverPlxk;
		else if (phys == kPlxhPhys)
			t->DDRAM_DOUT = 0; // no live PLXH; analog is reset-snapshot OSD
		else
			t->DDRAM_DOUT = 0;
	}
}

struct PlxjWe {
	bool saw = false;
	bool saw_l4 = false;
	uint32_t phys = 0;
	uint32_t lo = 0;
	uint32_t hi = 0;
	uint8_t token = 0;
	uint16_t x = 0;
	uint16_t y = 0;
};

static void note_we(Vddr_frame_store_plxj_ack_tb* t, PlxjWe& we) {
	if (!t->DDRAM_WE || t->DDRAM_BUSY)
		return;
	const uint32_t phys = ((uint32_t)t->DDRAM_ADDR) << 3;
	const uint32_t lo = (uint32_t)(t->DDRAM_DIN & 0xffffffffull);
	const uint32_t hi = (uint32_t)(t->DDRAM_DIN >> 32);
	if (phys == kL4PlxjPhys && lo == kMagicJ)
		we.saw_l4 = true;
	if (phys == kPlxjPhys && lo == kMagicJ) {
		we.saw = true;
		we.phys = phys;
		we.lo = lo;
		we.hi = hi;
		we.x = (uint16_t)(hi & 0x0fffu);
		we.y = (uint16_t)((hi >> 12) & 0x0fffu);
		we.token = (uint8_t)(hi >> 24);
	}
}

static void idle(Vddr_frame_store_plxj_ack_tb* t, PlxjWe* we, int n) {
	for (int i = 0; i < n; i++) {
		service_idle_ddr(t);
		if (we)
			note_we(t, *we);
		tick(t);
	}
}

static void send_packet(Vddr_frame_store_plxj_ack_tb* t, PlxjWe* we,
                        uint16_t index, uint32_t magic, uint16_t x, uint16_t y,
                        uint8_t token) {
	uint8_t b[9] = {
		(uint8_t)(magic & 0xffu),
		(uint8_t)((magic >> 8) & 0xffu),
		(uint8_t)((magic >> 16) & 0xffu),
		(uint8_t)((magic >> 24) & 0xffu),
		(uint8_t)(x & 0xffu),
		(uint8_t)((x >> 8) & 0xffu),
		(uint8_t)(y & 0xffu),
		(uint8_t)((y >> 8) & 0xffu),
		token,
	};
	t->ioctl_index = index;
	t->ioctl_wr = 0;
	t->ioctl_dout = 0;
	t->ioctl_download = 1;
	idle(t, we, 2);
	for (int i = 0; i < 9; i++) {
		t->ioctl_dout = b[i];
		t->ioctl_wr = 1;
		service_idle_ddr(t);
		if (we)
			note_we(t, *we);
		tick(t);
		t->ioctl_wr = 0;
		idle(t, we, 1);
	}
	t->ioctl_download = 0;
	idle(t, we, 2);
}

static bool wait_we(Vddr_frame_store_plxj_ack_tb* t, PlxjWe& we, int max_c) {
	for (int i = 0; i < max_c; i++) {
		service_idle_ddr(t);
		note_we(t, we);
		tick(t);
		if (we.saw)
			return true;
	}
	return we.saw;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	auto top = std::make_unique<Vddr_frame_store_plxj_ack_tb>();
	auto* t = top.get();

	t->reset = 1;
	t->rd_active = 1; // analog Template DE high
	t->ioctl_download = 0;
	t->ioctl_wr = 0;
	t->ioctl_dout = 0;
	t->ioctl_index = 0;
	t->DDRAM_BUSY = 0;
	t->DDRAM_DOUT = 0;
	t->DDRAM_DOUT_READY = 0;
	idle(t, nullptr, 20);
	t->reset = 0;
	idle(t, nullptr, 40);
	// Leftover HDMI PLXK on every doorbell poll (token 3). Must not set
	// has_frame/swap before the first ACK, and must not starve ioctl-4 WE.
	idle(t, nullptr, 512);
	if (t->has_frame) {
		std::printf("FAIL leftover PLXK set has_frame before first ACK\n");
		// keep going; ACK miss is the product fail
	} else {
		std::printf("leftover PLXK: has_frame=0 before ACK (isolated)\n");
	}

	int fails = 0;
	if (t->has_frame)
		fails++;
	const uint8_t tog0 = t->ack_toggle ? 1 : 0;

	PlxjWe we4{};
	send_packet(t, &we4, 4, kMagicA, 4, 3, 4);
	if (!wait_we(t, we4, kWait)) {
		std::printf("FAIL PLXJ WE missing after ioctl index 4 PLXA (analog rd_active=1 has_frame=%u)\n",
		            (unsigned)t->has_frame);
		fails++;
	} else {
		const uint8_t tog1 = t->ack_toggle ? 1 : 0;
		if (tog1 == tog0) {
			std::printf("FAIL ack_toggle did not flip after PLXA (was %u)\n", tog0);
			fails++;
		}
		if (we4.token != 4 || we4.x != 4 || we4.y != 3) {
			std::printf("FAIL PLXJ payload token=%u x=%u y=%u want 4 4:3\n",
			            we4.token, we4.x, we4.y);
			fails++;
		}
		if (we4.phys != kPlxjPhys) {
			std::printf("FAIL PLXJ phys=0x%08X want 0x%08X\n", we4.phys, kPlxjPhys);
			fails++;
		}
		std::printf("GREEN ioctl4: toggle %u→%u WE phys=0x%08X token=%u %u:%u has_frame=%u\n",
		            tog0, tog1, we4.phys, we4.token, we4.x, we4.y,
		            (unsigned)t->has_frame);
	}
	if (we4.saw_l4) {
		std::printf("FAIL PLXJ WE at leftover L4 0x3047F130\n");
		fails++;
	}

	PlxjWe we5{};
	send_packet(t, &we5, 5, kMagicA, 4, 3, 5);
	wait_we(t, we5, 512);
	if (we5.saw) {
		std::printf("FAIL index 5 ioctl produced PLXJ WE token=%u (index must be 4)\n",
		            we5.token);
		fails++;
	} else {
		std::printf("index 5: no PLXJ WE (product)\n");
	}

	PlxjWe webad{};
	send_packet(t, &webad, 4, 0x41414141u, 4, 3, 6);
	wait_we(t, webad, 512);
	if (webad.saw) {
		std::printf("FAIL non-PLXA magic produced PLXJ WE token=%u\n", webad.token);
		fails++;
	} else {
		std::printf("non-PLXA magic: no PLXJ WE (product)\n");
	}

	if (fails) {
		std::printf("FAIL ddr_frame_store_plxj_ack: %d failure(s)\n", fails);
		return 1;
	}
	std::printf("OK plxj ack: toggle then WE 0x3007F130 token=4 analog-DE leftover-PLXK isolated\n");
	return 0;
}
