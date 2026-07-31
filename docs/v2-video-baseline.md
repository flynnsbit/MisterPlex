# v0.2.0 video regression baseline

## What this is

The GitHub release **v0.2.0** is the last combination proven on real hardware to
render Plex playback with no left-edge defect. It is installed side-by-side with
the development build so the MiSTer always has a working configuration, and it is
the reference every future build must be measured against.

| Component | Path on device | md5 |
|---|---|---|
| Core | `/media/fat/_Utility/Plex_v2.rbf` | `dfebf2bfd08dd70b473b587dd7e81848` |
| Daemon | `/media/fat/misterplex_v2/bin/misterplexd` | `7cd10b4d438c714a9b8c4766dc982d59` |
| Conf | `/media/fat/misterplex_v2/misterplex.conf` | `PRESENT=fpga` |

The daemon binary is byte-identical to the one shipped in the public
`misterplex-v0.2.0.tar.gz` release asset.

## PRESENT=fpga, not fb0

The v0.2.0 release notes say *"`PRESENT=fb0` is the default and the safe
configuration"*, and the on-device conf carried a `(fb0 cast path)` provenance
note. **On this hardware fb0 does not reach HDMI.** Measured: with `PRESENT=fb0`
the daemon decoded normally (`vfps=22.9`, `drops=0`, `av-lock`) but `pfps=0.00`
and the captured screen was a stable, genuine black. Switching to `PRESENT=fpga`
produced `pfps=23.6` and a correct picture. The v0.2.0 bitstream presents from a
320-wide SPI-fed frame store (`present_core.sv`: `H_DE=529`, `H_STORE=320`), and
`PRESENT=fpga` is what feeds it.

## Why the dev build cannot simply reuse this core

The v0.2.0/v0.3.0 bitstreams have **no `ddr_frame_store.sv`** — only
`frame_store.sv`. The current daemon writes a 624-stride DDR YUV420p canvas
(`media_player.cpp`: *"every non-none PRESENT must open FPGA for core scanout"*),
which those older bitstreams have no reader for. Loading `Plex_v3.rbf` while the
development daemon is running produces a garbage picture — confirmed on hardware.

The DDR path landed 56 minutes after v0.3.0 was tagged:

| Event | Timestamp |
|---|---|
| `v0.3.0` tag | 2026-07-26 20:00:10 |
| `ddr_frame_layout.hpp` added (`c39f93a0`) | 2026-07-26 20:56:17 |
| `ddr_frame_store.sv` added (`d0ea6dac`) | 2026-07-27 00:40:38 |

Every daemon binary archived on the SD card post-dates that switch, so no
archived binary can drive an older core.

## The defect this baseline detects

The picture defect is identified by **edge asymmetry**, not by eyeballing:

| Build | LEFT spread | RIGHT spread | Verdict |
|---|---|---|---|
| dev core, idle screen | 61 px | **0 px** | DEFECT |
| v0.2.0 baseline, playback | 13 px | 12 px | clean |

A pixel-perfect right edge with a wandering left edge means the **DDR line fetch
starts late** — `ddr_frame_store.sv` outputs black on a miss, so the head of each
line is blanked until the burst catches up:

```systemverilog
wire rd_miss_now = rd_active && rd_visible && has_frame && (!y_hit_now || !c_hit_now);
```

This is RTL-side and needs a Quartus fit; it cannot be patched from the daemon.
It appears on the **idle screen** too, so it is not decode-, ffmpeg- or
PMS-related.

## Running the regression

```bash
scripts/video_regression.sh verify      # check the baseline hashes only
scripts/video_regression.sh baseline    # measure the v0.2.0 reference
scripts/video_regression.sh dev         # measure the development build
```

Each run enforces a single daemon, loads the matching core, casts the 240p
telemetry clip, captures HDMI and measures edge straightness.

**Parent orchestrator only.** Agents have no device access (see AGENTS.md
"Who tests").

## Capture rules that this harness enforces

- The HDMI grabber emits ~15 warm-up frames that are a single flat value
  (`min == max`). `tools/measure_edges.py` discards every uniform frame and
  fails loudly if none remain. A uniform frame is **never** scored as a pass —
  misreading one as "black screen" previously caused three false findings.
- Only one `misterplexd` may run. Duplicates were observed binding UDP 32412
  simultaneously (SO_REUSEPORT) while only one owned TCP 3005. Launch through
  `scripts/plexctl.sh`, which holds an exclusive `flock`; the older
  `dedupe_daemon.sh` races and can spawn a second daemon.

