MiSTerPlex v3 fallback bundle
=============================

Pairing
-------
- Core: /media/fat/_Utility/Plex_v3.rbf
  md5 41adb98c7a630b541091c22ce291be68
  (= release_artifacts/v0.3.0/Plex.rbf)
- Daemon: misterplexd built from tag v0.3.0 (cacd8717) plus optional
  present-path-neutral GDM idle-CPU back-port (see docs/v3-fallback.md).

Install location (side-by-side; never overwrites dev)
----------------------------------------------------
  /media/fat/misterplex_v3/bin/misterplexd
  /media/fat/misterplex_v3/misterplex.conf
  /media/fat/misterplex_v3/scripts/*.sh

Dev install at /media/fat/misterplex/ and /media/fat/_Utility/Plex.rbf
are left alone.

Binary md5 (this tree after build):
  see misterplexd.md5 next to the binary, or md5sum misterplexd
