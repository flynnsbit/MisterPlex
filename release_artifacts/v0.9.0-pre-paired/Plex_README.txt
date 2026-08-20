Plex cores (pick ONE from the Utility menu):

  Plex_480p      HDMI / 31 kHz VGA — 640x480 @ 30 Hz
                 F12 Content 240p or 480p
                 F12 Display MUST be 480p (Display 240p = dead store)

  Plex_240p15    15 kHz 240p RGB CRT on VGA
                 [Plex] vga_scaler=0   (do NOT ascal 15 kHz video_mode)

  Plex_480i      15 kHz 480i RGB CRT on VGA
                 [Plex] vga_scaler=0   (do NOT ascal 15 kHz video_mode)

  Plex_720p24    HDMI 1280x720 @ ~24.1 Hz (lab-pre)
                 F12 Content 720p, Display 720p
                 Live PMS 1280x720 transcode; remux PCM audio
                 Star Trek 40868: pfps 23.9, av_drift tens of ms

Only one core runs. The watcher starts the matching daemon from
/media/fat/misterplex/rbf_daemon_pairs.txt and writes A/V conf for that
core (lead 40, drop 0, fast_bilinear, fps filter off, OSD_CONTROL=0).
Do not restore a generic Plex.rbf.
