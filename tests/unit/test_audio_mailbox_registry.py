#!/usr/bin/env python3
"""Exercise the shared registry gate without running unrelated RTL guards."""
import contextlib
import io
import json
import unittest
from unittest import mock

import test_rtl_invariants as invariants


class MailboxRegistryTests(unittest.TestCase):
    def setUp(self):
        self.registry = json.loads(
            invariants.read(invariants.ROOT / "docs/plx_mailbox_map.json")
        )

    def assert_rejected(self, message, check_fn=invariants.check_mailbox_map_collisions):
        errors = io.StringIO()
        with mock.patch("json.loads", return_value=self.registry):
            with contextlib.redirect_stderr(errors):
                with self.assertRaises(SystemExit) as failure:
                    check_fn()
        self.assertEqual(failure.exception.code, 1)
        self.assertIn(message, errors.getvalue())

    def test_current_host_rtl_and_registry_agree(self):
        invariants.check_mailbox_map_collisions()

    def test_audio_status_cannot_be_omitted(self):
        del self.registry["fpga_audio_session"]["MAST"]
        self.assert_rejected("Audio request/status mailboxes are missing")

    def test_audio_request_body_is_reserved(self):
        self.registry["fpga_audio_session"]["MAST"]["address"] = "0x30140108"
        self.assert_rejected("MACT mailbox region overlaps MAST")

    def test_video_presentation_body_is_reserved(self):
        self.registry["fpga_audio_session"]["MACT"]["address"] = "0x301400A0"
        self.assert_rejected("MVPS mailbox region overlaps MACT")

    def test_audio_magic_cannot_alias_another_mailbox(self):
        audio = self.registry["fpga_audio_session"]
        audio["MAST"]["magic"] = audio["MACT"]["magic"]
        self.assert_rejected("Ring magic collision")

    def test_audio_size_must_match_host(self):
        self.registry["fpga_audio_session"]["MACT"]["size_bytes"] = 32
        self.assert_rejected("MACT size differs from mailbox_abi_spec.hpp")

    def test_audio_version_must_match_host(self):
        self.registry["fpga_audio_session"]["_abi_version"] = 1
        self.assert_rejected("Audio ABI version differs from mailbox_abi_spec.hpp")

    def test_audio_producer_position_word_cannot_be_omitted(self):
        del self.registry["fpga_audio_session"]["MACT"]["qwords"][4]
        self.assert_rejected("MACT documented qword count differs from mailbox size")

    def test_audio_commit_magic_must_match_host(self):
        self.registry["fpga_audio_session"]["MACT"]["commit_magic"] = "0xDEADBEEF"
        self.assert_rejected("MACT commit magic differs from mailbox_abi_spec.hpp")

    def test_generated_rtl_address_must_match_registry(self):
        real_read = invariants.read

        def changed_read(path):
            text = real_read(path)
            if path.name == "audio_session_abi.svh":
                text = text.replace("32'h30140140", "32'h30140148")
            return text

        with mock.patch.object(invariants, "read", side_effect=changed_read):
            self.assert_rejected("MAST address differs from rtl/audio_session_abi.svh")

    def test_ring_reset_epoch_contract_matches(self):
        invariants.check_ddr_bitstream_ring()

    def test_ring_reset_ack_cannot_revert_to_reserved_bits(self):
        real_read = invariants.read

        def changed_read(path):
            text = real_read(path)
            if path == invariants.DDR_BITSTREAM_READER:
                text = text.replace("4'd0, reset_seen, telem_seq", "5'd0, telem_seq")
            return text

        with mock.patch.object(invariants, "read", side_effect=changed_read):
            self.assert_rejected(
                "ddr_bitstream_reader no longer packs PLXE",
                invariants.check_ddr_bitstream_ring,
            )


if __name__ == "__main__":
    unittest.main()
