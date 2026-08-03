# PLXC control bootstrap map (w-mem arbitration)

**Owner:** w-mem (`mailbox_abi_spec.hpp`). w-osd consumes; does not redefine phys.

## Problem (rd-duck)

| Agent | Address | Role |
|-------|---------|------|
| OSD loader default (was) | `0x3007F000+0x130` | legacy *example* control page |
| Product legacy frame doorbell | `0x300FF000` | 480p PLXK / banks |
| Option-C frame doorbell | `0x3047F000` | 720p/960 payload banks |
| Host if `layout.doorbell+0x130` | follows **active frame** map | splits under Option-C |

Unless host and loader share one fixed page, chrome list is never seen.

## Arbitration (binding)

**PLXC / PLXO / list live on the control bootstrap page** — product YUV doorbell
`0x300FF000` + offsets — **the same 4 KiB page as PLXG bootstrap**.

| Slot | Phys |
|------|------|
| bootstrap doorbell | `0x300FF000` |
| PLXC | `0x300FF130` |
| PLXO | `0x300FF138` |
| list base | `0x300FF140` |
| PLXG | `0x300FF800` |

- Frame payload doorbell may be `0x300FF000` (legacy) or `0x3047F000` (Option-C).
- Chrome **does not** move with Option-C frame doorbell.
- `mailbox_abi::kPlxcAddr` (`0x3007F130`) remains the collision-table *example* only.

## Code

| Side | API / param |
|------|-------------|
| Host | `plxcControlPhys()` / `kPlxcBootstrapPhys` — ignore active frame db |
| FAULT | `plxcPhysFaultFollowFrameDoorbell(active_db)` |
| RTL | `plex_chrome_ddr_loader.DOORBELL_PHYS` default `0x300F_F000` |
| Plex.sv | already `.DOORBELL_PHYS(32'h300F_F000)` |

## Tests

`test_ddr_720p_abi`: `PLXC_BOOTSTRAP_MAP` — leg+optc host phys stable; FAULT Option-C
follow diverges from loader.
