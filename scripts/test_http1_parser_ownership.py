#!/usr/bin/env python3
"""Keep raw HTTP response framing in one tested shared implementation."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PARSER = ROOT / "packages/ssrvpn_shared/lib/services/http1_response_decoder.dart"
BARREL = ROOT / "packages/ssrvpn_shared/lib/ssrvpn_shared.dart"
CALLERS = (
    ROOT / "packages/ssrvpn_shared/lib/services/direct_fetcher.dart",
    ROOT / "SSRVPN_Android/lib/services/subscription_service.dart",
)
CONTRACT_TEST = (
    ROOT / "packages/ssrvpn_shared/test/http1_response_decoder_test.dart"
)


class Http1ParserOwnershipTests(unittest.TestCase):
    def test_both_raw_socket_callers_use_the_shared_decoder(self) -> None:
        for caller in CALLERS:
            source = caller.read_text(encoding="utf-8")
            self.assertEqual(source.count("Http1ResponseDecoder("), 1, caller)
            self.assertNotIn("class _ChunkedBodyDecoder", source, caller)
            self.assertNotIn("decodeHttp1HeaderBytes(", source, caller)

    def test_decoder_is_public_and_owns_framing(self) -> None:
        source = PARSER.read_text(encoding="utf-8")
        self.assertIn("class Http1ResponseDecoder", source)
        self.assertIn("class _ChunkedBodyDecoder", source)
        self.assertIn("decodeHttp1HeaderBytes(", source)
        self.assertIn(
            "services/http1_response_decoder.dart",
            BARREL.read_text(encoding="utf-8"),
        )

    def test_contract_covers_fragmentation_and_fail_closed_boundaries(self) -> None:
        source = CONTRACT_TEST.read_text(encoding="utf-8")
        for contract in (
            "every byte boundary",
            "chunk extensions and trailers",
            "truncated content-length",
            "incomplete chunked body",
            "transfer-encoding and content-length conflict",
            "invalid content-length and status-line syntax",
            "decoded body and wire framing beyond their limits",
        ):
            self.assertIn(contract, source)


if __name__ == "__main__":
    unittest.main()
