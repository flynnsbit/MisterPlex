# PLXF_PRODUCT_WRITER — MAGIC_F at doorbell+0x118 (sibling + hunks)

**Worker:** D-plxf-product · **2026-08-14T19:33Z**
**DESIGN_OK + sibling RTL + TB_OK.** Live store **not** edited this tick.
**DESIGN_OK ≠ unique-24 ≠ FIT_GO ≠ BUILD_OK.** Soft-skip ≠ PASS.
**unique24=FAIL.** **FIT_GO=NO** from this card. Do **not** Quartus. Do **not** n29.
Do **not** loosen host MAGIC_F to **+0x110**.

SoT: `/home/shawn/Projects/MisterPlex-wt-480p-lessons`

---

## Verdict

| | |
|--|--|
| **Name** | **`PRODUCT_PLXF_WRITER`** |
| **This tick** | Sibling writer **ready**. Exact store hunks **ready**. Live `sdram_i420_store.sv` **untouched** |
| **Why no live edit** | This tick: do **not** apply. CEA wrap is now **FREE / TERMINAL** (`347bb7ea`, parent **BUILD_OK_CEA + PLAY_GO_CEA**). Applying would **DRIFT** live SRC vs CEA RBF freeze **`8dc97b71`**. Parent play CEA first. **FIT_GO=NO** until parent stamp |
| **unique24** | **FAIL.** Lab **`d8d376f2` 7.18**. Silicon MAGIC_F still **+0x110** |
| **FIT_GO / Quartus / play** | **NO** |
| **Host** | Keep `plxfPhys = doorbell_phys + 0x118`. Do **not** loosen |

---

## Why shared `iss_*` still publishes F at +0x110

Live product store **`8dc97b71`** (pagefill / CEA freeze) already has:

```
FRAME_MAILBOX_PHYS = DOORBELL_PHYS + 32'h118   // L103
iss_addr <= FRAME_MAILBOX_W                    // L884 D_IDLE F arm
D_BURST_ISS: DDRAM_ADDR <= iss_addr; DDRAM_WE <= iss_we  // L928–931
```

That is n20-class **registered pair then WE** on a **shared** `output reg DDRAM_ADDR/WE`.
PAGEFILL play **`d8d376f2`**: `MAGIC_F_AT_118=NO` `MAGIC_F_AT_110=YES`
(`PEEK_PLXM=46584c5002000000`). **PAGEFILL DID_NOT_MOVE_F.**

n25–n28 closed PHYS offset / F-only / no-retime / PLUS8 on `ddr_frame_store`.
Leftover is **`WE_WITHOUT_ADDR_COMMIT`**: port WE and ADDR are different enables.
This is **not** another n29 exclusive on `ddr_frame_store`. Product file is
`sdram_i420_store.sv`.

---

## Why not n29

| n29 leftover | This product writer |
|--------------|---------------------|
| `ddr_frame_store.sv` `S_MBOX_ISS` | **Not** that file. Live product is `sdram_i420_store.sv` |
| PHYS+8 / MAGIC retarget / ROM | Hardwired `DOORBELL_PHYS+0x118` only |
| Shared `iss_*` / `DDRAM_*` flops | Own `addr_r` / `din_r` / `we_r`; mux only while `fw_we` |
| Mailbox experiment loop (L57) | One-shot WE + `wait_r` until parent drops `arm` |

**L57:** do not run n17–n29 mailbox loops. Host abort on +0x118 empty is **CORRECT**.

---

## Design (sibling already on disk)

`sdram_i420_plxf_writer.sv`:

- **Every** `clk_ddr` beat: `addr_r <= PLXF_W` where `PLXF_W = (DOORBELL+0x118)[31:3]` = `0x608FE23` on L4 (`0x3047F000`).
- **Never** `+0x110` (`0x608FE22`). Writer source has **no** `0x110` token.
- **DIN:** `{payload[63:32], MAGIC_F}` registered every beat. Lo is forced `0x504C5846`.
- **Own WE:** one-cycle `we_r`. `wait_r` holds until `!arm && bus_idle` (parent `fw_ack` must drop `frame_mbox_req`).
- `(* keep, preserve *)` on ADDR/DIN/WE so Quartus cannot merge them into `iss_addr`.

