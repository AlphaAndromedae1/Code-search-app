"""Prints the UDID of an available iPhone simulator on the newest iOS runtime."""
import json
import subprocess
import sys

listing = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
for runtime, devices in sorted(listing["devices"].items(), reverse=True):
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)
sys.exit("No available iPhone simulator found")
