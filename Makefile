# MiSTerPlex top-level Makefile
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
CXX  ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -I$(ROOT)/host

.PHONY: all unit arm-plexd clean help plexd

all: unit

help:
	@echo "Targets:"
	@echo "  make unit       - host unit tests (cadence, resolve, companion HTTP)"
	@echo "  make arm-plexd  - cross-build ARM misterplexd (if toolchain present)"
	@echo "  make build-rbf  - build Plex.rbf via misterfpga-dev (long)"
	@echo "  make test       - alias for unit"

test: unit

unit: $(ROOT)/build/test_cadence $(ROOT)/build/test_resolve $(ROOT)/build/test_frame_store_math $(ROOT)/build/test_annexb_count $(ROOT)/build/test_sps_parse $(ROOT)/build/test_slice_hdr
	$(ROOT)/build/test_cadence
	$(ROOT)/build/test_resolve
	$(ROOT)/build/test_frame_store_math
	$(ROOT)/build/test_annexb_count
	@python3 $(ROOT)/scripts/gen_test_annexb_real.py /tmp/plex_real_baseline.h264
	$(ROOT)/build/test_sps_parse /tmp/plex_real_baseline.h264
	$(ROOT)/build/test_slice_hdr /tmp/plex_real_baseline.h264
	@chmod +x $(ROOT)/tests/unit/test_companion_http.sh
	$(ROOT)/tests/unit/test_companion_http.sh

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

$(ROOT)/build/test_resolve: $(ROOT)/tests/unit/test_resolve.cpp \
		$(ROOT)/arm/misterplexd/plex_resolve.cpp \
		$(ROOT)/arm/misterplexd/plex_resolve.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -I$(ROOT)/arm/misterplexd -o $@ \
		$(ROOT)/tests/unit/test_resolve.cpp $(ROOT)/arm/misterplexd/plex_resolve.cpp

# Native host daemon for local smoke
MPLEX_SRC := \
	$(ROOT)/arm/misterplexd/main.cpp \
	$(ROOT)/arm/misterplexd/companion.cpp \
	$(ROOT)/arm/misterplexd/fb_present.cpp \
	$(ROOT)/arm/misterplexd/media_player.cpp \
	$(ROOT)/arm/misterplexd/plex_resolve.cpp \
	$(ROOT)/arm/misterplexd/fpga_spi.cpp
MPLEX_INC := -I$(ROOT)/arm/misterplexd

$(ROOT)/build/misterplexd: $(MPLEX_SRC) \
		$(ROOT)/arm/misterplexd/companion.hpp \
		$(ROOT)/arm/misterplexd/media_player.hpp \
		$(ROOT)/arm/misterplexd/plex_resolve.hpp \
		$(ROOT)/arm/misterplexd/fb_present.hpp \
		$(ROOT)/arm/misterplexd/fpga_spi.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) $(MPLEX_INC) -pthread -o $@ $(MPLEX_SRC)

plexd: $(ROOT)/build/misterplexd

# Standalone: push one RGB565 file to Plex frame_store via SPI ioctl
$(ROOT)/build/push_frame: $(ROOT)/arm/misterplexd/fpga_spi.cpp \
		$(ROOT)/tools/push_frame.cpp $(ROOT)/arm/misterplexd/fpga_spi.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -I$(ROOT)/arm/misterplexd -o $@ \
		$(ROOT)/tools/push_frame.cpp $(ROOT)/arm/misterplexd/fpga_spi.cpp

push-frame: $(ROOT)/build/push_frame

# ARM hard-float for MiSTer (try common cross compilers + local mistercast toolchain)
ARM_CXX ?= $(shell command -v arm-none-linux-gnueabihf-g++ 2>/dev/null || command -v arm-linux-gnueabihf-g++ 2>/dev/null || command -v armv7l-linux-gnueabihf-g++ 2>/dev/null || ls /home/shawn/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin/arm-none-linux-gnueabihf-g++ 2>/dev/null)

# Fully static: MiSTer glibc is 2.31; modern toolchains need 2.32+ for dynamic.
# whole-archive pthread required for std::thread under -static.
arm-plexd:
	@if [ -z "$(ARM_CXX)" ]; then echo "No armhf g++ found"; exit 1; fi
	@mkdir -p $(ROOT)/build/arm
	$(ARM_CXX) -std=c++17 -O2 -Wall $(MPLEX_INC) \
		-o $(ROOT)/build/arm/misterplexd $(MPLEX_SRC) \
		-static -Wl,--whole-archive -lpthread -Wl,--no-whole-archive
	$(ARM_CXX) -std=c++17 -O2 -Wall $(MPLEX_INC) \
		-o $(ROOT)/build/arm/push_frame \
		$(ROOT)/tools/push_frame.cpp $(ROOT)/arm/misterplexd/fpga_spi.cpp \
		-static
	@file $(ROOT)/build/arm/misterplexd $(ROOT)/build/arm/push_frame
	@echo "Built $(ROOT)/build/arm/misterplexd + push_frame"

MISTER_DEV ?= /home/shawn/Projects/misterfpga-dev
build-rbf:
	$(MISTER_DEV)/scripts/mister-dev build $(ROOT)/fpga/Plex_MiSTer --qpf Plex.qpf

clean:
	rm -rf $(ROOT)/build
