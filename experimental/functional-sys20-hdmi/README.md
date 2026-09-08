# functional-sys20-hdmi

Frozen experimental publication of the complete independently approved HDMI
fractional-path correction source cohort. This is **constrained source** only:
SYS20/native20/DDR90/SDRAM142, fixed date260906, E1FF/default 8192-byte AU,
separate 8192-byte VCL, native DAR and diagnostic painter. It is **not**
approval of timing, image quality, FPS, tiers, glass or deployment.

## Included

- full 149-member product source tree under `project/fpga/Plex_MiSTer`
- all 6 reviewed validation/provenance source members, including the campaign
  driver plus the 5 replayed regression/import files
- exact `source.tar`, `inputs.tar`, `inputs.json`
- exact `source.patch`, `validation.patch`, `effective-identity.patch`
- exact source/effective/validation maps, `preimages.tar`, frozen `manifest.json`
- exact frozen `owner-result.json` plus the later review supplement
  `review-receipt.json`

## Key hashes

- product source: `4ca23f39cc5b8a45f2aab30a95b6877da58e9fa0f4644b2ea4dd8b1aea4c19d7`
- effective inputs: `8a72c03653c45cf7bdd993bed164aa8299d517efef95d70638d637d515324697`
- manifest: `4334c6878e76b83d5e7267982034663bfc8effc67e0882e836f57b3448dc5fdc`
- source.tar: `182e388df1402e0f069a31f7447af9a652196ad8bcf6dcdff31eba5941fd92ba`
- inputs.tar: `74be17d185a880c2196b27bdf5e48d871c04daaf9010fcc62b9bbb41156b1bc7`
- inputs.json: `8351f83adf530bdbf8b76d97380fa52e0d18120c72ccaa8b15ef1e68bafbad8f`
- source.patch: `98a5d2637fd2ed3c161d4c49dfcc24dffe40b8f743ae9a8a3ad2beea64c595b9`
- validation-source.tar: `609d7a076bde39ea27e077c1617197fba1e97505c77cafd8ee319efd0dfc1d16`
- validation.patch: `ed53b0c9e055d63dae4fbec1fa0caf68cbffc5d3ddd1b867a2a3a67f35781e79`

## Source scope and limits

Only `sys/ascal.vhd` changes in the 149-member product source; all other 148
source members are unchanged. The effective 150-member fit cohort differs only
by the eight-character derived QSF identity. The arithmetic source change keeps
latency/registering unchanged and replaces the final serial quotient decisions
with parallel 2s/4s/6s comparisons using exact one's-complement negative
folding.

Reviewer precision supplement: 4,198,400 arithmetic pairs, 819,200 driven
pipeline cycles, 818,400 post-warmup comparisons after excluding 25×32 warmup
cycles, 300 reported reference frames, all 44 assigned signal groups compared
except the unwritten fraction element. Boundary/random, startup/truncation,
after-run tool observations and packaging-failure limits remain explicit.

`owner-result.json` and `manifest.json` are preserved exactly as frozen. Use the
later immutable `review-receipt.json` for the precise count clarification rather
than rewriting the original frozen artifacts. The separately owned fixed-cohort
physical fit is out of scope for this publication and remains unapproved until
its own timing/hardware gate is satisfied.
