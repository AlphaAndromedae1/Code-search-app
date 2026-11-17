"""CI report: the fuel prices the app downloaded on the iOS simulator (Tools › Fuel Prices).

Usage: python3 Tests/fuel_check.py "<data container>/Library/Application Support/CodeShelf"
Exits 1 (reported as a warning in CI) if prices couldn't be read.
"""
import json
import pathlib
import sys
import time

root = pathlib.Path(sys.argv[1])
probe = None
deadline = time.time() + 120
while time.time() < deadline:
    try:
        probe = json.loads((root / "fuel-probe.json").read_text())
        break
    except (FileNotFoundError, json.JSONDecodeError):
        time.sleep(3)

if probe is None:
    print("No fuel-probe.json written")
    sys.exit(1)

print(f"Survey markets: {probe['markets']}  error: {probe['error'] or 'none'}")
print(f"Furnace oil cities: {', '.join(probe['furnaceOilCities']) or 'none'}")
print(f"Heating fuel, monthly (Statistics Canada): {', '.join(probe.get('heatingMonthly', [])) or 'none'}")
print(f"Furnace oil problems: {probe.get('furnaceProblem') or 'none'}")
ok = True
for row in probe["rows"]:
    cents = row["cents"]
    good = 40 <= cents <= 500
    ok = ok and good
    print(f"  {'OK  ' if good else 'BAD '} {row['name']:<20} {cents:7.1f} ¢/L  {row['date']}  {row['note'][:90]}")
names = {row["name"] for row in probe["rows"]}
wanted = {"Propane", "Furnace Oil", "Gasoline — Regular", "Gasoline — Premium", "Diesel", "Dyed Diesel"}
missing = wanted - names
if missing:
    print("Missing:", ", ".join(sorted(missing)))
sys.exit(0 if ok and not missing else 1)