## Cast target does not appear: check the host firewall FIRST

The Plex Media Server runs in a docker container with `net=host` on the
workstation, so the **workstation's** firewall governs whether the server can
complete GDM discovery of LAN players. With ufw default-deny, MiSTerPlex's
discovery replies were dropped before reaching PMS and no cast targets appeared
in the Plex Web picker.

```bash
sudo ufw allow from 192.168.1.0/24 to any port 32410:32414 proto udp
sudo ufw allow from 192.168.1.0/24 to any port 32400 proto tcp
sudo ufw reload
```

Verify with a GDM probe — before the rules this timed out, after it returns a
283-byte reply:

```bash
python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.settimeout(4.0)
s.sendto(b"M-SEARCH * HTTP/1.1\r\nHost: 192.168.1.255:32412\r\n\r\n",
         ("192.168.1.255", 32412))
print(s.recvfrom(2048)[1])
PY
```

**Do not conclude from a missing plex.tv registry entry that the fault is
plex.tv registration.** That inference was made here more than once and was
wrong; see also the multi-PMS picker case below. A device can legitimately be
absent from `plex.tv/api/resources` while local GDM discovery is healthy (or
broken for unrelated reasons).

Note the ufw conntrack trap when probing by hand: replies to a **broadcast**
probe arrive from the device's unicast address while the conntrack entry has the
broadcast destination, so they are classed NEW. Probing from the MiSTer itself
avoids this.

## Cast target missing in Select Player: companionServer + FriendlyName (2026-07-30)

**Operator runbook (symptom → diagnose → rename → booby-trap warning):**
[select-player-runbook.md](select-player-runbook.md).

**Acceptance for "no cast option" is the Plex Web "Select Player" UI**, not an
HTTP status on plex.tv and not "device appears in some `/clients` somewhere."

> **Superseded (b24f9557):** an earlier write-up of this section claimed the
> remedy was to remove/stop/sign-out the SHIELD PMS so Web would stop preferring
> it. **That was wrong.** Parent later proved the SHIELD can stay running; the
> fix is a **distinct FriendlyName on the user's own PMS** so
> `CompanionServerManager` picks that server as `companionServer`. Do not
> resurrect "dismantle the SHIELD" as the product or operator fix.

### How the LAN picker is fed (Plex Web 4.160.0, cited)

Source bundle (served from the local PMS web UI):

`http://192.168.1.24:32400/web/js/main-8792-5e6a05fd7fbc07797f88-plex-4.160.0-75ddd7b.js`
(Plex Web **4.160.0**)

The picker does **not** poll "the server you are browsing." It polls a dedicated
**`companionServer`**:

```js
[oe](e){const t=e.get("companionServer"); t&&(t.get("desktop").get("players").fetch(), t.get("desktop").get("neighborhoodDevices").fetch()); ...}
```

That issues:

1. `GET {companionServer}/clients`
2. `GET {companionServer}/neighborhood/devices`

`companionServer` is chosen by `CompanionServerManager`:

```js
_pickCompanionServer(){ ... this.companionServer = this.servers.find(Ac) || this.servers.find(vc) ... }
```

```js
function vc(e){return!!(function(e){return!(!e||e.get("isCloud")||"iOS"===e.get("platform"))}(e)&&(t=e.get("activeConnection"),t&&t.get("isPrivate")&&t.get("isConnected")));var t}
function Ac(e){return!(!vc(e)||e.get("isShared"))}
```

`Array.prototype.find` returns the **first** match in `ServerCollection` order.
That order is alphabetical by lowercased friendly name (owned first; cloud last):

```js
comparator(e){const t=e.get("isShared"),r=e.get("friendlyName")||"",n=e.get("sourceTitle")||"",i=t?n+r:r;return e.get("isCloud")?"9":(t?"1":"0")+i.toLowerCase()}
```

So: first owned, non-cloud, non-iOS server with a private connected connection,
in **friendlyName A→Z order**, becomes `companionServer` and alone feeds the
player picker.

(OSS context still useful: plex-mpv-shim needs no plex.tv login; LAN listing is
GDM → PMS `/clients`. That path only helps once Web is asking the PMS that
actually discovered the player.)

### Root cause in this lab (measured)

