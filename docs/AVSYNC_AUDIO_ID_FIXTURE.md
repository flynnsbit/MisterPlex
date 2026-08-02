# Audio self-check marker (w-asset480)

Video fixture encodes `G n=NNNNNN c=D` (digit-sum mod 10). Audio needs the same
class of self-check so a confident-but-wrong onset cannot invent a sequence.

## Contract v1 (`tools/avsync_audio_id.py`)

At each integer second **S** (file time = flash onset):

| Phase | Duration | Content |
|-------|----------|---------|
| SYNC  | 40 ms | 1000 Hz — **lipsync onset** |
| GAP   | 5 ms | silence |
| ID    | 4×8 ms | FSK: 2000 Hz=1, 1500 Hz=0; nibble=S%16 MSB first |
| CHK   | 4×8 ms | FSK of `chk=(nibble+(nibble>>1)+1)&0xF` |

Total ≈ 109 ms < 1.0 s. Flash (video) file-aligned to SYNC start.
fps for 480p soak RCA: **24.000** only.

```bash
python3 tools/avsync_audio_id.py --self-test; echo "true rc=$?"
```

Existing soak480 (50 ms 1 kHz only): ID = NO-DATA (not FAIL).
