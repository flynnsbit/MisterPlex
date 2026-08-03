// RTL bank-selector boundary oracle — elaborates real ddr_frame_store.
// Host helpers alone cannot catch qword-floor / width-key / canvas-as-storage bugs.
//
// Vectors (exact-byte payload; host plxgI420PayloadBytes parity):
//   geom_off, 624x480, usable-exact 520192, usable+step, 720x482, 960x540,
//   canvas-trap 1280x720 storage wrong, w=968 reject, DE-only 1280 on 960 store.
// FAULT build (-DDDR_FRAME_STORE_FAULT_FORCE_LEGACY_BANK_MAP): 960x540 must
// stay legacy (REPRO_OK). GOOD: Option-C + U@518400.

#include "Vddr_frame_store_selector_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

constexpr uint32_t kLegBasePhys = 0x30000000u;
constexpr uint32_t kOptcBasePhys = 0x30180000u;
constexpr uint32_t kLegDoorbellPhys = 0x300FF000u;
constexpr uint32_t kOptcDoorbellPhys = 0x3047F000u;
constexpr uint32_t kUsable = 520192u;
constexpr uint32_t kLegBaseW0 = kLegBasePhys >> 3;
constexpr uint32_t kOptcBaseW0 = kOptcBasePhys >> 3;
constexpr uint32_t kLegDoorbellW = kLegDoorbellPhys >> 3;
constexpr uint32_t kOptcDoorbellW = kOptcDoorbellPhys >> 3;

// Mirror host/RTL: y_stride*h + chroma_stride*h  (== Y + U + V for 4:2:0).
static uint32_t i420Bytes(uint32_t ys, uint32_t cs, uint32_t h) {
	return ys * h + cs * h;
}

struct Sim {
	Vddr_frame_store_selector_tb top{};

	Sim() {
		// Never memset a Verilated model (destroys C++ members → SIGSEGV).
		top.clk = 0;
		top.clk_ddr = 0;
		top.reset = 0;
		top.geom_enable = 0;
		top.q5_reserved_reject = 0;
		top.rt_coded_w = 0;
		top.rt_coded_h = 0;
		top.rt_y_stride = 0;
		top.rt_chroma_stride = 0;
		top.rt_display_w = 0;
		top.rt_display_h = 0;
		top.rt_present_x = 0;
		top.rt_present_y = 0;
		top.rt_crop_left = 0;
		top.rt_crop_top = 0;
		top.DDRAM_BUSY = 0;
		top.DDRAM_DOUT = 0;
		top.DDRAM_DOUT_READY = 0;
	}

	void tick() {
		top.clk = 0;
		top.clk_ddr = 0;
		top.eval();
		top.clk = 1;
		top.clk_ddr = 1;
		top.eval();
	}

	void resetCycles(int n = 4) {
		top.reset = 1;
		for (int i = 0; i < n; ++i)
			tick();
		top.reset = 0;
		for (int i = 0; i < 4; ++i)
			tick();
	}

	void driveGeom(bool en, int cw, int ch, int ys, int cs, int dw = 0, int dh = 0,
	               int crop_l = 0, int crop_t = 0, int pres_x = 0, int pres_y = 0) {
		top.geom_enable = en ? 1 : 0;
		top.rt_coded_w = cw;
		top.rt_coded_h = ch;
		top.rt_y_stride = ys;
		top.rt_chroma_stride = cs;
		top.rt_display_w = dw;
		top.rt_display_h = dh;
		top.rt_present_x = pres_x;
		top.rt_present_y = pres_y;
		top.rt_crop_left = crop_l;
		top.rt_crop_top = crop_t;
		// Registered path: settle a few clocks.
		for (int i = 0; i < 6; ++i)
			tick();
	}
};

struct Expect {
	const char* name;
	bool en;
	int cw, ch, ys, cs;
	int dw, dh;
	bool want_raw_ok;
	bool want_optc; // registered eff_optc_map (product); FAULT forces 0 when en&&raw
	uint32_t want_payload;
	uint32_t want_u_bytes; // only checked when geom_en_r
	bool check_u;
};

static int g_fails = 0;

