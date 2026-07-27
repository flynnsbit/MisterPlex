# MiSTerPlex top-level Makefile
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
CXX  ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -I$(ROOT)/host

.PHONY: all unit arm-plexd arm-ddr-bench ddr-bench present-harness clean help plexd package

all: unit

help:
	@echo "Targets:"
	@echo "  make unit       - host unit tests (cadence, resolve, companion HTTP)"
	@echo "  make arm-plexd  - cross-build ARM misterplexd (if toolchain present)"
	@echo "  make build-rbf  - build Plex.rbf via misterfpga-dev (long)"
	@echo "  make test       - alias for unit"
	@echo "  make package    - dist tarball (ARM + conf + docs + Plex.rbf if present)"
	@echo "  make arm-ddr-bench - cross-build DDR write microbenchmark"
	@echo "  make present-harness - build offline present-loop pipe/copy harness"

test: unit

UNIT_ANNEXB := $(ROOT)/build/plex_real_baseline.264

unit: $(ROOT)/build/test_cadence $(ROOT)/build/test_avclock $(ROOT)/build/test_mraudio_status $(ROOT)/build/test_osd_menu $(ROOT)/build/test_playback_overlay $(ROOT)/build/test_input_mailbox $(ROOT)/build/test_pixel_format $(ROOT)/build/test_main_guard $(ROOT)/build/test_resolve $(ROOT)/build/test_pms_timeline $(ROOT)/build/test_frame_store_math $(ROOT)/build/test_annexb_count $(ROOT)/build/test_sps_parse $(ROOT)/build/test_slice_hdr $(ROOT)/build/test_cavlc_dc $(ROOT)/build/test_idct_quant
	$(ROOT)/build/test_cadence
	$(ROOT)/build/test_avclock
	$(ROOT)/build/test_mraudio_status
	$(ROOT)/build/test_osd_menu
	$(ROOT)/build/test_playback_overlay
	$(ROOT)/build/test_input_mailbox
	$(ROOT)/build/test_pixel_format
	$(ROOT)/build/test_main_guard
	$(ROOT)/build/test_resolve
	$(ROOT)/build/test_pms_timeline
	$(ROOT)/build/test_frame_store_math
	$(ROOT)/build/test_annexb_count
	@mkdir -p $(ROOT)/build
	@python3 $(ROOT)/scripts/gen_test_annexb_real.py $(UNIT_ANNEXB)
	$(ROOT)/build/test_sps_parse $(UNIT_ANNEXB)
	$(ROOT)/build/test_slice_hdr $(UNIT_ANNEXB)
	$(ROOT)/build/test_cavlc_dc $(UNIT_ANNEXB)
	$(ROOT)/build/test_idct_quant $(UNIT_ANNEXB)
	@chmod +x $(ROOT)/tests/unit/test_companion_http.sh $(ROOT)/tests/unit/test_plex_browse.sh $(ROOT)/tests/unit/test_no_private_data.sh $(ROOT)/tests/unit/test_capture_rig.sh $(ROOT)/tests/unit/test_rtl_invariants.sh $(ROOT)/tests/unit/test_mister_ini_plex_guard.sh $(ROOT)/tests/unit/test_release_rbf_hash.sh
	$(ROOT)/tests/unit/test_companion_http.sh
	$(ROOT)/tests/unit/test_plex_browse.sh
	$(ROOT)/tests/unit/test_no_private_data.sh
	$(ROOT)/tests/unit/test_capture_rig.sh
	$(ROOT)/tests/unit/test_rtl_invariants.sh
	$(ROOT)/tests/unit/test_mister_ini_plex_guard.sh
	$(ROOT)/tests/unit/test_release_rbf_hash.sh

