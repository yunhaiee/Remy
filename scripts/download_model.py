#!/usr/bin/env python3
"""Fetch the exact public Gemma artifact, resume safely, and check its SHA-256."""
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / "iOS/Remy/Resources/model-manifest.json").read_text())
directory = ROOT / "models"
directory.mkdir(exist_ok=True)
target = directory / manifest["filename"]
partial = target.with_suffix(target.suffix + ".partial")

def sha256(path):
    # hashlib.file_digest needs Python 3.11; the macOS system python3 is older.
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while chunk := file.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()

def valid(path):
    return path.exists() and path.stat().st_size == manifest["size"] and sha256(path) == manifest["sha256"]

if valid(target):
    print("Gemma is already downloaded and verified.")
    raise SystemExit(0)
offset = partial.stat().st_size if partial.exists() else 0
request = urllib.request.Request(manifest["url"], headers={"Range": f"bytes={offset}-"} if offset else {})
with urllib.request.urlopen(request, timeout=90) as response:
    resume = offset > 0 and response.status == 206
    if resume and not response.headers.get("Content-Range", "").startswith(f"bytes {offset}-"):
        raise RuntimeError("Server returned an unexpected resume range")
    count = offset if resume else 0
    with partial.open("ab" if resume else "wb") as output:
        while chunk := response.read(4 * 1024 * 1024):
            output.write(chunk)
            count += len(chunk)
            print(f"\rGemma: {count / manifest['size']:.1%}", end="", flush=True)
print("\nChecking model integrity…")
if not valid(partial):
    raise RuntimeError("Model size or SHA-256 did not match. The partial file was retained for inspection.")
partial.replace(target)
print(f"Verified: {target}")
