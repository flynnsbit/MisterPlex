#!/usr/bin/env python3
"""Source-bound, ordinary-decoder GOP12 comparison. A mismatch is always nonzero."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
PIN = "00e187d0771223cdc41a604de89b65b1443d4d4a"
RTL = "fpga/Plex_MiSTer/rtl/"
FIXTURE = "tests/fixtures/h264_phase1a_p16skip/plex_phase1a_p16skip_320x240_12f.264"
SOURCES = [
    "stream_ingest", "bitstream_fifo", "nalu_scanner", "sps_parser", "pps_parser",
    "slice_hdr_parser", "h264_iq_idct_4x4", "h264_inter_pred", "h264_coeff_sat9",
    "h264_i16_dc_hadamard", "h264_recon", "h264_bit_reader", "h264_residual_seq",
    "h264_slice_rbsp_ram", "h264_cavlc_residual", "h264_intra_pred",
    "h264_syntax_primitives", "h264_deblock", "h264_dpb", "h264_p_slice_modes",
    "h264_mb_ctrl", "decode_stub", "stream_path",
]
BENCH = ["tests/rtl/gop12_oracle_tb.sv", "tests/rtl/gop12_oracle_tb.cpp"]
AU_BENCH = ["tests/rtl/fpga_video_publish_tb_top.sv", "tests/rtl/fpga_video_publish_tb.cpp"]
DDR_BENCH = [BENCH[0], "tests/rtl/gop12_ddr_oracle_tb.cpp"]
HARNESS = BENCH + ["tests/unit/gop12_oracle.py", "tests/unit/run_gop12_fpga_sim.sh",
                   "scripts/run_verilator.sh"]
FLAGS = ["--cc", "--exe", "--build", "--top-module", "gop12_oracle_tb",
         "-Wno-fatal", "-CFLAGS", "-std=c++17 -O2"]
WIDTH, HEIGHT, COUNT = 320, 240, 12
PICTURE = WIDTH * HEIGHT * 3 // 2


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def file_hash(path):
    return digest(path.read_bytes())


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def checked(cmd, **kwargs):
    return subprocess.check_output(cmd, cwd=ROOT, **kwargs)


def git_bytes(pin, path):
    return checked(["git", "show", f"{pin}:{path}"])


def verify_files(directory, hashes):
    for name, expected in hashes.items():
        path = directory / name
        if not path.is_file() or file_hash(path) != expected:
            raise RuntimeError(f"missing/stale/tampered artifact: {path}")


def verify_build(directory, key, hashes):
    manifest = json.loads((directory / "build.json").read_text())
    if manifest["input_key"] != key or manifest["inputs"] != hashes:
        raise RuntimeError("stale build binding; refusing binary reuse")
    verify_files(directory / "inputs", hashes)
    verify_files(directory, manifest["outputs"])
    return manifest


def tool_identity(executable):
    path = Path(executable).resolve()
    return {"path": str(path), "sha256": file_hash(path),
            "version": checked([str(path), "-version" if path.name.startswith("ff") else
                                "--version"], stderr=subprocess.STDOUT).decode().splitlines()[0]}


def prepare(args):
    pin = args.source_pin
    source_build = None
    source_manifest = None
    if pin != "worktree":
        pin = checked(["git", "rev-parse", "--verify", f"{pin}^{{commit}}"]).decode().strip()
    if args.source_build:
        source_build = (ROOT / args.source_build).resolve()
        if not source_build.is_relative_to(ROOT / "build/verilator/gop12-oracle"):
            raise RuntimeError("source build must be an immutable oracle build inside this worktree")
        source_manifest = json.loads((source_build / "build.json").read_text())
        verify_build(source_build, source_manifest["input_key"], source_manifest["inputs"])
        if source_manifest["source_pin"] != "worktree":
            raise RuntimeError("shared worktree cohort cannot silently adopt a historical donor pin")
        get = lambda p: (source_build / "inputs" / p).read_bytes()
    else:
        get = (lambda p: (ROOT / p).read_bytes()) if pin == "worktree" else (
            lambda p: git_bytes(pin, p))
    source_names = [RTL + name + ".sv" for name in SOURCES]
    ddr_ports = re.search(rb"\binput\s+wire\s+ddr_stream_enable\b",
                          get(RTL + "stream_path.sv")) is not None
    if ddr_ports:
        source_names.append(RTL + "ddr_bitstream_reader.sv")
    selected = source_names + [RTL + "h264_chroma_nc.svh", "fpga/Plex_MiSTer/LICENSE"]
    bench = BENCH
    binary = "obj/Vgop12_oracle_tb"
    if args.au_publish or args.ddr_native:
        qip = "fpga/Plex_MiSTer/files.qip"
        source_names = ["fpga/Plex_MiSTer/" + name for name in re.findall(
            r"^set_global_assignment\s+-name\s+SYSTEMVERILOG_FILE\s+(rtl/\S+)\s*$",
            get(qip).decode(), re.MULTILINE)]
        if not source_names or any(".." in Path(p).parts for p in source_names):
            raise RuntimeError("invalid composed AU source specification")
        bench, binary = ((DDR_BENCH, "obj/Vgop12_oracle_tb") if args.ddr_native else
                         (AU_BENCH, "obj/Vfpga_video_publish_tb"))
        selected = source_names + [
            qip, "fpga/Plex_MiSTer/LICENSE", *bench,
            "host/libmisterplex/ddr_bitstream_ring.hpp",
            "host/libmisterplex/mailbox_abi_spec.hpp",
        ]
        selected += (["tests/rtl/ddr_bitstream_ring_bfm.hpp"] if args.ddr_native else
                     ["tests/unit/test_fpga_video_au_publish.sh"])
    data = {}
    for path in selected:
        data[path] = get(path)
        if path.endswith((".sv", ".svh")):
            for include in re.findall(rb'^\s*`include\s+"([^"]+)"', data[path], re.MULTILINE):
                name = include.decode()
                if Path(name).is_absolute() or ".." in Path(name).parts:
                    raise RuntimeError(f"include escapes selected RTL directory: {name}")
                dependency = str(Path(path).parent / name)
                if not dependency.startswith(RTL):
                    raise RuntimeError(f"include outside selected RTL: {dependency}")
                if dependency not in selected:
                    selected.append(dependency)
    if args.au_publish and args.frames != 2 and b"FULL_AU_FRAMES" not in data[AU_BENCH[1]]:
        raise RuntimeError("selected source-owned AU producer does not support FULL_AU_FRAMES")
    if (args.au_publish and args.au_input_limit > 8192 and
            re.search(rb"encoded\.size\(\)\s*<=\s*8192\b", data[AU_BENCH[1]])):
        raise RuntimeError("selected source-owned AU producer still has the legacy 8192-byte guard; modern 64KiB integration is unresolved")
    if args.au_publish and args.pts_sidecar and b"FULL_AU_ORIGINAL_TIMING" not in data[AU_BENCH[1]]:
        raise RuntimeError("selected composed producer lacks strict original-timing support")
    if args.au_runtime_geometry and b"FULL_AU_RUNTIME_GEOMETRY" not in data[AU_BENCH[1]]:
        raise RuntimeError("selected composed producer lacks the runtime coded/crop geometry contract")
    if args.au_native_beam and (
            not all(token in data[AU_BENCH[0]] for token in
                    (b"NATIVE_BEAM", b"NATIVE_SCANDOUBLE", b"DDR_FRAME_STORE")) or
            not all(token in data[AU_BENCH[1]] for token in
                    (b"FULL_AU_NATIVE_BEAM", b"FULL_AU_SCANDOUBLE"))):
        raise RuntimeError("selected composed producer lacks matching native-beam/scandouble controls")
    if args.au_idr_only and b"IDR_ONLY_PROFILE" not in data[AU_BENCH[0]]:
        raise RuntimeError("selected composed producer lacks the static-IDR profile selection")
    if (args.ddr_native and args.au_input_limit > 8192 and
            re.search(rb"\.MAX_AU_BYTES\s*\(\s*8192\s*\)", data[RTL + "stream_path.sv"])):
        raise RuntimeError("selected stream_path still configures the legacy 8192-byte reader; modern 64KiB integration is unresolved")
    fixture = args.fixture or FIXTURE
    fixture_path = (ROOT / fixture).resolve()
    if not fixture_path.is_relative_to(ROOT):
        raise RuntimeError("fixture must be inside this worktree")
    fixture = str(fixture_path.relative_to(ROOT))
    fixture_get = (lambda p: (ROOT / p).read_bytes()) if args.fixture else get
    data[fixture] = fixture_get(fixture)
    notice = str(Path(fixture).parent / "README.md")
    data[notice] = fixture_get(notice)
    fixture_deblock = None
    if args.fixture:
        provenance = str(Path(fixture).parent / "provenance.json")
        if (ROOT / provenance).is_file():
            data[provenance] = fixture_get(provenance)
            declared = json.loads(data[provenance])
            fixture_deblock = declared.get("required_disable_deblocking_filter_idc")
            if fixture_deblock is not None and fixture_deblock not in (0, 1, 2):
                raise RuntimeError("invalid required encoded deblocking flag in provenance")
            if declared.get("annexb_sha256") != digest(data[fixture]):
                raise RuntimeError("fixture bytes do not match encoder provenance")
            for name, expected_hash in declared.get("source_files", {}).items():
                source_file = (ROOT / name).resolve()
                if not source_file.is_relative_to(ROOT):
                    raise RuntimeError("fixture provenance source must be inside worktree")
                content = source_file.read_bytes()
                if digest(content) != expected_hash:
                    raise RuntimeError(f"fixture provenance source changed: {name}")
                data[name] = content
            generator = declared.get("source_generator")
            if generator:
                generator_path = (ROOT / generator).resolve()
                if not generator_path.is_relative_to(ROOT):
                    raise RuntimeError("fixture generator must be inside worktree")
                data[generator] = generator_path.read_bytes()
                if digest(data[generator]) != declared["generator_sha256"]:
                    raise RuntimeError("fixture generator does not match encoder provenance")
        named_provenance = str(Path(fixture).with_suffix(".json"))
        if (ROOT / named_provenance).is_file():
            data[named_provenance] = fixture_get(named_provenance)
            declared = json.loads(data[named_provenance])
            expected_hash = declared.get("annexb_sha256", declared.get("sha256"))
            if expected_hash is not None and expected_hash != digest(data[fixture]):
                raise RuntimeError("fixture bytes do not match named provenance")
            required_idc = declared.get("required_disable_deblocking_filter_idc",
                                        declared.get("disable_deblocking_filter_idc"))
            if required_idc is not None:
                if required_idc not in (0, 1, 2) or fixture_deblock not in (None, required_idc):
                    raise RuntimeError("invalid/conflicting encoded filtering provenance")
                fixture_deblock = required_idc
    for path in HARNESS:
        if (args.au_publish and path in BENCH) or (args.ddr_native and path == BENCH[1]):
            continue
        data[path] = (ROOT / path).read_bytes()
    if args.au_publish:
        path = "tests/unit/au_publish_oracle.py"
        data[path] = (ROOT / path).read_bytes()
    pts_sidecar = None
    if args.ddr_native or args.au_runtime_geometry:
        for path in ("tests/unit/ddr_native_oracle.py", "tests/unit/check_pms_capture_oracle.py"):
            data[path] = (ROOT / path).read_bytes()
    if args.au_runtime_geometry:
        path = "tests/unit/au_geometry_oracle.py"
        data[path] = (ROOT / path).read_bytes()
    if args.pts_sidecar:
        sidecar = (ROOT / args.pts_sidecar).resolve()
        if not sidecar.is_relative_to(ROOT):
            raise RuntimeError("PTS sidecar must be inside the worktree")
        pts_sidecar = str(sidecar.relative_to(ROOT))
        data[pts_sidecar] = sidecar.read_bytes()
    if args.require_color_motion:
        path = "tests/unit/gop12_motion_coverage.cpp"
        data[path] = (ROOT / path).read_bytes()
    # A changing integration tree must never silently become a mixed snapshot.
    for path in selected:
        if get(path) != data[path]:
            raise RuntimeError(f"source changed while snapshotting: {path}; retry")
    hashes = {p: digest(b) for p, b in data.items()}
    if source_manifest:
        for path in selected:
            if hashes[path] != source_manifest["inputs"].get(path):
                raise RuntimeError(f"shared source cohort differs from its frozen build: {path}")
        for path in hashes:
            if (path.startswith("tests/unit/") or path == "scripts/run_verilator.sh") and (
                    hashes[path] != source_manifest["inputs"].get(path)):
                raise RuntimeError(f"oracle helper changed since the shared source snapshot: {path}")
    wrapper = ROOT / "scripts/run_verilator.sh"
    version = checked([str(wrapper), "--version"], stderr=subprocess.STDOUT).decode().strip()
    verilator = os.environ.get("VERILATOR")
    if not verilator:
        suite = Path(os.environ.get("OSS_CAD_SUITE", str(Path.home() / ".local/oss-cad-suite")))
        verilator = str(suite / "bin/verilator") if (suite / "bin/verilator").exists() else shutil.which("verilator")
    if not verilator:
        raise RuntimeError("Verilator is required; a skipped simulator is not a pass")
    compiler = shutil.which("g++")
    if not compiler:
        raise RuntimeError("g++ is required")
    tools = {"verilator": {"version": version, "path": str(Path(verilator).resolve()),
                           "sha256": file_hash(Path(verilator))},
             "compiler": tool_identity(compiler),
             "ffmpeg": tool_identity(shutil.which("ffmpeg") or "ffmpeg"),
             "ffprobe": tool_identity(shutil.which("ffprobe") or "ffprobe")}
    verilator_bin = Path(verilator).resolve().with_name("verilator_bin")
    if not verilator_bin.is_file():
        raise RuntimeError("cannot bind actual verilator_bin beside launcher")
    tools["verilator"]["binary_sha256"] = file_hash(verilator_bin)
    if args.require_color_motion:
        packages = ["libavformat", "libavcodec", "libavutil"]
        libraries = {}
        for package in packages:
            directory = checked(["pkg-config", "--variable=libdir", package]).decode().strip()
            library = (Path(directory) / (package + ".so")).resolve()
            libraries[str(library)] = file_hash(library)
        tools["motion_libav"] = {
            "flags": shlex.split(checked(["pkg-config", "--cflags", "--libs"] + packages).decode()),
            "versions": checked(["pkg-config", "--modversion"] + packages).decode().splitlines(),
            "libraries": libraries,
        }
    lifetime = all(token in data[RTL + "h264_mb_ctrl.sv"] for token in
                   (b"dpb_write_ready", b"dpb_frame_promoted", b"dpb_frame_error", b"decode_error"))
    color_metadata = all(token in data[RTL + "h264_mb_ctrl.sv"] for token in
                         (b"lat_full_range", b"lat_matrix"))
    frontend_mode = re.search(rb"parameter\s+(?:bit\s+)?ENABLE_AU_PROTOCOL",
                              data[RTL + "stream_path.sv"]) is not None
    if b"frame_promoted" in data[RTL + "h264_dpb.sv"] and not lifetime:
        raise RuntimeError("new DPB lacks known composed acceptance/promotion observation wiring")
    flags = FLAGS + (["-DGOP12_DDR_PORTS"] if ddr_ports else [])
    if lifetime:
        flags.append("-DGOP12_DPB_LIFETIME")
    if color_metadata:
        flags.append("-DGOP12_COLOR_METADATA")
    if frontend_mode:
        flags.append("-DGOP12_OBSERVE_FRONTEND_MODE")
    if args.au_publish:
        flags = ["--cc", "--exe", "--build", "--top-module", "fpga_video_publish_tb",
                 "-Wno-fatal", "-GINTEGRATE_STREAM=1", "-DFULL_AU_RTL=1",
                 "-CFLAGS", f"-std=c++17 -O2 -DFULL_AU=1 -DFULL_AU_FRAMES={args.frames} "
                 "-I@INPUTS@/host/libmisterplex"]
        if args.pts_sidecar:
            flags[-1] += " -DFULL_AU_ORIGINAL_TIMING=1"
        if args.au_runtime_geometry:
            flags[-1] += " -DFULL_AU_RUNTIME_GEOMETRY=1"
        if args.au_native_beam:
            scandouble = 1 if args.au_native_scandouble is None else args.au_native_scandouble
            flags[-1] += f" -DFULL_AU_NATIVE_BEAM=1 -DFULL_AU_SCANDOUBLE={scandouble}"
            flags += ["-GNATIVE_BEAM=1", f"-GNATIVE_SCANDOUBLE={scandouble}", "-DDDR_FRAME_STORE=1"]
        if args.au_idr_only:
            flags.append("-GIDR_ONLY_PROFILE=1")
    if args.ddr_native:
        if not (ddr_ports and lifetime and color_metadata and frontend_mode):
            raise RuntimeError("real DDR native oracle requires current AU/lifetime/metadata observation interfaces")
        flags += ["-DGOP12_REAL_DDR", "-CFLAGS",
                  "-I@INPUTS@/host/libmisterplex -I@INPUTS@/tests/rtl"]
    build_env = {k: os.environ.get(k) for k in (
        "PATH", "CXX", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS",
        "CPATH", "CPLUS_INCLUDE_PATH", "LIBRARY_PATH", "VERILATOR_ROOT",
        "LD_LIBRARY_PATH", "LD_PRELOAD")}
    build_env["TMPDIR"] = "@BUILD@/compiler-scratch"
    binding = {"schema": "misterplex.gop12.inputs.v1", "source_pin": pin,
               "source_base_commit": (source_manifest["source_base_commit"] if source_manifest else
                                      checked(["git", "rev-parse", "HEAD"]).decode().strip()
                                      if pin == "worktree" else pin),
               "inputs": hashes, "tools": tools, "flags": flags,
               "compiler_make_flags": f"CXX={compiler} LINK={compiler}",
               "environment": build_env, "fixture": fixture,
               "expected_frames": args.frames,
               "binary_path": binary, "au_publish": args.au_publish, "ddr_native": args.ddr_native,
               "au_input_limit_bytes": args.au_input_limit if args.au_publish or args.ddr_native else None,
               "pts_sidecar": pts_sidecar, "fixture_timeline": args.fixture_timeline,
               "dpb_lifetime_observed": lifetime and not args.au_publish,
               "color_metadata_observed": color_metadata and not args.au_publish,
               "frontend_mode_observed": frontend_mode and not args.au_publish,
               "require_color_motion": args.require_color_motion,
               "qualification_policy": {"encoded_deblock_idc": [1], "reference_vcl_required": True},
               "transport": ("real DDR ring Probe/Begin/AUs/Drain and independent accepted-native observer"
                             if args.ddr_native else
                             "real DDR ring Probe/Begin/Pause/AUs/Resume/Drain and native publisher"
                             if args.au_publish else
                             "paced ioctl bytes, three idle cycles per byte; 512 per NAL")}
    if fixture_deblock is not None:
        binding["required_disable_deblocking_filter_idc"] = fixture_deblock
    if args.au_runtime_geometry:
        binding["au_runtime_geometry"] = True
    if args.au_native_beam:
        binding["au_native_beam"] = True
        binding["au_native_scandouble"] = scandouble
    if args.au_idr_only:
        binding["au_idr_only"] = True
    binding["source_cohort_sha256"] = digest(canonical({p: hashes[p] for p in selected}))
    if source_manifest:
        binding["source_snapshot"] = {
            "input_key": source_manifest["input_key"],
            "build_manifest_sha256": file_hash(source_build / "build.json"),
        }
    key = digest(canonical(binding))
    build = ROOT / "build/verilator/gop12-oracle" / key
    build.mkdir(parents=True, exist_ok=True)
    scratch = build / "compiler-scratch"
    scratch.mkdir(exist_ok=True)
    compile_environment = dict(os.environ, TMPDIR=str(scratch))
    with (build / "build.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return materialize_build(args, build, data, source_names, bench, binary,
                                 binding, key, fixture, compiler, compile_environment)


def materialize_build(args, build, data, source_names, bench, binary,
                      binding, key, fixture, compiler, compile_environment):
    hashes, flags, tools, pin = (binding["inputs"], binding["flags"],
                                binding["tools"], binding["source_pin"])
    snapshot = build / "inputs"
    if snapshot.exists():
        verify_files(snapshot, hashes)
    else:
        snapshot.mkdir()
        for path, content in data.items():
            dest = snapshot / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(content)
            dest.chmod(0o444)
        for directory, _, _ in os.walk(snapshot, topdown=False):
            Path(directory).chmod(0o555)
    if (build / "build.json").exists():
        manifest = verify_build(build, key, hashes)
        print(f"SOURCE_BOUND_REUSE {key}", flush=True)
    else:
        if args.reuse_only:
            raise RuntimeError("no verified build for these exact inputs; refusing stale reuse")
        command = ["bash", str(snapshot / "scripts/run_verilator.sh")] + [
            flag.replace("@INPUTS@", str(snapshot)) for flag in flags] + [
            "--Mdir", str(build / "obj"), "-I" + str(snapshot / RTL),
            "-MAKEFLAGS", f"CXX={compiler} LINK={compiler}"]
        command += [str(snapshot / bench[0])]
        command += [str(snapshot / p) for p in source_names]
        command += [str(snapshot / bench[1])]
        print(f"BUILD {key} pin={pin}", flush=True)
        with (build / "compile.log").open("w") as log:
            rc = subprocess.call(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                 env=compile_environment)
        if rc:
            raise RuntimeError(f"Verilator build failed ({rc}); see {build / 'compile.log'}")
        outputs = {binary: file_hash(build / binary)}
        motion_command = None
        if args.require_color_motion:
            motion_command = [compiler, "-std=c++17", "-O2",
                              str(snapshot / "tests/unit/gop12_motion_coverage.cpp"),
                              "-o", str(build / "gop12_motion_coverage")]
            motion_command += tools["motion_libav"]["flags"]
            with (build / "motion-compile.log").open("w") as log:
                subprocess.run(motion_command, cwd=ROOT, stdout=log,
                               stderr=subprocess.STDOUT, check=True, env=compile_environment)
            outputs["gop12_motion_coverage"] = file_hash(build / "gop12_motion_coverage")
        verify_files(snapshot, hashes)
        manifest = dict(binding, input_key=key, command=command,
                        motion_command=motion_command, outputs=outputs)
        write_json(build / "build.json", manifest)
    return build, manifest, snapshot / fixture


def compare(actual, reference, count=COUNT):
    if len(actual) != count * PICTURE or len(reference) != count * PICTURE or not count:
        raise RuntimeError(f"exact GOP12 byte count: actual={len(actual)} oracle={len(reference)} "
                           f"expected={count * PICTURE}")
    frames = []
    total_wrong = 0
    first = None
    for frame in range(count):
        planes = {}
        for plane, offset, size, width in (
            ("Y", 0, WIDTH * HEIGHT, WIDTH),
            ("U", WIDTH * HEIGHT, WIDTH * HEIGHT // 4, WIDTH // 2),
            ("V", WIDTH * HEIGHT * 5 // 4, WIDTH * HEIGHT // 4, WIDTH // 2)):
            begin = frame * PICTURE + offset
            a, b = actual[begin:begin + size], reference[begin:begin + size]
            wrong, error, maximum = 0, 0, 0
            for i, (av, bv) in enumerate(zip(a, b)):
                diff = abs(av - bv)
                error += diff
                maximum = max(maximum, diff)
                wrong += diff != 0
                if diff and first is None:
                    first = {"frame": frame, "plane": plane, "x": i % width, "y": i // width,
                             "actual": av, "oracle": bv}
            planes[plane] = {"mismatches": wrong, "samples": size, "mae": error / size,
                             "max_error": maximum, "actual_sha256": digest(a), "oracle_sha256": digest(b)}
            total_wrong += wrong
        frames.append({"index": frame, "planes": planes})
    return {"exact": total_wrong == 0, "mismatches": total_wrong,
            "first_mismatch": first, "frames": frames}


def negative_controls(reference, build, manifest):
    # These isolate the scorer/provenance checks; never substitute for DUT output.
    wrong = bytearray(reference)
    wrong[0] ^= 1
    count = manifest["expected_frames"]
    controls = {
        "scorer_self_comparison": compare(reference, reference, count)["exact"],
        "wrong_oracle_rejected": not compare(reference, wrong, count)["exact"],
    }
    if count > 1:
        controls["frozen_output_rejected"] = not compare(reference[:PICTURE] * count, reference, count)["exact"]
    else:
        controls["constant_zero_output_rejected"] = not compare(bytes(len(reference)), reference, count)["exact"]
    for plane, offset in (("U", WIDTH * HEIGHT), ("V", WIDTH * HEIGHT * 5 // 4)):
        wrong_chroma = bytearray(reference)
        wrong_chroma[offset] ^= 1
        controls[f"wrong_oracle_{plane}_rejected"] = not compare(reference, wrong_chroma, count)["exact"]
    try:
        verify_build(build, "wrong-source-key", manifest["inputs"])
        controls["stale_build_rejected"] = False
    except RuntimeError:
        controls["stale_build_rejected"] = True
    try:
        verify_files(build, {"nonexistent-actual-output.i420": digest(reference)})
        controls["score_without_actual_output_rejected"] = False
    except RuntimeError:
        controls["score_without_actual_output_rejected"] = True
    if not all(controls.values()):
        raise RuntimeError(f"negative-control failure: {controls}")
    return controls


def slice_headers(ffmpeg, fixture, output, count):
    command = [ffmpeg, "-hide_banner", "-loglevel", "info", "-nostdin", "-i", str(fixture),
               "-map", "0:v:0", "-c:v", "copy", "-bsf:v", "trace_headers", "-f", "null", "-"]
    with output.open("w") as log:
        subprocess.run(command, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=log, check=True)
    headers = []
    pps_qp, pps_id, in_pps = {}, None, False
    for line in output.read_text().splitlines():
        if "Picture Parameter Set" in line:
            in_pps, pps_id = True, None
        elif "Slice Header" in line:
            in_pps = False
            headers.append({})
        parameter = re.search(r"\]\s+\d+\s+(pic_parameter_set_id|pic_init_qp_minus26)\s+\S+\s+=\s+(-?\d+)", line)
        if in_pps and parameter:
            if parameter[1] == "pic_parameter_set_id":
                pps_id = int(parameter[2])
            elif pps_id is not None:
                pps_qp[pps_id] = 26 + int(parameter[2])
            continue
        match = re.search(r"\]\s+\d+\s+(nal_ref_idc|frame_num|first_mb_in_slice|slice_type|"
                          r"pic_parameter_set_id|slice_qp_delta|"
                          r"disable_deblocking_filter_idc|slice_alpha_c0_offset_div2|"
                          r"slice_beta_offset_div2)\s+\S+\s+=\s+(-?\d+)", line)
        if match and headers and not in_pps:
            # Intervening AUD/SPS/PPS NALs must not replace the slice's own NRI.
            if match[1] == "nal_ref_idc" and "nal_ref_idc" in headers[-1]:
                continue
            headers[-1][match[1]] = int(match[2])
            if match[1] == "slice_qp_delta":
                active_pps = headers[-1].get("pic_parameter_set_id")
                if active_pps not in pps_qp:
                    raise RuntimeError("ordinary slice QP lacks its encoded PPS identity")
                headers[-1]["pic_init_qp"] = pps_qp[active_pps]
                headers[-1]["slice_qp"] = pps_qp[active_pps] + int(match[2])
    if len(headers) != count or any(h.get("first_mb_in_slice") != 0 or
                                   "frame_num" not in h or "nal_ref_idc" not in h for h in headers):
        raise RuntimeError(f"required {count} independently identified single-slice frames")
    return headers, command


def color_spans(reference):
    return {
        plane: [{"min": min(reference[f * PICTURE + offset:f * PICTURE + offset + size]),
                 "max": max(reference[f * PICTURE + offset:f * PICTURE + offset + size])}
                for f in range(COUNT)]
        for plane, offset, size in (("Y", 0, WIDTH * HEIGHT),
                                   ("U", WIDTH * HEIGHT, WIDTH * HEIGHT // 4),
                                   ("V", WIDTH * HEIGHT * 5 // 4, WIDTH * HEIGHT // 4))
    }


def motion_coverage(build, fixture, run_dir, reference):
    command = [str(build / "gop12_motion_coverage"), str(fixture)]
    output = run_dir / "motion.frames.jsonl"
    with output.open("w") as frames, (run_dir / "motion.log").open("w") as log:
        subprocess.run(command, cwd=ROOT, stdout=frames, stderr=log, check=True)
    decoded = [json.loads(line) for line in output.read_text().splitlines()]
    if len(decoded) != COUNT:
        raise RuntimeError("motion decoder did not produce twelve frame identities")
    total = {"vectors": 0, "p16_vectors": 0, "fractional_luma": 0, "fractional_chroma": 0,
             "fractional_border_support": 0, "fractional_chroma_border_support": 0,
             "non_previous_reference": 0}
    borders = {p: 0 for p in ("left", "right", "top", "bottom")}
    chroma_borders = dict(borders)
    phases, per_frame, examples, footprints = {}, [], [], []
    for i, frame in enumerate(decoded):
        if (frame["index"], frame["width"], frame["height"], frame["pict_type"]) != (
                i, WIDTH, HEIGHT, "I" if i == 0 else "P"):
            raise RuntimeError("ordinary motion decoder frame identity mismatch")
        count = {k: 0 for k in total}
        for vector_index, vector in enumerate(frame["vectors"]):
            scale = vector["motion_scale"]
            if scale != 4:
                raise RuntimeError("H264 vector export did not use quarter-luma units")
            x, y = vector["motion_x"], vector["motion_y"]
            qx, qy = x % scale, y % scale
            fractional = bool(qx or qy)
            count["vectors"] += 1
            count["p16_vectors"] += (vector["w"], vector["h"]) == (16, 16)
            count["non_previous_reference"] += vector["source"] != -1
            count["fractional_luma"] += fractional
            fractional_chroma = bool(x % (2 * scale) or y % (2 * scale))
            count["fractional_chroma"] += fractional_chroma
            phase = f"{qx},{qy}"
            phases[phase] = phases.get(phase, 0) + 1
            dx, dy = vector["dst_x"] - vector["w"] // 2, vector["dst_y"] - vector["h"] // 2
            if any(v % 2 for v in (dx, dy, vector["w"], vector["h"])):
                raise RuntimeError("motion partition is not aligned for 4:2:0 footprint observation")
            ix, iy = dx + x // scale, dy + y // scale
            bounds = {"left": ix - (2 if qx else 0),
                      "right": ix + vector["w"] - 1 + (3 if qx else 0),
                      "top": iy - (2 if qy else 0),
                      "bottom": iy + vector["h"] - 1 + (3 if qy else 0)}
            touched = {"left": bounds["left"] < 0, "right": bounds["right"] >= WIDTH,
                       "top": bounds["top"] < 0, "bottom": bounds["bottom"] >= HEIGHT}
            cx, cy = x % 8, y % 8
            chroma_x, chroma_y = dx // 2 + x // 8, dy // 2 + y // 8
            chroma_bounds = {"left": chroma_x, "right": chroma_x + vector["w"] // 2 - 1 + bool(cx),
                             "top": chroma_y, "bottom": chroma_y + vector["h"] // 2 - 1 + bool(cy)}
            chroma_touched = {"left": chroma_bounds["left"] < 0, "right": chroma_bounds["right"] >= WIDTH // 2,
                              "top": chroma_bounds["top"] < 0, "bottom": chroma_bounds["bottom"] >= HEIGHT // 2}
            border = fractional and any(touched.values())
            count["fractional_border_support"] += border
            if fractional:
                for side, hit in touched.items():
                    borders[side] += hit
            count["fractional_chroma_border_support"] += fractional_chroma and any(chroma_touched.values())
            if fractional_chroma:
                for side, hit in chroma_touched.items():
                    chroma_borders[side] += hit
            observed = dict(vector, index=i, vector_index=vector_index, pts=frame["pts"],
                            destination_left_top=[dx, dy], luma_qpel_phase=[qx, qy],
                            luma_reference_integer_origin=[ix, iy],
                            luma_tap_bounds_inclusive=bounds, border_support=touched,
                            chroma_eighth_phase=[cx, cy],
                            chroma_reference_integer_origin=[chroma_x, chroma_y],
                            chroma_bilinear_bounds_inclusive=chroma_bounds,
                            chroma_border_support=chroma_touched)
            footprints.append(observed)
            if border and len(examples) < 16:
                examples.append(observed)
        per_frame.append(dict(count, index=i))
        for key, value in count.items():
            total[key] += value
    with (run_dir / "motion.footprints.jsonl").open("w") as output:
        for footprint in footprints:
            output.write(json.dumps(footprint, sort_keys=True) + "\n")
    colors = color_spans(reference)
    requirements = {
        "all_motion_partitions_16x16": total["vectors"] == total["p16_vectors"] > 0,
        "past_reference_only": total["non_previous_reference"] == 0,
        "fractional_luma_present": total["fractional_luma"] > 0,
        "fractional_chroma_present": total["fractional_chroma"] > 0,
        "all_16_luma_qpel_phase_pairs_present": len(phases) == 16,
        "all_four_borders_need_fractional_support": all(borders.values()),
        "all_four_chroma_borders_need_fractional_support": all(chroma_borders.values()),
        "each_P_picture_has_motion": all(f["vectors"] for f in per_frame[1:]),
        "textured_Y_and_color_UV_each_picture": all(
            f["max"] - f["min"] >= 16 for plane in colors.values() for f in plane),
    }
    return {"qualified": all(requirements.values()), "requirements": requirements,
            "command": command, "totals": total, "fractional_border_support": borders,
            "fractional_chroma_border_support": chroma_borders,
            "luma_qpel_phase_counts": phases, "frames": per_frame, "color_spans": colors,
            "border_examples": examples,
            "actual_motion_extrema_quarter_luma": {
                axis: [min(f[axis] for f in footprints), max(f[axis] for f in footprints)] if footprints else None
                for axis in ("motion_x", "motion_y")},
            "per_vector_footprints": "motion.footprints.jsonl",
            "tap_bounds_note": "Inclusive pre-clamp integer bounding rectangles, not all fetched addresses; odd/odd qpel filters use sparse cross support.",
            "partition_note": "16x16 exported motion includes P_Skip; this is not a coded-MB-type count.",
            "reference_note": "AVMotionVector.source gives past/future direction, not a unique reference index; previous-picture interpretation needs independently verified one-reference syntax.",
            "limitation": "Independent decoder coverage only; no vectors/reference pixels enter RTL."}


def simulate(command, log_path):
    # Donor ST_PAINT prints once per clock. Preserve transitions, not 180 MB of duplicates.
    with log_path.open("w") as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
        previous, repeated = None, 0
        for line in process.stdout:
            if line == previous:
                repeated += 1
                continue
            if repeated:
                log.write(f"[previous line repeated {repeated} additional times]\n")
            log.write(line)
            previous, repeated = line, 0
        if repeated:
            log.write(f"[previous line repeated {repeated} additional times]\n")
        return process.wait()


def partial_score(path, reference, headers):
    partial = json.loads(path.read_text())
    frame = partial["index"]
    if not 0 <= frame < len(headers) or partial["complete"]:
        raise RuntimeError("invalid incomplete-picture diagnostic")
    seen = set()
    planes = {p: {"written_samples": 0, "mismatches": 0, "absolute_error": 0} for p in "YUV"}
    first = None
    for offset, value in partial["samples"]:
        if offset in seen or not 0 <= offset < PICTURE or not 0 <= value <= 255:
            raise RuntimeError("invalid native partial sample")
        seen.add(offset)
        if offset < WIDTH * HEIGHT:
            plane, index, width = "Y", offset, WIDTH
        elif offset < WIDTH * HEIGHT * 5 // 4:
            plane, index, width = "U", offset - WIDTH * HEIGHT, WIDTH // 2
        else:
            plane, index, width = "V", offset - WIDTH * HEIGHT * 5 // 4, WIDTH // 2
        expected = reference[frame * PICTURE + offset]
        metric = planes[plane]
        metric["written_samples"] += 1
        metric["mismatches"] += value != expected
        metric["absolute_error"] += abs(value - expected)
        if value != expected and first is None:
            first = {"frame": frame, "plane": plane, "x": index % width, "y": index // width,
                     "actual": value, "oracle": expected}
    partial.pop("samples")
    return dict(partial, planes=planes, first_mismatch=first,
                encoded_header=headers[frame], covered_samples=len(seen),
                acceptance=False, limitation="Incomplete native writes only; not a decoded-frame score.")


def verify_result(path, build, manifest):
    path = path.resolve()
    if not path.is_relative_to(build / "runs"):
        raise RuntimeError("stale result path: not from the requested exact input build")
    verify_files(path.parent, json.loads((path.parent / "result.sha256.json").read_text()))
    result = json.loads(path.read_text())
    if (result["input_key"] != manifest["input_key"] or
            result["build_manifest_sha256"] != file_hash(build / "build.json")):
        raise RuntimeError("stale result/build binding")
    verify_files(path.parent, result["artifacts"])
    # Even a purported green JSON must carry the actual bytes; do not trust its score.
    actual = (path.parent / "actual.i420").read_bytes()
    oracle = (path.parent / "oracle.i420").read_bytes()
    if not actual or not (path.parent / "actual.frames.jsonl").read_bytes():
        raise RuntimeError("artifact-only score without actual pictures/identities")
    if not result["pass"]:
        print(f"FAIL recorded nonpassing result: {path}")
        return 1
    if manifest.get("ddr_native"):
        from ddr_native_oracle import compare_native
        exact = compare_native(actual, oracle, result["geometry"]["coded_width"],
                               result["geometry"]["coded_height"], manifest["expected_frames"])["exact"]
    elif manifest.get("au_runtime_geometry"):
        from au_geometry_oracle import (
            ALLOCATION_SUFFIX, delivered_geometry, native_beam_errors, native_dar_scope, score_geometry,
        )
        geometry = delivered_geometry(path.parent / "headers.log",
                                      json.loads((path.parent / "ffprobe.json").read_text())["frames"])
        values = [geometry["coded_width"], geometry["coded_height"],
                  *geometry["crop_left_right_top_bottom"]]
        if (geometry != result["geometry"] or
                list(map(int, (path.parent / "geometry.txt").read_text().split())) != values):
            raise RuntimeError("recorded runtime geometry differs from delivered SPS/crop")
        scored = score_geometry(actual, (path.parent / ("actual.i420" + ALLOCATION_SUFFIX)).read_bytes(),
                                oracle, (path.parent / "reference-coded.yuv").read_bytes(),
                                geometry, manifest["expected_frames"])
        exact = scored["pass"]
        if result.get("native_dar", {}).get("qualified") is not False:
            raise RuntimeError("this pixel/publication scorer cannot substantiate native-DAR qualification")
        if manifest.get("au_native_beam"):
            scope = native_dar_scope(geometry, result["native_dar"]["source_display_aspect_ratio"],
                                     (path.parent / "simulation.log").read_text())
            if (scope != result["native_dar"] or native_beam_errors(
                    scope, geometry, manifest["expected_frames"], manifest["au_native_scandouble"])):
                raise RuntimeError("recorded native-beam observations are incomplete or inconsistent")
    else:
        exact = compare(actual, oracle, manifest["expected_frames"])["exact"]
    if not exact:
        raise RuntimeError("recorded score does not match actual bytes")
    print(f"PASS verified actual-output hashes: {path}")
    return 0


def run(args):
    build, manifest, fixture = prepare(args)
    if args.verify_result:
        return verify_result(Path(args.verify_result), build, manifest)
    if args.ddr_native:
        sys.dont_write_bytecode = True
        from ddr_native_oracle import run_ddr
        return run_ddr(build, manifest, fixture)
    if args.au_publish:
        sys.dont_write_bytecode = True
        from au_publish_oracle import run_au
        return run_au(build, manifest, fixture)
    run_dir = build / "runs" / str(time.time_ns())
    run_dir.mkdir(parents=True)
    ffmpeg = manifest["tools"]["ffmpeg"]["path"]
    ffprobe = manifest["tools"]["ffprobe"]["path"]
    oracle = run_dir / "oracle.i420"
    probe_command = [ffprobe, "-v", "error", "-show_frames", "-show_streams",
                     "-select_streams", "v:0", "-of", "json", str(fixture)]
    probe = json.loads(checked(probe_command))
    write_json(run_dir / "ffprobe.json", probe)
    frames = probe["frames"]
    if len(frames) != args.frames or any(
            (f["width"], f["height"]) != (WIDTH, HEIGHT) or
            f["pix_fmt"] not in ("yuv420p", "yuvj420p") for f in frames):
        raise RuntimeError(f"ordinary decoder did not return exactly {args.frames} 320x240 I420 pictures")
    pixel_format = frames[0]["pix_fmt"]
    if any(f["pix_fmt"] != pixel_format for f in frames):
        raise RuntimeError("mid-sequence native pixel-format change is outside this exact lane")
    if [f["pict_type"] for f in frames] != ["I"] + ["P"] * (args.frames - 1):
        raise RuntimeError("this lane requires one I followed only by the requested P pictures")
    # Preserve native sample range as well as encoded filtering. Forcing yuv420p
    # on a yuvj420p decode would silently turn this into a range-conversion oracle.
    oracle_command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
                      "-threads", "1", "-i", str(fixture), "-map", "0:v:0",
                      "-fps_mode", "passthrough", "-pix_fmt", pixel_format,
                      "-f", "rawvideo", str(oracle)]
    subprocess.run(oracle_command, cwd=ROOT, check=True)
    headers, trace_command = slice_headers(ffmpeg, fixture, run_dir / "headers.log", args.frames)
    expected_deblock = manifest.get("required_disable_deblocking_filter_idc")
    if expected_deblock is not None and any(
            h.get("disable_deblocking_filter_idc") != expected_deblock for h in headers):
        raise RuntimeError("encoded deblocking flags do not match frozen fixture provenance")
    policy_errors = []
    if any(h.get("disable_deblocking_filter_idc") != 1 for h in headers):
        policy_errors.append("encoded filter-on/idc2 requires an implemented full filter scheduler; numerical exactness cannot qualify it")
    if any(h["nal_ref_idc"] == 0 for h in headers):
        policy_errors.append("non-reference VCL requires retain-reference completion; unconditional promotion cannot qualify it")
    reference = oracle.read_bytes()
    controls = negative_controls(reference, build, manifest)
    coverage = motion_coverage(build, fixture, run_dir, reference) if args.require_color_motion else None
    runtime_inputs = {p.name: file_hash(p) for p in run_dir.iterdir() if p.is_file()}
    for name in runtime_inputs:
        (run_dir / name).chmod(0o444)
    actual = run_dir / "actual.i420"
    records = run_dir / "actual.frames.jsonl"
    partial = run_dir / "actual.frames.jsonl.partial.json"
    simulation = [str(build / manifest["binary_path"]), str(fixture), str(actual), str(records), str(args.frames)]
    verify_build(build, manifest["input_key"], manifest["inputs"])
    sim_rc = simulate(simulation, run_dir / "simulation.log")
    verify_build(build, manifest["input_key"], manifest["inputs"])
    verify_files(run_dir, runtime_inputs)
    result = {"schema": "misterplex.gop12.result.v1", "input_key": manifest["input_key"],
              "source_pin": manifest["source_pin"], "build_manifest_sha256": file_hash(build / "build.json"),
              "expected_frames": args.frames,
              "oracle_pixel_format": pixel_format,
              "binary_sha256": manifest["outputs"][manifest["binary_path"]],
              "fixture_sha256": file_hash(fixture), "oracle_command": oracle_command,
              "probe_command": probe_command, "trace_headers_command": trace_command,
              "simulation_command": simulation,
              "simulation_rc": sim_rc, "negative_controls": controls, "pass": False,
              "runtime_input_hashes": runtime_inputs,
              "filter_reference_policy_satisfied": not policy_errors,
              "independent_color_motion_coverage": coverage,
              "limitations": [
                  "Decoder-only, paced ioctl; not DDR ingestion, realtime, HDMI, PMS or product acceptance.",
                  ("Donor fixture: I+11P, 95.3% P skip, no intra-in-P or I16 plane, neutral chroma."
                   if manifest["fixture"] == FIXTURE else
                   "Alternate fixture; no profile/coverage approval implied. See frozen adjacent README."),
                  "Observe native DPB writes, not grayscale RGB565 presentation; require every Y/U/V sample written.",
                  "Annex-B has no container PTS; absent timestamps remain null, never invented.",
                  "Legacy IDR nofilter scores are not comparable to this ordinary decoder.",
                  "Native full/limited sample range is preserved; RGB rounding/pixel values are not scored.",
                  "Consecutive identical simulator log lines are losslessly run-length summarized.",
                  ("Single-IDR mode cannot test frozen-frame replay, temporal reference reuse or inter prediction."
                   if args.frames == 1 else
                   f"{args.frames}-picture mode includes a frozen-first-frame scorer negative control."),
              ]}
    errors = list(policy_errors)
    if coverage and not coverage["qualified"]:
        errors.append("encoded fixture failed required actual color/fractional/border coverage")
    events = []
    try:
        if not actual.is_file() or not records.is_file():
            raise RuntimeError("score requires actual simulator bytes and frame identities")
        events = [json.loads(line) for line in records.read_text().splitlines()]
        actual_bytes = actual.read_bytes()
        completed = len(actual_bytes) // PICTURE
        if len(actual_bytes) % PICTURE or completed > args.frames:
            raise RuntimeError("simulator emitted partial or extra picture bytes")
        if completed:
            result["comparison"] = compare(actual_bytes, reference[:completed * PICTURE], completed)
        else:
            result["comparison"] = {"exact": False, "mismatches": None, "frames": []}
        result["comparison"]["completed_frames"] = completed
        if completed != args.frames:
            errors.append(f"only {completed}/{args.frames} actual pictures; partial score cannot pass")
        if len(events) != args.frames:
            errors.append(f"missing frame identities: {len(events)}/{args.frames}")
        identity = []
        for i, (event, frame, header) in enumerate(zip(events, frames, headers)):
            # This exact I+11P baseline fixture has decode order = display order.
            if event["index"] != i or event["rtl_frame_num"] != header["frame_num"]:
                errors.append(f"frame {i}: RTL identity/order mismatch")
            if event["nal_type"] != (5 if frame["pict_type"] == "I" else 1):
                errors.append(f"frame {i}: slice identity mismatch")
            if event["covered_samples"] != PICTURE:
                errors.append(f"frame {i}: only {event['covered_samples']}/{PICTURE} native samples written")
            if event["frontend_mode_observed"] and event["legacy_diagnostic_mode"]:
                errors.append(f"frame {i}: explicit legacy diagnostic frontend is not bounded decoder verification")
            if event["dpb_lifetime_observed"]:
                if (not event["reference_promoted"] or event["reference_error"] or event["decoder_error"] or
                        event["promotion_count"] != 1):
                    errors.append(f"frame {i}: reference promotion/error contract failed")
                if (event["promoted_reference_width"], event["promoted_reference_height"],
                    event["promoted_reference_base"], event["coverage_at_promotion"]) != (
                        WIDTH, HEIGHT, event["bank"] * PICTURE, PICTURE):
                    errors.append(f"frame {i}: reference promoted with wrong geometry/bank or incomplete accepted coverage")
                if event["rgb_write_accepts_at_frame_signal"] != WIDTH * HEIGHT:
                    errors.append(f"frame {i}: completion without exactly 76800 accepted RGB writes")
            if event["color_metadata_observed"]:
                full_range = frame.get("color_range") == "pc" or pixel_format == "yuvj420p"
                matrix = frame.get("color_space", "unknown")
                if event["color_full_range"] != full_range:
                    errors.append(f"frame {i}: latched sample range differs from encoded metadata")
                if matrix not in ("unknown", "bt709", "bt470bg", "smpte170m"):
                    errors.append(f"frame {i}: unsupported encoded color matrix {matrix}")
                elif ((matrix == "bt709") != (event["color_matrix"] == 1) or
                      event["color_matrix"] not in (1, 2, 5, 6)):
                    errors.append(f"frame {i}: latched BT601/BT709 matrix differs from encoded metadata")
            packet_start, packet_bytes = int(frame["pkt_pos"]), int(frame["pkt_size"])
            if not (packet_start <= event["nal_offset"] and
                    event["nal_offset"] + event["nal_bytes"] <= packet_start + packet_bytes):
                errors.append(f"frame {i}: VCL bytes do not belong to ordinary decoder packet")
            encoded = fixture.read_bytes()[event["nal_offset"]:event["nal_offset"] + event["nal_bytes"]]
            identity.append(dict(event, vcl_sha256=digest(encoded),
                                 oracle_picture_type=frame["pict_type"],
                                 oracle_color_range=frame.get("color_range"),
                                 oracle_color_matrix=frame.get("color_space"),
                                 encoded_header=header,
                                 oracle_packet_offset=packet_start, oracle_packet_bytes=packet_bytes,
                                 pts=frame.get("pts"), pts_time=frame.get("pts_time"),
                                 best_effort_timestamp=frame.get("best_effort_timestamp"),
                                 duration=frame.get("duration", frame.get("pkt_duration")),
                                 time_base=probe["streams"][0].get("time_base")))
        result["identities"] = identity
    except (RuntimeError, KeyError, ValueError) as error:
        errors.append(str(error))
    if partial.is_file():
        result["partial_native_diagnostic"] = partial_score(partial, reference, headers)
    if sim_rc:
        errors.append(f"simulator failed ({sim_rc}); see simulation.log")
    result["errors"] = errors
    result["pass"] = not errors and result.get("comparison", {}).get("exact", False)
    result["artifacts"] = {p.name: file_hash(p) for p in
                           (actual, records, partial, oracle, run_dir / "ffprobe.json",
                            run_dir / "headers.log", run_dir / "motion.frames.jsonl",
                            run_dir / "motion.footprints.jsonl", run_dir / "motion.log",
                            run_dir / "simulation.log") if p.is_file()}
    write_json(run_dir / "result.json", result)
    write_json(run_dir / "result.sha256.json", {"result.json": file_hash(run_dir / "result.json")})
    for artifact in run_dir.iterdir():
        artifact.chmod(0o444)
    run_dir.chmod(0o555)
    comparison = result.get("comparison", {})
    print(f"{'PASS' if result['pass'] else 'FAIL'} ordinary_ffmpeg_all_YUV "
          f"mismatches={comparison.get('mismatches', 'unavailable')} "
          f"first={comparison.get('first_mismatch')}", flush=True)
    print(f"RESULT {run_dir / 'result.json'}", flush=True)
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    return 0 if result["pass"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-pin", default=PIN,
                        help="git commit, or worktree for an immutable selected-input integration snapshot")
    parser.add_argument("--source-build",
                        help="with --source-pin worktree, obtain the complete source/bench/ABI cohort from this verified build, not live files")
    parser.add_argument("--fixture", help="alternate worktree Annex-B fixture with adjacent README.md; default exact GOP12")
    parser.add_argument("--reuse-only", action="store_true",
                        help="refuse to run unless this exact source/test/fixture/toolchain already has a verified build")
    parser.add_argument("--verify-result",
                        help="verify a recorded result against current requested inputs and actual output files")
    parser.add_argument("--require-color-motion", action="store_true",
                        help="also require independently exported fractional P16 vectors, four borders and textured YUV")
    parser.add_argument("--frames", type=int, default=COUNT,
                        help="default exact GOP12; legacy/publication accept 1/2/12; DDR-native accepts 1..256")
    parser.add_argument("--au-publish", action="store_true",
                        help="reuse the real DDR-AU decoder/publisher producer on the selected complete AUs")
    parser.add_argument("--au-runtime-geometry", action="store_true",
                        help="two original-timed publication AUs: derive SPS crop and score visible/coded DDR plus padding")
    parser.add_argument("--au-native-beam", action="store_true",
                        help="runtime geometry: explicitly enable the source producer's actual present_core raster checks")
    parser.add_argument("--au-native-scandouble", type=int, choices=(0, 1),
                        help="native-beam scan doubling (default 1); both SV and C++ selections are frozen together")
    parser.add_argument("--au-idr-only", action="store_true",
                        help="select the existing composed producer's static-IDR policy with IDR_ONLY_PROFILE=1")
    parser.add_argument("--au-input-limit", type=int, choices=(8192, 65536), default=65536,
                        help="AU producer input bound: modern target 65536; explicit 8192 preserves legacy/model coverage")
    parser.add_argument("--ddr-native", action="store_true",
                        help="real shared DDR-ring BFM into stream_path, with independent accepted-native capture")
    parser.add_argument("--pts-sidecar", help="hashed original-pts.json from the preserved capture oracle")
    parser.add_argument("--fixture-timeline", action="store_true",
                        help="explicit synthetic local-fixture timeline derived from its declared rate; never original PTS")
    args = parser.parse_args()
    if (args.ddr_native and not 1 <= args.frames <= 256) or (
            not args.ddr_native and args.frames not in (1, 2, 12)):
        parser.error("frame count must be 1..256 for DDR-native, otherwise 1/2/12")
    if args.au_publish and args.ddr_native:
        parser.error("--au-publish and --ddr-native are distinct observation paths")
    if args.source_build and (args.source_pin != "worktree" or not args.au_publish):
        parser.error("--source-build requires --source-pin worktree --au-publish")
    if args.au_idr_only and not args.au_publish:
        parser.error("--au-idr-only requires --au-publish")
    if args.au_runtime_geometry and (not args.au_publish or args.frames != 2 or not args.pts_sidecar):
        parser.error("--au-runtime-geometry requires --au-publish --frames 2 --pts-sidecar PATH")
    if args.au_native_beam and not args.au_runtime_geometry:
        parser.error("--au-native-beam requires --au-runtime-geometry")
    if args.au_native_scandouble is not None and not args.au_native_beam:
        parser.error("--au-native-scandouble requires --au-native-beam")
    if args.ddr_native and bool(args.pts_sidecar) == bool(args.fixture_timeline):
        parser.error("--ddr-native requires exactly one of --pts-sidecar or explicit --fixture-timeline")
    if args.pts_sidecar and not (args.ddr_native or args.au_publish):
        parser.error("original PTS metadata applies only to DDR-native or composed publication")
    if args.fixture_timeline and not args.ddr_native:
        parser.error("--fixture-timeline applies only to --ddr-native")
    if args.frames != COUNT and args.require_color_motion:
        parser.error("--require-color-motion requires the full twelve-picture GOP")
    if args.verify_result:
        args.reuse_only = True
    try:
        return run(args)
    except (RuntimeError, OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"FAIL GOP12 oracle: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