$(ROOT)/build/test_idct_quant: $(ROOT)/tests/unit/test_idct_quant.cpp \
		$(ROOT)/host/libmisterplex/h264_cavlc.hpp $(ROOT)/host/libmisterplex/h264_nal.hpp \
		$(ROOT)/host/libmisterplex/h264_sps.hpp $(ROOT)/host/libmisterplex/h264_recon.hpp \
		$(ROOT)/host/libmisterplex/h264_residual_gold.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_idct_quant.cpp

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

$(ROOT)/build/test_frame_store_math: $(ROOT)/tests/unit/test_frame_store_math.cpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_frame_store_math.cpp

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
		$(ROOT)/host/libmisterplex/idle_screen.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_osd_menu.cpp

$(ROOT)/build/test_playback_overlay: $(ROOT)/tests/unit/test_playback_overlay.cpp \
		$(ROOT)/host/libmisterplex/playback_overlay.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_playback_overlay.cpp

$(ROOT)/build/test_input_mailbox: $(ROOT)/tests/unit/test_input_mailbox.cpp \
		$(ROOT)/host/libmisterplex/input_mailbox.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_input_mailbox.cpp

$(ROOT)/build/test_pixel_format: $(ROOT)/tests/unit/test_pixel_format.cpp \
		$(ROOT)/host/libmisterplex/pixel_format.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_pixel_format.cpp

$(ROOT)/build/test_resolve: $(ROOT)/tests/unit/test_resolve.cpp \
		$(ROOT)/arm/misterplexd/plex_resolve.cpp \
		$(ROOT)/arm/misterplexd/plex_resolve.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -I$(ROOT)/arm/misterplexd -o $@ \
		$(ROOT)/tests/unit/test_resolve.cpp $(ROOT)/arm/misterplexd/plex_resolve.cpp

$(ROOT)/build/test_pms_timeline: $(ROOT)/tests/unit/test_pms_timeline.cpp \
		$(ROOT)/arm/misterplexd/pms_timeline.cpp \
		$(ROOT)/arm/misterplexd/pms_timeline.hpp \
		$(ROOT)/arm/misterplexd/plex_resolve.cpp \
		$(ROOT)/arm/misterplexd/plex_resolve.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -I$(ROOT)/arm/misterplexd -pthread -o $@ \
		$(ROOT)/tests/unit/test_pms_timeline.cpp \
		$(ROOT)/arm/misterplexd/pms_timeline.cpp $(ROOT)/arm/misterplexd/plex_resolve.cpp

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

# ARM hard-float for MiSTer (try common cross compilers + local mistercast toolchain)
ARM_TOOLCHAIN_BIN ?= $(HOME)/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin
ARM_CXX ?= $(shell command -v arm-none-linux-gnueabihf-g++ 2>/dev/null || command -v arm-linux-gnueabihf-g++ 2>/dev/null || command -v armv7l-linux-gnueabihf-g++ 2>/dev/null || ls $(ARM_TOOLCHAIN_BIN)/arm-none-linux-gnueabihf-g++ 2>/dev/null)

# Fully static: MiSTer glibc is 2.31; modern toolchains need 2.32+ for dynamic.
# whole-archive pthread required for std::thread under -static.
arm-ddr-bench:
	@if [ -z "$(ARM_CXX)" ]; then echo "No armhf g++ found"; exit 1; fi
	@mkdir -p $(ROOT)/build/arm
	$(ARM_CXX) -std=c++17 -O2 -Wall \
		-o $(ROOT)/build/arm/ddr_write_bench \
		$(ROOT)/tools/ddr_write_bench.cpp \
		-static
	@file $(ROOT)/build/arm/ddr_write_bench

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
	@chmod +x $(ROOT)/tests/unit/test_no_private_data.sh $(ROOT)/tests/unit/test_release_rbf_hash.sh
	REQUIRE_ARTIFACT=1 $(ROOT)/tests/unit/test_no_private_data.sh
	REQUIRE_ARTIFACT=1 $(ROOT)/tests/unit/test_release_rbf_hash.sh

clean:
	rm -rf $(ROOT)/build