| Fact | Evidence |
|------|----------|
| User workstation PMS `/clients` already listed MiSTerPlex | Parent: size="1", `machineIdentifier=misterplex-dev` |
| SHIELD Android PMS `/clients` empty | Parent: size="0"; `/neighborhood/devices` size="0" |
| Android/SHIELD PMS sends no GDM probes | Parent: 40 s sniff, zero probes |
| Web polled SHIELD (`192.168.1.122` via `plex.direct`), not workstation | Playwright **context** request log (not `page.on` — that captured 0) |
| Local PMS had **blank FriendlyName** → fell back to hostname `node-worker1` | Same string as SHIELD PMS friendly name |
| Sort keys both `0node-worker1`; SHIELD won `find` | Bundle `comparator` + identical names |
| MiSTer GDM + `:3005/resources` healthy | Parent — not the defect |

### Fix (configuration on the user's own PMS — SHIELD untouched)

Give every owned PMS a **distinct** `FriendlyName`, and ensure the PMS that
should feed Select Player sorts **first** alphabetically among eligible owned
servers (see `comparator` / `Ac` / `vc` above).

Parent applied locally (SHIELD left running):

```bash
curl -X PUT "http://192.168.1.24:32400/:/prefs?FriendlyName=MiSTerPlex%20Studio&X-Plex-Token=…"
# → HTTP 200
```

New sort keys (owned, lowercased): `0misterplex studio` < `0node-worker1` <
`0studio`. Playwright re-run: discovery went to
`http://127.0.0.1:32400/clients` and `/neighborhood/devices`,
`POLLED_122_SHIELD=false`, picker contents `Cast... | MiSTerPlex | MiSTerPlex`
(screenshot `/tmp/local_D_picker.png`). **No MiSTerPlex daemon change.**

### What is NOT the fix

| Claim | Status |
|-------|--------|
| Remove/stop/sign-out the SHIELD PMS | **Superseded / wrong** as the remedy (see callout above). SHIELD can remain; name the local PMS distinctly. |
| Implement plex.tv player registration / upsert | **Do not implement.** Parent registered a device with `provides=player` and re-ran the picker — **MiSTerPlex still did not appear.** plex.tv `provides=player` is **neither necessary nor sufficient**. |
| Daemon `PLEXTV_ANNOUNCE` GET `api/v2/resources` creates a device | **False.** 200 + `self_in_body=0` is a list no-op (`2f81e96b`). |
| MiSTerPlex GDM / companion broken when workstation `/clients` already lists it | **False** for this complaint. |

### Debugging notes (keep; not remedies)

- **IPv4-only block of a PMS is insufficient for isolation tests.** The same
  `*.plex.direct` hash also resolves over **IPv6**; parent had to block the
  hash (all address families) before Web stopped using SHIELD. That proved
  "wrong companionServer" by forced fallback; it is **not** the user-facing fix.
- Prefer Playwright **`context.on('request')`**; `page.on('request')` missed the
  `/clients` traffic entirely in an earlier run.
- Do **not** add CI tests that encode one household's multi-PMS topology or a
  SHIELD existing — flaky gate on accident, not product behavior.

### Operator checklist (parent / user)

1. Player alive: `GET http://<mister>:3005/resources` → 200 Player XML.
2. Each owned PMS: `GET http://<pms>:32400/clients?X-Plex-Token=…` — which list
   `MiSTerPlex`?
3. Open Select Player; note which host serves `/clients` and
   `/neighborhood/devices` (that host **is** `companionServer`).
4. If the wrong PMS is companionServer: set a distinct FriendlyName on the PMS
   you want (Settings → General, or `PUT /:/prefs?FriendlyName=…`) so it sorts
   first among owned private servers. **Do not** require removing other PMSes.
5. Do not chase plex.tv registration for this symptom.

## Switching bundles

```bash
/media/fat/misterplex/bin/plexctl.sh v2      # known-good v0.2.0
/media/fat/misterplex/bin/plexctl.sh dev     # development build
/media/fat/misterplex/bin/plexctl.sh status
/media/fat/misterplex/bin/plexctl.sh stop
```

Loading the matching core is separate:

```bash
printf '%s\n' 'load_core /media/fat/_Utility/Plex_v2.rbf' > /dev/MiSTer_cmd
```

Always pair `plexctl.sh v2` with `Plex_v2.rbf`, and `plexctl.sh dev` with
`Plex.rbf`. Mismatched pairs produce a garbage or black picture.
