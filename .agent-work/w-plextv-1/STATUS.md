# w-plextv — after parent PASS @ prior tip

Parent-proven: picker exact, transitions, TEARDOWN (agent-run ≠ evidence).

## Tip features for HDMI join + companion fragility

### UI_STATE markers (no pixels)
Grep log / `build/e2e-artifacts/ui_state_marks.jsonl`:
```
UI_STATE run_id=… wall_ms=… state=playing|paused|overlay_visible|idle|seeking
UI_STATE_JSON {...}
```
Align HDMI capture to `wall_ms`. Suite does **not** grab frames or score overlay res / chevron.

### Companion sort diagnosis
- Logs `COMPANION_SELECTED host=… friendlyName=…`
- **FAIL** `companion_pms_friendlyname_blank` if FriendlyName blank (hostname collision class)
- **FAIL** `companion_friendlyname_sort_collision` if two hosts share lowercased name
- **FAIL** `wrong_companion_server` with sort diagnosis (winner before PMS-under-test)
- Optional pin: `EXPECT_COMPANION_FRIENDLYNAME=MiSTerPlex Studio` (name only — no LAN IP)
- `ASSERT_COMPANION=0` → **FAIL unconfigured** (not soft-pass)

### Paste
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-fix
./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"
```
Overlay grab:
```bash
E2E_OVERLAY_ONLY=1 E2E_OVERLAY_HOLD_SEC=10 ./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"
```
