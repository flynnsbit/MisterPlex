#!/usr/bin/env bash
# Idempotent Cloud Agent bootstrap for the raetro Quartus 17.0.2 image.
# Proves the toolchain is on PATH. Does not run a Quartus fit or produce an RBF.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v quartus_sh >/dev/null 2>&1; then
  echo "quartus_sh not on PATH" >&2
  echo "PATH=$PATH" >&2
  exit 1
fi

version="$(quartus_sh --version 2>&1 || true)"
printf '%s\n' "$version"
if ! printf '%s\n' "$version" | grep -q '17.0.2'; then
  echo "Expected Quartus Prime 17.0.2 in quartus_sh --version" >&2
  exit 1
fi

make define-parity
make quartus-sv-subset

echo "cloud-agent-install: Quartus 17.0.2 present; define-parity and quartus-sv-subset OK"
echo "Fit (not part of install): cd fpga/Plex_MiSTer && quartus_sh --flow compile Plex.qpf"
