"""CI smoke test: confirms the app imported, categorized and indexed the fixture PDFs,
and that the on-device search index answers rule-number and word queries.

Usage: python3 Tests/smoke_check.py "<app data container>/Library/Application Support/CodeShelf"
"""
import json
import pathlib
import sqlite3
import sys
import time

root = pathlib.Path(sys.argv[1])
failures = []


def check(condition, message):
    print(("PASS  " if condition else "FAIL  ") + message)
    if not condition:
        failures.append(message)


# Wait for import + background indexing to finish (library.json is saved as it goes).
books = []
deadline = time.time() + 180
while time.time() < deadline:
    try:
        books = json.loads((root / "library.json").read_text())["books"]
        log_done = (root / "import-log.txt").exists() and "protected.pdf: FAILED" in (root / "import-log.txt").read_text()
        if len(books) >= 4 and log_done and all(b["pageCount"] > 0 and b["indexedPages"] >= b["pageCount"] for b in books):
            break
    except (FileNotFoundError, json.JSONDecodeError, KeyError):
        pass
    time.sleep(3)

# The app runs its searches, re-reads the B139 sample with OCR, then searches again (search-probe.json).
probe = {}
deadline = time.time() + 240
while time.time() < deadline:
    try:
        probe = json.loads((root / "search-probe.json").read_text())
        if "1" in probe.get("rounds", {}):
            break
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    time.sleep(3)
try:
    books = json.loads((root / "library.json").read_text())["books"]
except (FileNotFoundError, json.JSONDecodeError, KeyError):
    pass

print("Library:")
for b in books:
    print(f"  {b.get('title')!r}: category={b.get('category')} shortName={b.get('shortName')!r} "
          f"jurisdiction={b.get('jurisdiction')!r} pages={b.get('pageCount')} indexed={b.get('indexedPages')}")

by_title = {b["title"]: b for b in books}
code = by_title.get("OESC 2024 sample")
bulletin = by_title.get("2-7-26")
oil_code = by_title.get("CSA B139-24 Installation code for oil-burning equipment")
manual = by_title.get("Acme AF100 Furnace Installation Instructions")
check(len(books) == 4, "all four fixture PDFs were imported")
check(code is not None and code["category"] == "electrical" and code["shortName"] == "OESC 2024",
      "code book filed as Electrical / 'OESC 2024'")
check(bulletin is not None and bulletin["category"] == "bulletin" and bulletin["shortName"] == "Bulletin 2-7-26"
      and bulletin["jurisdiction"] == "ESA", "bulletin filed as Bulletins & Updates / 'Bulletin 2-7-26' / ESA")
check(oil_code is not None and oil_code["category"] == "oil" and oil_code["shortName"] == "B139 2024",
      "B139 filed as Fuel Oil & Petroleum / 'B139 2024'")
check(manual is not None and manual["category"] == "manufacturer", "furnace manual filed as Manufacturer Instructions")
check(all(b["indexedPages"] >= b["pageCount"] for b in books), "indexing finished for every book")

db = sqlite3.connect(root / "search-index.sqlite")
total = db.execute("SELECT count(*) FROM pages").fetchone()[0]
check(total == 5, f"search index holds 5 pages (found {total})")

rule_hits = db.execute(
    """SELECT book_id, page, snippet(pages, 0, '[', ']', '…', 8) FROM pages
       WHERE pages MATCH '"26 700"' ORDER BY rank"""
).fetchall()
for row in rule_hits:
    print("  26-700 ->", row)
check(len(rule_hits) == 2, "'26-700' finds the code page and the bulletin")

smoke_hits = db.execute("SELECT page FROM pages WHERE pages MATCH 'smoke* alarm*'").fetchall()
check(smoke_hits == [(1,)], "'smoke alarm' finds page 2 of the code book")

article_hits = db.execute("""SELECT page FROM pages WHERE pages MATCH '"9 10 19 1"'""").fetchall()
check(article_hits == [(1,)], "'9.10.19.1' finds the smoke alarm article")

clause_hits = db.execute("""SELECT book_id FROM pages WHERE pages MATCH '"7 3 1"'""").fetchall()
check(oil_code is not None and clause_hits == [(oil_code["id"],)], "'7.3.1' finds the B139 clause")