---

## Instance sites — apply AFTER CEA play (parent stamp). **Not this tick.**

Recipe file: `fpga/Plex_MiSTer/rtl/sdram_i420_store.plxf.patch` (vs freeze **`8dc97b71`**).

### 1. Port split (live L45–52 `output reg` → wires)

```
output wire  [7:0] DDRAM_BURSTCNT,
output wire [28:0] DDRAM_ADDR,
output wire        DDRAM_RD,
output wire [63:0] DDRAM_DIN,
output wire        DDRAM_WE,
```

### 2. FSM regs + writer instance (after `iss_*` / `mailbox_d_din`)

```
reg        fsm_rd, fsm_we;
reg [28:0] fsm_addr;
reg [7:0]  fsm_bcnt;
reg [63:0] fsm_din;
wire [28:0] fw_addr;
wire [63:0] fw_din;
wire        fw_we;
wire        fw_ack;
wire        fw_issuing = fw_we;

assign DDRAM_ADDR     = fw_issuing ? fw_addr : fsm_addr;
assign DDRAM_WE       = fw_issuing ? 1'b1    : fsm_we;
assign DDRAM_DIN      = fw_issuing ? fw_din  : fsm_din;
assign DDRAM_RD       = fw_issuing ? 1'b0    : fsm_rd;
assign DDRAM_BURSTCNT = fw_issuing ? 8'd1    : fsm_bcnt;

sdram_i420_plxf_writer #(
	.DOORBELL_PHYS(DOORBELL_PHYS)
) u_plxf (
	.clk_ddr(clk_ddr),
	.reset(reset_ddr),
	.blank_ok(!rd_act_d2),
	.bus_idle(!DDRAM_BUSY && !fsm_rd && !fsm_we && (state_ddr == D_IDLE)),
	.arm(frame_mbox_req),
	.payload(mailbox_f_din),
	.fw_addr(fw_addr),
	.fw_din(fw_din),
	.fw_we(fw_we),
	.fw_ack(fw_ack)
);
```

`bus_idle` uses **`fsm_*` + `D_IDLE`**, never `DDRAM_WE` (no combo loop).

### 3. Park D_IDLE F arm (delete `iss_addr <= FRAME_MAILBOX_W` block)

Writer is the **only** MAGIC_F publisher. Heartbeat still sets `frame_mbox_req`;
`fw_ack` clears it and bumps `frame_mbox_seq`. Other issue paths (`J`/`D`/`I`/doorbell/DMA)
check `!fsm_rd && !fsm_we && !fw_we`. `D_BURST_ISS` writes **`fsm_*`**, not `DDRAM_*`.

### 4. QSF `SYSTEMVERILOG_FILE` line (via `files.qip`, **not** `Plex.qsf` / CEA QSF)

```
set_global_assignment -name SYSTEMVERILOG_FILE rtl/sdram_i420_plxf_writer.sv
```

Insert **after** `rtl/sdram_i420_store.sv` (live qip L25). Product `Plex.qsf` `source files.qip`.
**Do not** edit `Plex.qsf` / `Plex_720p24cea.qsf` this tick. **Not** in live `files.qip` now.

---

## Landed this tick (CEA-safe)

| Path | md5 | Role |
|------|-----|------|
| `fpga/Plex_MiSTer/rtl/sdram_i420_plxf_writer.sv` | **`50012e63ec3f01419da8a5769f03d465`** | Writer. Force MAGIC_F lo. `wait_r` until `!arm`. **Not** in `files.qip` |
| `fpga/Plex_MiSTer/rtl/sdram_i420_store.plxf.patch` | **`2a0fe386b49aee50331d106edbf2d7ef`** | Exact hunks vs freeze **`8dc97b71`** + qip line |
| `tests/rtl/sdram_i420_plxf_writer_tb.sv` | **`a2299030ed3868d1959a32e597b99c2e`** | WE ⇒ ADDR=`+0x118`, never PLXM; garbage lo still MAGIC_F |
| `tests/rtl/sdram_i420_plxf_writer_tb.sh` | **`1240a6c7df68380c2989a5739d9f9f93`** | iverilog wrapper + static ABI greps |

