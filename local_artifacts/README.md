# Local non-build artefact cache

This directory is for local, non-redistributable artefacts that must survive `make clean`.
It is intentionally git-ignored except for this README.

Current use: the derived 624×480 H.264 validation asset described in
`docs/derived-validation-assets.md` may be cached under
`local_artifacts/derived_validation/`. The media is derived from user library
content, so do not commit it. Verify hashes against the tracked provenance file
before using it for measurements.
