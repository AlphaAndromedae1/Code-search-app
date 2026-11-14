# CodeShelf

A private iPhone/iPad app for Ontario's fuel industry: CSA B149.1 / B149.2 natural gas and propane codes, CSA B139 oil-burning equipment, TSSA code adoption documents and advisories, and the manufacturer installation instructions for the equipment you install — CSST, ULC S636 venting, propane regulators, relief valves, tanks and cylinders. It also handles the OBC, Fire Code, OESC and municipal by-laws. Search everything at once, compare sections side by side, and get new TSSA / CSA / e-Laws updates automatically.

Your library stays on your device. The app goes online only to check the TSSA, CSA and e-Laws pages you follow, to download manufacturer instructions from the manufacturers' own sites, and when you browse in the app.

**Adding PDFs with the Files app:** open Files › On My iPhone › CodeShelf and copy PDFs into **Code Books** (or **Manufacturer Instructions**, **Bulletins**, **By-laws**, or any folder you create there). CodeShelf adds them automatically — no need to use the + button. Every PDF in the library lives in this folder: moving or renaming a file there keeps its bookmarks and links, replacing it re-indexes it, and deleting it removes it from CodeShelf. Settings and the Library have an **Open CodeShelf Folder in Files** button.

**Importing a PDF:** with the + button, after you pick a file, the result appears at the top of the Library — added, already there, or why it couldn't be imported. PDFs locked with publisher DRM (such as FileOpen, used on some purchased standards) can only be opened in the publisher's approved reader, and CodeShelf says so instead of failing silently. Settings → Import Log shows each step if you need to troubleshoot.

## Features

**Library**
- Import PDFs from the Files app, iCloud Drive, email attachments, or the share sheet (“Open in CodeShelf”).
- Books are auto-sorted by category from the file name (e.g. `2024_OBC.pdf` becomes *Building · OBC 2024*, `CSA B149.1-25.pdf` becomes *Gas & Propane · B149.1 2025*, `ASHRAE 90.1-2019.pdf` becomes *Standards · ASHRAE 90.1 2019*, `2-7-26.pdf` becomes *Bulletins & Updates · Bulletin 2-7-26 (ESA)*). Title, short name, category, jurisdiction, edition and notes are all editable.
- Categories: Building, Residential, Fire, Electrical, Plumbing, Mechanical, **Gas & Propane** (CSA B149.1 Natural Gas and Propane Installation Code, B149.2 Propane Storage and Handling Code, TSSA adoption documents), **Fuel Oil & Petroleum** (CSA B139 oil-burning equipment, Fuel Oil and Liquid Fuels regulations, TSSA Liquid Fuels Handling Code for gasoline and diesel), Energy, Accessibility, Municipal By-laws, **Standards** (NFPA, ASHRAE, ASTM, ULC and other CSA standards the codes reference), **Manufacturer Instructions**, and Bulletins & Updates.
- Every page is indexed for full-text search in the background. Scanned PDFs (no selectable text) are read with Apple's on-device text recognition (OCR).

**Search everything**
- One search box across every book, with results grouped by book and best matches first. Snippets highlight what matched.
- Rule, article and clause numbers match exactly: `26-700` finds Rule 26-700, `9.10.14.5` finds that article (not 9.10.14.50), and `6.18.2` finds that B149 clause.
- `smoke alarm` finds pages with both words, including word starts like *alarms*.
- `"means of egress"` matches an exact phrase.
- `egress OR exit` matches either word. You can also switch to "match any word" in the filter menu.
- Filter by category chips (Building, Fire, Municipal…) or pick specific books.
- Tapping a result opens the page with your search terms highlighted.

**Reader**
- Table of contents from the PDF's bookmarks, with a filter box.
- Go to a printed page label (e.g. `3-12`) or a PDF page number.
- Search within this book.
- **Find in Other Books:** select text on the page (like a section number) and tap the books button. CodeShelf searches every other code book for it. Tap a result to open it, and use Back to return.
- Bookmarks with notes.

