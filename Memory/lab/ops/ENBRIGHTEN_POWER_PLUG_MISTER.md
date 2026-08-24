# Enbrighten power plug → MiSTer hard power cycle

**Purpose:** If MiSTer hard-locks or SSH is dead, power-cycle AC via the
Enbrighten smart plug on the LAN.

**Living SSH (2026-08-24):** `root@192.168.2.2` via node-worker1. WiFi
`192.168.1.183` is unassociated. After a cycle, wait on **192.168.2.2**, not 183.

| Field | Value |
|-------|--------|
| Plug LAN IP | **192.168.1.91** (reserve DHCP / static) |
| MAC | **d8:c8:0c:c2:60:27** |
| OUI / silicon | **Tuya Smart Inc.** (Enbrighten Wi‑Fi plugs are Tuya OEM) |
| Load | MiSTer / DE10-Nano power brick (and anything on that outlet) |
| Use when | No SSH, no serial recovery, hung so soft reboot impossible |
| Do **not** use | Routine residual tests while FPGA fit is healthy |

## What we measured on this LAN (2026-08-04)

- Host **pings** (icmp OK).
- **No TCP listeners** on common ports (1–1024 + 6668/8080/etc.): no plain `http://192.168.1.91/on`.
- Not a dumb HTTP smart plug (Shelly/Tasmota-style).
- **Tuya local protocol** is the path: encrypted UDP discovery + TCP (often 6668) after you have
  **device_id + local_key + IP**.

`tinytuya` LAN scan found **0 devices** until a local key is paired (normal for silent Tuya
firmware; discovery often empty without prior cloud link).

## How to control it (local, once keyed)

### 1) One-time: get `device_id` + `local_key`

Any of:

1. **TinyTuya wizard** (easiest if you have a Tuya/Smart Life / Enbrighten Wi‑Fi app account):

   ```bash
   # venv example
   uv venv ~/tuya-venv && uv pip install --python ~/tuya-venv/bin/python tinytuya
   ~/tuya-venv/bin/python -m tinytuya wizard
   ```

   Follow prompts: Tuya IoT project / API keys from [iot.tuya.com](https://iot.tuya.com),
   link the same account as the phone app, pull device list → `devices.json` with `id` + `key`.

2. **Home Assistant LocalTuya / Tuya Local** — if HA ever has this plug, copy device id + local key
   from the integration options.

3. **Phone app only** is **not** enough for headless scripts without the cloud API extract step.

Fill secrets (do **not** commit real keys to git):

```bash
# ~/.config/misterplex/enbrighten-mister.env  (mode 600)
export ENBRIGHTEN_IP=192.168.1.91
export ENBRIGHTEN_DEVICE_ID='xxxxxxxxxxxxxxxxxxxx'
export ENBRIGHTEN_LOCAL_KEY='xxxxxxxxxxxxxxxx'
export ENBRIGHTEN_VERSION=3.3   # try 3.4 if status fails
export ENBRIGHTEN_SWITCH_DPS=1  # usual on/off DP for plugs
```

### 2) Power cycle script (repo)

```bash
# After keys exist:
source ~/.config/misterplex/enbrighten-mister.env
./scripts/enbrighten_mister_power_cycle.sh
```

Script lives at:

`scripts/enbrighten_mister_power_cycle.sh`

Python helper:

`scripts/enbrighten_tuya_plug.py`

Behavior:

1. `off` plug  
2. sleep ~8s (PSU drain)  
3. `on` plug  
4. wait for MiSTer SSH (192.168.1.183) up to ~120s  

### 3) Manual one-liners (after keys)

```bash
source ~/.config/misterplex/enbrighten-mister.env
python3 scripts/enbrighten_tuya_plug.py status
python3 scripts/enbrighten_tuya_plug.py off
python3 scripts/enbrighten_tuya_plug.py on
python3 scripts/enbrighten_tuya_plug.py cycle --off-secs 8
```

Using tinytuya API directly:

```python
import tinytuya, os, time
d = tinytuya.OutletDevice(
    os.environ["ENBRIGHTEN_DEVICE_ID"],
    os.environ.get("ENBRIGHTEN_IP", "192.168.1.91"),
    os.environ["ENBRIGHTEN_LOCAL_KEY"],
)
d.set_version(float(os.environ.get("ENBRIGHTEN_VERSION", "3.3")))
dps = int(os.environ.get("ENBRIGHTEN_SWITCH_DPS", "1"))
d.set_status(False, dps)  # OFF
time.sleep(8)
d.set_status(True, dps)   # ON
print(d.status())
```

## Parent / agent policy

- Prefer **SSH soft recovery** first (`ssh root@192.168.1.183`, `reboot`, kill hung processes).
- Use **Enbrighten cycle only** for hard lock / no route / no SSH after retries.
- After cycle: wait for SSH, then re-check LIVE RBF / misterplexd; **do not** invent G-DEVICE green.
- Device token stays PARENT; power plug is **infra**, not a residual score path.
- If plug IP changes, update this file + `ENBRIGHTEN_IP` (prefer DHCP reservation for MAC d8:c8:0c:c2:60:27).

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| Scan finds 0 devices | Need cloud extract for local key; or plug offline |
| `status` error / timeout | Wrong version (try 3.4/3.5), wrong key, or AP isolation |
| Works in phone app only | App uses cloud; local key not extracted yet |
| Cycle but MiSTer never boots | PSU/order, or plug not feeding MiSTer brick |

## Setup incomplete until

- [ ] `ENBRIGHTEN_DEVICE_ID` + `ENBRIGHTEN_LOCAL_KEY` stored in `~/.config/misterplex/enbrighten-mister.env`
- [ ] `python3 scripts/enbrighten_tuya_plug.py status` returns switch state
- [ ] One successful `cycle` with SSH recovery verified

Once keys are filled, parent can call `scripts/enbrighten_mister_power_cycle.sh` autonomously on lockup.