manual_hits = db.execute("SELECT book_id FROM pages WHERE pages MATCH 'clearance* combustible*'").fetchall()
check(manual is not None and manual_hits == [(manual["id"],)], "'clearance combustible' finds the furnace manual")

# Ranking: code books come before manufacturer instructions even when a manual matches better.
# 'venting instructions' (any word): the furnace manual matches both words three times; B139 only 'venting'.
plain = db.execute(
    "SELECT book_id FROM pages WHERE pages MATCH 'venting* OR instructions*' ORDER BY rank"
).fetchall()
print("  bm25 order alone:", [next((b["title"] for b in books if b["id"] == row[0]), row[0]) for row in plain])
rounds = probe.get("rounds", {})
before_ocr = rounds.get("0", {})
after_ocr = rounds.get("1", {})
check(before_ocr.get("bookCount") == 4, "search probe ran with all four books")
answers = before_ocr.get("queries", {})


def ranked_for(query):
    return [(r["title"], r["tier"]) for r in answers.get(query, {}).get("results", [])]


ranked = ranked_for("venting instructions")
print("  Search tab order:", ranked)
titles = [t for t, _ in ranked]
check(len(ranked) >= 2 and ranked[0] == ("CSA B139-24 Installation code for oil-burning equipment", "Code Books")
      and "Acme AF100 Furnace Installation Instructions" in titles
      and titles.index("CSA B139-24 Installation code for oil-burning equipment") < titles.index("Acme AF100 Furnace Installation Instructions"),
      "Search lists the code book before the manufacturer manual")
check(dict(ranked).get("Acme AF100 Furnace Installation Instructions") == "Manufacturer Instructions",
      "manual results are grouped under Manufacturer Instructions")

# Clause numbers the PDF prints joined to other text, like the real code books do.
B139 = "CSA B139-24 Installation code for oil-burning equipment"
for query, how in [("7.3.3", "run into the next word (7.3.3Tank)"), ("7.4.2", "joined to the word before (Clause7.4.2)")]:
    results = answers.get(query, {}).get("results", [])
    print(f"  {query}:", json.dumps(results, ensure_ascii=False)[:400])
    check(any(r["title"] == B139 and r["tier"] == "Code Books" and r["firstPage"] == 0 for r in results),
          f"'{query}' is found in the code book when the PDF prints it {how}")
missing = answers.get("7.9.9", {})
print("  7.9.9:", json.dumps(missing)[:300])
check(missing.get("results") == [] and missing.get("missedCodeBooks") is True,
      "a clause that isn't in any book says so and explains each code book's status")

# 7.5.1 is printed on the page, but the PDF's text layer has it as "q.w.e" (heading font without digit mapping).
scrambled = answers.get("7.5.1", {})
print("  7.5.1 before OCR:", json.dumps(scrambled)[:300])
check(scrambled.get("results") == [] and scrambled.get("missedCodeBooks") is True,
      "a clause number the PDF's text scrambles can't be found before OCR (as on the user's B149.1)")
after = after_ocr.get("queries", {})
found = after.get("7.5.1", {}).get("results", [])
print("  7.5.1 after Re-read with OCR:", json.dumps(found, ensure_ascii=False)[:400])
check(any(r["title"] == B139 and r["tier"] == "Code Books" and r["firstPage"] == 0 and not r["note"] for r in found),
      "after Re-read with OCR, the scrambled clause number 7.5.1 is found exactly")
kept = after.get("7.3.1", {}).get("results", [])
check(any(r["title"] == B139 for r in kept), "after OCR the PDF's own text is still searchable too (7.3.1)")
b139 = next((b for b in json.loads((root / "library.json").read_text())["books"] if b["title"] == B139), {})
print(f"  B139 after OCR: forceOCR={b139.get('forceOCR')} ocrPages={b139.get('ocrPages')} clausePages={b139.get('clausePages')}")
check(b139.get("forceOCR") is True and b139.get("ocrPages", 0) >= 1, "Re-read with OCR is recorded on the book")
text_pages = {}
deadline = time.time() + 30
while time.time() < deadline:
    try:
        text_pages = {b["title"]: b.get("textPages", -1) for b in json.loads((root / "library.json").read_text())["books"]}
    except (FileNotFoundError, json.JSONDecodeError, KeyError):
        pass
    if text_pages and all(v >= 0 for v in text_pages.values()):
        break
    time.sleep(2)
