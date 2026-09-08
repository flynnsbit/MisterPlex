#!/usr/bin/env bash
set -euo pipefail
echo "=== Existing complete frame-deblock oracle, including pipeline cancellation extensions ==="
bash tests/unit/test_h264_deblock_frame.sh all
echo "=== Original chroma oracle plus complete pipeline/ownership checks ==="
bash tests/unit/test_p2_chroma_pred.sh
echo "=== Original DPB/inter/reference campaign plus staged sample/QP checks ==="
bash tests/unit/test_h264_inter_reference.sh
