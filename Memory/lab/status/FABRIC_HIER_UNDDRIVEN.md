# ebfe4a12 fd=0 — fstore fabric_* undriven (2026-08-13)

**RCA_OK.** **FABRIC_PASS=NO.** Soft-skip ≠ PASS.
**POKE_LIVE ≠ FABRIC_PASS.** **MAPS MATCH ≠ PASS.** **RCA_OK ≠ PASS.**
P3-720P24 stays **IN_PROGRESS / pfps FAIL**. **P4 stay TODO.** No RGB565.
Do **not** bounce / kill 13881 / compact / W-flag-off.

Lab RBF **`ebfe4a12`**. true480 **`07f54d9f`**. Live **13881** poke
**`0x04100000`** legal (W-maps-13881 n338=1 MATCH).

## Exact mismatch

```
fabric_allows_swap = fabric_copy_visible && (fabric_copy_token == db_token)
```

slot720p24h `compile.log` **Warning 10030**:

- `ddr_frame_store.sv:1008` `fabric_copy_visible` **no driver → 0**
- `ddr_frame_store.sv:1009` `fabric_copy_token` **no driver → 0**

Live PLXK `db_token` = **`0xa0001733`** (bank=1, fmt=YUV=1, seq).
`0 && (0 == 0xa0001733) = 0` → no `db_new_seq` → **fd=0 pending=0**.

`emu.fabric_copy_*` from `emu|present|fstore` does not bind to sibling
`emu|u_fdirect`. present_core has **no** fabric ports (lessons L4).

## Not the miss

- PFN **0x04100000** legal. PLXP magic+src sticky.
- Host idle **does** write PLXK token (reader copies **PLXK[63:32]**,
  not PLXP magic). Token increment 0x1733→0x1735.
- fmt / bank OK. This RBF polls PLXP **0x138** (not fit-tree 0x200).
- `u_fdirect` is **in** the netlist. Reader complete still cannot
  open a tied-0 gate.

## Do not

- Do **not** treat another poke / bounce / flag-off as the fix.
- Fix is RTL: clk_ddr ports (or a kept bind) + **new** RBF.
  Not a one-line host bug. **No patch this card.**

## Evidence

`/tmp/misterplex-agent-W-swap-rca2.txt`
`remote_out/slot720p24h/compile.log` L956–957
`/tmp/misterplex-agent-W-plxp-re2.txt` + `W-maps-13881.txt`
