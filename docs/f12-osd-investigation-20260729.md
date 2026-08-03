# F12 / OSD on live v0.3.0 box — investigation (2026-07-29)

**Rule 0:** claims below are either **measured**, **quoted code**, or **UNKNOWN**
with the settling check named. No cause is asserted without that backing.

**Scope:** User report “F12 doesn't work on the mister.” Read-only device.
No core reload, deploy, conf edit, Quartus. No HDMI capture.

**Device samples (measured this session):**
- `md5sum /media/fat/_Utility/Plex.rbf` → `41adb98c7a630b541091c22ce291be68`
- `cat /tmp/CORENAME` → `Plex`
- `pidof MiSTer` → `933`; `pidof misterplexd` → `2014` (pids move over time)
- conf (token redacted): `PRESENT=fpga STREAM=0 DECODE=320x240 OSD_CONTROL=1`
  (comment in file still says “fb0 cast path”; **file keys** are fpga / OSD_CONTROL=1)
- daemon log contains: `present=fpga`, `media: OSD via DDR mailbox (no SPI)`,
  and lines `media: idle screen painted (mode=…)` / `OSD word=0x…`

---

## Pre-registered prediction (mandatory) — and miss

| Rank | Hypothesis | Prior |
|------|------------|-------|
| 1 | Parent `PRESENT=fb0` continuous paint blocks F12/OSD | ~55% |
| 2 | `[Plex] fb_terminal=0` / ini | secondary |
| 3 | Long-standing core OSD gap | possible |
| 4 | `OSD_CONTROL` interaction | low |

**Miss (published):** primary fb0-paint hypothesis does **not** hold as the
explanation of the **lab instruments under the conf actually measured**
(`PRESENT=fpga`). See falsifiers below. Cause of the user-visible F12 report
remains **UNKNOWN**.

---

## Measured facts (not causes)

| # | Measurement | Result | Artifact / quote |
|---|-------------|--------|------------------|
| M1 | Live CONF_STR | Full v6 menu string | `set_status --confstr` → `Plex;;` … `O[15:14],Idle screen,...` `v,6;` **true rc=0** |
| M2 | uinput F12 inject | Script reports send | `osd_keys.py` log: `sent: f12 via misterplex-uinput-keys`; dmesg `input: misterplex-uinput-keys` |
| M3 | Main holds keyboards | Open fds | `/proc/$(pidof MiSTer)/fd` → `event0/1/2` (at sample time) |
| M4 | PNG after held uinput F12 | Still logo palette | `20260729_100933-screen.png`: **529×479**, **unique=3** colors `#182021` 98.33%, `#e7a208` 1.67%, `#000000` ~0% |
| M5 | PNG without F12 (earlier) | Same class | e.g. `100546-screen.png`: same 3 colors, gold count 4230 vs 4234 (tiny delta) |
| M6 | `/tmp/OSD_VISIBLE` after F12 | **Absent** | `Path.exists()→False`. **Code:** Main only `MakeFile("/tmp/OSD_VISIBLE")` if `cfg.log_file_entry` (`user_io_osd_key_enable`). Device `MiSTer.ini`: **no** `log_file_entry` line → this file’s absence is **not** evidence OSD is closed |
| M7 | `echo volume N > /dev/MiSTer_cmd` for N in 1..7, unmute | `Plex_volume.cfg` stays `00`, mtime unchanged in those samples | xxd + `ls --full-time` |
| M8 | `echo screenshot > /dev/MiSTer_cmd` | New PNG files appear | `/media/fat/screenshots/Plex/*-screen.png` mtimes advance |
| M9 | conf PRESENT key | `fpga` | grep conf; daemon adopted line `present=fpga` |
| M10 | misterplexd `SIGSTOP` then uinput F12 + screenshot | PNG still 3-color logo; `OSD_VISIBLE` still absent | stop test log; plexd state `T` then `CONT` → `S` |
| M11 | Main utime/stime over 2s, plexd running vs STOP | ~201 vs ~202 jiffies/2s | measured; **no healthy-Main baseline** in this session |
| M12 | `strace` on device | **Absent** | `which strace` → not found |

---

## What those facts do **not** settle

