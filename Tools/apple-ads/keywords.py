"""Make Apple Ads keyword uploads from the IDs Apple assigned to the US test."""

import argparse
import csv
import json
import tempfile
from decimal import Decimal, InvalidOperation
from pathlib import Path


LAUNCH = Path(__file__).resolve().parents[2] / "AppStore/apple-ads/us-search.json"
DISCOVERY = "Lively US - Discovery"
APP_ID = "6835590432"


def assigned_groups(settings, campaigns):
    required = {(name, group) for name, groups in campaigns.items() for group in groups}
    found = {}
    campaign_ids = {}
    group_owners = {}
    for row in csv.DictReader(settings):
        key = row["Campaign Name"], row["Ad Group Name"]
        if key not in required:
            continue
        if row["App ID"] != APP_ID or row["Countries Or Regions"] != "US":
            raise ValueError(f"Unexpected app or storefront for {key}")
        campaign_id, group_id = row["Campaign ID"], row["Ad Group ID"]
        if not all(value and value.isascii() and value.isdigit() and int(value) > 0
                   for value in (campaign_id, group_id)):
            raise ValueError(f"Export the assigned numeric IDs for {key}")
        try:
            bid = Decimal(row["Default Max Bid"] or "")
        except InvalidOperation:
            raise ValueError(f"Expected a numeric Default Max Bid for {key}") from None
        if not bid.is_finite() or bid <= 0:
            raise ValueError(f"Expected a positive Default Max Bid for {key}")
        settings_row = campaign_id, group_id, bid
        if (campaign_ids.setdefault(key[0], campaign_id) != campaign_id
                or group_owners.setdefault(group_id, key) != key
                or (key in found and found[key] != settings_row)):
            raise ValueError(f"Conflicting Apple settings for {key}")
        found[key] = settings_row
    if required - found.keys():
        raise ValueError(f"Missing ad groups: {sorted(required - found.keys())}")
    if len(set(campaign_ids.values())) != len(campaign_ids):
        raise ValueError("Multiple campaigns have the same Apple ID")
    return found


def create_uploads(settings, campaigns):
    assigned = assigned_groups(settings, campaigns)
    target_header = ["Action", "Keyword ID", "Keyword", "Match Type", "Status", "Bid", "Campaign ID", "Ad Group ID"]
    uploads = {}
    negatives = [["Action", "Keyword ID", "Negative Keyword", "Match Type", "Campaign ID", "Ad Group ID"]]
    discovery_id = assigned[DISCOVERY, "Search Match"][0]
    exact_terms = set()
    for name, groups in campaigns.items():
        for group, spec in groups.items():
            campaign_id, group_id, bid = assigned[name, group]
            targets = []
            for match in ("exact", "broad"):
                for term in spec.get(match, []):
                    targets.append(["CREATE", "", term, match.upper(), "ACTIVE", format(bid, "f"), campaign_id, group_id])
                    if match == "exact" and name != DISCOVERY:
                        exact_terms.add(term)
            if targets:
                uploads[f"{group} - {group_id}.csv"] = [target_header, *targets]
    for term in sorted(exact_terms):
        negatives.append(["CREATE", "", term, "EXACT", discovery_id, ""])
    uploads["discovery-negatives.csv"] = negatives
    return uploads


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("settings", type=Path, help="Apple's downloaded Settings worksheet exported as UTF-8 CSV")
    parser.add_argument("output", type=Path, help="new directory for the keyword uploads")
    args = parser.parse_args()
    try:
        with args.settings.open(encoding="utf-8-sig", newline="") as settings:
            uploads = create_uploads(settings, json.loads(LAUNCH.read_text()))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        if args.output.exists():
            raise FileExistsError(f"Choose a new output directory: {args.output}")
        with tempfile.TemporaryDirectory(dir=args.output.parent) as tmp:
            staged = Path(tmp) / "uploads"
            staged.mkdir()
            for filename, rows in uploads.items():
                with (staged / filename).open("w", encoding="utf-8", newline="") as out:
                    csv.writer(out).writerows(rows)
            staged.rename(args.output)
    except (KeyError, OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
