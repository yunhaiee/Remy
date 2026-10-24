#!/usr/bin/env python3
"""Fetch the pinned public camera detector. No app, camera, or sensor data is transmitted."""
import hashlib
from pathlib import Path
import urllib.request

root = Path(__file__).resolve().parents[1]
target = root / 'iOS/Remy/Resources/ObjectDetector/efficientdet_lite0.tflite'
expected = '0720bf247bd76e6594ea28fa9c6f7c5242be774818997dbbeffc4da460c723bb'
url = 'https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite0/int8/1/efficientdet_lite0.tflite'

def sha256(path):
    # hashlib.file_digest needs Python 3.11; the macOS system python3 is older.
    digest = hashlib.sha256()
    with path.open('rb') as file:
        while chunk := file.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()

def valid(path):
    return path.exists() and path.stat().st_size == 4602795 and sha256(path) == expected

if not valid(target):
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix('.partial')
    with urllib.request.urlopen(url, timeout=90) as response, temporary.open('wb') as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)
    if not valid(temporary):
        raise RuntimeError('Detector integrity check failed; existing model was not replaced.')
    temporary.replace(target)
print('Public camera detector downloaded and verified.')
