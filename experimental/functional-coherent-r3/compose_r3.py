#!/usr/bin/env python3
"""Compose the exact frozen picture R3 with the frozen central-only cohort."""
import datetime
import difflib
import json
import os
from pathlib import Path
import subprocess

from freeze_functional import digest, encode, file_hash, identity, load, mapping, members

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
CENTRAL = HERE / "release-central"
BASE = HERE.parent / "fpga-coherent-a11/critical-cones-v15-5754/release-v15"
R3 = HERE.parent / "fpga-picture-functional-r3-5754/release-r3"
OUT = HERE / "coherent-r3"
OWNER = "ce6e3c70-35d0-47b7-a3b9-c1704c76e2be"
GRANT = "complete-existing-fpga-functionality-before-performance-5754"
CENTRAL_SOURCE = "d34d2e27f04e50e1d0e69227762723af65ebbe9145a11513103031d8d3d9cb34"
R3_RTL = "042659f2c58bc97f2bf706af969a7a40709e96bad112d7f955f615954a45154b"


def restore(root, content):
    for name, data in content.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        assert not path.exists()
        path.write_bytes(data)
        path.chmod(0o444)


def main():
    assert not OUT.exists(), "Never overwrite any composed source or failure"
    registry_path = ROOT / "Memory/lab/fpga-h264-30ff2997/handoff/registry.json"
    registry = load(registry_path)
    scope = next(item for item in registry["fresh_outcome_scopes"] if item["id"] == GRANT)
    assert scope["owner"] == OWNER and scope["state"].startswith("active")
    assert "exact frozen direct R3" in scope["allowed"]
    assert file_hash(CENTRAL / "manifest.json") == \
        "eb71c95f2ccc34a0e331d6407e0cadba314fe6f8886368c34aa1af959b4feb67"
    for name, expected in load(CENTRAL / "manifest.json")["artifacts_sha256"].items():
        assert file_hash(CENTRAL / name) == expected, name
    assert file_hash(BASE / "manifest.json") == \
        "b32dd240e54cbafca70262bf4d149b2fb5d5ca877c6b86d4b05cda5b49417a51"
    for name, expected in load(BASE / "manifest.json")["artifacts_sha256"].items():
        assert file_hash(BASE / name) == expected, name
    before, original = members(CENTRAL / "source.tar"), members(BASE / "source.tar")
    assert identity(mapping(before)) == CENTRAL_SOURCE
    assert set(before) == set(original) and len(before) == 149
    original_validation = members(BASE / "validation-code.tar")
    validation = members(CENTRAL / "validation-code.tar")
    assert len(validation) == 87
    expected_r3 = {
        "manifest.json": "c5d2ce5623c5298e4bb48903ba815aa8070129d28ffd71d03c0429f403c223a9",
        "picture-r3-from-v15.patch": "caaad09faf701f3db712b5354483caf0687305eb8228a410469879b6aa00fd6c",
        "picture-r3-from-r2.patch": "9985d18b4e042b48c4da55af03160b17123b943b228b599d299e363355fb7245",
        "source-files.tar": "bdfdb753c43af9f6b61b6bdc0bbbbaa61ae80910c82559ebafc0d67e74f9c8f6",
        "project-inputs.json": "ce7028875909b86e3aa93c539527e4a5e2e7a06317c9860a2836498879c25a30",
    }
    for name, expected in expected_r3.items():
        assert file_hash(R3 / name) == expected, name
    leaf = load(R3 / "manifest.json")
    postimages = members(R3 / "source-files.tar")
    descriptions = {**leaf["changed_source_members"], **leaf["validation_setup_member"]}
    assert set(postimages) == set(descriptions) and len(postimages) == 5
    for name, description in descriptions.items():
        assert digest(postimages[name]) == description["sha256"], name
    for name in leaf["changed_source_members"]:
        if name.startswith("fpga/Plex_MiSTer/"):
            short = name.removeprefix("fpga/Plex_MiSTer/")
            assert before[short] == original[short]
        else:
            assert validation["central-only/project/" + name] == original_validation["project/" + name]
    assert digest(postimages["fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"]) == R3_RTL
    expected_source = dict(before)
    expected_source["rtl/ddr_frame_store.sv"] = postimages["fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"]
    source_sha = identity(mapping(expected_source))
    intent = {
        "owner": OWNER, "grant": GRANT, "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "handle": "functional-compose-r3-a01", "registry_sha256": file_hash(registry_path),
        "action": "Restore complete frozen central/V15 cohorts; apply exact V15-relative R3 patch with zero fuzz; restore explicit setup modes.",
        "output": str(OUT), "central_source_sha256": CENTRAL_SOURCE,
        "expected_composed_source_sha256": source_sha,
        "base_manifest_sha256": file_hash(BASE / "manifest.json"),
        "central_manifest_sha256": file_hash(CENTRAL / "manifest.json"),
        "r3_inputs_sha256": expected_r3, "validation_members_before": 87,
        "fixtures_sha256": file_hash(CENTRAL / "fixture-preservation.json"),
        "late_r1_message": "Exact R1 already composed as59ec0afa and retained under rejected/picture-r1; independently rejected. Current mission/registry authorize corrected R3, not R1 reacceptance.",
        "source_or_hardware_approval": False,
    }
    intent_path = HERE / "evidence/picture-r3-composition-intent.json"
    assert not intent_path.exists()
    intent_path.write_bytes(encode(intent))
    OUT.mkdir()
    (OUT / "evidence").mkdir()
    (OUT / "intent.json").write_bytes(encode(intent))
    restore(OUT / "project/fpga/Plex_MiSTer", before)
    restore(OUT, {name.removeprefix("central-only/"): data
                  for name, data in validation.items() if name.startswith("central-only/")})
    fixtures = load(CENTRAL / "fixture-preservation.json")
    assert len(fixtures) == 96
    for name, expected in fixtures.items():
        source = HERE / "central-only" / name
        assert file_hash(source) == expected, name
        destination = OUT / name
        if destination.exists():
            assert file_hash(destination) == expected, name
        else:
            restore(OUT, {name: source.read_bytes()})
    preimages = {name: file_hash(OUT / "project" / name)
                 for name in leaf["changed_source_members"]}
    for name in leaf["changed_source_members"]:
        (OUT / "project" / name).chmod(0o644)
    scratch = OUT / "evidence/compiler-scratch"
    scratch.mkdir()
    env = os.environ.copy()
    env.update(TMPDIR=str(scratch), TMP=str(scratch), TEMP=str(scratch))
    command = ["patch", "--batch", "--forward", "--fuzz=0", "-p1",
               "--directory", str(OUT / "project"),
               "--input", str(R3 / "picture-r3-from-v15.patch")]
    result = subprocess.run(command, env=env, text=True, capture_output=True)
    (OUT / "evidence/picture-r3-patch-apply.log").write_text(result.stdout + result.stderr)
    assert result.returncode == 0, result.stdout + result.stderr
    for name, description in descriptions.items():
        path = OUT / "project" / name
        assert file_hash(path) == description["sha256"], name
        path.chmod(int(description["mode"], 8))
    source = {str(path.relative_to(OUT / "project/fpga/Plex_MiSTer")): path.read_bytes()
              for path in (OUT / "project/fpga/Plex_MiSTer").rglob("*") if path.is_file()}
    assert source == expected_source
    changed = sorted(name for name in source if source[name] != original[name])
    assert changed == ["Plex.qsf", "Plex.sv", "rtl/ddr_frame_store.sv"]
    for name, description in leaf["unchanged_owned_rtl"].items():
        assert file_hash(OUT / "project" / name) == description["sha256"]
    patch = "".join("".join(difflib.unified_diff(
        original[name].decode().splitlines(True), source[name].decode().splitlines(True),
        fromfile="a/" + name, tofile="b/" + name)) for name in changed)
    (OUT / "evidence/coherent-product.patch").write_text(patch)
    (OUT / "evidence/central.patch").write_bytes((CENTRAL / "central.patch").read_bytes())
    (OUT / "evidence/picture-r3-from-v15.patch").write_bytes((R3 / "picture-r3-from-v15.patch").read_bytes())
    receipt = {
        **intent, "result": "EXACT_R3_COMPOSED_WITH_FROZEN_CENTRAL_PENDING_COHERENT_VALIDATION_AND_REVIEW",
        "command": command, "command_exit_code": result.returncode,
        "preimages": preimages, "expected_postimages_verified": descriptions,
        "source_map": mapping(source), "source_sha256": source_sha,
        "changed_product_members_from_v15": changed,
        "unchanged_product_members_from_v15": 146,
        "only_product_change_from_central": "rtl/ddr_frame_store.sv",
        "fixture_members_preserved": 96,
        "composed_product_patch_sha256": digest(patch.encode()),
        "central_patch_sha256": file_hash(CENTRAL / "central.patch"),
        "leaf_patch_sha256": file_hash(R3 / "picture-r3-from-v15.patch"),
        "setup_execute_mode": "0o544, explicit manifest restore; identical helper bytes",
        "guard_wrapper_sha256": file_hash(OUT / "guarded_campaign.py"),
        "running_commands": [], "no_physical_tools": True,
    }
    (OUT / "evidence/composition-result.json").write_bytes(encode(receipt))
    print(json.dumps({key: receipt[key] for key in (
        "result", "source_sha256", "composed_product_patch_sha256",
        "changed_product_members_from_v15", "fixture_members_preserved",
        "leaf_patch_sha256", "central_patch_sha256",
    )}, indent=2))


if __name__ == "__main__":
    main()
