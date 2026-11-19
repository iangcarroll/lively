import re
import struct
import unittest
from pathlib import Path


STORE = Path(__file__).resolve().parents[2] / "AppStore"
LISTINGS = [STORE / "localizations" / locale for locale in ("ja", "zh-Hant")]


def png_dimensions(path):
    with path.open("rb") as image:
        header = image.read(24)
    if not header.startswith(b"\x89PNG\r\n\x1a\n") or header[12:16] != b"IHDR":
        raise ValueError(f"Invalid PNG: {path}")
    return struct.unpack(">II", header[16:24])


class LocalizedListingTests(unittest.TestCase):
    def test_fields_fit_app_store_connect(self):
        for listing in LISTINGS:
            with self.subTest(locale=listing.name):
                fields, description = (listing / "metadata.md").read_text().split("## Description\n")
                values = dict(re.findall(r"^- (.+?): `([^`]+)`$", fields, re.MULTILINE))
                for field, limit in [("Name", 30), ("Subtitle", 30), ("Promotional Text", 170)]:
                    self.assertLessEqual(len(values[field]), limit, field)
                keywords = values["Keywords"]
                self.assertLessEqual(len(keywords.encode("utf-8")), 100)
                self.assertEqual(len(keywords.split(",")), len(set(keywords.split(","))))
                self.assertTrue(all(len(term.strip()) > 2 for term in keywords.split(",")))
                self.assertTrue(0 < len(description.strip()) <= 4000)
                self.assertIn(values["Privacy Policy URL"], description)

    def test_localized_sets_match_supported_device_placements(self):
        def placements(root):
            return {p.relative_to(root): png_dimensions(p) for p in root.glob("*/*.png")}
        expected = placements(STORE / "marketing")
        self.assertTrue(expected)
        for listing in LISTINGS:
            with self.subTest(locale=listing.name):
                self.assertEqual(placements(listing / "marketing"), expected)


if __name__ == "__main__":
    unittest.main()