**Compare**
- Two books side by side (stacked on iPhone portrait, side by side in landscape and on iPad).
- One search box searches both books, and each side jumps to its best match. Use ▲▼ to step through matches.
- Swap sides, or **Link these pages** to save a cross-reference.

**Ontario laws & your by-laws** (Library → + → Ontario Laws & By-laws)
- **e-Laws:** one tap opens the official text of the Building Code regulation (O. Reg. 163/24) and Building Code Act, the Fire Code (O. Reg. 213/07, published in full) and Fire Protection and Prevention Act, the Electrical Safety Code regulation (O. Reg. 164/99), TSSA's Gaseous Fuels (O. Reg. 212/01), Propane Storage and Handling (O. Reg. 211/01), Fuel Oil (O. Reg. 213/01) and Liquid Fuels (O. Reg. 217/01) regulations. Save any of them as a searchable book.
- **By-laws:** enter your municipality once. Ontario municipalities publish their own by-laws, so CodeShelf runs targeted searches (by-laws; building, zoning and property standards; building division; fence, pool, sign and tree by-laws; region/county by-laws) and opens the results in a built-in browser.
- Star your municipality's by-law page (☆) so it opens straight there next time.
- Open the by-law you need and tap **Save**. CodeShelf loads long pages completely, keeps the by-law text (dropping menus and sidebars), and saves it as a searchable PDF with the web address and date. By-laws posted as PDFs are saved as-is.
- Later, open a saved page from **Saved From the Web** (or the reader's ••• → View Online) and save again to replace your copy. Bookmarks and links are kept.
- Saving is one page at a time, on request, like "Print → Save as PDF". The app doesn't bulk-download whole sites.

**Fuel Equipment Library** (Library → + → Fuel Equipment Library)
- Manufacturer installation instructions for **CSST** (Gastite/FlashShield, WARDFlex, TracPipe CounterStrike), **ULC S636 venting** (DuraVent PolyPro, IPEX System 636, Centrotherm InnoFlue), **propane regulators** (RegO, Fisher R600/R622/R632, R122H/R222H/R232, 912/Y200, Marshall Excelsior), **relief valves** (Fisher H100 and H series, RegO) and **propane tanks & cylinders** (Manchester Tank, RegO, Worthington).
- Documents with a direct manufacturer link are downloaded automatically and re-downloaded when the manufacturer posts a newer version (bookmarks and links are kept). The others open a search for the manufacturer's copy; once you save it, it's kept with your manuals.
- The list lives in `CodeShelf/Resources/FuelCatalog.json`; the **Check links** workflow verifies every link weekly.

**Manufacturer instructions** (Library → + → Manufacturer Instructions)
- Keep the installation manual for each model you install: furnaces, boilers, water heaters, oil burners and tanks, generators, panels and more. Codes like CSA B149.1 and B139 refer to the manufacturer's certified installation instructions.
- Enter the manufacturer, model number(s) and equipment type, then **Import PDF**, **Scan Paper Instructions** with the camera (multi-page, auto-cropped, text-recognized so it's searchable), or **Find Online** and save the manufacturer's PDF.
- Manuals are searched along with your codes. Filter the Library by manufacturer or model number, and link a manual page to the code clause it relates to with a cross-reference.

**Updates & bulletins** (Updates tab)
- Suggests Ontario sources to follow, matched to the codes in your library:
  - **Electrical:** ESA (OESC page, bulletins, code & technical), e-Laws O. Reg. 164/99, CSA's CE Code page, and a search for new CE Code Memorandums of Revision.
  - **Building:** the Ministry's Building Code updates page, e-Laws O. Reg. 163/24, the OBOA CodeNews archive, and a search for Building Code Commission / BMEC rulings.
  - **Fire:** e-Laws O. Reg. 213/07 and a search for Fire Marshal technical guidelines and communiqués.
  - **Gas & propane:** TSSA fuels news, TSSA code adoption documents and advisories, e-Laws O. Reg. 212/01 and 211/01, and CSA B149 updates.
  - **Fuel oil & petroleum:** TSSA's fuel oil page, e-Laws O. Reg. 213/01 and 217/01, and searches for CSA B139 updates and Liquid Fuels Handling Code amendments.
  - **Proposed changes:** a search for TSSA code adoption document proposals posted for comment on the Environmental Registry of Ontario.
  - **Your municipality:** a search for by-law amendments and building division notices.
  - You can add any page with +.
- **e-Laws amendments:** following a regulation's e-Laws page flags each new amending regulation (e.g. *O. Reg. 325/26 — amends Fire Code*) the next time you check.
- **Automatic:** TSSA's advisories and code adoption documents, TSSA fuels news and fuel oil pages, CSA B149 searches and the fuel regulations on e-Laws are followed from the start. The app checks them when it opens (if 6+ hours have passed) and in the background a few times a day as iOS allows, and sends a notification when something new appears.
- **Check for New Bulletins** checks right away. Each followed page is compared with last time, and new items are listed most relevant first (tagged with the codes from your library and any rule numbers they mention). The first check of a page records what's already there.
- Open an item and tap **Save** to keep it. Saved or imported bulletins (e.g. the ESA bulletins included with the OESC, named like `2-7-26.pdf`) go under *Bulletins & Updates*.
- **Bulletins linked to rules:** while reading a code, a 📣 button appears when a saved bulletin mentions a rule or section printed on that page (e.g. Rule 26-700, Article 9.10.14.5 or B149 Clause 6.18.2). Tap it to jump to the bulletin with the rule highlighted.
- Turn automatic checks, notifications and manufacturer downloads on or off in Settings → Automatic Updates.

**Cross-references**
- Save named links between pages in different books, e.g. *OESC Rule 26-700 ↔ CE Code Rule 26-700 (Ontario amendment)* or *OBC 9.8.8 ↔ City fence and pool enclosure by-law*, with notes.
- When you're on a linked page, a “🔗 linked” button appears in the reader. Tap it to jump to the related pages.
- Manage everything in the **Saved** tab, and open any two linked pages side by side.

## Planned

Ideas queued for later versions:

1. **Tap a reference to jump to it.** Record where each rule/article starts during indexing, so you can tap "see Rule 26-700" or "Sentence 9.10.14.5.(2)", type `26-700` in Go to Page, and see a "Same rule in other books" button (e.g. a CE Code rule with its OESC amendment and related ESA bulletins).
2. **Search synonyms.** GFCI ↔ ground fault, receptacle ↔ outlet, smoke alarm ↔ smoke detector, barrier-free ↔ accessible.
3. **Track editions.** Mark older books as superseded (e.g. OESC 2021 once 2024 applies), so current editions come first in search while older ones stay available.
4. **Highlights and notes on pages.** Highlight passages and pin notes directly on code pages.
5. **Weekly reminder to check updates.** A local notification nudging you to tap "Check for New Bulletins". Nothing would be fetched in the background.
6. **Site notes with code citations.** Take a photo, attach the rule it relates to, and export a simple PDF list for deficiency lists and inspection follow-ups.

## Getting the .ipa (no Mac needed)

You can't build iOS apps on Windows or Linux directly, but GitHub provides free Mac build machines. The included workflow builds the app there.

1. Create a free account at github.com, then create a **new private repository** (e.g. `codeshelf`).
2. Upload this whole folder to it. The simplest way is the command line (with [git](https://git-scm.com) installed), run from inside the `CodeShelf` folder:
   ```bash
   git init -b main
   ```
   ```bash
   git add -A && git commit -m "CodeShelf"
   ```
   ```bash
   git remote add origin https://github.com/YOUR-USERNAME/codeshelf.git
   ```
   ```bash
   git push -u origin main
   ```
   If you'd rather use the website's “Add file → Upload files”, note that it can skip the hidden `.github` folder. If it does, create the file `.github/workflows/build-ipa.yml` by hand (“Add file → Create new file”) and paste in its contents.
3. Open the **Actions** tab of the repository. The **Build IPA** workflow runs on every push (or press **Run workflow**). It takes about 5–10 minutes.
4. When it shows a green check, open the run and download the **CodeShelf-ipa** artifact. Unzip it to get `CodeShelf.ipa`.

The workflow also runs a **simulator smoke test**. It launches the app on an iPhone simulator, imports four sample PDFs from `Tests/Fixtures` (an OESC-style page, an ESA bulletin, a B139 page and a furnace manual), and checks that they are filed and indexed correctly and that searches for `26-700`, `9.10.19.1`, `7.3.1`, `smoke alarm` and `clearance combustible` work. It then relaunches the app to confirm the saved library reloads, and uploads a screenshot as the **simulator-screenshot** artifact.

If the build fails, download the **xcodebuild-log** artifact (or copy the red error lines from the log) and fix the reported error. Pasting it back to Claude works.

## Installing on your iPhone/iPad

The workflow produces an **unsigned** IPA. Apple only allows installing apps signed with an Apple ID, so a sideloading tool signs it for you:

- **Sideloadly** (Windows/Mac, sideloadly.io): plug in your iPhone, drag in `CodeShelf.ipa`, enter your Apple ID, and click Start.
- **AltStore** (altstore.io): installs and automatically re-signs apps over Wi-Fi.

Then on the device:
- **Settings → General → VPN & Device Management**: trust your Apple ID's developer profile.
- On iOS 16 and later, turn on **Settings → Privacy & Security → Developer Mode** and restart.

**Free Apple ID:** apps must be re-signed every 7 days (AltStore does this automatically; with Sideloadly just reinstall). Re-installing over the existing app keeps your library, as long as you use the same Apple ID and don't delete the app first.

**Paid Apple Developer account ($99/yr):** signatures last a year. You can also open the project in Xcode and run it directly.

## Building on a Mac instead

```bash
brew install xcodegen
```
```bash
xcodegen generate
```
```bash
open CodeShelf.xcodeproj
```

In Xcode, pick your team under *Signing & Capabilities*, connect your device and press Run. Requires Xcode 16 or newer; the app targets iOS 17+.

## About your PDFs

- **DRM-protected code books won't open.** Some publishers sell PDFs locked with a viewer plug-in (e.g. FileOpen) that only works in Adobe Reader. No other app can read them. Unprotected PDFs, including those with only “owner” restrictions on printing or copying, work fine.
- **Password-protected PDFs** need the password removed before importing.
- **Municipal by-laws:** use Library → + → Ontario Laws & By-laws (above), or import a by-law PDF you downloaded yourself (it's filed under *Municipal By-laws* automatically when the name says by-law, city of, township, etc.).
- **Saved web pages are unofficial copies.** Always confirm against the official, current code before relying on it; each saved page records its source and retrieval date.
- **ESA bulletins:** the complete OESC bulletin set comes with the OESC purchase from ESA. Import those PDFs so they're searchable and linked to the rules they cover.
- Imported files are copied into the app's private storage. The original stays where it was.

## Project layout

```
project.yml                 XcodeGen spec (generates CodeShelf.xcodeproj)
Config/Info.plist           App settings (PDF "Open in" support, orientations)
.github/workflows/          GitHub Actions workflow that builds the .ipa
CodeShelf/
  App/                      App entry point, cross-tab router
  Models/                   Book, Bookmark, CrossReference
  Services/
    SearchIndex.swift       SQLite FTS5 full-text index
    QueryBuilder.swift      Turns typed queries into FTS queries; snippet formatting
    Indexer.swift           Per-page text extraction + Vision OCR fallback
    LibraryStore.swift      Library state, persistence, indexing queue
    LibraryFiles.swift      Import + category guessing (incl. Canadian codes, bulletins)
    WebPageCapture.swift    Saves a browsed page as a searchable PDF
    UpdatesStore.swift      Followed bulletin sources, new-item detection, rule-number matching
    Ontario.swift           e-Laws regulations and municipal by-law search links
  Views/                    Library, Search, Reader, Compare, Saved, Updates, Web browser
```
