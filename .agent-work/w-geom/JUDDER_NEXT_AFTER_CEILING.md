# Judder next (post-ceiling) — p_d1, p_hold_d1 emit, residual hitch RTL, 907e handoff

**Ceiling closed (two lines):** source T7b `8fdf440f` + parent glass A/B.  
**This note:** open judder instrumentation + residual mechanisms.  
**RBF under discussion:** `8fdf440fbf4b8b51f5f98df559cc20e5` freeze  
`/home/flynnsbit/mplex-builds/fit-t7b-prog480/Plex_MiSTer/`  
**`ddr_frame_store.sv` md5:** `6c39218e83f30a888841b3e1e0e94d6d` · `true rc=0`  
**Prior soak pair for p_d1=0.0335 (parent):** RBF `78eff44e` + daemon `7c991e47` (same store md5 as 8fdf for PLXD pack).  
**Agent:** source/sim only.

---

## 1. Is `8fdf440f` a swap-counter RBF? What is p_d1=0.0335?

### RTL the daemon reads (freeze, quoted)

Increment — **only on successful bank swap**, not every vsync:

```systemverilog
// ddr_frame_store.sv:271-287 (fit-t7b-prog480)
if (vsync_pulse && swap_pending && pending_ready_s2) begin
    disp_bank <= pending_bank;
    ...
    frames_done <= frames_done + 16'd1;   // :284
    vsync_toggle <= ~vsync_toggle;
end else if (vsync_pulse) begin
    vsync_toggle <= ~vsync_toggle;        // vsync without swap: NO frames_done++
end
```

PLXD pack — **swap counter CDC**, not `bank_vsync_count`:

```systemverilog
// :1036-1043
// frames_done MUST be the real swap counter (not bank_vsync_count).
DDRAM_DIN <= {frames_done_d2,  // [63:48] real swaps (CDC)
              ...
```

`bank_vsync_count` still ++ on every CDC vsync (`:954`) but is **not** packed into PLXD[63:48].

**Verdict:** **`8fdf440f` IS a swap-counter RBF** for PLXD[63:48]. Same pack as `78eff44e` store (`6c39218e` identical).

### Expected `p_d1` under free-gate 1 doorbell → ≤1 swap per publish

| Field | Derivation |
|-------|------------|
| `p_d1` / `p_delta1` | frac(unwrap(Δ PLXD[63:48]) == 1) between consecutive **publish notes** |

Healthy free-gate: **`p_d1 ≈ 1.0`**, `mean_delta ≈ 1`, `p_delta_ge2 ≈ 0`, `fd_semantics=SWAP_COUNTER`.

### Parent `p_d1=0.0335` + `p_dge2=0.9639`

**Not expected** on a swap-counter RBF with one swap per present.

| Interpretation | Status |
|----------------|--------|
| “3.35% one-refresh holds” | **Invalid** (wrong field; retracted) |
| Expected healthy swap shape | **No** — opposite of swap-counter shape |
| Degenerate / tooling / old summary | **Likely** — daemon `7c991e47` log lacked `fd_semantics` / `mean_delta` / `p_hold_d*`; shape matches **vsync-pack classifier** (`LIKELY_VSYNC_PACKED` when p_delta1&lt;0.5) despite RTL packing swaps |
| Real multi-swap defect | **Unknown** until tip daemon prints `mean_delta` + `fd_semantics` on **8fdf440f** |

**Rule 0:** Source proves pack is swaps. Source does **not** prove why that soak printed 0.0335 — settle on device with tip daemon EOS lines (below). Do not treat 0.0335 as hitch rate or as proof pack is vsync.

---

## 2. What the daemon must emit for `p_hold_d1` (cheap, permanent)

### Already implemented in tip host + `media_player` (not in `7c991e47` build)

**Compute** (`host/libmisterplex/publish_swap_delta_ledger.hpp`):

```cpp
// :147-151
static int holdDFromIvMs(double iv_ms, double t_vsync_ms) {
    if (t_vsync_ms <= 0.0 || iv_ms <= 0.0) return -1;
    return static_cast<int>(std::llround(iv_ms / t_vsync_ms));
}
// note(): iv_ms from Δmono_us between publishes; hold_d = holdDFromIvMs(...);
// hold_d==1 → ++hold_d1
// summarize: p_hold_d1 = hold_d1 / hold_n
// alias: p_one_refresh_hold = p_hold_d1
// der string: "round(publish_iv_ms/T_vsync)==1"
```

**Sample path** (`arm/misterplexd/media_player.cpp`):

```cpp
// ~782-785 after successful present/publish
pubSwapDelta_.note(preUs, brs.frames_done,
                   swap_pending, free_mask, disp_bank);
// preUs = steady clock at publish (same path as interval ledger)
// brs.frames_done from lastPublishBankRelease (PLXD read inside sendDdrFrame)
```

**Emit** (session end — always on, no env):

```cpp
// media_player.cpp ~4591-4596
log(... pubSwapDelta_.formatSummaryLine("measured") + " phase=session_end");
log(... pubSwapDelta_.formatCompatAliasLine() + " phase=session_end");
log(... pubSwapDelta_.formatPhaseLine());
```

`formatSummaryLine` already includes  
`p_hold_d1=... p_hold_d2=... p_hold_d3=... p_hold_d_ge4=... cadence_verdict=... fd_semantics=... mean_delta=...`  
when tip headers are linked.

**Optional mid-session** (env, leave off by default):  
`MISTERPLEX_PUBLISH_INTERVAL_LOG=1` → every 240 pubs (`:788-798`).

### Parent deploy checklist (daemon only — no RBF)

