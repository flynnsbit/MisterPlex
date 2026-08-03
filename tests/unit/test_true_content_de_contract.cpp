// True content-DE contract for the ascal near-term fit (w-scaler).
//
// Parent requirement: core DE must be **exactly** content-sized (960×540 or
// 640×360), not a content island inside Template H_DE=529 or canvas 1280 DE.
// ascal iauto=1 sizes the input image from i_de edges (ascal.vhd); an island
// inside a large DE is faithfully upscaled → small picture on glass (dead end).
//
// This test is the integrator check w-nostub can run without a device:
//   - models ascal-measured (ihsize, ivsize) from DE high runs
//   - PASS only when DE extent == content extent and every DE pixel is content
//   - RED twin: island-in-large-DE MUST fail the same predicates
//
// true rc direct. Soft-skip ≠ PASS. What would fail it: island config scoring
// de_is_true_content==1, or true config scoring content_frac < 1.

#include <cstdint>
#include <cstdio>
#include <cstdlib>

static int g_fail = 0;
#define EXPECT(c, m)                                                                 \
	do {                                                                             \
		if (!(c)) {                                                                  \
			std::fprintf(stderr, "FAIL %s\n", m);                                    \
			++g_fail;                                                                \
		}                                                                            \
	} while (0)

// One progressive frame of DE + "is content pixel" flags.
// de[y][x]=1 means core asserts DE at that sample; content[y][x]=1 means the
// pixel carries store data (not forced black pad).
struct FrameModel {
	int h_total;
	int v_total;
	// Active region the beam can paint; we only model active+simple blank.
	const uint8_t *de;      // [v_total * h_total]
	const uint8_t *content; // same size; only meaningful where de==1
};

// ascal iauto: hsize from first..last DE on a line (max over lines);
// vsize from first..last line that has any DE (ascal i_hmax/i_hmin style).
static void ascal_iauto_size(const FrameModel &f, int *ih, int *iv, int *de_pix,
                             int *content_on_de)
{
	int hmin = 4095, hmax = -1;
	int vmin = 4095, vmax = -1;
	int nde = 0, ncont = 0;
	for (int y = 0; y < f.v_total; ++y) {
		int row_hmin = 4095, row_hmax = -1;
		int row_de = 0;
		for (int x = 0; x < f.h_total; ++x) {
			const int i = y * f.h_total + x;
			if (!f.de[i])
				continue;
			++nde;
			++row_de;
			if (x < row_hmin)
				row_hmin = x;
			if (x > row_hmax)
				row_hmax = x;
			if (f.content[i])
				++ncont;
		}
		if (row_de == 0)
			continue;
		if (y < vmin)
			vmin = y;
		if (y > vmax)
			vmax = y;
		if (row_hmin < hmin)
			hmin = row_hmin;
		if (row_hmax > hmax)
			hmax = row_hmax;
	}
	if (hmax < 0 || vmax < 0) {
		*ih = 0;
		*iv = 0;
	} else {
		*ih = hmax - hmin + 1;
		*iv = vmax - vmin + 1;
	}
	*de_pix = nde;
	*content_on_de = ncont;
}

// Contract predicates (integrator checklist at present_core → sys_top).
struct DeContract {
	int content_w;
	int content_h;
	int ihsize; // ascal-measured
	int ivsize;
	int de_pixels;
	int content_on_de;
	int store_identity; // 1 if mapping is 1:1 (no stretch across larger DE)
	// derived
	int de_eq_content;
	int no_pad_inside_de;
	int content_frac_num; // content_on_de
	int content_frac_den; // de_pixels
	int true_content_de;  // all of the above
};

static DeContract evaluate(int cw, int ch, int ih, int iv, int de_pix, int cont_on_de,
                           int store_identity)
{
	DeContract c{};
	c.content_w = cw;
	c.content_h = ch;
	c.ihsize = ih;
	c.ivsize = iv;
	c.de_pixels = de_pix;
	c.content_on_de = cont_on_de;
	c.store_identity = store_identity;
	c.de_eq_content = (ih == cw && iv == ch && de_pix == cw * ch) ? 1 : 0;
	c.no_pad_inside_de = (de_pix > 0 && cont_on_de == de_pix) ? 1 : 0;
	c.content_frac_num = cont_on_de;
	c.content_frac_den = de_pix > 0 ? de_pix : 1;
#ifdef FAULT_ISLAND_PASSES
	// FAULT / red twin: accept any non-empty DE as "true content DE".
	// Island configs must still fail the product binary (this define off).
	c.true_content_de = (ih > 0 && iv > 0) ? 1 : 0;
#else
	c.true_content_de =
	    (c.de_eq_content && c.no_pad_inside_de && store_identity && ih > 0) ? 1 : 0;
#endif
	return c;
}

