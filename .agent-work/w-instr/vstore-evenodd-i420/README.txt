V_STORE even/odd I420 fixtures — coded 624x480 planar YUV420p
bytes/frame = 449280 (kPlex480pYuv420pBytes=449280)

PRE-REGISTER on c5382bee (store_y=py*2, even rows only):
  even_black → solid BLACK
  even_white → solid WHITE
  odd_black  → solid WHITE  (inversion vs even_black)
  odd_white  → solid BLACK
  mid_grey   → uniform MID-GREY (CONTROL)
If control is not mid-grey, UNSCORE entire run (publish path broken).
If even_black ≡ even_white on glass, ceiling claim FALSIFIED.

Publish path (product):
  build/arm/push_frame --ddr --yuv420p 624x480 FILE.i420
  → FpgaSpi::sendYuv420pFrameDdr → publishDdrFrame → sendDdrFrame
  Same path as MediaPlayer playback DDR present.

Daemon: STOP misterplexd before push (it will overwrite the bank).
Restore after capture. Daily-driver safe if parent restores.

Score captures:
  python3 tools/hdmi_vstore_discriminate.py --flat-suite CAP_DIR