1. Build/deploy misterplexd from tip (or any SHA that includes `publish_swap_delta_ledger.hpp` hold_d + EOS formatSummary).  
2. Confirm md5 **≠** `7c991e47`.  
3. EOS grep must show **all** of:
   - `p_hold_d1=` with derivation via `p_one_refresh_hold` / alias line  
   - `p_d1_is=delta_frames_done_eq1_NOT_hold_refresh`  
   - `fd_semantics=` (`SWAP_COUNTER` expected on 8fdf)  
   - `mean_delta=`  
   - `cadence_verdict=`  
4. Cost: one `note()` per successful publish (already have PLXD sample); a few floats at EOS. **Leave permanent.**

No RTL change required for `p_hold_d1`.

---

## 3. Remaining RTL mechanisms that can hitch at 480p (invisible to drops=0)

Ledger `drops=0 publish_misses=0 unaccounted=0 frames=presents` proves **ARM supply closed** — not that display hold cadence is 2/3 clean.

| Mechanism | Source | Drops frames? | Visible hitch? | Counter that catches it |
|-----------|--------|---------------|----------------|-------------------------|
| **No min-2 refresh interlock** | swap iff `vsync && swap_pending && pending_ready` only | No | **Yes** — 1-refresh hold RTL-legal | **`p_hold_d1`** / `p_one_refresh_hold` |
| **No intentional 3:2** | `avDecide` drift servo + 2 ms sleep; async free-gate swap | No (if on time) | **Yes** — irregular 2/3 even if mean_ms ideal | **`p_hold_d2/d3`**, `cad_alt_frac`, `cadence_verdict` |
| **Early/late ARM publish phase vs vsync** | doorbell anytime; swap next ready vsync | No if eventually published | **Yes** | **`p_hold_d*`** + `publish_interval` / disc `LATE_ARRIVAL` |
| **Late `pending_ready`** | prep incomplete → skip swap this vsync | No (holds old bank) | **Yes** — long hold | **`p_hold_d_ge4`**, `max_swap_stall` (sim); fabric stall not in FRAME_LEDGER |
| **Same-cycle doorbell drop (legacy)** | HOLDS=0 NBA clear | Can freeze / lose pending | Freeze class | **907e gate**; product HOLDS=1 on 8fdf |
| **true Drop path** | `avDecide` Drop | **Yes** | jump | **`drops`** (already 0 on soak) |
| **publish fail** | sendDdrFrame fail | miss | stutter | **`publish_misses` / residual** |

**Plain answer:** Yes — **cadence/hold mechanisms remain**, primarily **legal 1-refresh holds + non-3:2 free-gate**, not a second “drop” counter.  
**Catch with:** tip daemon **`p_hold_d1`** (and cadence_verdict), not FRAME_LEDGER drops.

---

## 4. 907e handoff to w-fit-1

### Status on deployed `8fdf440f`: **ALREADY INTEGRATED**

Freeze store md5 `6c39218e` includes:

```systemverilog
parameter bit SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC = 1'b1  // :49 product default
// :266-283 hold-across logic (907e5950)
```

**No new exclusive fit required for 907e** unless a future tree drops HOLDS.

### Exact diff (commit `907e5950` — already in freeze)

```diff
+ parameter bit SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC = 1'b1
  if (swap_req_s2 != swap_req_seen) begin
-   swap_pending <= 1'b1;
+   if (!(SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC
+         && vsync_pulse && swap_pending && pending_ready_s2))
+       swap_pending <= 1'b1;
  end
  if (vsync_pulse && swap_pending && pending_ready_s2) begin
-   swap_pending <= 1'b0;
+   if (SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC && (swap_req_s2 != swap_req_seen))
+       swap_pending <= 1'b1;
+   else
+       swap_pending <= 1'b0;
    frames_done <= frames_done + 16'd1;
```

### Sim gate (must FAIL before / PASS after)

```bash
./tests/unit/test_ddr_frame_store_scanout_sustained.sh
# A) holds=0 sticky=0 recycle=0 → REPRO_OK freeze
# B) holds=1 sticky=1 recycle=1 → PASS sustained swaps+motion
```

**This session (captured):**

| Leg | Result | true rc |
|-----|--------|---------|
| A broken (holds=0) | `REPRO_OK sustained_nosticky: freeze-class` · `broken rc=0` | **0** (script OK = repro succeeded) |
| B product (holds=1) | `PASS sustained_product: sustained swaps+motion fd_delta=240` · `good rc=0` | **0** |
| Whole script | `OK ddr_frame_store_scanout_sustained: REPRO_OK nosticky + PASS product` | **`true rc=0`** |

Markers required (not compile-only): `REPRO_OK sustained_nosticky`, `PASS sustained_product`, race model PASS.

### w-fit-1 action

1. **Confirm** next fit tree still has `SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC=1'b1` and gate in rollcall.  
2. **Do not** spend exclusive slot “adding 907e” — it rides `8fdf440f` already.  
3. If a branch reverts HOLDS, gate A must still REPRO and B must FAIL until restored.

---

## Bottom line for parent

1. **`8fdf440f` = swap-counter** (`frames_done++` on swap only; PLXD packs `frames_done_d2`).  
2. **`p_d1=0.0335` is not healthy swap shape** and is **not** hitch rate — remeasure with tip daemon `mean_delta`/`fd_semantics`/`p_hold_d1`.  
3. **Emit `p_hold_d1`:** deploy tip daemon; EOS already logs it via `formatSummaryLine` — permanent, cheap.  
4. **Residual hitch:** min-2 absent + no 3:2 free-gate — use **`p_hold_d1`**, not drops.  
5. **907e:** already on `8fdf440f`; gate **true rc=0** (REPRO + PASS); handoff = preserve, don’t re-fit.
