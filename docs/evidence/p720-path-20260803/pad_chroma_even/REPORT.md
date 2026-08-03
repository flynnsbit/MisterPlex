# pad 426→432 chroma-even oracle (rd-duck)

## Failure
`af53860a` used ideal center `pad_x=(432-426)/2=3` and emitted
`pad=432:240:(ow-iw)/2:(oh-ih)/2`. Live FFmpeg yuv420p places content at **x=2**
(2 left / 4 right): row0 `[16,16,0,1,2,...]` (studio-black pad Y=16).

## Fix
- `padInsetChromaEven(ideal) = ideal & ~1`
- Emit explicit `pad=432:240:2:0:color=black`
- Unit + live ffmpeg oracle both require L=2; NEG pad_x!=3

## Evidence
```
./build/test_ffmpeg_vf ; echo true rc=$?
→ PASS test_ffmpeg_vf
true rc=0
```
