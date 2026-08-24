# Host re-resolve live PFN before pokePlxp (2026-08-13)

**Status:** **RERESOLVE_OK** (host source + unit). **NOT deployed.**
**FABRIC_PASS=NO.** **T7 NOT_RUN.** Soft-skip ≠ PASS.
**RERESOLVE_OK ≠ FABRIC_PASS ≠ T7.** P3-720P24 stays **IN_PROGRESS / pfps FAIL**.
**P4-DISPLAY / P4-720P-MIX** stay **TODO**. No RGB565. Do **not** bounce.

Lab **`ebfe4a12`**. true480 **`07f54d9f`**. Live 10420 still pokes **`0x01200000`**
until a parent deploy token (this ticket did not scp / bounce).

## What landed (lessons tree)

`sendDdrFrame` always calls `resolveCachedSrcPhys(payload,len)` then
`chooseLivePokeSrcPhys(cached, live)`:

- live != 0 → poke live (updates idle `slot.phys` via `refreshFabricSlotPhys`)
- live == 0 → STUB memcpy; **do not poke stale** `0x01200000`

Idle keeps process-lifetime virt (`minSlots=1` allocate-once). Play
`minSlots=2` fail-closed unchanged. **No** pageIndex/firstPfn swap (W-slot-fix
NOFIX stands).

## Unit

`test_cached_src_phys` mock: stale `0x01200000` + hole/0 live → poke 0;
stale + live `0x0562a000` → poke live. Host pagemap **hidden STUB** — not
device REAL.

## Do not

- Do **not** harvest as FABRIC_PASS / T7 / pfps.
- Do **not** bounce 10411/10420 / W-flag-off without parent token.
- **NOT deployed.** 10420 still pokes **0x01200000**.

## Evidence

`/tmp/misterplex-agent-W-reresolve.txt`