Live store **`8dc97b71620833ddacd4f52f0a11b4f6` UNTOUCHED**.
`sdram.sv` **`10ef07ea9b28ec9ed07bb929a06204d7` UNTOUCHED**.
`files.qip` **no** `plxf_writer` line.

---

## Evidence this tick

| Gate | Result |
|------|--------|
| Writer TB script | **RC=0** `PLXF_WRITER_TB=YES` |
| iverilog | **IVL_RC=0** |
| vvp | **VVP_RC=0** PASS `ADDR=doorbell+0x118 WE_own MAGIC_F` |
| PLXF_W | **`0x608fe23`** (never **`0x608fe22`**) |
| Patch `--dry-run -p1` on **copy** | **RC=0** |
| Patch apply on **copy** | **RC=0** copy store `547074c1` |
| iverilog `-t null -s sdram_i420_store` patched copy + writer + fifo + linebuf | **ELAB_RC=0** |
| Live store after | still **`8dc97b71`** · `u_plxf` count **0** |

Log: `build/iverilog/sdram_i420_plxf_writer/plxf_writer_tb.log`
**TB_OK ≠ unique-24.** **ELAB ≠ BUILD_OK.**

---

## Apply later (parent only; after CEA ONE play, new FIT_GO)

```bash
# only when parent stamps FIT_GO for PRODUCT_PLXF_WRITER
# live store must still be 8dc97b71 (CEA freeze) or restamp first
cd /home/shawn/Projects/MisterPlex-wt-480p-lessons
patch --dry-run -p1 < fpga/Plex_MiSTer/rtl/sdram_i420_store.plxf.patch
patch -p1 < fpga/Plex_MiSTer/rtl/sdram_i420_store.plxf.patch
tests/rtl/sdram_i420_plxf_writer_tb.sh
```

Do **not** apply during CEA play. Do **not** FIT from this card.

---

## Discriminators (future play — not this tick)

Host **must** keep MAGIC_F at **+0x118** (`arm/misterplexd/fpga_spi.cpp`:
`plxfPhys = ddrLayout_.doorbell_phys + 0x118u`).

| Branch | Peek | Next |
|--------|------|------|
| **SUCCESS** | `PEEK_PLXF` lo=`0x504C5846` **and** `PEEK_PLXM` **not** MAGIC_F | Then unique24 only if pfps≥23.9 **and** hw_fps≥23.9 **and** drops=0 **and** presented>0 |
| **FAIL still F@110** | MAGIC_F still +0x110, 118 empty | Writer-on-m0 leftover is **outside** store. Do **not** loosen host |
| **FAIL starve** | 110 and 118 empty | WE never landed. Keep F publish |

**SUCCESS ≠ unique-24.** F@118 ≠ 23.9. Last honest unique **j `968b828a` 14.1** / **n14 `00f36ca0` 7.23**. Pagefill **`d8d376f2` 7.18**.

---

## Honesty

- **unique24=FAIL.**
- Live store freeze **`8dc97b71` kept.** Writer **not** in live qip.
- CEA **TERMINAL** RBF **`347bb7ea`**. This worker **PLAY=NO**. **FIT_GO=NO.**
- **Not** n29. **Not** Quartus. **Not** host loosen. **Not** `/bin/fpga`.
- **DESIGN_OK ≠ unique-24.** **TB_OK ≠ unique-24.** **ELAB ≠ BUILD_OK.**
- **BUILD_OK_CEA ≠ unique-24.** **PLAY_GO_CEA ≠ apply this writer.**

---

## Backlog suggestion (W-docs owns PHASE_BACKLOG)

**P3-720P24 IN_PROGRESS / unique24 FAIL.**
**P3 DESIGN sibling ready** (`PRODUCT_PLXF_WRITER`). **FIT_GO=NO** until CEA
ONE play done **and** parent stamp. Do **not** n29. Do **not** loosen MAGIC_F.
