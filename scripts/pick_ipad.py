"""Prints the UDID of the newest available iPad simulator (prefers iPad Air)."""
import json
import re
import sys

devices = json.load(sys.stdin)["devices"]
best = None
for runtime, entries in devices.items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for device in entries:
        if not device.get("isAvailable", True) or not device["name"].startswith("iPad"):
            continue
        score = (version, "Air" in device["name"])
        if best is None or score > best[0]:
            best = (score, device["udid"])
print(best[1] if best else "")
