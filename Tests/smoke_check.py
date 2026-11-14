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
