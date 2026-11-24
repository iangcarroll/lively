"""Check the localized resources shipped in the app and its widget (no SDK required)."""
from collections import Counter
import json
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / "android/app/src/main/res"
ANDROID_NAME = "{http://schemas.android.com/apk/res/android}name"


def apple_strings(path):
    entries = {}
    quoted = r'"(?:[^"\\]|\\.)*"'
    for line in path.read_text().splitlines():
        if line.strip():
            match = re.fullmatch(rf"({quoted}) = ({quoted});", line)
            key, value = map(json.loads, match.groups())
            if key in entries:
                raise ValueError(f"{path}: duplicate {key}")
            entries[key] = value
    return entries


def android_strings(path):
    entries = {}
    for node in ET.parse(path).getroot():
        if node.get("translatable") != "false":
            value = node.text
            # Android treats enclosing double quotes as delimiters that preserve spaces.
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            entries[node.attrib["name"]] = value
    return entries


def arguments(text):
    """Allow word order to change while preserving argument positions and types."""
    formats = re.finditer(r"%(?:(\d+)\$)?(lld|ld|d|s|@)", text.replace("%%", ""))
    return Counter((int(match[1] or index), match[2]) for index, match in enumerate(formats, 1))


class AppLocalizations(unittest.TestCase):
    locales = {node.attrib[ANDROID_NAME] for node in ET.parse(ANDROID / "xml/locales_config.xml").getroot()}

    def check_tables(self, english, translated):
        self.assertEqual(english.keys(), translated.keys())
        for key, source in english.items():
            with self.subTest(key=key):
                value = translated[key]
                self.assertTrue(value.strip())
                # Sentence separators belong between the localized messages.
                self.assertEqual(source, source.strip())
                self.assertEqual(value, value.strip())
                if len(source.split()) >= 7:
                    self.assertNotEqual(value, source)
                self.assertEqual(arguments(source), arguments(value))
                # Translating the disclosure must preserve the tappable destination.
                if "](" in source:
                    self.assertRegex(value, r"\[[^\]]+\]\(%@\)")

    def test_apple_app_and_widget(self):
        for target in ["Lively", "LivelyWidgets"]:
            folder = ROOT / target
            self.assertEqual(self.locales, {p.stem for p in folder.glob("*.lproj")})
            for table in (folder / "en.lproj").glob("*.strings"):
                english = apple_strings(table)
                for locale in self.locales - {"en"}:
                    with self.subTest(target=target, table=table.name, locale=locale):
                        self.check_tables(english, apple_strings(folder / f"{locale}.lproj" / table.name))

    def test_android(self):
        english = android_strings(ANDROID / "values/strings.xml")
        for locale in self.locales - {"en"}:
            qualifier = "b+" + locale.replace("-", "+") if "-" in locale else locale
            with self.subTest(locale=locale):
                self.check_tables(english, android_strings(ANDROID / f"values-{qualifier}/strings.xml"))


if __name__ == "__main__":
    unittest.main()
