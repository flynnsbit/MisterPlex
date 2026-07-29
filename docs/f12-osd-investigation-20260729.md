# F12 / OSD dead on live v0.3.0 box — investigation (2026-07-29)

**Scope:** User report “F12 doesn't work on the mister” on the shipped
`41adb98c` / daemon `06c5735a` product box. Read-only (no core reload, no
deploy, no conf edit). No Quartus. No HDMI capture.

**Device at investigation end (quoted):**
- RBF md5 `41adb98c7a630b541091c22ce291be68` (`/media/fat/_Utility/Plex.rbf`)
- `CORENAME=Plex`, Main pid 933, misterplexd pid 2014
- conf (no token): `PRESENT=fpga STREAM=0 DECODE=320x240 OSD_CONTROL=1`
- Note: parent’s earlier “I set PRESENT=fb0” is **not** the live conf; live is `PRESENT=fpga`. Comment in conf still says “fb0 cast path”.

---

## Pre-registered prediction (published)

| Rank | Hypothesis | Prior |
|------|------------|-------|
| 1 | Parent `PRESENT=fb0` regression (continuous `/dev/fb0` paint masks OSD) | ~55% |
| 2 | `[Plex] fb_terminal=0` / conflicting `vga_scaler` ini | secondary |
| 3 | Long-standing core OSD gap on this RBF | possible |
| 4 | `OSD_CONTROL` interaction | low |

**Falsifiers registered:** F12 still dead under `PRESENT=fpga`; F12 still dead with daemon `SIGSTOP` (no paint).

---

## What is proveable without glass vs eyes-only

| Claim | Status | Evidence |
|-------|--------|----------|
| Core carries v6 CONF_STR / menu | **PROVED** | `set_status --confstr` → full `Plex;;` … `O[15:14],Idle screen,...` `v,6;` `rc=0` |
| Main accepts uinput keyboard | **PROVED** | dmesg `misterplex-uinput-keys`; Main holds `/dev/input/event*`; `osd_keys.py` “sent: f12” |
| `/tmp/OSD_VISIBLE` means OSD up | **VACUOUS** | Main_MiSTer `user_io_osd_key_enable`: only `MakeFile("/tmp/OSD_VISIBLE")` if `cfg.log_file_entry`. Device ini: **no** `log_file_entry` |
| Screenshot shows OSD chrome when open | **HISTORICALLY SOUND** | G-OSD2 PASS used uinput F12 + PNG (`/tmp/osd5.png`); OSD adds multi-color chrome |
| F12 opens OSD **now** (lab) | **FAIL by that instrument** | Held F12 PNGs `20260729_100933` etc.: **529×479, unique=3** colors `#182021/#e7a208/#000000` (logo only). Not menu chrome |
| `volume N` cmd path healthy | **FAIL** | Valid `volume 1..7` / `unmute` leave `Plex_volume.cfg` = `00`, mtime stuck |
| `screenshot` cmd path healthy | **PASS** | New files under `/media/fat/screenshots/Plex/` |
| Continuous fb0 paint is sole F12 blocker | **FALSIFIED** | Live `PRESENT=fpga`; with daemon `SIGSTOP` (state `T`) F12 still no OSD chrome; Main jiffies/s **unchanged** (~200/2s) with plexd stopped |
| Physical K400 F12 / Fn layer | **EYES-ONLY** | No capture; lab uinput uses real KEY_F12 (88) so Fn is N/A for lab path |
| “OSD appeared on glass” | **EYES-ONLY** | User is the only visual instrument |

---

## Adversarial answer on parent `PRESENT=fb0` change

**Bluntly: it is not the live root cause of F12 being dead right now.**

1. Live conf is **`PRESENT=fpga`**, not `fb0` (daemon log: `present=fpga`, `FPGA frame path OK`).
2. Daemon **SIGSTOP** (no blits) did not restore OSD chrome.
3. Main CPU burn is **independent** of misterplexd (same jiffies with plexd stopped).

**What remains possible:** if F12 first broke during the fb0 hour, Main may have entered a **partial wedge** that **survives** conf revert until **reboot**. That is the G-OSD6 pattern (F12 dead until reboot; not an RTL bug). We did **not** reboot (no clearance). So:

- **Not proven:** “fb0 paint covers OSD pixels.”
- **Not cleared:** “fb0 session left Main wedged.”
- **Clearing test:** user or parent **reboot**, then F12 **before** starting misterplexd / cast.

---

## Best-supported live diagnosis

**Partial Main dysfunction (G-OSD6 family), not a missing CONF_STR / not live fb0 paint.**

Supporting:
- G-OSD1-class CONF_STR **OK** on `41adb98c`.
- G-OSD2-class F12→PNG **no OSD chrome**.
- `volume` cmd **dead** while `screenshot` **alive** → not a total Main death, not a pure “keyboards unplugged” story.
- README / backlog already document: *“F12/OSD dead … crashed daemon could strand Main … Reboot”* and G-OSD6 resolved by reboot with zero RTL change.
- Daemon log: `OSD via DDR mailbox (no SPI)` / `playback input via DDR mailbox` — SPI not required for product path; `/tmp/misterplex_spi.lock` exists but plexd STOP doesn’t cool Main.

Weaker / not primary:
- `[Plex] fb_terminal=0` affects FB terminal (F9), not the F12 menu gate in Main source.
- `OSD_CONTROL=1` only makes daemon **read** status; it must not grab F12 (no EVIOCGRAB in v0.3.0 daemon).

---

## User try-list (short)

1. **Reboot the MiSTer** (power cycle). This is the historical fix for dead F12 (G-OSD6).
2. After reboot, load **Plex**, **do not start a cast yet**. Press **F12**.  
   - Menu with Aspect / TV Mode / Video delay / Idle screen? → Main was wedged.  
   - Still nothing? → try step 3–4.
3. On **Logitech K400**: try **Fn+F12** (F-keys often media-first). Try the **other** K400 if both are paired.
4. Press volume up/down on the keyboard: does a **volume bar** appear?
5. Tell us: did F12 work **this morning before** any conf tinkering? After reboot, does F12 die again only **after** misterplexd has been running a while?

---

## Parent clearance asks (do not do without OK)

| Ask | Why |
|-----|-----|
| Reboot MiSTer | Decisive G-OSD6 clear; user-visible |
| Brief misterplexd stop (or delay start post-reboot) | Split “Main alone” vs “daemon present” |
| Optional `log_file_entry=1` in ini | Makes `/tmp/OSD_VISIBLE` a real oracle |
| Do **not** need core reload if reboot + same RBF |

---

## Commands / quotes (evidence)

```
md5sum Plex.rbf → 41adb98c7a630b541091c22ce291be68
PRESENT=fpga STREAM=0 DECODE=320x240 OSD_CONTROL=1
set_status --confstr → Plex;; … O[15:14],Idle screen,… v,6;  rc=0
OSD_VISIBLE after F12 → never created (log_file_entry off — vacuous)
volume 4 / 1 / unmute → Plex_volume.cfg remains 00
F12 hold PNG 100933: 529x479 unique=3 (#182021 98.33%, #e7a208 1.67%)
daemon SIGSTOP: Main jiffies/2s 202 vs baseline 201 (no drop)
```

**Confidence:** High that live fb0 paint is not the active cause; high that lab F12 does not open OSD chrome; medium that reboot fixes (G-OSD6 prior); low on exact Main spin site without `strace` (absent on device).

**Prediction outcome:** Pre-reg fb0 primary **missed**. Published above.
