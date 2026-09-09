# SYS85 audio CDC: reviewed experimental source

This isolated cohort publishes source `f2bdd413` reviewed as
**APPROVED_FOR_PHYSICAL_TRIAL at source/CDC level only**. It does not replace
the repository's canonical FPGA files, root tools, or earlier experiments.
It contains no bitstream or deployment approval.

## Contents and identity

| Material | Published form |
| --- | --- |
| Product | All 155 exact source members at `project/fpga/Plex_MiSTer`; original `source.tar` and source map |
| Effective compiler inputs | Original 156-member `inputs.tar`, `inputs.json`, and effective map; separate from plain source |
| Reviewed support | 95 of 111 members, byte-exact, with portable imports/tests and `project/run_preservation.py`; explicit 16-member omission map |
| Actual accepted R4 | 17 exact runtime/documentation/policy members under `tooling/accepted-r4`; explicit 8-member omission map from the original 25-member tool archive |
| Provenance | Original-member/public-file/mode maps, source-only review supplement, exact resource metadata, separate QSF clarification, original source patch, licensing, and host-only restoration record |

Source: `f2bdd413c7ee8c2415545410af06f23c36f14ea2b94d7a8affb2c61011c12ed2`  
Effective: `2ac8dae8355a97697803b7e023bf0742662d5f3ed1d83ecfd2f6babc7db6bc20`  
Original private release manifest: `637bf8c73c14123bd5754f78aceb40820f4360465fdd233c023185f5bae4f1a7`  
Independent review: `0edd9060357acc914380430cbbb57fffa6ac757d1058cd4bc2cb42aac2b5c003`

The original full release manifest, support archive, and tool archive are
**not** mirrored wholesale. Their hashes and complete original member maps
identify the public selections without implying publication of omitted files.
`support-public-source.tar` and `r4-public-source.tar` are explicitly new subset
containers, not the original 111-member/25-member archives.

## Correct build-tool binding

The accepted driver is
`tooling/accepted-r4/scripts/rbf_build.py`, SHA-256
`0be637ccb53ecb6bd1335b53bec7bdef1a87bbb8671c3e1c055172ca32441e16`,
from original R4 source archive
`48292a5b9dc7b9ce3cc6bffce894fc91e2f9d82460a4c65e8b17eadf36fe2180`.
Its sibling reporter/checker modules, Tcl, hierarchy/exclusion policies, and
historical rejected-image hash gate are preserved. The two JSON files beneath
its `tests/fixtures/` directory are **runtime policy configuration**, not
captured test/media fixtures. Omitting them would remove required build gates.

**Do not build this cohort with the historical `8166ff88` driver at the
repository root or at `project/scripts/rbf_build.py`.** The latter remains
byte-exact for reviewed source-enumeration imports only; its operational
entrypoint is inert historical support, not authority or the accepted flow.
R4's creation-time `HOST_ONLY_CORRECTION` / `REQUIRED_NEXT` labels are preserved
as historical metadata in `build-tool-binding.json`; they are not a claim
that the subsequently accepted `0be637cc` driver is unqualified.

No build, source test, SDK, or hardware operation was performed to publish this
tree. Future builds require their own authorization, an installed/licensed
Quartus 17.0.2 Build 602 environment, exclusive resource ownership, and the
original pinned image:

`sha256:1fba8b9347973365e9f7851d73f7cb035e38fefb827cbf0ed2ea291b48bdf6dd`

For an independently authorized replay, use R4's explicit project argument
pointing to a **writable scratch copy**, and `--snapshot` pointing to this
cohort's `inputs.tar` with its adjacent `inputs.json` and `source.tar`.
Select the backend explicitly; supply the pinned image and a separately
qualified reference through the documented R4 environment. Do not invoke
R4's default project path, which is relative to its isolated tool root.
Do not build inside the published source tree or alter the archived inputs.
The local permission/guard/refusal behavior remains unchanged; publication
provides none of those permissions. No reference RBF is supplied.

Plain product source intentionally lacks the effective build-ID injection.
The effective archive supplies normal identity `f2bdd413` and fixed date
`260906`; taking a fresh date-based snapshot is not an exact replay.
`inputs.json`'s original snapshot Git commit identifies the private source
freeze, **not this public branch's commit**. Compiler input, SDK installation,
scratch output, original private release, and public source are distinct
locations; none is silently substituted for another.

## Source contract and remaining obligations

The source adds held complete audio controls with retained reset intent,
per-domain FIFO reset/flush epochs and peer readiness, and precise first-hop
constraints. All 12 Gray capture bits include the actual top-bit
`wr_gray[11]`/`wr_ptr[11]` alias. Later stages and local DSP/reset timing remain
exposed. The 148 unchanged predecessor members preserve the native/scaler,
painter, P/reference/deblock, default 8 KiB AU plus independent VCL, R3/E1FF,
and R2/II2 behavior.

SYS85/native CE4/17, DDR90, Avalon100, HDMI148.5 CE1, audio24.576, management50,
retained SDRAM142 selection, seed6, two processors, and the 81920-bit/96-M10K
FPGA320 floors remain unchanged.

The source review verified 13 new groups/202 retained capture checks and
41 inherited framework groups. Prior accepted/rendered/reset-aborted sample
counts were 8406/8378/28; native/scaler pixel matrices remain inherited,
**not rerun for this publication**. Portable test/import source is present;
the 15 original validation fixtures/media and licensed vendor declarations
are intentionally absent. Fixture-dependent codec tests, historical baseline
comparisons, and whole-top vendor-declaration tests require separately
provided inputs. Do not treat the public subset as a newly executed full suite.

**Physical work is still required.** Warning 330000 persists; ignored
`ASYNC_REG` attributes are not implementation proof. Post-map FIFO read-reset
recovery is **-0.501 ns**, not PASS. CLK100-init, CLK50-request, and unclocked
HPS reset are asynchronous assertion boundaries with local synchronized
release, not newly delay-qualified external paths. Actual reset pulse width,
distribution, recovery/removal, routed capacity, skew, MTBF, all four timing
models, exact reference identity, FPS, tiers, glass, and deployment remain
unapproved by this publication.

`resources.json` is unchanged, including its false
`clock_seed_effort_QSF_bytes_unchanged` comparison. The separately pinned
`resource-metadata-clarification.json` (`a9379d00`) was **outside** the original
`637bf8c7` manifest. Source QSF `408c4e52` is unchanged; the effective-QSF
difference is solely line143's normal `c31b6992` to `f2bdd413` build ID.

## Safety, maps, and licensing

No raw owner receipts, grants, registries, handoffs, runtime/host observations,
SDK binaries, retained databases, raw evidence/logs, validation media, browser
data, credentials, or private recovery bundles are included. R4 mock report
fixtures and their four dependent Python unit files are also omitted.

`original-members.json` accounts for every original member, including exact
hash, mode, public destination or explicit omission. `public-file-map.json`
covers every published file except itself; the Git subtree also binds that
map. `publication-checks.json` records host-only byte/mode/archive/reference
restoration, not HDL execution or timing acceptance.

Per-file copyright and license notices remain authoritative and unchanged.
`licenses/` includes the existing project's GPL-2.0 text and the GPL-3.0 text
required by GPL-3.0-or-later files. Existing Intel-generated project RTL keeps
its Intel notices; no SDK or simulation-library redistribution is asserted.