static void check_case(Sim& sim, const Expect& e, bool fault_force_legacy) {
	sim.driveGeom(e.en, e.cw, e.ch, e.ys, e.cs, e.dw, e.dh);

	const bool raw_ok = sim.top.obs_raw_ok != 0;
	const bool need = sim.top.obs_need_optc != 0;
	const bool optc = sim.top.obs_optc_map != 0;
	const bool gen = sim.top.obs_geom_en_r != 0;
	const uint32_t payload = sim.top.obs_payload_bytes;
	const uint32_t base = static_cast<uint32_t>(sim.top.obs_base_w0);
	const uint32_t db = static_cast<uint32_t>(sim.top.obs_doorbell_w);
	const uint32_t u_qw = static_cast<uint32_t>(sim.top.obs_u_base_qw);
	const uint32_t v_qw = static_cast<uint32_t>(sim.top.obs_v_base_qw);
	const uint32_t u_bytes = u_qw * 8u;
	const uint32_t v_bytes = v_qw * 8u;

	const bool expect_optc =
	    fault_force_legacy ? false : e.want_optc;
	// When geom rejected or disabled, map is legacy regardless of need_optc wire.
	const bool expect_gen = e.en && e.want_raw_ok;
	const bool expect_map_optc = expect_gen && expect_optc;

	auto fail = [&](const char* msg) {
		std::cerr << "FAIL " << e.name << ": " << msg
		          << " raw_ok=" << raw_ok << " need=" << need << " optc=" << optc
		          << " gen=" << gen << " payload=" << payload
		          << " base_w0=0x" << std::hex << (base << 3) << std::dec
		          << " u_bytes=" << u_bytes << "\n";
		++g_fails;
	};

	if (raw_ok != e.want_raw_ok)
		fail("raw_ok mismatch");
	// Payload wire is pure arithmetic even when raw_ok=0; only demand host
	// parity on accepted geometries (reject path must not silently accept).
	if (e.want_raw_ok && e.en && payload != e.want_payload)
		fail("payload_bytes mismatch vs exact host arithmetic");
	if (gen != expect_gen)
		fail("geom_en_r mismatch");
	if (optc != expect_map_optc)
		fail(fault_force_legacy ? "FAULT must force legacy map"
		                        : "optc_map mismatch (capacity usable rule)");

	if (expect_map_optc) {
		if (base != kOptcBaseW0)
			fail("Option-C base_w0");
		if (db != kOptcDoorbellW)
			fail("Option-C doorbell");
	} else if (expect_gen || !e.en) {
		// legacy map (geom off or capacity-fit or FAULT)
		if (base != kLegBaseW0)
			fail("legacy base_w0");
		if (db != kLegDoorbellW)
			fail("legacy doorbell");
	}

	if (e.check_u && expect_gen && !fault_force_legacy) {
		if (u_bytes != e.want_u_bytes)
			fail("U plane base bytes (storage vs canvas trap)");
		// V = U + chroma plane = U + cs*(h/2)
		const uint32_t want_v = e.want_u_bytes + static_cast<uint32_t>(e.cs) * (static_cast<uint32_t>(e.ch) / 2u);
		if (v_bytes != want_v)
			fail("V plane base bytes");
		// Fetch counts: y=w/8, c=w/16 (requires w%16==0)
		if (static_cast<int>(sim.top.obs_y_fetch_qw) != e.cw / 8)
			fail("y_fetch_qw");
		if (static_cast<int>(sim.top.obs_c_fetch_qw) != e.cw / 16)
			fail("c_fetch_qw");
		if (static_cast<int>(sim.top.obs_coded_w) != e.cw ||
		    static_cast<int>(sim.top.obs_coded_h) != e.ch)
			fail("eff coded dims must be STORAGE not DE canvas");
	}

	// Combinational need_optc must track usable threshold whenever raw_ok.
	if (e.want_raw_ok && e.en) {
		const bool host_need = e.want_payload > kUsable;
		if (need != host_need)
			fail("rt_need_optc vs host usable threshold");
	}

	std::cout << "case " << e.name << " payload=" << payload << " optc=" << optc
	          << " u=" << u_bytes << " raw_ok=" << raw_ok << "\n";
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);

	const char* mode = std::getenv("SELECTOR_MODE");
	const bool fault = mode && std::string(mode) == "fault";
	const bool silent_geom = mode && std::string(mode) == "silent_geom";
	const bool leg_rebase_fault =
	    mode && std::string(mode) == "leg_rebase_fault";
	const bool expect_fresh = !fault && !silent_geom && !leg_rebase_fault;

	std::cout << "PRE-REGISTER selector fault=" << fault
	          << " silent_geom=" << silent_geom
	          << " usable=" << kUsable
	          << " expect_optc_960=" << (expect_fresh ? 1 : 0) << "\n";

	Sim sim;
	sim.resetCycles();

	// Red twin: silent reject path — raw_ok=0 but NO sticky 0xE2 (defect class).
	if (silent_geom) {
		sim.driveGeom(true, 468, 360, 468, 234, 468, 360);
		for (int i = 0; i < 8; ++i)
			sim.tick();
		if (sim.top.obs_raw_ok != 0 || sim.top.obs_geom_en_r != 0) {
			std::cerr << "FAIL silent twin setup: 468 must fail raw_ok\n";
			return 1;
		}
		// Defect: no loud marker — this is what product must NOT do.
		if (sim.top.obs_geom_reject_r != 0 || sim.top.obs_debug_state == 0xE2) {
			std::cerr << "FAIL silent twin: expected NO 0xE2 under FAULT_SILENT\n";
			return 1;
		}
		// Still on legacy bank map (silent fallthrough).
		if (sim.top.obs_base_w0 != kLegBaseW0) {
			std::cerr << "FAIL silent twin: expected legacy base\n";
			return 1;
		}
		std::cout << "REPRO_OK silent_geom: 468x360 raw_ok=0 geom_en=0 no 0xE2 "
		          << "debug=0x" << std::hex << (int)sim.top.obs_debug_state
		          << std::dec << " (silent legacy fallthrough)\n";
		return 0;
	}

	// RED TWIN: compile-time LEG→Option-C rebase under OPTION_C — geom_off
	// must NOT match host legacy doorbell (this is the rd-duck defect).
	if (leg_rebase_fault) {
		sim.driveGeom(false, 0, 0, 0, 0, 0, 0);
		const uint32_t base = static_cast<uint32_t>(sim.top.obs_base_w0) << 3;
		const uint32_t db = static_cast<uint32_t>(sim.top.obs_doorbell_w) << 3;
		std::cout << "MEASURED leg_rebase_fault geom_off base=0x" << std::hex
		          << base << " db=0x" << db << std::dec << "\n";
		// Defect: LEG rebased → Option-C phys/doorbell while geom off.
		if (base == kOptcBasePhys && db == kOptcDoorbellPhys) {
			std::cout << "REPRO_OK leg_rebase: geom_off on Option-C map "
			          << "(host still rings legacy 0x300FF000)\n";
			return 0;
		}
		std::cerr << "FAIL leg_rebase twin: expected Option-C LEG rebase on geom_off\n";
		return 1;
	}

	// Realizable usable-exact: h=512, ys=680, cs=336, w=672 → 512*(680+336)=520192
	const uint32_t exact_payload = i420Bytes(680, 336, 512);
	// Next 8-aligned stride bump: ys=688 → 512*1024=524288 (> usable, still < full
	// would-be if someone keyed on stride alone wrong — still Option-C).
	const uint32_t over_payload = i420Bytes(688, 336, 512);
	// Smallest step over exact with h=2, 8-aligned strides: 2*(260096+8)=520208
	// ys=173408? too wide. Use 720x482 product edge instead (520560).

	const Expect cases[] = {
	    // name, en, cw, ch, ys, cs, dw, dh, raw_ok, optc, payload, u_bytes, check_u
	    {"geom_off_legacy", false, 0, 0, 0, 0, 0, 0, false, false, 0, 0, false},
	    {"prod_624x480", true, 624, 480, 624, 312, 618, 480, true, false, 449280u,
	     299520u, true},
	    {"usable_exact_520192", true, 672, 512, 680, 336, 672, 512, true, false,
	     exact_payload, 680u * 512u, true},
	    {"usable_over_524288", true, 672, 512, 688, 336, 672, 512, true, true,
	     over_payload, 688u * 512u, true},
	    {"edge_720x482", true, 720, 482, 720, 360, 720, 482, true, true, 520560u,
	     720u * 482u, true},
	    {"prod_960x540", true, 960, 540, 960, 480, 960, 540, true, true, 777600u,
	     518400u, true},
	    // display > coded must REJECT (was silently accepted; OOB src_x risk)
	    {"reject_display_gt_coded", true, 960, 540, 960, 480, 1280, 720, false,
	     false, 777600u, 0, false},
	    // Canvas-as-storage trap: if coded wrongly set to 1280x720 → U@921600 Option-C
	    {"trap_canvas_as_storage", true, 1280, 720, 1280, 640, 1280, 720, true, true,
	     1382400u, 921600u, true},
	    // w%16: 968 is 8-aligned but chroma >>4 drops 4B — must REJECT
	    {"reject_w968", true, 968, 540, 968, 488, 968, 540, false, false,
	     i420Bytes(968, 488, 540), 0, false},
	    {"reject_odd_h", true, 960, 541, 960, 480, 960, 541, false, false, 0, 0,
	     false},
	    {"reject_zero", true, 0, 540, 960, 480, 0, 0, false, false, 0, 0, false},
	        // PMS AR-fit boxes (parent survey) — must loud-reject, not silent legacy
	        {"pms_468x360", true, 468, 360, 468, 234, 468, 360, false, false, 0, 0,
	         false},
	        {"pms_426x240", true, 426, 240, 426, 213, 426, 240, false, false, 0, 0,
	         false},
	    };

	// Sanity host arithmetic
	if (exact_payload != kUsable) {
		std::cerr << "FAIL fixture exact_payload=" << exact_payload
		          << " != usable " << kUsable << "\n";
		return 2;
	}
	if (i420Bytes(960, 480, 540) != 777600u || i420Bytes(720, 360, 482) != 520560u) {
		std::cerr << "FAIL fixture I420 arithmetic\n";
		return 2;
	}

	for (const auto& e : cases)
		check_case(sim, e, fault);

	if (fault) {
		// Explicit REPRO marker for shell
		sim.driveGeom(true, 960, 540, 960, 480, 960, 540);
		if (sim.top.obs_optc_map != 0 || sim.top.obs_base_w0 != kLegBaseW0) {
			std::cerr << "FAIL fault twin: 960x540 must stay legacy map\n";
			return 1;
		}
		std::cout << "REPRO_OK selector_fault: 960x540 forced legacy "
		          << "payload=" << sim.top.obs_payload_bytes
		          << " need_optc=" << (int)sim.top.obs_need_optc << "\n";
		return g_fails ? 1 : 0;
	}

	// Product: 960 must be Option-C with storage U base (display=coded, not DE canvas)
	sim.driveGeom(true, 960, 540, 960, 480, 960, 540);
	if (sim.top.obs_optc_map == 0 || sim.top.obs_u_base_qw * 8u != 518400u) {
		std::cerr << "FAIL product 960x540 Option-C U@518400\n";
		return 1;
	}
	// usable-1 pure byte threshold is host-side; RTL need_optc on exact fixture
	if (sim.top.obs_need_optc == 0) {
		std::cerr << "FAIL product need_optc\n";
		return 1;
	}

	// rd-duck crop/display window bounds (exact boundary):
	// crop_left + display_w == coded_w PASS; == coded_w+1 FAIL → loud E2.
	// 624×480, crop_l=10, display_w=614 → sum 624 PASS (geom_en_r).
	sim.driveGeom(true, 624, 480, 624, 312, 614, 480, /*crop_l*/10, /*crop_t*/0);
	if (sim.top.obs_raw_ok == 0 || sim.top.obs_geom_en_r == 0) {
		std::cerr << "FAIL crop boundary: 10+614==624 must accept raw_ok="
		          << (int)sim.top.obs_raw_ok << " en_r=" << (int)sim.top.obs_geom_en_r
		          << "\n";
		return 1;
	}
	std::cout << "MEASURED_CROP_EQ crop_l=10 disp_w=614 coded=624 raw_ok=1\n";
	// +1 over: crop_l=10, display_w=615 → sum 625 FAIL
	sim.driveGeom(true, 624, 480, 624, 312, 615, 480, /*crop_l*/10, /*crop_t*/0);
	if (sim.top.obs_raw_ok != 0 || sim.top.obs_geom_reject_now == 0 ||
	    sim.top.obs_geom_en_r != 0 || sim.top.obs_debug_state != 0xE2) {
		std::cerr << "FAIL crop+1: 10+615 must reject E2 raw_ok="
		          << (int)sim.top.obs_raw_ok
		          << " reject_now=" << (int)sim.top.obs_geom_reject_now
		          << " en_r=" << (int)sim.top.obs_geom_en_r
		          << " debug=0x" << std::hex << (int)sim.top.obs_debug_state
		          << std::dec << "\n";
		return 1;
	}
	std::cout << "MEASURED_CROP_PLUS1 crop_l=10 disp_w=615 reject E2\n";
	// B14 Direct-Part: coded 432 display 426 crop_left 2 (FFmpeg pad x=2).
	// Raw 426 is rejected above; padded storage must ACCEPT window (rd-duck).
	sim.driveGeom(true, 432, 240, 432, 216, 426, 240, /*crop_l*/ 2, /*crop_t*/ 0);
	if (sim.top.obs_raw_ok == 0 || sim.top.obs_geom_en_r == 0) {
		std::cerr << "FAIL B14 432/426/crop2 must accept raw_ok="
		          << (int)sim.top.obs_raw_ok << " en_r=" << (int)sim.top.obs_geom_en_r
		          << "\n";
		return 1;
	}
	if (sim.top.obs_payload_bytes != 155520u) {
		std::cerr << "FAIL B14 payload expect 155520 got " << sim.top.obs_payload_bytes
		          << "\n";
		return 1;
	}
	if (sim.top.obs_optc_map != 0) {
		std::cerr << "FAIL B14 155520 must stay LEG map\n";
		return 1;
	}
	std::cout << "MEASURED_B14_432_426 crop_l=2 disp=426 coded=432 raw_ok=1 payload=155520\n";
	// Identity 432/432/crop0 also raw_ok (self-consistent) but is metadata FAULT
	// for Direct-Part — host oracle rejects B14 predicate; store still accepts.
	sim.driveGeom(true, 432, 240, 432, 216, 432, 240, /*crop_l*/ 0, /*crop_t*/ 0);
	if (sim.top.obs_raw_ok == 0) {
		std::cerr << "FAIL identity 432 window must raw_ok (self-consistent)\n";
		return 1;
	}
	// crop2 + display 432 → 434 > 432 must reject
	sim.driveGeom(true, 432, 240, 432, 216, 432, 240, /*crop_l*/ 2, /*crop_t*/ 0);
	if (sim.top.obs_raw_ok != 0 || sim.top.obs_geom_reject_now == 0) {
		std::cerr << "FAIL B14 neg: crop2+disp432 must reject\n";
		return 1;
	}
	std::cout << "MEASURED_B14_NEG crop2+disp432 reject\n";
	// Vertical: crop_t=0, dh=480, ch=480 PASS; crop_t=1 FAIL
	sim.driveGeom(true, 624, 480, 624, 312, 624, 480, 0, 0);
	if (sim.top.obs_raw_ok == 0) {
		std::cerr << "FAIL crop_t=0 full height must pass\n";
		return 1;
	}
	sim.driveGeom(true, 624, 480, 624, 312, 624, 480, 0, /*crop_t*/1);
	if (sim.top.obs_raw_ok != 0 || sim.top.obs_debug_state != 0xE2) {
		std::cerr << "FAIL crop_t+1: 1+480>480 must E2\n";
		return 1;
	}
	std::cout << "MEASURED_CROP_T_PLUS1 reject E2\n";
	// Mode exit clear sticky before next vectors
	sim.driveGeom(false, 0, 0, 0, 0, 0, 0);

	// Loud geom reject (0xE2): PMS 468x360 stays geom_en_r=0 and sticky E2.
	// Parent puzzle: w-scaler B5 saw accepted=168480 (=468*360). Measure pins.
	// PREDICTION: pin geom_enable=1, raw_ok=0, reject_now=1, enable_eff=0,
	//             eff_coded stays legacy (not 468), debug=E2, payload from
	//             combinational rt_* may still report 468*360 math.
	sim.driveGeom(true, 468, 360, 468, 234, 468, 360);
	for (int i = 0; i < 8; ++i)
		sim.tick();
	const uint32_t pay468 = 468u * 360u + 2u * (234u * 180u); // 252720 I420
	const uint32_t luma468 = 468u * 360u; // 168480 — counter trap if request-counted
	std::cout << "MEASURED_468"
	          << " geom_enable_pin=" << (int)sim.top.obs_geom_enable_pin
	          << " rt_raw_ok=" << (int)sim.top.obs_raw_ok
	          << " geom_reject_now=" << (int)sim.top.obs_geom_reject_now
	          << " geom_enable_eff=" << (int)sim.top.obs_geom_enable_eff
	          << " geom_en_r=" << (int)sim.top.obs_geom_en_r
	          << " geom_reject_r=" << (int)sim.top.obs_geom_reject_r
	          << " debug=0x" << std::hex << (int)sim.top.obs_debug_state << std::dec
	          << " eff_cw=" << (int)sim.top.obs_coded_w
	          << " eff_ch=" << (int)sim.top.obs_coded_h
	          << " rt_payload=" << sim.top.obs_payload_bytes
	          << " luma468_trap=" << luma468
	          << " i420_468=" << pay468
	          << "\n";
	if (sim.top.obs_geom_enable_pin != 1) {
		std::cerr << "FAIL measure: geom_enable pin must be 1 under driveGeom(true)\n";
		return 1;
	}
	if (sim.top.obs_raw_ok != 0 || sim.top.obs_geom_reject_now != 1 ||
	    sim.top.obs_geom_enable_eff != 0) {
		std::cerr << "FAIL measure: expect raw_ok=0 reject_now=1 enable_eff=0\n";
		return 1;
	}
	if (sim.top.obs_geom_en_r != 0) {
		std::cerr << "FAIL loud reject: 468x360 must not latch geom_en_r\n";
		return 1;
	}
	// Accepted path uses legacy dims when reject — not 468.
	if (sim.top.obs_coded_w == 468 || sim.top.obs_coded_h == 360) {
		std::cerr << "FAIL measure: eff_coded took rejected 468x360 (store bug)\n";
		return 1;
	}
	if (sim.top.obs_geom_reject_r == 0 || sim.top.obs_debug_state != 0xE2) {
		std::cerr << "FAIL loud reject: expect sticky 0xE2 debug_state got 0x"
		          << std::hex << (int)sim.top.obs_debug_state << std::dec
		          << " reject_r=" << (int)sim.top.obs_geom_reject_r << "\n";
		return 1;
	}
	// rt_payload may equal I420(468) combinationally — that is NOT acceptance.
	if (sim.top.obs_payload_bytes == luma468) {
		std::cerr << "NOTE: payload==luma468 would be counter trap; got i420 math\n";
	}
	std::cout << "MEASURED_468_VERDICT store_guard_holds"
	          << " (enable_eff=0 eff_coded!=468 debug=E2);"
	          << " if a TB prints accepted=168480 it is counting REQUEST not ACCEPTED"
	          << " or bypasses geom_enable_eff\n";
	// Mode exit clears sticky.
	sim.driveGeom(false, 0, 0, 0, 0, 0, 0);
	for (int i = 0; i < 8; ++i)
		sim.tick();
	if (sim.top.obs_geom_reject_r != 0 || sim.top.obs_debug_state == 0xE2) {
		std::cerr << "FAIL loud reject: geom_enable=0 must clear 0xE2\n";
		return 1;
	}

	// ABI#2 q5 reserved → PLXF 0xE4 (sticky, observable like 0xE2).
	sim.top.q5_reserved_reject = 1;
	for (int i = 0; i < 8; ++i)
		sim.tick();
	std::cout << "MEASURED_Q5_E4 debug=0x" << std::hex << (int)sim.top.obs_debug_state
	          << std::dec << "\n";
	if (sim.top.obs_debug_state != 0xE4) {
		std::cerr << "FAIL q5 reserved must surface as PLXF debug 0xE4 got 0x"
		          << std::hex << (int)sim.top.obs_debug_state << std::dec << "\n";
		return 1;
	}
	sim.top.q5_reserved_reject = 0;
	for (int i = 0; i < 8; ++i)
		sim.tick();
	if (sim.top.obs_debug_state == 0xE4) {
		std::cerr << "FAIL q5 E4 must clear when latch sticky drops\n";
		return 1;
	}
	std::cout << "PASS q5_reserved PLXF 0xE4 observable\n";

	if (g_fails) {
		std::cerr << "FAIL selector: " << g_fails << " checks\n";
		return 1;
	}
	// rd-duck: explicit disable / geom_off must stay true legacy even when
	// product QSF defines OPTION_C (this binary may be built -DOPTION_C).
	sim.driveGeom(false, 0, 0, 0, 0, 0, 0);
	{
		const uint32_t base = static_cast<uint32_t>(sim.top.obs_base_w0) << 3;
		const uint32_t db = static_cast<uint32_t>(sim.top.obs_doorbell_w) << 3;
		std::cout << "MEASURED_GEOM_OFF base=0x" << std::hex << base
		          << " db=0x" << db << std::dec
		          << " optc=" << (int)sim.top.obs_optc_map << "\n";
		if (sim.top.obs_optc_map != 0 || base != kLegBasePhys || db != kLegDoorbellPhys) {
			std::cerr << "FAIL geom_off must be true legacy 0x30000000/0x300FF000 "
			          << "(not Option-C) under product OPTION_C\n";
			return 1;
		}
	}

	std::cout << "PASS selector_product: usable edges + 960x540 Option-C "
	          << "U@518400 + w%16 reject + crop_window_E2 + loud_E2 + q5_E4\n";
	return 0;
}