// Paint helpers into flat buffers.
static void clear(uint8_t *a, int n)
{
	for (int i = 0; i < n; ++i)
		a[i] = 0;
}

// TRUE: DE rectangle == content rectangle at (0,0)..(cw-1,ch-1); every DE is content.
// store_identity=1 (hc maps 1:1 into store while in DE).
static DeContract model_true_de(int cw, int ch, int h_total, int v_total)
{
	const int n = h_total * v_total;
	uint8_t *de = new uint8_t[n];
	uint8_t *co = new uint8_t[n];
	clear(de, n);
	clear(co, n);
	for (int y = 0; y < ch; ++y) {
		for (int x = 0; x < cw; ++x) {
			const int i = y * h_total + x;
			de[i] = 1;
			co[i] = 1;
		}
	}
	FrameModel f{h_total, v_total, de, co};
	int ih = 0, iv = 0, dp = 0, cc = 0;
	ascal_iauto_size(f, &ih, &iv, &dp, &cc);
	const DeContract out = evaluate(cw, ch, ih, iv, dp, cc, /*store_identity=*/1);
	delete[] de;
	delete[] co;
	return out;
}

// ISLAND (dead end): large DE (de_w × de_h) with content only in [0,cw)×[0,ch).
// store stretched across full DE (store_identity=0) — present_core Template class.
static DeContract model_island(int cw, int ch, int de_w, int de_h, int h_total,
                               int v_total)
{
	const int n = h_total * v_total;
	uint8_t *de = new uint8_t[n];
	uint8_t *co = new uint8_t[n];
	clear(de, n);
	clear(co, n);
	for (int y = 0; y < de_h; ++y) {
		for (int x = 0; x < de_w; ++x) {
			const int i = y * h_total + x;
			de[i] = 1;
			if (x < cw && y < ch)
				co[i] = 1; // content island; rest of DE is pad/black
		}
	}
	FrameModel f{h_total, v_total, de, co};
	int ih = 0, iv = 0, dp = 0, cc = 0;
	ascal_iauto_size(f, &ih, &iv, &dp, &cc);
	const DeContract out = evaluate(cw, ch, ih, iv, dp, cc, /*store_identity=*/0);
	delete[] de;
	delete[] co;
	return out;
}

static void print_contract(const char *tag, const DeContract &c)
{
	std::printf(
	    "CONTRACT %s cw=%d ch=%d ih=%d iv=%d de_pix=%d cont_on_de=%d "
	    "de_eq=%d no_pad=%d store_id=%d true_de=%d frac=%d/%d\n",
	    tag, c.content_w, c.content_h, c.ihsize, c.ivsize, c.de_pixels,
	    c.content_on_de, c.de_eq_content, c.no_pad_inside_de, c.store_identity,
	    c.true_content_de, c.content_frac_num, c.content_frac_den);
}

// present_core boundary checklist strings for integrators (must appear in PASS).
static const char *kChecklist[] = {
    "CHECK de_width_cycles == content_w",
    "CHECK de_height_lines == content_h",
    "CHECK every_DE_sample_is_content (no pad inside DE)",
    "CHECK store_x==hc and store_y==py inside DE (identity, not stretch)",
    "CHECK H_DE/win_h_de == content_w NOT 529 Template NOT 1280 canvas",
    "CHECK ascal_iauto ihsize/ivsize == content_w/h",
};

