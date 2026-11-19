import csv
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import keywords


class KeywordUploadTests(unittest.TestCase):
    def setUp(self):
        self.campaigns = json.loads(keywords.LAUNCH.read_text())
        self.rows = []
        for campaign_id, (name, groups) in enumerate(self.campaigns.items(), start=900):
            for group in groups:
                self.rows.append({
                    "App ID": keywords.APP_ID, "Countries Or Regions": "US",
                    "Campaign Name": name, "Ad Group Name": group,
                    "Campaign ID": str(campaign_id), "Ad Group ID": str(1000 + len(self.rows)),
                    "Default Max Bid": f"{1 + len(self.rows)}.45",
                })

    def export(self, rows):
        file = io.StringIO()
        writer = csv.DictWriter(file, fieldnames=self.rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
        file.seek(0)
        return file

    def test_export_to_apples_upload_files(self):
        # One row per ad in an Apple export. Two ads can belong to the same group.
        export = self.export([*reversed(self.rows), self.rows[0], {**self.rows[0], "Campaign Name": "Unrelated"}])
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            settings = base / "settings.csv"
            settings.write_text(export.getvalue(), encoding="utf-8-sig")
            output = base / "uploads"
            command = [sys.executable, keywords.__file__, settings, output]
            subprocess.run(command, check=True)
            targets = []
            for file in output.glob("* - *.csv"):
                with file.open(newline="") as f:
                    group_rows = list(csv.DictReader(f))
                self.assertEqual({r["Ad Group ID"] for r in group_rows}, {file.stem.split(" - ")[-1]})
                targets.extend(group_rows)
            with (output / "discovery-negatives.csv").open(newline="") as f:
                negatives = list(csv.DictReader(f))
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
        expected = []
        for row in self.rows:
            group = self.campaigns[row["Campaign Name"]][row["Ad Group Name"]]
            for match in ("exact", "broad"):
                for term in group.get(match, []):
                    expected.append((term, match.upper(), row["Default Max Bid"], row["Campaign ID"], row["Ad Group ID"]))
        self.assertCountEqual([(r["Keyword"], r["Match Type"], r["Bid"], r["Campaign ID"], r["Ad Group ID"])
                               for r in targets], expected)
        exact = {r["Keyword"] for r in targets if r["Match Type"] == "EXACT"}
        discovery = next(r["Campaign ID"] for r in self.rows if r["Campaign Name"] == keywords.DISCOVERY)
        self.assertCountEqual([(r["Negative Keyword"], r["Match Type"], r["Campaign ID"], r["Ad Group ID"])
                               for r in negatives], [(term, "EXACT", discovery, "") for term in exact])

    def test_incomplete_or_conflicting_assignments_do_not_generate_uploads(self):
        original = self.rows[0]
        for rows in (
            self.rows[1:],
            [{**original, "App ID": "123"}, *self.rows[1:]],
            [{**original, "Countries Or Regions": "JP"}, *self.rows[1:]],
            [{**original, "Ad Group ID": ""}, *self.rows[1:]],
            [{**original, "Default Max Bid": "NaN"}, *self.rows[1:]],
            [{**original, "Default Max Bid": ""}, *self.rows[1:]],
            [*self.rows, {**original, "Campaign ID": "321"}],
            [{**original, "Ad Group ID": self.rows[-1]["Ad Group ID"]}, *self.rows[1:]],
        ):
            with self.subTest(first=rows[0]), self.assertRaises(ValueError):
                keywords.create_uploads(self.export(rows), self.campaigns)


if __name__ == "__main__":
    unittest.main()
