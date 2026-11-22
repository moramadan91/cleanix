#!/usr/bin/env python3
"""Merge {key: [en, ar]} from a JSON file into the String Catalog (existing keys are overwritten)."""
import json
import sys

CATALOG = "Sources/Naddaf/Resources/Localizable.xcstrings"

def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}

new = json.load(open(sys.argv[1], encoding="utf-8"))
catalog = json.load(open(CATALOG, encoding="utf-8"))
for key, (en, ar) in new.items():
    catalog["strings"][key] = {"localizations": {"ar": unit(ar), "en": unit(en)}}
with open(CATALOG, "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
print(f"{len(new)} keys merged, {len(catalog['strings'])} total")
