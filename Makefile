# MiSTerPlex top-level Makefile
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
CXX  ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -I$(ROOT)/host
FFMPEG_CFLAGS := $(shell pkg-config --cflags libavformat libavcodec libavutil 2>/dev/null)
FFMPEG_LIBS   := $(shell pkg-config --libs libavformat libavcodec libavutil 2>/dev/null)

.PHONY: all preflight unit unit-unlocked unit-rollcall rtl-sim rtl-sim-unlocked rtl-lint verilator-elab quartus-sv-subset define-parity pre-synth-gates post-fit-hierarchy post-fit-timing timing-exclusion pms-baseline-check pms-baseline-live pms-nal-stats arm-plexd arm-ddr-bench arm-profile-tools ddr-bench profile-tools present-harness clean help plexd package h264-golden-tools cast-timeline-gate cast-timeline-playwright capture-rig-preflight left-edge-clip-gate rbf-label-check

all: unit

help:
	@echo "Targets:"
	@echo "  make unit       - serialized host unit tests with resource backoff (cadence, resolve, companion HTTP)"
	@echo "  make rtl-sim    - run real Verilator RTL simulations if Verilator is installed"
	@echo "  make rtl-lint   - run Verilator parse/lint width/implicit regression gate (not Quartus synthesis)"
	@echo "  make verilator-elab - run fast Verilator elaboration guard for synthesis-fatal owned RTL errors"
	@echo "  make quartus-sv-subset - curated Quartus SV subset guard plus fast Verilator elaboration"
	@echo "  make define-parity - verify Quartus product macros match Verilator/lint macros"
	@echo "  make pre-synth-gates - run define parity + fast pre-Quartus RTL buildability gates"
	@echo "  make post-fit-hierarchy FIT_RPT=... [MAP_RPT=...] [COMPILE_LOG=...] - critical fitted-module guard"
	@echo "  make post-fit-timing STA_RPT=... - fail negative Quartus timing slack"
	@echo "  make timing-exclusion [STA_RPT=...] - detect timing closed by exclusion not design"
	@echo "  make pms-baseline-check - live PMS delivered-SPS guard (requires PLEX_BASE/TOKEN/KEY)"
	@echo "  make pms-baseline-live - secret-safe live PMS Baseline gate; prompts for token"
	@echo "  make pms-nal-stats      - live PMS NAL size/jitter probe (requires PLEX_BASE/TOKEN/KEY)"
	@echo "  make h264-golden-tools - build shared H.264 golden fixture extractor"
	@echo "  make arm-plexd  - cross-build ARM misterplexd (if toolchain present)"
	@echo "  make build-rbf  - build Plex.rbf via misterfpga-dev (long)"
	@echo "  make test       - alias for unit"
	@echo "  make package    - dist tarball (ARM + conf + docs + Plex.rbf if present)"
	@echo "  make arm-ddr-bench - cross-build DDR write microbenchmark"
	@echo "  make arm-profile-tools - cross-build ARM decode/profile probes"
	@echo "  make present-harness - build offline present-loop pipe/copy harness"
	@echo "  make cast-timeline-gate      - live cast/timeline HTTP gate (requires MiSTer + PMS)"
	@echo "  make cast-timeline-playwright - live cast/timeline Playwright browser fidelity check"
	@echo "  make capture-rig-preflight   - HDMI capture rig probe (device, liveness, signal state)"
	@echo "  make rbf-label-check         - verify RBF identity label in HDMI idle screen (OCR)"

test: unit

UNIT_ANNEXB := $(ROOT)/build/plex_real_baseline.264

preflight:
	@bash $(ROOT)/scripts/test_resource_preflight.sh

unit:
	@bash $(ROOT)/scripts/run_with_resource_preflight.sh -- python3 $(ROOT)/scripts/run_with_skip_summary.py --label make-unit -- $(MAKE) unit-rollcall unit-unlocked

unit-rollcall:
	python3 $(ROOT)/tests/unit/test_unit_rollcall.py

