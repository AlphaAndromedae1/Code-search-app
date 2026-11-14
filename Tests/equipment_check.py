"""CI report: which Fuel Equipment Library manuals the app downloaded on a real iOS simulator.

Usage: python3 Tests/equipment_check.py "<data container>/Library/Application Support/CodeShelf" CodeShelf/Resources/FuelCatalog.json
Exits 1 (reported as a warning in CI) if nothing could be downloaded.
"""
import json
import pathlib
import sys
import time

root = pathlib.Path(sys.argv[1])
catalog = json.loads(pathlib.Path(sys.argv[2]).read_text())["equipment"]
wanted = {doc["url"].lower().rstrip("/"): doc for doc in catalog if doc.get("url")}


def downloaded():
    try:
        books = json.loads((root / "library.json").read_text())["books"]
    except (FileNotFoundError, json.JSONDecodeError, KeyError):
        return {}
    return {b.get("sourceURL", "").lower().rstrip("/"): b for b in books if b.get("category") == "manufacturer"}


deadline = time.time() + 240
found = {}
while time.time() < deadline:
    found = downloaded()
    if all(url in found for url in wanted):
        break
    time.sleep(5)

print(f"Downloaded {sum(url in found for url in wanted)} of {len(wanted)} manufacturer documents:")
for url, doc in wanted.items():
    book = found.get(url)
    mark = "OK  " if book else "MISS"
    detail = f"{book['pageCount']} pages" if book else "not downloaded (check the link-check job)"
    print(f"  {mark} {doc['manufacturer']}: {doc['title']} — {detail}")
sys.exit(0 if any(url in found for url in wanted) else 1)
