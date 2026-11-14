"""Checks every link CodeShelf depends on, from a machine with open internet (GitHub Actions).

- Fuel Equipment Library entries with a 'url' must serve a PDF (the app downloads them automatically).
- Update sources (TSSA, CSA, e-Laws, ESA, Ontario pages) must load.

Usage: python3 Tests/check_links.py
"""
import json
import pathlib
import re
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Identify like the iOS app (URLSession / CFNetwork); some manufacturer sites block generic script agents.
HEADERS = {"User-Agent": "CodeShelf/1 CFNetwork/3826.400.120 Darwin/25.0.0", "Accept": "*/*"}


def fetch(url, limit=2048):
    request = urllib.request.Request(url, headers=HEADERS)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, response.headers.get("Content-Type", ""), response.read(limit)
    except urllib.error.HTTPError as error:
        return error.code, "", b""
    except Exception as error:  # DNS, TLS, timeouts
        return None, str(error), b""


problems = []

# Ad-hoc candidates: python3 Tests/check_links.py https://example.com/a.pdf ...
if len(sys.argv) > 1:
    print("== Candidate URLs")
    for url in sys.argv[1:]:
        status, kind, head = fetch(url)
        print(f"  HTTP {status}  {kind[:50]}  {'PDF' if b'%PDF' in head else 'not a PDF'}  {url}")
    sys.exit(0)

print("== Fuel Equipment Library (must be PDFs)")
catalog = json.loads((ROOT / "CodeShelf/Resources/FuelCatalog.json").read_text())["equipment"]
for doc in catalog:
    url = doc.get("url")
    if not url:
        print(f"  --   {doc['id']}: search only ({doc['search']})")
        continue
    status, kind, head = fetch(url)
    is_pdf = b"%PDF" in head
    ok = status == 200 and is_pdf
    print(f"  {'OK ' if ok else 'BAD'}  {doc['id']}: HTTP {status} {kind[:40]} {'PDF' if is_pdf else 'not a PDF'}  {url}")
    if not ok:
        problems.append(f"{doc['id']}: {url} -> HTTP {status}, {'PDF' if is_pdf else 'not a PDF'}")

print("\n== Update sources and e-Laws pages (must load)")
sources = set()
for path in ["CodeShelf/Services/UpdatesStore.swift", "CodeShelf/Services/Ontario.swift"]:
    for url in re.findall(r'"(https://[^"\\]+)"', (ROOT / path).read_text()):
        if "google." not in url:
            sources.add(url)
for url in sorted(sources):
    status, kind, _ = fetch(url, limit=512)
    ok = status == 200
    print(f"  {'OK ' if ok else 'BAD'}  HTTP {status}  {url}")
    if not ok:
        problems.append(f"{url} -> HTTP {status} {kind[:80]}")

if problems:
    print(f"\n{len(problems)} link problem(s):")
    for problem in problems:
        print("  - " + problem)
    sys.exit(1)
print("\nAll links OK")
