"""Shared fabric H.264 decoder conformance harness (ARM oracle vs RTL).

Framework only — stage lanes plug bit-exact vectors into compare/corpus/coverage.
Named feature: fabric decode replacing ARM; defect class: QIP-only / never-
instantiated h264_* and demo-path hardcoding.
"""

from .compare import CompareResult, compare_i420, compare_bytes, format_first_divergence
from .corpus import load_corpus_manifest, select_subjects, Selection
from .coverage import load_coverage_ledger, check_coverage_claims
from .reachability_claims import check_claimed_decoder_modules

__all__ = [
    "CompareResult",
    "compare_i420",
    "compare_bytes",
    "format_first_divergence",
    "load_corpus_manifest",
    "select_subjects",
    "Selection",
    "load_coverage_ledger",
    "check_coverage_claims",
    "check_claimed_decoder_modules",
]
