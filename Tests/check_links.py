"""Checks every link CodeShelf depends on, from a machine with open internet (GitHub Actions).

- Fuel Equipment Library entries with a 'url' must serve a PDF (the app downloads them automatically).
- Update sources (TSSA, CSA, e-Laws, ESA, Ontario pages) must load.

Usage: python3 Tests/check_links.py
"""
import json
import socket
import ssl
import pathlib
import re
import sys
import time
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
for path in ["CodeShelf/Services/UpdatesStore.swift", "CodeShelf/Services/Ontario.swift", "CodeShelf/Services/FuelPrices.swift"]:
    for url in re.findall(r'"(https://[^"\\]+)"', (ROOT / path).read_text()):
        # Search engines aren't checked; the StatCan web service only answers POSTs (checked below).
        # Statistics Canada is checked separately below (it sometimes shows apps a browser security check).
        if "google." not in url and "statcan.gc.ca" not in url:
            sources.add(url)
for url in sorted(sources):
    status, kind, _ = fetch(url, limit=512)
    ok = status == 200
    print(f"  {'OK ' if ok else 'BAD'}  HTTP {status}  {url}")
    if not ok:
        problems.append(f"{url} -> HTTP {status} {kind[:80]}")

print("\n== Fuel price data (Tools › Fuel Prices)")
csv_url = "https://ontario.ca/v1/files/fuel-prices/fueltypesall.csv"
status, kind, body = fetch(csv_url, limit=4096)
header = body.decode("utf-8", "replace").splitlines()[0] if body else ""
ok = status == 200 and header.startswith("Date,") and ",Fuel Type," in header and "Ontario Average" in header
print(f"  {'OK ' if ok else 'BAD'}  HTTP {status}  header: {header[:120]}")
if not ok:
    problems.append(f"{csv_url} -> HTTP {status}, unexpected CSV header: {header[:120]}")
for city, location in [("Kingston", 72), ("Thunder Bay", 23), ("Windsor", 19)]:
    feed = f"https://www2.nrcan.gc.ca/eneene/sources/pripri/webfeed_e.cfm?priceYear={time.strftime('%Y')}&productID=7&locationID={location}"
    status, kind, body = fetch(feed, limit=8192)
    text = body.decode("utf-8", "replace")
    price = re.search(r"<description>\$(\d+\.\d+)</description>\s*<pubDate>([^<]+)</pubDate>", text)
    ok = status == 200 and "<item>" in text
    print(f"  {'OK ' if ok else 'BAD'}  furnace oil {city}: HTTP {status} latest {price.groups() if price else 'none listed'}")
    if not ok:
        problems.append(f"NRCan furnace oil feed for {city} -> HTTP {status}")

oeb = "https://www.oeb.ca/consumer-information-and-protection/natural-gas-rates"
status, kind, body = fetch(oeb, limit=400000)
page = body.decode("utf-8", "replace")
heading = re.search(r"Current gas rates for supply \(([^)]+)\)", page)
rates = re.findall(r"<td>([^<]+)</td>\s*<td>.*?([0-9]+\.[0-9]+)\s*(?:</span>)?\s*¢/m", page)
ok = status == 200 and heading is not None and len(rates) >= 4
print(f"  {'OK ' if ok else 'BAD'}  natural gas, OEB ({heading.group(1) if heading else 'no date'}): {[(n.strip(), v) for n, v in rates][:6]}")
if not ok:
    problems.append("Ontario Energy Board natural gas rates table not found")

statcan = "https://www150.statcan.gc.ca/t1/wds/rest/getDataFromCubePidCoordAndLatestNPeriods"
body = json.dumps([{"productId": 18100001, "coordinate": f"{geo}.7.0.0.0.0.0.0.0.0", "latestN": 1} for geo in (9, 8, 10)]).encode()
request = urllib.request.Request(statcan, data=body, headers={**HEADERS, "Content-Type": "application/json", "Accept": "application/json"})
try:
    with urllib.request.urlopen(request, timeout=60) as response:
        reply = json.loads(response.read())
    values = [(r["object"]["vectorDataPoint"][-1]["refPer"], r["object"]["vectorDataPoint"][-1]["value"]) for r in reply if r.get("status") == "SUCCESS"]
    ok = len(values) == 3
    print(f"  {'OK ' if ok else 'BAD'}  heating fuel, Statistics Canada (Toronto, Ottawa, Thunder Bay): {values}")
except Exception as error:  # HTTP errors, JSON changes
    ok = False
    print(f"  BAD  heating fuel, Statistics Canada: {error}")
if not ok:
    # A backup source; Statistics Canada sometimes puts a browser security check in front of its API.
    print("  WARN Statistics Canada isn't answering apps right now (furnace oil falls back to NRCan only)")

print("\n== TLS offered by the furnace oil servers (iOS needs TLS 1.2+; forward secrecy unless excepted)")
for host in ("www2.nrcan.gc.ca", "www2.nrcan-rncan.gc.ca"):
    for label, maximum in (("default", None), ("TLS 1.2 only", ssl.TLSVersion.TLSv1_2)):
        context = ssl.create_default_context()
        if maximum:
            context.maximum_version = maximum
        try:
            with socket.create_connection((host, 443), timeout=20) as raw:
                with context.wrap_socket(raw, server_hostname=host) as tls:
                    name, version, bits = tls.cipher()
                    issuer = dict(x[0] for x in tls.getpeercert()["issuer"]).get("organizationName", "?")
                    fs = "forward secrecy" if ("ECDHE" in name or "DHE" in name or version == "TLSv1.3") else "NO forward secrecy"
                    print(f"  {host} [{label}]: {tls.version()} {name} ({fs}), certificate from {issuer}")
        except Exception as error:
            print(f"  {host} [{label}]: FAILED {error}")
    # iOS 27 refuses TLS 1.2 without the extended master secret extension inside apps (Apple support 126655).
    try:
        import subprocess
        out = subprocess.run(["openssl", "s_client", "-connect", f"{host}:443", "-servername", host, "-tls1_2"],
                             input="", capture_output=True, text=True, timeout=30).stdout
        ems = next((line.strip() for line in out.splitlines() if "Extended master secret" in line), "not reported")
        print(f"  {host}: {ems}")
        # The certificate chain (iOS no longer trusts newer Entrust certificates; the app pins NRCan's issuer).
        chain = subprocess.run(["openssl", "s_client", "-connect", f"{host}:443", "-servername", host, "-showcerts"],
                               input="", capture_output=True, text=True, timeout=30).stdout
        pems = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", chain, re.S)
        for number, pem in enumerate(pems):
            info = subprocess.run(["openssl", "x509", "-noout", "-subject", "-issuer", "-dates", "-fingerprint", "-sha256"],
                                  input=pem, capture_output=True, text=True).stdout.strip().replace("\n", " | ")
            print(f"  {host} chain[{number}]: {info}")
            if number > 0 and host == "www2.nrcan.gc.ca":
                print(pem)
    except Exception as error:
        print(f"  {host}: openssl check failed: {error}")

if problems:
    print(f"\n{len(problems)} link problem(s):")
    for problem in problems:
        print("  - " + problem)
    sys.exit(1)
print("\nAll links OK")
