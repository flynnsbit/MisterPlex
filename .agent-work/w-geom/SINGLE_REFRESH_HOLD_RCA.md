# Single-refresh hold RCA + 78eff44e PLXD pack (fitted artifacts)

**Lane:** w-geom  
**Branch/HEAD (repo):** `w-avsync-hdmi-measure` / see `git rev-parse`  
**Fit tree (authority for silicon):** `/home/flynnsbit/mplex-builds/fit-ceil-fd/`  
**RBF md5 (output_files/Plex.rbf):** `78eff44ed32c7ce35d648e3da5e2b93f` — matches parent “78eff44e”  
**Fitted `ddr_frame_store.sv` md5:** `6c39218e83f30a888841b3e1e0e94d6d`  
**Tip tree same file md5:** `6c39218e83f30a888841b3e1e0e94d6d` — **byte-identical to fit freeze**

---

## Field names (derivation)

| Name | Derivation |
|------|------------|
| `p_d0` / `p_d1` / `p_dge2` | Fraction of consecutive **publish notes** where unwrap(Δ PLXD[63:48] `frames_done`) is 0 / 1 / ≥2. **Not** display hold refreshes. |
| `p_hold_d1` | `round(publish_interval_ms / T_vsync) == 1` — **this** is the 1-refresh hold signal (tip ledger; may be absent on daemon `7c991e47`). |
| `frames` / `presents` / `drops` | ARM supply path only; no FPGA observe. |
| PLXD[63:48] on **78eff44e** | Packed `frames_done_d2` = CDC of `frames_done`, which increments **only** on bank swap (fitted source below). |
| PLXD[63:48] on **c5382bee** | Was `bank_vsync_count` (every vsync). |

**Parent reading `p_d1=0.0335` as “3.35% one-refresh holds” is a field-name error.**  
Under swap-counter semantics, **Δfd=1 is the healthy one-swap-per-publish case** (`p_d1` should be ~1.0).  
Tip alias: `p_d1_is=delta_frames_done_eq1_NOT_hold_refresh`.

---

## Candidate (a) — 907e same-cycle vsync+doorbell → early swap?

### Is 907e on 78eff44e?

**YES — it is in the fitted source.** Parent “NEVER FITTED” is **false for this RBF**.

Fitted `ddr_frame_store.sv:49`:
```systemverilog
parameter bit SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC = 1'b1
```

Fitted swap arm (`:260-287`):
```systemverilog
// Capture new doorbell before vsync-swap decision so a same-cycle collision
// can retain swap_pending for the newly latched bank (product).
// Legacy: both branches NBA-assigned swap_pending; the vsync clear
// won, consuming swap_req_seen while dropping the new pending frame.
if (swap_req_s2 != swap_req_seen) begin
    swap_req_seen <= swap_req_s2;
    pending_bank <= pending_bank_s2;
    if (!(SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC
          && vsync_pulse && swap_pending && pending_ready_s2))
        swap_pending <= 1'b1;
end

if (vsync_pulse && swap_pending && pending_ready_s2) begin
    // Uses pre-NBA pending_bank: the bank that was ready this cycle.
    // A same-cycle swap_req updates pending_bank for the *next* swap.
    disp_bank <= pending_bank;
    ...
    if (SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC
        && (swap_req_s2 != swap_req_seen))
        swap_pending <= 1'b1;   // re-arm NEW bank for NEXT vsync
    else
        swap_pending <= 1'b0;
    frames_done <= frames_done + 16'd1;
end
```

Commit message `907e5950` (repo): *hold swap_pending across same-cycle vsync+doorbell* so doorbell is **not dropped** (scanout freeze class under sustained ~24 fps). Gate: holds=0 REPRO freeze; holds=1 PASS.

### Does same-cycle consume swap “one refresh early” (shorten **prior** hold to 1)?

**KILLED.**

Timeline under HOLDS=1, same-cycle doorbell+vsync:

1. Pre-NBA: `swap_pending` names **old** ready bank A.  
2. Vsync arm: `disp_bank <= pending_bank` → **A goes on glass now** (this was already pending; not “early”).  
3. Same-cycle doorbell: `pending_bank` ← B; HOLDS leaves `swap_pending=1` for **B**.  
4. **B** swaps at the **next** vsync — not this one.

So 907e **extends** the new frame’s pending across the boundary; it does **not** pull the previous frame’s swap one refresh sooner than “next vsync after A was pending+ready.”

Legacy HOLDS=0 same-cycle: new doorbell **lost** → freeze (no B), not hitchy 1-hold of A.

**Verdict (a): not load-bearing for 1-refresh display holds. Clean kill.**

---

## Candidate (b) — missing min-2-refresh interlock

### Is 1-refresh hold RTL-legal?

**YES.**

Swap predicate (fitted, only gate):
```systemverilog
if (vsync_pulse && swap_pending && pending_ready_s2)
```

Grep of fitted RTL (`fit-ceil-fd/Plex_MiSTer/rtl/*.sv`): **no** `min_hold`, `hold_count`, `MIN_*REFRESH`, `disp_hold` interlock on the swap path.

`frames_done` increments once per successful swap; **no** “must wait N vsyncs since last swap” counter.

Therefore: doorbell → ready → **next** vsync swaps. If the following doorbell is armed in time for the **following** vsync, prior frame was on glass for **exactly one** refresh. **Legal by construction.**

### What would have to change (design sketch only — not implementing)