unit-unlocked: unit-rollcall preflight $(ROOT)/build/test_cadence $(ROOT)/build/test_avclock $(ROOT)/build/test_mraudio_status $(ROOT)/build/test_osd_menu $(ROOT)/build/test_last_frame_latch $(ROOT)/build/test_playback_overlay $(ROOT)/build/test_input_mailbox $(ROOT)/build/test_pixel_format $(ROOT)/build/test_main_guard $(ROOT)/build/test_status_telemetry $(ROOT)/build/test_resolve $(ROOT)/build/test_pms_timeline $(ROOT)/build/test_companion_eof $(ROOT)/build/test_companion_plant_seek $(ROOT)/build/pms_baseline_probe $(ROOT)/build/test_h264_bitstream_source $(ROOT)/build/test_bitstream_ring_lifecycle $(ROOT)/build/test_frame_store_math $(ROOT)/build/test_frame_store_sdram_sim $(ROOT)/build/test_frame_store_ddr_prefetch_sim $(ROOT)/build/test_sdram_memtest_sim $(ROOT)/build/test_sdram_mailbox $(ROOT)/build/test_annexb_count $(ROOT)/build/test_sps_parse $(ROOT)/build/test_slice_hdr $(ROOT)/build/test_cavlc_dc $(ROOT)/build/test_idct_quant $(ROOT)/build/test_p3_host_recon_vectors $(ROOT)/build/test_p3_idct_reference_model $(ROOT)/build/test_p3_inter_pred_vectors $(ROOT)/build/extract_h264_golden
	$(ROOT)/build/test_cadence
	$(ROOT)/build/test_avclock
	$(ROOT)/build/test_mraudio_status
	$(ROOT)/build/test_osd_menu
	bash $(ROOT)/tests/unit/test_osd_menu_red.sh
	$(ROOT)/build/test_last_frame_latch
	bash $(ROOT)/tests/unit/test_last_frame_latch_red.sh
	$(ROOT)/build/test_playback_overlay
	$(ROOT)/build/test_input_mailbox
	$(ROOT)/build/test_pixel_format
	$(ROOT)/build/test_main_guard
	$(ROOT)/build/test_status_telemetry
	$(ROOT)/build/test_resolve
	$(ROOT)/build/test_pms_timeline
	$(ROOT)/build/test_companion_eof
	$(ROOT)/build/test_companion_plant_seek
	$(ROOT)/tests/unit/test_pms_baseline_gate.sh
	$(ROOT)/tests/unit/test_pms_baseline_live_gate.sh
	$(ROOT)/build/test_h264_bitstream_source
	$(ROOT)/build/test_bitstream_ring_lifecycle
	$(ROOT)/build/test_frame_store_math
	$(ROOT)/build/test_frame_store_sdram_sim
	$(ROOT)/build/test_frame_store_ddr_prefetch_sim
	$(ROOT)/build/test_sdram_memtest_sim
	$(ROOT)/build/test_sdram_mailbox
	$(ROOT)/build/test_annexb_count
	python3 $(ROOT)/tests/unit/test_ddr_publish_path_static.py
	@mkdir -p $(ROOT)/build
	@python3 $(ROOT)/scripts/gen_test_annexb_real.py $(UNIT_ANNEXB)
	$(ROOT)/build/test_status_telemetry $(UNIT_ANNEXB)
	$(ROOT)/build/test_sps_parse $(UNIT_ANNEXB)
	$(ROOT)/build/test_slice_hdr $(UNIT_ANNEXB)
	$(ROOT)/build/test_cavlc_dc $(UNIT_ANNEXB)
	$(ROOT)/build/test_idct_quant $(UNIT_ANNEXB)
	$(ROOT)/build/test_p3_host_recon_vectors
	$(ROOT)/tests/unit/test_h264_golden_extractor.sh
	$(ROOT)/tests/unit/test_h264_frame_plane_goldens.sh
	$(ROOT)/tests/unit/test_derived_validation_hashes.sh
	$(ROOT)/tests/unit/test_i420_candidate_score.sh
	$(ROOT)/tests/unit/test_h264_multinal_stream_path.sh
	$(ROOT)/build/test_p3_idct_reference_model
	$(ROOT)/build/test_p3_inter_pred_vectors
	python3 $(ROOT)/tests/unit/test_no_conflict_markers.py
	python3 $(ROOT)/tests/unit/test_bench_rtl_filelists.py
	python3 $(ROOT)/tests/unit/test_p3_high_cabac_scope.py
	python3 $(ROOT)/tests/unit/test_p3_intra_mb0_verilator.py
	python3 $(ROOT)/tests/unit/test_h264_intra_nb_ctx_verilator.py
	python3 $(ROOT)/tests/unit/test_p3_idct_rtl_model.py
	python3 $(ROOT)/tests/unit/test_p3_intra_frame_verilator.py
	@chmod +x $(ROOT)/tests/unit/*.sh $(ROOT)/tests/unit/*.py $(ROOT)/tests/hw/*.sh 2>/dev/null || true
	$(ROOT)/tests/unit/test_p3_inter_rtl_sim.sh
	$(ROOT)/tests/unit/test_p3_dpb_mc_rtl_sim.sh
	$(ROOT)/tests/unit/test_h264_decode_core_writeback_rtl_sim.sh
	$(ROOT)/tests/unit/test_h264_decode_core_p16z_rtl_sim.sh
	$(ROOT)/tests/unit/test_h264_decode_core_real_slice_rtl_sim.sh
	$(ROOT)/tests/unit/test_h264_p_slice_modes_rtl_sim.sh
	$(ROOT)/tests/unit/test_p3_inter_stream_path_rtl_sim.sh
	$(ROOT)/tests/unit/test_companion_http.sh
	$(ROOT)/tests/unit/test_plex_browse.sh
	$(ROOT)/tests/unit/test_play_file_delivery.sh
	$(ROOT)/tests/unit/test_no_private_data.sh
	$(ROOT)/tests/unit/test_capture_rig.sh
	$(ROOT)/tests/unit/test_capture_preflight.sh
	python3 $(ROOT)/tests/unit/test_capture_warmup.py
	python3 $(ROOT)/tests/unit/test_idle_screen_score.py
	python3 $(ROOT)/tests/unit/test_prove_decoded_frame.py
	python3 $(ROOT)/tests/unit/test_capture_gate_states.py
	python3 $(ROOT)/tests/unit/test_left_edge_dynamics.py
	python3 $(ROOT)/scripts/mutation_check.py --self-test
	python3 $(ROOT)/scripts/fabric_provenance.py --self-test
	$(ROOT)/tests/unit/test_capture_lock_shared.sh
	$(ROOT)/tests/unit/test_resource_preflight.sh
	$(ROOT)/scripts/check_define_parity.py
	python3 $(ROOT)/tests/unit/test_hw_visual_compare.py
	$(ROOT)/tests/unit/test_decode_throughput_gate.sh
	$(ROOT)/tests/unit/test_rtl_invariants.sh
	$(ROOT)/tests/unit/test_mister_ini_plex_guard.sh
	$(ROOT)/tests/unit/test_confstr_guard.sh
	$(ROOT)/tests/unit/test_release_rbf_hash.sh
	$(ROOT)/tests/unit/test_sdram_startup_verilator.sh
	$(ROOT)/tests/unit/test_sdram_dq_turnaround_verilator.sh
	$(ROOT)/tests/unit/test_h264_cavlc_residual_verilator.sh
	$(ROOT)/tests/unit/test_level_width_verilator.sh
	$(ROOT)/tests/unit/test_stream_path_recon_integration.sh
	$(ROOT)/tests/unit/test_stream_path_full_frame_compare.sh
	$(ROOT)/tests/unit/test_ddram_frame_rd_bank_select.sh
	python3 $(ROOT)/tests/parse_res_csum_status.py --self-test
	$(ROOT)/tests/unit/test_p3_idct_rtl_sim.sh
	$(ROOT)/tests/unit/test_p3_deblock_rtl_sim.sh
	$(ROOT)/tests/unit/test_p3_stream_path_recon_rtl_sim.sh
	$(ROOT)/tests/unit/test_stream_path_deblock_integration.sh
	bash $(ROOT)/tests/unit/test_stream_path_ddr_ring_integration.sh
	$(ROOT)/tests/unit/test_ddr_frame_store_warm_reset.sh
	$(ROOT)/scripts/rtl_lint.py
	$(ROOT)/tests/unit/test_h264_syntax_primitives_rtl_sim.sh
	$(ROOT)/tests/unit/test_h264_sps_geometry_rtl_sim.sh
	$(ROOT)/tests/unit/test_h264_baseline_syntax_rtl_sim.sh

rtl-sim:
	python3 $(ROOT)/scripts/run_with_skip_summary.py --label rtl-sim -- $(MAKE) rtl-sim-unlocked

rtl-sim-unlocked:
	$(ROOT)/tests/unit/test_p3_idct_rtl_sim.sh
	$(ROOT)/tests/unit/test_p3_deblock_rtl_sim.sh
	bash $(ROOT)/tests/unit/test_stream_path_ddr_ring_integration.sh
	$(ROOT)/tests/unit/test_h264_cavlc_residual_verilator.sh
	$(ROOT)/tests/unit/test_p3_stream_path_recon_rtl_sim.sh
	$(ROOT)/tests/unit/test_stream_path_deblock_integration.sh
	$(ROOT)/tests/unit/test_ddr_frame_store_warm_reset.sh
	$(ROOT)/tests/unit/test_stream_path_recon_integration.sh
	$(ROOT)/tests/unit/test_stream_path_full_frame_compare.sh
	$(ROOT)/tests/unit/test_ddram_frame_rd_bank_select.sh
	$(ROOT)/tests/unit/test_h264_syntax_primitives_rtl_sim.sh
	$(ROOT)/tests/unit/test_h264_sps_geometry_rtl_sim.sh
	$(ROOT)/tests/unit/test_h264_baseline_syntax_rtl_sim.sh
	$(ROOT)/tests/unit/test_h264_p_slice_modes_rtl_sim.sh
	$(ROOT)/tests/unit/test_h264_decode_core_writeback_rtl_sim.sh
	$(ROOT)/tests/unit/test_h264_decode_core_p16z_rtl_sim.sh
	$(ROOT)/tests/unit/test_h264_decode_core_real_slice_rtl_sim.sh
	$(ROOT)/tests/unit/test_p3_inter_rtl_sim.sh
	$(ROOT)/tests/unit/test_p3_dpb_mc_rtl_sim.sh
	$(ROOT)/tests/unit/test_p3_inter_stream_path_rtl_sim.sh

rtl-lint:
	$(ROOT)/scripts/rtl_lint.py

verilator-elab:
	$(ROOT)/scripts/check_verilator_elab.py

quartus-sv-subset:
	$(ROOT)/scripts/check_quartus_sv_subset.py $$($(ROOT)/scripts/rtl_lint.py --list-files)
	$(ROOT)/scripts/check_verilator_elab.py

define-parity:
	$(ROOT)/scripts/check_define_parity.py

pre-synth-gates: define-parity quartus-sv-subset

post-fit-hierarchy:
	@if [ -z "$(FIT_RPT)" ]; then echo "FIT_RPT is required" >&2; exit 2; fi
	$(ROOT)/scripts/check_quartus_fit_hierarchy.py --fit-rpt "$(FIT_RPT)" \
		$(if $(MAP_RPT),--map-rpt "$(MAP_RPT)",) \
		$(if $(COMPILE_LOG),--log "$(COMPILE_LOG)",)

post-fit-timing:
	@if [ -z "$(STA_RPT)" ]; then echo "STA_RPT is required" >&2; exit 2; fi
	$(ROOT)/scripts/check_quartus_timing.py --sta-rpt "$(STA_RPT)"

timing-exclusion:
	$(ROOT)/scripts/check_timing_exclusions.py $(if $(STA_RPT),--sta-rpt "$(STA_RPT)",)

pms-baseline-check: $(ROOT)/build/pms_baseline_probe
	python3 $(ROOT)/scripts/run_with_skip_summary.py --label pms-baseline-check -- $(ROOT)/tests/hw/test_pms_baseline_profile.sh

pms-baseline-live: $(ROOT)/build/pms_baseline_probe
	$(ROOT)/scripts/run_pms_baseline_live_gate.sh

pms-nal-stats: $(ROOT)/build/pms_nal_stats
	python3 $(ROOT)/scripts/run_with_skip_summary.py --label pms-nal-stats -- bash $(ROOT)/tests/hw/test_pms_nal_stats.sh

h264-golden-tools: $(ROOT)/build/extract_h264_golden $(ROOT)/build/score_h264_native_frames $(ROOT)/build/analyze_h264_intra_mbs

$(ROOT)/build/test_status_telemetry: $(ROOT)/tests/unit/test_status_telemetry.cpp \
		$(ROOT)/arm/misterplexd/fpga_spi.cpp $(ROOT)/arm/misterplexd/fpga_spi.hpp \
		$(ROOT)/host/libmisterplex/ddr_bitstream_ring.hpp \
		$(ROOT)/host/libmisterplex/status_telemetry.hpp \
		$(ROOT)/host/libmisterplex/h264_residual_gold.hpp \
		$(ROOT)/host/libmisterplex/pixel_format.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -I$(ROOT)/arm/misterplexd -pthread -o $@ \
		$(ROOT)/tests/unit/test_status_telemetry.cpp $(ROOT)/arm/misterplexd/fpga_spi.cpp

$(ROOT)/build/test_idct_quant: $(ROOT)/tests/unit/test_idct_quant.cpp \
		$(ROOT)/host/libmisterplex/h264_cavlc.hpp $(ROOT)/host/libmisterplex/h264_nal.hpp \
		$(ROOT)/host/libmisterplex/h264_sps.hpp $(ROOT)/host/libmisterplex/h264_recon.hpp \
		$(ROOT)/host/libmisterplex/h264_residual_gold.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_idct_quant.cpp

$(ROOT)/build/test_p3_host_recon_vectors: $(ROOT)/tests/unit/test_p3_host_recon_vectors.cpp \
		$(ROOT)/host/libmisterplex/h264_recon.hpp \
		$(ROOT)/host/libmisterplex/h264_slice_walk.hpp \
		$(ROOT)/host/libmisterplex/h264_cavlc.hpp \
		$(ROOT)/tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264 \
		$(ROOT)/tests/fixtures/p3_host_recon/mb0_luma_v1.json \
		$(ROOT)/tests/fixtures/p3_host_recon/frame_mae_v1.csv
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_p3_host_recon_vectors.cpp

$(ROOT)/build/extract_h264_golden: $(ROOT)/tools/extract_h264_golden.cpp \
		$(ROOT)/host/libmisterplex/h264_recon.hpp \
		$(ROOT)/host/libmisterplex/h264_slice_walk.hpp \
		$(ROOT)/host/libmisterplex/h264_cavlc.hpp \
		$(ROOT)/host/libmisterplex/h264_residual_gold.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tools/extract_h264_golden.cpp

$(ROOT)/build/score_h264_native_frames: $(ROOT)/tools/score_h264_native_frames.cpp \
		$(ROOT)/host/libmisterplex/h264_recon.hpp \
		$(ROOT)/host/libmisterplex/h264_slice_walk.hpp \
		$(ROOT)/host/libmisterplex/h264_cavlc.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tools/score_h264_native_frames.cpp

$(ROOT)/build/analyze_h264_intra_mbs: $(ROOT)/tools/analyze_h264_intra_mbs.cpp \
		$(ROOT)/host/libmisterplex/h264_recon.hpp \
		$(ROOT)/host/libmisterplex/h264_slice_walk.hpp \
		$(ROOT)/host/libmisterplex/h264_cavlc.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tools/analyze_h264_intra_mbs.cpp

$(ROOT)/build/test_p3_idct_reference_model: $(ROOT)/tests/unit/test_p3_idct_reference_model.cpp \
		$(ROOT)/host/libmisterplex/h264_cavlc.hpp \
		$(ROOT)/host/libmisterplex/h264_nal.hpp \
		$(ROOT)/host/libmisterplex/h264_sps.hpp \
		$(ROOT)/host/libmisterplex/h264_recon.hpp \
		$(ROOT)/host/libmisterplex/h264_slice_walk.hpp \
		$(ROOT)/host/libmisterplex/h264_residual_gold.hpp \
		$(ROOT)/fpga/Plex_MiSTer/files.qip \
		$(ROOT)/fpga/Plex_MiSTer/rtl/slice_hdr_parser.sv \
		$(ROOT)/fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv \
		$(ROOT)/tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264 \
		$(ROOT)/tests/fixtures/p3_host_recon/mb0_luma_v1.json \
		$(ROOT)/tests/fixtures/p3_host_recon/frame_mae_v1.csv
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_p3_idct_reference_model.cpp

$(ROOT)/build/test_p3_inter_pred_vectors: $(ROOT)/tests/unit/test_p3_inter_pred_vectors.cpp \
		$(ROOT)/host/libmisterplex/h264_nal.hpp \
		$(ROOT)/host/libmisterplex/h264_sps.hpp \
		$(ROOT)/scripts/gen_test_annexb_inter.py \
		$(ROOT)/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264 \
		$(ROOT)/tests/fixtures/p3_inter_pred/pframe1_mb_v1.json \
		$(ROOT)/tests/fixtures/p3_inter_pred/frame_mae_v1.csv
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) $(FFMPEG_CFLAGS) -o $@ $(ROOT)/tests/unit/test_p3_inter_pred_vectors.cpp $(FFMPEG_LIBS)

$(ROOT)/build/test_cavlc_dc: $(ROOT)/tests/unit/test_cavlc_dc.cpp \
		$(ROOT)/host/libmisterplex/h264_cavlc.hpp $(ROOT)/host/libmisterplex/h264_nal.hpp \
		$(ROOT)/host/libmisterplex/h264_sps.hpp $(ROOT)/host/libmisterplex/h264_slice_walk.hpp \
		$(ROOT)/host/libmisterplex/h264_recon.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_cavlc_dc.cpp

$(ROOT)/build/test_sps_parse: $(ROOT)/tests/unit/test_sps_parse.cpp $(ROOT)/host/libmisterplex/h264_sps.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_sps_parse.cpp

$(ROOT)/build/test_slice_hdr: $(ROOT)/tests/unit/test_slice_hdr.cpp \
		$(ROOT)/host/libmisterplex/h264_nal.hpp $(ROOT)/host/libmisterplex/h264_sps.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_slice_hdr.cpp

$(ROOT)/build/test_frame_store_math: $(ROOT)/tests/unit/test_frame_store_math.cpp \
		$(ROOT)/host/libmisterplex/ddr_frame_layout.hpp \
		$(ROOT)/host/libmisterplex/ddr_present_bank.hpp \
		$(ROOT)/host/libmisterplex/pixel_format.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_frame_store_math.cpp

$(ROOT)/build/test_frame_store_sdram_sim: $(ROOT)/tests/unit/test_frame_store_sdram_sim.cpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_frame_store_sdram_sim.cpp

$(ROOT)/build/test_frame_store_ddr_prefetch_sim: $(ROOT)/tests/unit/test_frame_store_ddr_prefetch_sim.cpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_frame_store_ddr_prefetch_sim.cpp

$(ROOT)/build/test_sdram_memtest_sim: $(ROOT)/tests/unit/test_sdram_memtest_sim.cpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_sdram_memtest_sim.cpp

$(ROOT)/build/test_sdram_mailbox: $(ROOT)/tests/unit/test_sdram_mailbox.cpp \
		$(ROOT)/host/libmisterplex/sdram_mailbox.hpp \
		$(ROOT)/host/libmisterplex/mailbox_abi_spec.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_sdram_mailbox.cpp

$(ROOT)/build/test_annexb_count: $(ROOT)/tests/unit/test_annexb_count.cpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_annexb_count.cpp

$(ROOT)/build/test_cadence: $(ROOT)/tests/unit/test_cadence.cpp $(ROOT)/host/libmisterplex/cadence.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_cadence.cpp

$(ROOT)/build/test_avclock: $(ROOT)/tests/unit/test_avclock.cpp \
		$(ROOT)/host/libmisterplex/av_clock.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_avclock.cpp

$(ROOT)/build/test_main_guard: $(ROOT)/tests/unit/test_main_guard.cpp \
		$(ROOT)/arm/misterplexd/fpga_spi.cpp $(ROOT)/arm/misterplexd/fpga_spi.hpp \
		$(ROOT)/host/libmisterplex/pixel_format.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -I$(ROOT)/arm/misterplexd -pthread -o $@ \
		$(ROOT)/tests/unit/test_main_guard.cpp $(ROOT)/arm/misterplexd/fpga_spi.cpp

$(ROOT)/build/test_mraudio_status: $(ROOT)/tests/unit/test_mraudio_status.cpp \
		$(ROOT)/host/libmisterplex/mraudio_status.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_mraudio_status.cpp

$(ROOT)/build/test_osd_menu: $(ROOT)/tests/unit/test_osd_menu.cpp \
		$(ROOT)/host/libmisterplex/osd_menu.hpp \
		$(ROOT)/host/libmisterplex/ddr_frame_layout.hpp \
		$(ROOT)/host/libmisterplex/idle_screen.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_osd_menu.cpp

$(ROOT)/build/test_last_frame_latch: $(ROOT)/tests/unit/test_last_frame_latch.cpp \
		$(ROOT)/host/libmisterplex/last_frame_latch.hpp \
		$(ROOT)/host/libmisterplex/ddr_frame_layout.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_last_frame_latch.cpp

$(ROOT)/build/test_playback_overlay: $(ROOT)/tests/unit/test_playback_overlay.cpp \
		$(ROOT)/host/libmisterplex/playback_overlay.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_playback_overlay.cpp

$(ROOT)/build/test_input_mailbox: $(ROOT)/tests/unit/test_input_mailbox.cpp \
		$(ROOT)/host/libmisterplex/input_mailbox.hpp \
		$(ROOT)/host/libmisterplex/mailbox_abi_spec.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_input_mailbox.cpp

$(ROOT)/build/test_pixel_format: $(ROOT)/tests/unit/test_pixel_format.cpp \
		$(ROOT)/host/libmisterplex/pixel_format.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_pixel_format.cpp

$(ROOT)/build/test_resolve: $(ROOT)/tests/unit/test_resolve.cpp \
		$(ROOT)/arm/misterplexd/plex_resolve.cpp \
		$(ROOT)/arm/misterplexd/plex_resolve.hpp \
		$(ROOT)/host/libmisterplex/osd_menu.hpp \
		$(ROOT)/host/libmisterplex/ddr_frame_layout.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -I$(ROOT)/arm/misterplexd -o $@ \
		$(ROOT)/tests/unit/test_resolve.cpp $(ROOT)/arm/misterplexd/plex_resolve.cpp

$(ROOT)/build/pms_baseline_probe: $(ROOT)/tools/pms_baseline_probe.cpp \
		$(ROOT)/arm/misterplexd/plex_resolve.cpp \
		$(ROOT)/arm/misterplexd/plex_resolve.hpp \
		$(ROOT)/host/libmisterplex/osd_menu.hpp \
		$(ROOT)/host/libmisterplex/ddr_frame_layout.hpp \
		$(ROOT)/host/libmisterplex/h264_nal.hpp \
		$(ROOT)/host/libmisterplex/h264_sps.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -I$(ROOT)/arm -I$(ROOT)/arm/misterplexd -o $@ \
		$(ROOT)/tools/pms_baseline_probe.cpp $(ROOT)/arm/misterplexd/plex_resolve.cpp

$(ROOT)/build/pms_nal_stats: $(ROOT)/tools/pms_nal_stats.cpp \
		$(ROOT)/arm/misterplexd/plex_resolve.cpp \
		$(ROOT)/arm/misterplexd/plex_resolve.hpp \
		$(ROOT)/host/libmisterplex/osd_menu.hpp \
		$(ROOT)/host/libmisterplex/ddr_frame_layout.hpp \
		$(ROOT)/host/libmisterplex/h264_bitstream_transport.hpp \
		$(ROOT)/host/libmisterplex/h264_nal_dispatch.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -I$(ROOT)/arm -I$(ROOT)/arm/misterplexd -o $@ \
		$(ROOT)/tools/pms_nal_stats.cpp $(ROOT)/arm/misterplexd/plex_resolve.cpp

$(ROOT)/build/test_pms_timeline: $(ROOT)/tests/unit/test_pms_timeline.cpp \
		$(ROOT)/arm/misterplexd/pms_timeline.cpp \
		$(ROOT)/arm/misterplexd/pms_timeline.hpp \
		$(ROOT)/arm/misterplexd/plex_resolve.cpp \
		$(ROOT)/arm/misterplexd/plex_resolve.hpp \
		$(ROOT)/host/libmisterplex/osd_menu.hpp \
		$(ROOT)/host/libmisterplex/ddr_frame_layout.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -I$(ROOT)/arm/misterplexd -pthread -o $@ \
		$(ROOT)/tests/unit/test_pms_timeline.cpp \
		$(ROOT)/arm/misterplexd/pms_timeline.cpp $(ROOT)/arm/misterplexd/plex_resolve.cpp

$(ROOT)/build/test_companion_eof: $(ROOT)/tests/unit/test_companion_eof.cpp \
		$(ROOT)/arm/misterplexd/companion.cpp \
		$(ROOT)/arm/misterplexd/companion.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -I$(ROOT)/arm/misterplexd -pthread -o $@ \
		$(ROOT)/tests/unit/test_companion_eof.cpp $(ROOT)/arm/misterplexd/companion.cpp

$(ROOT)/build/test_companion_plant_seek: $(ROOT)/tests/unit/test_companion_plant_seek.cpp \
		$(ROOT)/arm/misterplexd/companion.cpp \
		$(ROOT)/arm/misterplexd/companion.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -I$(ROOT)/arm/misterplexd -pthread -o $@ \
		$(ROOT)/tests/unit/test_companion_plant_seek.cpp $(ROOT)/arm/misterplexd/companion.cpp

$(ROOT)/build/test_h264_bitstream_source: $(ROOT)/tests/unit/test_h264_bitstream_source.cpp \
		$(ROOT)/host/libmisterplex/h264_bitstream_transport.hpp \
		$(ROOT)/host/libmisterplex/h264_nal_dispatch.hpp \
		$(ROOT)/tests/fixtures/p3_multinal/wcap_residual14_idr_plus_p.264
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_h264_bitstream_source.cpp

$(ROOT)/build/test_bitstream_ring_lifecycle: $(ROOT)/tests/unit/test_bitstream_ring_lifecycle.cpp \
		$(ROOT)/host/libmisterplex/h264_bitstream_transport.hpp \
		$(ROOT)/host/libmisterplex/h264_nal_dispatch.hpp \
		$(ROOT)/host/libmisterplex/ddr_bitstream_ring.hpp \
		$(ROOT)/tests/fixtures/p3_multinal/wcap_residual14_idr_plus_p.264 \
		$(ROOT)/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_bitstream_ring_lifecycle.cpp

# Native host daemon for local smoke
MPLEX_SRC := \
	$(ROOT)/arm/misterplexd/main.cpp \
	$(ROOT)/arm/misterplexd/companion.cpp \
	$(ROOT)/arm/misterplexd/fb_present.cpp \
	$(ROOT)/arm/misterplexd/media_player.cpp \
	$(ROOT)/arm/misterplexd/pms_timeline.cpp \
	$(ROOT)/arm/misterplexd/plex_resolve.cpp \
	$(ROOT)/arm/misterplexd/fpga_spi.cpp
MPLEX_INC := -I$(ROOT)/arm/misterplexd -I$(ROOT)/host
# Host recon headers (Phase 3.3i STREAM path)
MPLEX_HDR := \
	$(ROOT)/host/libmisterplex/h264_recon.hpp \
	$(ROOT)/host/libmisterplex/h264_slice_walk.hpp \
	$(ROOT)/host/libmisterplex/h264_cavlc.hpp \
	$(ROOT)/host/libmisterplex/h264_nal.hpp \
	$(ROOT)/host/libmisterplex/h264_sps.hpp \
	$(ROOT)/host/libmisterplex/ddr_frame_layout.hpp \
	$(ROOT)/host/libmisterplex/osd_menu.hpp \
	$(ROOT)/host/libmisterplex/idle_screen.hpp \
	$(ROOT)/host/libmisterplex/input_mailbox.hpp \
	$(ROOT)/host/libmisterplex/playback_overlay.hpp \
	$(ROOT)/host/libmisterplex/pixel_format.hpp

$(ROOT)/build/misterplexd: $(MPLEX_SRC) \
		$(ROOT)/arm/misterplexd/companion.hpp \
		$(ROOT)/arm/misterplexd/media_player.hpp \
		$(ROOT)/arm/misterplexd/pms_timeline.hpp \
		$(ROOT)/arm/misterplexd/plex_resolve.hpp \
		$(ROOT)/arm/misterplexd/fb_present.hpp \
		$(ROOT)/arm/misterplexd/fpga_spi.hpp \
		$(MPLEX_HDR)
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) $(MPLEX_INC) -pthread -o $@ $(MPLEX_SRC)

plexd: $(ROOT)/build/misterplexd

# Standalone: push one RGB565 file to Plex frame_store via SPI ioctl
$(ROOT)/build/push_frame: $(ROOT)/arm/misterplexd/fpga_spi.cpp \
		$(ROOT)/tools/push_frame.cpp $(ROOT)/arm/misterplexd/fpga_spi.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -I$(ROOT)/arm/misterplexd -I$(ROOT)/host -o $@ \
		$(ROOT)/tools/push_frame.cpp $(ROOT)/arm/misterplexd/fpga_spi.cpp

push-frame: $(ROOT)/build/push_frame

$(ROOT)/build/ddr_write_bench: $(ROOT)/tools/ddr_write_bench.cpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tools/ddr_write_bench.cpp

ddr-bench: $(ROOT)/build/ddr_write_bench

$(ROOT)/build/present_loop_harness: $(ROOT)/tools/present_loop_harness.cpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -pthread -o $@ $(ROOT)/tools/present_loop_harness.cpp

present-harness: $(ROOT)/build/present_loop_harness

$(ROOT)/build/ffmpeg_cpu_probe: $(ROOT)/tools/ffmpeg_cpu_probe.cpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tools/ffmpeg_cpu_probe.cpp

profile-tools: $(ROOT)/build/ffmpeg_cpu_probe $(ROOT)/build/ddr_write_bench $(ROOT)/build/present_loop_harness

# ARM hard-float for MiSTer (try common cross compilers + local mistercast toolchain)
ARM_TOOLCHAIN_BIN ?= $(HOME)/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin
ARM_CXX ?= $(shell command -v arm-none-linux-gnueabihf-g++ 2>/dev/null || command -v arm-linux-gnueabihf-g++ 2>/dev/null || command -v armv7l-linux-gnueabihf-g++ 2>/dev/null || ls $(ARM_TOOLCHAIN_BIN)/arm-none-linux-gnueabihf-g++ 2>/dev/null)

# Fully static: MiSTer glibc is 2.31; modern toolchains need 2.32+ for dynamic.
# whole-archive pthread required for std::thread under -static.
arm-ddr-bench:
	@if [ -z "$(ARM_CXX)" ]; then echo "No armhf g++ found"; exit 1; fi
	@mkdir -p $(ROOT)/build/arm
	$(ARM_CXX) -std=c++17 -O2 -Wall -I$(ROOT)/host \
		-o $(ROOT)/build/arm/ddr_write_bench \
		$(ROOT)/tools/ddr_write_bench.cpp \
		-static
	@file $(ROOT)/build/arm/ddr_write_bench

arm-profile-tools: arm-ddr-bench
	@if [ -z "$(ARM_CXX)" ]; then echo "No armhf g++ found"; exit 1; fi
	@mkdir -p $(ROOT)/build/arm
	$(ARM_CXX) -std=c++17 -O2 -Wall -I$(ROOT)/host \
		-o $(ROOT)/build/arm/ffmpeg_cpu_probe \
		$(ROOT)/tools/ffmpeg_cpu_probe.cpp \
		-static
	$(ARM_CXX) -std=c++17 -O2 -Wall -pthread \
		-o $(ROOT)/build/arm/present_loop_harness \
		$(ROOT)/tools/present_loop_harness.cpp \
		-static
	@file $(ROOT)/build/arm/ffmpeg_cpu_probe $(ROOT)/build/arm/present_loop_harness

arm-plexd: $(MPLEX_HDR) arm-ddr-bench
	@if [ -z "$(ARM_CXX)" ]; then echo "No armhf g++ found"; exit 1; fi
	@mkdir -p $(ROOT)/build/arm
	$(ARM_CXX) -std=c++17 -O2 -Wall $(MPLEX_INC) \
		-o $(ROOT)/build/arm/misterplexd $(MPLEX_SRC) \
		-static -Wl,--whole-archive -lpthread -Wl,--no-whole-archive
	$(ARM_CXX) -std=c++17 -O2 -Wall -I$(ROOT)/arm/misterplexd -I$(ROOT)/host \
		-o $(ROOT)/build/arm/push_frame \
		$(ROOT)/tools/push_frame.cpp $(ROOT)/arm/misterplexd/fpga_spi.cpp \
		-static
	$(ARM_CXX) -std=c++17 -O2 -Wall -I$(ROOT)/arm/misterplexd -I$(ROOT)/host \
		-o $(ROOT)/build/arm/set_status \
		$(ROOT)/tools/set_status.cpp $(ROOT)/arm/misterplexd/fpga_spi.cpp \
		-static
	$(ARM_CXX) -std=c++17 -O2 -Wall -I$(ROOT)/host \
		-o $(ROOT)/build/arm/input_mailbox_probe \
		$(ROOT)/tools/input_mailbox_probe.cpp \
		-static
	@file $(ROOT)/build/arm/misterplexd $(ROOT)/build/arm/push_frame $(ROOT)/build/arm/set_status $(ROOT)/build/arm/input_mailbox_probe
	@echo "Built $(ROOT)/build/arm/misterplexd + push_frame + set_status + input_mailbox_probe"

$(ROOT)/build/arm/input_mailbox_probe: $(ROOT)/tools/input_mailbox_probe.cpp \
		$(ROOT)/host/libmisterplex/input_mailbox.hpp
	@if [ -z "$(ARM_CXX)" ]; then echo "No armhf g++ found"; exit 1; fi
	@mkdir -p $(ROOT)/build/arm
	$(ARM_CXX) -std=c++17 -O2 -Wall -I$(ROOT)/host \
		-o $@ $(ROOT)/tools/input_mailbox_probe.cpp -static

MISTER_DEV ?= $(HOME)/Projects/misterfpga-dev
build-rbf:
	$(MISTER_DEV)/scripts/mister-dev build $(ROOT)/fpga/Plex_MiSTer --qpf Plex.qpf

package:
	$(ROOT)/scripts/package_release.sh
	REQUIRE_ARTIFACT=1 $(ROOT)/tests/unit/test_no_private_data.sh
	REQUIRE_ARTIFACT=1 $(ROOT)/tests/unit/test_release_rbf_hash.sh

clean:
	rm -rf $(ROOT)/build

# ── cast/timeline end-to-end gates ───────────────────────────────────────────
# Primary gate: direct HTTP control protocol (no browser, robust, fast).
# Requires live MiSTer at MISTER_HOST and PMS reachable from this host.
# Exits 77 (UNSCORED/SKIP) if device or credentials are unavailable.
cast-timeline-gate:
	python3 $(ROOT)/scripts/run_with_skip_summary.py --label cast-timeline-gate -- \
	  bash $(ROOT)/tests/hw/test_cast_timeline_poll.sh

# Browser fidelity check: Playwright drives Plex Web UI, asserts on same
# /player/timeline/poll endpoint.  Exits 77 if Playwright not installed or
# UI selectors fail (Plex Web is a heavy React app with unstable selectors).
cast-timeline-playwright:
	python3 $(ROOT)/scripts/run_with_skip_summary.py --label cast-timeline-playwright -- \
	  node $(ROOT)/tests/hw/e2e/test_cast_timeline_playwright.js

# ── HDMI capture rig preflight ────────────────────────────────────────────────
# Enumerates /dev/video* capture nodes, probes format/resolution/fps, grabs N
# live frames to prove liveness, and classifies the signal as CONTENT_PRESENT /
# BLACK_SIGNAL / NO_SIGNAL.  Exits 77 (UNSCORED) when no capture hardware is
# present.  BLACK_SIGNAL is a known state for resident RBF 00eebd5e.
capture-rig-preflight:
	python3 $(ROOT)/scripts/run_with_skip_summary.py --label capture-rig-preflight -- \
	  bash $(ROOT)/tests/hw/test_capture_preflight.sh

# Left-edge clip artifact gate.  After a core reset the idle logo grey background
# (DDR luma=44 from col 0) must appear at display col 0.  Known defect in RBF
# 00eebd5e: 24-pixel black strip on left edge (source cols 0-10 absent from HDMI).
# Pass captured frames as args, or let it capture live from auto-detected HDMI device.
left-edge-clip-gate:
	python3 $(ROOT)/scripts/run_with_skip_summary.py --label left-edge-clip-gate -- \
	  bash $(ROOT)/tests/hw/test_left_edge_clip.sh

# RBF identity label check.  Verifies that misterplexd's idle-screen label
# "RBF xxxxxxxx" (first 8 hex chars of Plex.rbf md5) is visible in the HDMI
# output.  Captures a live frame, OCRs the label region, compares to the
# md5 fetched from the MiSTer via SSH.
# Override: EXPECTED_MD5=xxxxxxxx to skip SSH fetch.
# Example: make rbf-label-check EXPECTED_MD5=fb4bad84
rbf-label-check:
	python3 $(ROOT)/scripts/run_with_skip_summary.py --label rbf-label-check -- \
	  python3 $(ROOT)/scripts/grade_rbf_label.py \
	    --capture \
	    $(if $(EXPECTED_MD5),--expected-md5 $(EXPECTED_MD5),)

