# MiSTerPlex top-level Makefile
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
CXX  ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -I$(ROOT)/host

.PHONY: all unit arm-plexd clean help

all: unit

help:
	@echo "Targets:"
	@echo "  make unit       - host unit tests (cadence, …)"
	@echo "  make arm-plexd  - cross-build ARM misterplexd (if toolchain present)"
	@echo "  make build-rbf  - build Plex.rbf via misterfpga-dev (long)"
	@echo "  make test       - alias for unit"

test: unit

unit: $(ROOT)/build/test_cadence
	$(ROOT)/build/test_cadence
	@chmod +x $(ROOT)/tests/unit/test_companion_http.sh
	$(ROOT)/tests/unit/test_companion_http.sh

$(ROOT)/build/test_cadence: $(ROOT)/tests/unit/test_cadence.cpp $(ROOT)/host/libmisterplex/cadence.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) -o $@ $(ROOT)/tests/unit/test_cadence.cpp

# Native host daemon for local smoke
MPLEX_SRC := $(ROOT)/arm/misterplexd/main.cpp $(ROOT)/arm/misterplexd/companion.cpp
MPLEX_INC := -I$(ROOT)/arm/misterplexd

$(ROOT)/build/misterplexd: $(MPLEX_SRC) $(ROOT)/arm/misterplexd/companion.hpp
	@mkdir -p $(ROOT)/build
	$(CXX) $(CXXFLAGS) $(MPLEX_INC) -pthread -o $@ $(MPLEX_SRC)

plexd: $(ROOT)/build/misterplexd

# ARM hard-float for MiSTer (try common cross compilers)
ARM_CXX ?= $(shell command -v arm-none-linux-gnueabihf-g++ 2>/dev/null || command -v arm-linux-gnueabihf-g++ 2>/dev/null || command -v armv7l-linux-gnueabihf-g++ 2>/dev/null)

arm-plexd:
	@if [ -z "$(ARM_CXX)" ]; then echo "No armhf g++ found"; exit 1; fi
	@mkdir -p $(ROOT)/build/arm
	$(ARM_CXX) -std=c++17 -O2 -Wall $(MPLEX_INC) -pthread -static-libstdc++ \
		-o $(ROOT)/build/arm/misterplexd $(MPLEX_SRC)
	@echo "Built $(ROOT)/build/arm/misterplexd"

MISTER_DEV ?= /home/shawn/Projects/misterfpga-dev
build-rbf:
	$(MISTER_DEV)/scripts/mister-dev build $(ROOT)/fpga/Plex_MiSTer --qpf Plex.qpf

clean:
	rm -rf $(ROOT)/build
