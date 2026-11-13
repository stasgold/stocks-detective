#!/usr/bin/env python3
"""Checks App Store limits and writes fastlane/metadata/<locale>/*.txt (the `fastlane deliver` layout).

Source: tools/appstore/metadata-*.json, one object per App Store Connect locale.
Run from the repo root:  python3 tools/appstore/build_metadata.py
"""
import glob, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "fastlane", "metadata")

NAME = "Stocks Detective"
LIMITS = {"name": 30, "subtitle": 30, "promotional_text": 170, "keywords": 100,
          "description": 4000, "release_notes": 4000}
# Same text for a second storefront locale of the same language.
ALIASES = {"es-MX": "es-ES", "fr-CA": "fr-FR", "en-GB": "en-US", "en-AU": "en-US", "en-CA": "en-US", "pt-PT": None}
REPO = "https://github.com/stasgold/stocks-detective"
# blob/HEAD follows the default branch, so the link survives a branch rename.
URLS = {"privacy_url": f"{REPO}/blob/HEAD/PRIVACY.md", "support_url": f"{REPO}/issues", "marketing_url": ""}
COPYRIGHT = "2026 Stas Goldberg"


def main():
    data = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "tools", "appstore", "metadata-*.json"))):
        data.update(json.load(open(path)))
    for alias, src in ALIASES.items():
        if src:
            data[alias] = data[src]

    errors = []
    for loc, fields in sorted(data.items()):
        fields = dict(fields, name=NAME)
        for key, limit in LIMITS.items():
            value = fields.get(key, "")
            if not value:
                errors.append(f"{loc}: {key} is empty")
            elif len(value) > limit:
                errors.append(f"{loc}: {key} is {len(value)} chars (limit {limit}): {value[:40]}…")
        kw = fields.get("keywords", "")
        if ", " in kw:
            errors.append(f"{loc}: keywords should be comma-separated without spaces after commas")
        if NAME.lower() in kw.lower():
            errors.append(f"{loc}: don't repeat the app name in keywords")
    if errors:
        print("\n".join(errors))
        sys.exit(1)

    for loc, fields in data.items():
        d = os.path.join(OUT, loc)
        os.makedirs(d, exist_ok=True)
        for key in LIMITS:
            value = NAME if key == "name" else fields[key]
            with open(os.path.join(d, f"{key}.txt"), "w") as f:
                f.write(value + "\n")
        for key, value in URLS.items():
            with open(os.path.join(d, f"{key}.txt"), "w") as f:
                f.write(value + "\n" if value else "")
    with open(os.path.join(OUT, "copyright.txt"), "w") as f:
        f.write(COPYRIGHT + "\n")
    print(f"OK: {len(data)} App Store locales written to fastlane/metadata")


if __name__ == "__main__":
    main()
