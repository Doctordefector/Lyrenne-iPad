"""Adds a release to source.json, the AltStore / SideStore source: python scripts/update-source.py v0.3.0

Run by .github/workflows/source.yml when a release is published. Reads the release's .ipa asset
and notes with the gh CLI; the newest version goes first, as AltStore expects.
"""
import json, re, subprocess, sys
from pathlib import Path

tag = sys.argv[1]
rel = json.loads(subprocess.check_output(
    ["gh", "release", "view", tag, "--json", "tagName,publishedAt,body,assets"], text=True))
ipa = next(a for a in rel["assets"] if a["name"].endswith(".ipa"))
min_os = re.search(r"\.iOS\(\.v(\d+)\)", Path("Package.swift").read_text()).group(1) + ".0"

src_path = Path("source.json")
src = json.loads(src_path.read_text())
app = src["apps"][0]
version = rel["tagName"].lstrip("v")
entry = {
    "version": version,
    "date": rel["publishedAt"],
    "localizedDescription": rel["body"].strip() or f"Lyrenne for iPad {version}",
    "downloadURL": ipa["url"],
    "size": ipa["size"],
    "minOSVersion": min_os,
}
app["versions"] = [entry] + [v for v in app["versions"] if v["version"] != version]
src_path.write_text(json.dumps(src, indent=2, ensure_ascii=False) + "\n")
print(f"source.json: {version} -> {ipa['url']} ({ipa['size']} bytes)")
