# AGENTS.md — MiSTerPlex

**YOU ARE AN AI AND YOU DO NOT STOP UNTIL THE TASK IS COMPLETE.**

## Hardware first (do not substitute)

You have **direct** lab access. Use it. Do not spend the turn writing
worker evidence cards, protocol cards, or unit tests instead of driving
the box.

| Resource | How |
|----------|-----|
| MiSTer SSH | `MISTER_HOST` (default `192.168.1.183`), `MISTER_PASS` (default `1`) |
| HDMI + audio | HDMI-to-USB grabber on this machine (`/dev/video0`, `scripts/hdmi_capture_idle.sh`). Live picture and sound are the product. |

Real hardware is the priority. A green `make unit`, an agent card under
`/tmp/misterplex-agent-*.txt`, or a status-file tick is **not** acceptance.

## Sign-off (cast / play / glass)

Before you claim play or cast works, test **end to end from a user
perspective** — not a companion curl, not a lab `--play-file`:

1. Open **Plex Web UI** (LAN, not app.plex.tv).
2. Press the **cast** icon.
3. Select **MisterPlex** as the target.
4. Play a real library title.
5. Verify on the HDMI grabber that glass matches the expected picture
   (content, not the idle chevron) while Web shows playing.

Do not sign off until that path is done.

## Quartus

At most **one** Quartus/RBF fit at a time. Do not mid-fit edit sources
under the live compile.

```bash
DEPLOY_LOAD=none|menu ./scripts/deploy_plex_core.sh
```

- `none` (default): copy RBF only
- `menu`: Menu bounce then Plex (preferred reload)
- Never thrash `load_core` / kill-9 storms

Companion: `scripts/deploy_misterplexd.sh`.

**Chat:** short status. Full dumps stay in `Memory/lab/` if needed.

## Build (not acceptance)

| Action | Command |
|--------|---------|
| RBF (sole) | `scripts/build_rbf.sh` — one at a time |
| Companion | `make arm-plexd` + `scripts/deploy_misterplexd.sh` |
| HDMI grab | `scripts/hdmi_capture_idle.sh OUT.png` (discard warmup frames) |

`make unit` is optional hygiene. It does not prove glass.

## Lab notes

- Freckle / HDMI fidelity resume pack: `~/Projects/Memory/lab/AGENTS.md`
  (chevron = two colors; Grid720 ratingKey **143**).
- Durable captures: `$HOME/Projects/MisterPlex/Memory/` (git-ignored).
  Do not run `git clean -xfd` in the primary clone.
- Live Plex tokens are never copied into the store.
- HDMI glass floor (not the product tip): `docs/glass-baseline-pair.md`.

## Stop

The user's named path works on glass (or the user tells you to stop).
Summaries, cards, and BUILD_OK are not stops.