print("  searchable pages:", text_pages)
check(bool(text_pages) and all(v >= 1 for v in text_pages.values()),
      "every indexed book records its searchable pages (none flagged as unreadable)")

# Calculators (same Swift code the Tools tab runs).
try:
    calc = json.loads((root / "calc-probe.json").read_text())
except (FileNotFoundError, json.JSONDecodeError):
    calc = {}
print("  calculators:", json.dumps(calc))
steel10 = calc.get("steelNG10ft", [])
steel100 = calc.get("steelNG100ft", [])
check(len(steel10) >= 4 and abs(steel10[0] - 172) <= 4 and abs(steel10[1] - 360) <= 8 and abs(steel10[2] - 678) <= 14,
      "natural gas, 1/2-3/4-1 in. steel at 10 ft, 0.5 in. w.c. drop ≈ 172 / 360 / 678 ft³/h (code table values)")
check(len(steel100) >= 3 and abs(steel100[0] - 50) <= 2 and abs(steel100[1] - 105) <= 3 and abs(steel100[2] - 198) <= 5,
      "natural gas, steel at 100 ft ≈ 50 / 105 / 198 ft³/h (code table values)")
lp = calc.get("steelLP10psi10ftMBH", [])
check(len(lp) >= 1 and 3300 <= lp[0] <= 3450, "propane 10 psi, 1 psi drop, 1/2 in. steel at 10 ft ≈ 3,370 MBH (equation 4-2)")
csst = calc.get("csst", {})
check(csst.get("tables") == 20, "all 20 Gastite CSST tables load")
check(csst.get("size") == '1"' and csst.get("column") == 40,
      "CSST: 100,000 BTU/h, 28 ft + 2 extra fittings -> 40 ft column -> 1 in.")
check(csst.get("propane10psiSize") == '1/2"', "CSST: propane 10 psi, 400 MBH at 100 ft -> 1/2 in.")

# The FileOpen-protected fixture must be refused with a clear explanation, not silently.
log_text = (root / "import-log.txt").read_text() if (root / "import-log.txt").exists() else ""
print("Import log (last lines):")
for line in log_text.splitlines()[-12:]:
    print("  " + line)
check("protected.pdf: FAILED" in log_text and "FileOpen" in log_text,
      "DRM-protected PDF refused with a FileOpen explanation")
check(not any("protected" in b["title"] for b in books), "DRM-protected PDF was not added to the library")

# Every PDF lives in Documents (Files › On My iPhone › CodeShelf), filed by category.
docs = root.parents[2] / "Documents"
expected_paths = {
    "OESC 2024 sample": "Code Books/OESC 2024 sample.pdf",
    "2-7-26": "Bulletins/2-7-26.pdf",
    "Acme AF100 Furnace Installation Instructions": "Manufacturer Instructions/Acme AF100 Furnace Installation Instructions.pdf",
    "CSA B139-24 Installation code for oil-burning equipment": "Code Books/CSA B139-24 Installation code for oil-burning equipment.pdf",
}
for title, path in expected_paths.items():
    book = by_title.get(title)
    print(f"  {title!r}: inDocuments={book and book.get('inDocuments')} fileName={book and book.get('fileName')!r}")
    check(book is not None and book.get("inDocuments") is True and book.get("fileName") == path and (docs / path).exists(),
          f"'{title}' is in Files at CodeShelf/{path}")
check(oil_code is not None and oil_code.get("inDocuments") is True,
      "PDF copied into the Files folder was picked up automatically")

# Deleting a PDF in Files removes it from the library.
(docs / expected_paths["CSA B139-24 Installation code for oil-burning equipment"]).unlink()
removed = False
deadline = time.time() + 45
while time.time() < deadline:
    try:
        titles = {b["title"] for b in json.loads((root / "library.json").read_text())["books"]}
    except (FileNotFoundError, json.JSONDecodeError, KeyError):
        titles = set()
    if "CSA B139-24 Installation code for oil-burning equipment" not in titles:
        removed = True
        break
    time.sleep(2)
check(removed, "deleting a PDF in Files removes it from the library")

if failures:
    print(f"\n{len(failures)} check(s) failed")
    sys.exit(1)
print("\nAll checks passed")
