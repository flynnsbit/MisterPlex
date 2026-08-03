# B9 DAR tag / bank_gen — rd-duck FIX STILL UNSAFE (ACK)

**Owner of B9 RTL:** **w-scaler** (`w-scaler-window`, tip includes `fad5a96f`)  
**w-clock tip:** this doc only — `plex_ar_*.sv` **not present** on `w-clock-bump`  
**B9_CLOSED:** false · couples to B20 `store_applied_*` (also OPEN)

## MEASURED (quoted from `fad5a96f`, not reconstructed)

### 1. `bank_gen` hard-tied to 0 in product
`sys_top.v` (scaler commit):
```
// bank_gen: 0 until B20 doorbell gen is parent-wired.
plex_ar_out_hold #( ... ) u_plex_ar_out_hold (
	...
	.bank_gen(16'd0),
```
Release path **cannot** distinguish banks while this tie stands.

### 2. `disp_matches_live` is DAR-only
`plex_ar_buf_model.sv`:
```
assign disp_matches_live = disp_valid_r &&
	(disp_dx_r == live_dar_x) && (disp_dy_r == live_dar_y);
```
`disp_bank_r` / `out_bank_gen` are **tracked** on push/pop but **not** in the match predicate.

### 3. Black release ignores bank generation
`plex_ar_out_hold.sv` product path:
```
if (disp_match_w && gen_after_hold) begin
	holding       <= 1'b0;
	ar_hold_black <= 1'b0;
```
`gen_after_hold = (gen_delta != 0) && ~gen_delta[15]` — compares **frame gen counter**, not
`disp_bank_w` vs applied bank generation. Comment in module header even says:
"gen-ack still keys on DAR tag match."

### 4. Failure mode (rd-duck) — consistent with (1–3)
PLXG DAR promotes at source VS while store misses `pending_ready` → completed old frame
may tag old DAR, next OLD-bank frame snapshots **new** want DAR → shadow later sees DAR
match + gen_after → **releases black before bank swap**. Prior-frame DAR tag (`fad5a96f`)
is directionally right for coincident VS+want but **does not close** bank miss.

### 5. ascal simultaneous i/o VS — model ≠ hardware
`ascal.vhd` (this tree / product):
```
-- Simultaneous change of input and output framebuffers
IF o_vsv(1)='1' AND o_vsv(0)='0' AND
	o_iendframe0='1' AND o_iendframe02='0' THEN
	o_bufup0<='0';
	o_obuf0<=o_ibuf0;
END IF;
```
Same-edge override: output takes **new** `o_ibuf` immediately. Shadow model discovers
ready before push and cannot pop that path — may be conservative at 24/30→60 but is
**not proof**. Need real `o_obuf`/`o_bufup` or slot-swap ack (w-scaler / ascal observe).

## Required fix (owners)

| Piece | Owner | Action |
|-------|-------|--------|
| Export **store-applied generation** (pend snapshot seq promoted **with** bank) | **w-mem** | Same bus as B20 `store_applied_seq` / `swap_applied_pulse` |
| Wire `sys_top.bank_gen` ← applied gen (not live seq, not 0) | **w-scaler** (+ parent) | Drop `16'd0` tie |
| `disp_matches_live` requires **DAR ∧ applied_gen** (disp_bank tag == live applied) | **w-scaler** | Model + hold release |
| Release: `disp_match && gen_after && bank_match` | **w-scaler** | Never DAR-only |
| ascal proof: expose o_obuf/o_bufup or real swap ack | **w-scaler** | Shadow ≠ ship proof |
| Do not use **current live** PLXG/geom seq as bank_gen | all | Live ≠ applied |

## w-clock stance
- **Does not own** `plex_ar_*` / `sys_top` AR hold (w-scaler).
- **Does own** beam-side applied visual tuple **once** w-mem exports it (B20 contract).
- Applied gen for B9 **must be the same** `store_applied_seq` as B20 — one SoT, not a
  second live counter.
- Will not claim B9 or B20 closed; will not edit sibling `MisterPlex-wt-scaler`.

## Cross-ref
- `.agent-work/w-clock/B20_PLXG_BANK_ATOMIC_CONTRACT.md`
- Scaler commit under audit: `fad5a96f` on `w-scaler-window`