| Question | Status | Settling check |
|----------|--------|----------------|
| Is OSD chrome on the **physical display** after F12? | **UNKNOWN** | User eyes (no `/dev/video*`). Lab PNG lacking chrome ≠ glass proof if screenshot path ever omits OSD — G-OSD2 used PNGs historically, but that is prior backlog text, not a re-run on this boot |
| Does physical K400 F12 reach Main as KEY_F12? | **UNKNOWN** | User try Fn+F12 / second keyboard; or `evtest` on device if installed (not present this session) |
| Why did `Plex_volume.cfg` not change? | **UNKNOWN** | Read `set_volume` on the **running** Main binary path; or `strace -p $(pidof MiSTer)` during `volume 4` (tool missing). Fact is only: cfg bytes/mtime did not change |
| Is Main “wedged” like G-OSD6? | **UNKNOWN** | G-OSD6 is a **historical** backlog incident (reboot restored F12). This session did **not** reboot, did **not** capture Main stuck in SPI wait, did **not** prove cmd path total death (screenshot works). High Main jiffies alone ≠ wedge without baseline |
| Did parent’s earlier `PRESENT=fb0` cause the user’s F12 report? | **UNKNOWN** | Live conf is `PRESENT=fpga`. Continuous fb0 paint is **not** active now. Whether an earlier fb0 boot left lasting Main state requires **reboot A/B** (clearance) |
| Does uinput F12 call `menu_key_set(KEY_F12)` inside Main? | **UNKNOWN** | Needs `strace`/debug build/`log_file_entry` + observed side effect |

---

## Falsifiers that **did** run (narrow claims only)

**Claim tested:** “Under **current** `PRESENT=fpga`, continuous misterplexd blits are necessary for lab PNG to lack OSD chrome after uinput F12.”

- plexd `SIGSTOP` → F12 → PNG still 3-color logo (M10).
- So: **blit activity is not required** for that lab outcome under this conf.

**Claim tested:** “Live conf is still `PRESENT=fb0`.”

- File + daemon log say `PRESENT=fpga` / `present=fpga` (M9). **False.**

**Not tested:** “User glass F12.” **Not tested:** “Reboot restores F12.”

---

## Related code (idle path — **different** symptom than F12 chrome)

Parent’s idle-menu inert finding is backed by code (HEAD; same structure at v0.3.0 tag):

```text
# media_player.cpp initPresent (HEAD ~764+)
bool wantFpga = (presentMode_ == "fpga" || presentMode_ == "both");
if (wantFpga) { fpga_.open(); ... }

# paintIdle (tag cacd8717 ~364+; HEAD ~645+)
if (fpga_.ok()) {
  // write idle frame to FPGA/DDR
  log("media: idle screen painted ...") / "idle paint failed ..."
}
```

Under `PRESENT=fb0`, `wantFpga` is false → `fpga_.open()` skipped → `fpga_.ok()` false →
**no** idle DDR repaint and **no** either log line. That is a **quoted-code**
mechanism for **idle-mode bits not changing what the core scans out**.

That mechanism is **about idle framebuffer content**, not about whether Main
composites the **framework OSD** on F12. Conflating them is a guess. On the
**current** boot, daemon log **does** contain `media: idle screen painted` and
`present=fpga`, so that particular fb0 idle hole is **not** what the live log
shows now.

---

## Ini facts (measured), not a diagnosis

`[Plex]` section includes `fb_terminal=0`, `vga_scaler=1`, `video_mode=5`,
`direct_video=0`. Global has `fb_terminal=1`, `key_menu_as_rgui=0`.  
Whether any of these block F12 on this box: **UNKNOWN** — settling check is
controlled ini A/B + user eyes or a non-vacuous OSD oracle.

---

## User eyes list (only visual instrument)

1. Press **F12** (and **Fn+F12** on K400). Does the MiSTer **blue/grey settings menu** appear?
2. After a **reboot**, load Plex, F12 **before** opening the cast app — same question.
3. Volume keys: volume bar on screen?
4. Idle screen menu item (if OSD opens): does the picture change?

---

## Parent clearance experiments (not run)

| Experiment | Would settle |
|------------|----------------|
| Reboot, F12 before misterplexd | Whether current Main session state is involved |
| `log_file_entry=1` then F12 | Non-vacuous `/tmp/OSD_VISIBLE` |
| Install/use `strace -p MiSTer` during F12 | Whether menu path runs |
| User glass report | Actual F12 UX |

---

## Rule 0 retractions vs earlier wording in this doc / agent report

| Earlier wording | Problem | Replacement |
|-----------------|---------|-------------|
| “Best-supported diagnosis: partial Main dysfunction (G-OSD6 family)” | Pattern-match, not measured wedge | **UNKNOWN cause** |
| “F12 is dead” as fact on glass | No glass; PNG≠glass | **Lab PNG after uinput F12 lacks OSD chrome (M4)**; glass **UNKNOWN** |
| “Reboot is the fix” | Historical G-OSD6, not this boot | **UNKNOWN** — reboot is a **settling experiment** |
| “Main busy-loop proves wedge” | No healthy baseline; screenshot still works | Jiffies measured (M11); **interpretation UNKNOWN** |
| “volume cmd dead” as Main pathology | Only cfg unchanged | **cfg did not change (M7)**; why **UNKNOWN** |
| “fb0 is not the cause of F12 dead” as global | Over-broad | **Live conf is fpga; blits not required for lab PNG outcome**; user-report root cause still **UNKNOWN** |

**Prediction outcome:** pre-reg primary missed for the lab/conf actually measured.