int main()
{
	std::printf(
	    "PREDICTION T1=true_960x540_passes T2=island_529_fails T3=island_1280_fails "
	    "T4=true_640x360_passes T5=frac_island_lt_1\n");

	// ---- Product film tier: true 960×540 ----
	const DeContract t960 = model_true_de(960, 540, /*ht*/ 1200, /*vt*/ 600);
	print_contract("true_960x540", t960);
	EXPECT(t960.true_content_de == 1, "true 960x540 is true_content_de");
	EXPECT(t960.ihsize == 960 && t960.ivsize == 540, "ascal sees 960x540");
	EXPECT(t960.de_pixels == 960 * 540, "DE pixel count == content area");
	EXPECT(t960.content_frac_num == t960.content_frac_den, "frac=1 on true DE");

	// ---- TV tier: true 640×360 ----
	const DeContract t640 = model_true_de(640, 360, 800, 400);
	print_contract("true_640x360", t640);
	EXPECT(t640.true_content_de == 1, "true 640x360 is true_content_de");
	EXPECT(t640.ihsize == 640 && t640.ivsize == 360, "ascal sees 640x360");

	// ---- RED: island 960×540 inside Template H_DE=529×480 (historical pad path) ----
	// Content wider than 529 cannot fit; classic dead end was smaller content in 529.
	// Model 320×240 content in 529×480 DE (documented quarter-glass class).
	const DeContract isl529 = model_island(320, 240, 529, 480, 800, 524);
	print_contract("island_320in529x480", isl529);
	EXPECT(isl529.true_content_de == 0, "island 529 must NOT pass true_content_de");
	EXPECT(isl529.ihsize == 529 && isl529.ivsize == 480, "ascal measures full Template DE");
	EXPECT(isl529.content_frac_num < isl529.content_frac_den, "pad inside DE");
	EXPECT(isl529.de_eq_content == 0, "DE ≠ content on island");

	// ---- RED: 960×540 island inside 1280×720 canvas DE (wrong "720p core" wiring) ----
	const DeContract isl1280 = model_island(960, 540, 1280, 720, 1650, 750);
	print_contract("island_960in1280x720", isl1280);
	EXPECT(isl1280.true_content_de == 0, "island 1280 must NOT pass true_content_de");
	EXPECT(isl1280.ihsize == 1280 && isl1280.ivsize == 720, "ascal measures canvas DE");
	EXPECT(isl1280.content_on_de == 960 * 540, "content pixels still 960x540");
	EXPECT(isl1280.de_pixels == 1280 * 720, "DE is full canvas");
	// Glass fraction after ascal identity-out would keep island; scale-up of whole DE
	// shrinks content share: 960/1280 * 540/720 = 0.5625 of output area.
	const double area_frac =
	    double(isl1280.content_on_de) / double(isl1280.de_pixels > 0 ? isl1280.de_pixels : 1);
	EXPECT(area_frac < 0.6 && area_frac > 0.5, "960-in-1280 content area frac ~0.5625");

	// ---- RED: 960 content width but H_DE left at 529 (partial island / crop class) ----
	const DeContract isl960_529 = model_island(960, 540, 529, 540, 800, 600);
	print_contract("de529_claim960", isl960_529);
	// DE is only 529 wide — ascal never sees 960; content beyond 529 is outside DE.
	EXPECT(isl960_529.ihsize == 529, "Template H_DE caps ascal ihsize at 529");
	EXPECT(isl960_529.true_content_de == 0, "claiming 960 with H_DE=529 is not true DE");

	// ---- Store identity rule ----
	// True DE requires identity mapping; stretch across larger DE is forbidden even
	// if someone painted content on every DE pixel by upscaling in ARM (defeats goal).
	EXPECT(t960.store_identity == 1, "true path store identity");
	EXPECT(isl1280.store_identity == 0, "island path is stretch (non-identity)");

	// ---- Integrator checklist emission (must be greppable in CI log) ----
	for (const char *line : kChecklist)
		std::printf("%s\n", line);

	// ---- Pre-registered prediction hits ----
	const int t1 = t960.true_content_de;
	const int t2 = (isl529.true_content_de == 0);
	const int t3 = (isl1280.true_content_de == 0);
	const int t4 = t640.true_content_de;
	const int t5 = (isl1280.content_frac_num < isl1280.content_frac_den);
	EXPECT(t1 && t2 && t3 && t4 && t5, "all true-DE predictions HIT");

	std::printf(
	    "CASE true_content_de_contract EXECUTED "
	    "pred=T1%d/T2%d/T3%d/T4%d/T5%d "
	    "true960=%d island529=%d island1280=%d true640=%d "
	    "finding=DE_extent_must_equal_content_ascal_iauto_from_i_de\n",
	    t1, t2, t3, t4, t5, t960.true_content_de, isl529.true_content_de,
	    isl1280.true_content_de, t640.true_content_de);

	if (g_fail) {
		std::printf("FAIL true_content_de_contract fails=%d\n", g_fail);
		return 1;
	}
	std::printf("PASS true_content_de_contract\n");
	return 0;
}
