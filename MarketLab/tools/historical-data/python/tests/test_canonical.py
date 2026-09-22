"""Canonical decimal/timestamp forms and the semantic stream digest."""

from __future__ import annotations

import sys
import tempfile
import unittest
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from marketlab_historical_data.canonical import (  # noqa: E402
    CanonicalValueError,
    SemanticStreamDigest,
    canonical_decimal_text,
    canonical_utc_timestamp_text,
    format_semantic_line,
    lean_decimal_representable,
    parse_decimal_text,
    sha256_file,
    sha256_hex,
    utc_is_millisecond_exact,
)

FIXTURE_DIGEST = "sha256:92db8c553e1229145d107d52e8da0e40f645b3f929bbe41a864d2c0e4053d218"


def utc(hour, minute, second, microsecond):
    return datetime(2014, 5, 5, hour, minute, second, microsecond, tzinfo=timezone.utc)


class ParseDecimalTextTests(unittest.TestCase):
    def test_plain_decimals_are_accepted_exactly(self):
        self.assertEqual(parse_decimal_text("1291.6770", "bid"), Decimal("1291.6770"))
        self.assertEqual(parse_decimal_text(" .5 ", "ask"), Decimal("0.5"))
        self.assertEqual(parse_decimal_text("+1.", "bid"), Decimal("1"))

    def test_exact_exponent_notation_is_accepted_exactly(self):
        self.assertEqual(parse_decimal_text("1.9e3", "bid"), Decimal("1900"))
        self.assertEqual(parse_decimal_text("1.9E+3", "ask"), Decimal("1900"))
        self.assertEqual(canonical_decimal_text(parse_decimal_text("1e5", "bid")), "100000")

    def test_non_decimal_spellings_are_rejected(self):
        for text in ("", "   ", "nan", "NaN", "inf", "-inf", "Infinity", "1_000", "1,5", "0x10", "abc", "1e", "e3"):
            with self.subTest(text=text):
                with self.assertRaises(CanonicalValueError):
                    parse_decimal_text(text, "bid")