In `ddr_frame_store.sv` swap always-block (same FSM as above), e.g.:

- `reg [1:0] holds_since_swap;`  
- on swap: `holds_since_swap <= 0` then count up each `vsync_pulse`;  
- swap enable becomes  
  `vsync_pulse && swap_pending && pending_ready_s2 && (holds_since_swap >= 2'd1)`  
  after at least one full refresh already displayed…  
  (exact threshold: ≥2 displayed refreshes ⇒ suppress swap until `holds_since_swap >= 2`).

**Tradeoffs (not a fit request):** kills d1 hitch; adds min latency; at 30 fps ideal≈33 ms fights the floor; does **not** create true 3:2; can stack lag if publisher stays early. Better product path after disc: intentional 2/3 cadence or cadence-gated swap (see `test_cadence_swap_path` C5) — **after** ARM vs phase cause is scored.

**Verdict (b): load-bearing permission.** RTL **allows** the hitch; free-gate + publish/vsync phase is how you **get** it. Not a “race bug”; a **missing policy**.

---

## Also load-bearing (design gap, not RTL race)

Product pacer (`av_clock.hpp` `avDecide` + `media_player` 2 ms Hold sleep): content/audio drift servo only — **no** forced 2,3,2,3.  
DDR swap is async free-gate (`test_cadence_swap_path` C1).  
Mean publish ms ≈ ideal **does not** imply smooth cadence.

---

## PLXD safety on 78eff44e (fitted — not tip-only claim)

### What does PLXD[63:48] pack on this RBF?

Fitted pack (`ddr_frame_store.sv:1034-1049`):
```systemverilog
// frames_done MUST be the real swap counter (not
// bank_vsync_count). Packing vsync kept PLXD "live" while
// swaps stuck — ARM stale detector could not fire
// (playback freeze class on c5382bee).
DDRAM_DIN <= {frames_done_d2,  // [63:48] real swaps (CDC)
              ...
```

`frames_done` write sites in fitted file (complete):
- `:242` reset `0`
- `:284` `frames_done <= frames_done + 16'd1` **only inside** `vsync_pulse && swap_pending && pending_ready_s2`

`bank_vsync_count` still `+1` every CDC vsync edge (`:954`) but **never** appears in any `DDRAM_DIN` assignment (only in comments).

**Answer: on 78eff44e, PLXD[63:48] is the real swap counter, not vsync.**

### Does that fix the c5382bee STALE-blind freeze class?

**At the RTL pack: YES** for the named failure mode (“swaps stuck, vsync still advances → fd-only liveness never fires”).  
If swaps freeze, `frames_done` stops; fd-only advance check would also go stale.

**Tip ARM (may not be daemon `7c991e47`):** `fpga_spi.cpp` degeneracy defence uses **`plxd_liveness.hpp` bank-identity** (`free_mask|disp|swap`), explicitly **not** frames_done-alone — correct on **both** RBFs.  
If device still runs pre-identity daemon, 78eff44e pack alone still makes fd-only STALE meaningful again.

**Shipping note:** identity gate is the durable fix; swap pack removes the vsync lie. Confirm device daemon includes `plxdLivenessTick` / bank-identity (tip), not fd-only.

---

## Tension to settle (Rule 0 — not guessed away)

Fitted + tip store are identical and pack **swap** counter ⇒ under free-gate **one doorbell → one swap**, tip ledger expects:

- `fd_semantics=SWAP_COUNTER`
- `mean_delta ≈ 1`, `p_delta1 ≈ 1`, `p_delta_ge2 ≈ 0`

Parent soak: `p_d1=0.0335 p_dge2=0.9639` + `skip_verdict=NO_ZERO_REFRESH_SKIP` **without** `fd_semantics` / `p_hold_d*` → **old summary format** (daemon `7c991e47` class).

That **Δ distribution is vsync-pack-shaped**, which **contradicts** the fitted pack if the metric truly samples PLXD[63:48] once per publish.

**Unknown — check that settles it (parent):**

1. Deploy tip daemon; print full `publish_swap_delta` including `mean_delta fd_semantics p_hold_d1 cadence_verdict`.  
2. If `SWAP_COUNTER` + `mean_delta~1`: parent’s old `p_dge2` line was wrong tool/build; re-score hitch via **`p_hold_d1`**.  
3. If still `p_delta_ge2~0.96`: something else multi-increments or mis-reads — then dump raw PLXD hi word each publish and compare to doorbell count (not inferred).

Do **not** treat parent `p_d1=3.35%` as hold-1 rate until (2).

---

## Bottom line

| Question | Answer |
|----------|--------|
| (a) 907e early-swap hitch? | **Killed.** Fitted on 78eff44e; preserves new doorbell; does not shorten prior hold via early swap. |
| (b) min-2 missing? | **Yes, load-bearing permission.** 1-hold is RTL-legal; fix is policy (min-hold or real 3:2), not 907e. |
| User “drops”? | Publish layer closed (your soak). Visible hitch = cadence/hold pattern, not lost frames. |
| 78eff44e fd vsync or swap? | **Swap** (`frames_done_d2`). c5382bee STALE-blind pack **fixed in this RBF**. |
| Next | Tip daemon soak → `p_hold_d1` + disc; only then min-hold / cadence exclusive. |

No device touch. No Quartus.  
Unit (prior): swap_delta / interval / cadence_swap_path / avclock **true rc=0**.