class Sha256Tests(unittest.TestCase):
    def test_streaming_hash_matches_one_shot(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "payload.bin"
            payload = bytes(range(256)) * 4096
            path.write_bytes(payload)
            self.assertEqual(sha256_file(path), sha256_hex(payload))
            self.assertEqual(sha256_file(path, chunk_size=7), sha256_hex(payload))


class CanonicalDecimalTests(unittest.TestCase):
    def test_numerically_equal_values_share_one_text(self):
        for text, expected in (
            ("1.2", "1.2"),
            ("1.20", "1.2"),
            ("1.200", "1.2"),
            ("1000.000", "1000"),
            ("0.000", "0"),
            ("-0.0", "0"),
            ("1291.6770", "1291.677"),
            ("0.0500", "0.05"),
            ("0.001", "0.001"),
            ("1291.68", "1291.68"),
            ("0.00000000000000000000000000001", "0.00000000000000000000000000001"),
        ):
            with self.subTest(text=text):
                self.assertEqual(canonical_decimal_text(Decimal(text)), expected)

    def test_zero_and_negative_zero(self):
        self.assertEqual(canonical_decimal_text(Decimal("0.000000")), "0")

    def test_lean_decimal_representability(self):
        self.assertTrue(lean_decimal_representable(Decimal("1291.677")))
        self.assertTrue(lean_decimal_representable(Decimal("0")))
        self.assertTrue(lean_decimal_representable(Decimal("1.000000000000000000000000000000")))
        self.assertTrue(lean_decimal_representable(Decimal("9223372036854775807")))
        self.assertFalse(lean_decimal_representable(Decimal("9223372036854775808")))
        self.assertFalse(lean_decimal_representable(Decimal("18446744073709551616")))
        self.assertFalse(lean_decimal_representable(Decimal("0.00000000000000000000000000001")))

    def test_round_prices_ending_in_zero_are_representable(self):
        for text in ("10", "100", "1000", "1900", "1900.00", "2000", "2010.0", "1200.50"):
            with self.subTest(text=text):
                self.assertTrue(lean_decimal_representable(Decimal(text)))

    def test_integer_values_beyond_the_signed_reader_are_rejected(self):
        self.assertTrue(lean_decimal_representable(Decimal("9223372036854775807")))
        self.assertFalse(lean_decimal_representable(Decimal("9223372036854775808")))
        self.assertFalse(lean_decimal_representable(Decimal("10000000000000000000")))

    def test_scale_29_is_rejected(self):
        self.assertFalse(
            lean_decimal_representable(Decimal("0.00000000000000000000000000001"))
        )
        self.assertTrue(
            lean_decimal_representable(Decimal("0.0000000000000000000000000001"))
        )

    def test_extreme_exponents_are_rejected_without_expanding_them(self):
        self.assertFalse(lean_decimal_representable(Decimal("1e999999999")))
        self.assertFalse(lean_decimal_representable(Decimal("1e-999999999")))
        self.assertFalse(lean_decimal_representable(Decimal("1e1000000")))
        self.assertTrue(lean_decimal_representable(Decimal("1e18")))

    def test_extreme_exponent_canonical_text_is_refused(self):
        with self.assertRaises(CanonicalValueError):
            canonical_decimal_text(Decimal("1e999999999"))


class CanonicalTimestampTests(unittest.TestCase):
    def test_canonical_text_is_fixed_millisecond_form(self):
        self.assertEqual(
            canonical_utc_timestamp_text(utc(8, 0, 0, 250000)), "2014-05-05T08:00:00.250Z"
        )

    def test_sub_millisecond_timestamp_is_refused_not_truncated(self):
        with self.assertRaises(CanonicalValueError):
            canonical_utc_timestamp_text(utc(8, 0, 0, 123456))

    def test_millisecond_exactness(self):
        self.assertTrue(utc_is_millisecond_exact(utc(8, 0, 0, 123000)))
        self.assertFalse(utc_is_millisecond_exact(utc(8, 0, 0, 123456)))


class SemanticDigestTests(unittest.TestCase):
    def _fixture_digest(self):
        digest = SemanticStreamDigest()
        digest.add(utc(8, 0, 0, 0), Decimal("1291.6770"), Decimal("1292.0330"))
        digest.add(utc(8, 0, 0, 100000), Decimal("1291.680"), Decimal("1291.680"))
        digest.add(utc(8, 0, 0, 100000), Decimal("1291.681"), Decimal("1291.684"))
        digest.add(utc(8, 0, 0, 250000), Decimal("1291.69"), Decimal("1291.72"))
        return digest

    def test_cross_language_reference_vector(self):
        digest = self._fixture_digest()
        self.assertEqual(digest.count, 4)
        self.assertEqual(digest.first_timestamp, "2014-05-05T08:00:00.000Z")
        self.assertEqual(digest.last_timestamp, "2014-05-05T08:00:00.250Z")
        self.assertEqual(digest.digest(), FIXTURE_DIGEST)

    def test_line_format_is_the_documented_tuple(self):
        self.assertEqual(
            format_semantic_line(1, utc(8, 0, 0, 0), Decimal("1291.6770"), Decimal("1292.0330")),
            "1|2014-05-05T08:00:00.000Z|1291.677|1292.033\n",
        )

    def test_digest_is_deterministic(self):
        self.assertEqual(self._fixture_digest().digest(), self._fixture_digest().digest())

    def test_digest_is_idempotent_on_one_instance(self):
        digest = self._fixture_digest()
        self.assertEqual(digest.digest(), digest.digest())

    def test_order_changes_the_digest(self):
        first = SemanticStreamDigest()
        first.add(utc(8, 0, 0, 0), Decimal("1.1"), Decimal("1.2"))
        first.add(utc(8, 0, 0, 1000), Decimal("1.3"), Decimal("1.4"))
        second = SemanticStreamDigest()
        second.add(utc(8, 0, 0, 1000), Decimal("1.3"), Decimal("1.4"))
        second.add(utc(8, 0, 0, 0), Decimal("1.1"), Decimal("1.2"))
        self.assertNotEqual(first.digest(), second.digest())

    def test_duplicate_rows_are_preserved(self):
        once = SemanticStreamDigest()
        once.add(utc(8, 0, 0, 0), Decimal("1.1"), Decimal("1.2"))
        twice = SemanticStreamDigest()
        twice.add(utc(8, 0, 0, 0), Decimal("1.1"), Decimal("1.2"))
        twice.add(utc(8, 0, 0, 0), Decimal("1.1"), Decimal("1.2"))
        self.assertEqual(twice.count, 2)
        self.assertNotEqual(once.digest(), twice.digest())

    def test_sub_millisecond_row_is_refused(self):
        digest = SemanticStreamDigest()
        with self.assertRaises(CanonicalValueError):
            digest.add(utc(8, 0, 0, 123456), Decimal("1.1"), Decimal("1.2"))


if __name__ == "__main__":
    unittest.main()
