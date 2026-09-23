#!/usr/bin/env python3
"""Build TV/Assets.xcassets — the tvOS brand-asset stack — from Tools/tvicon.

    python3 Tools/tvicons.py

Two parallax layers (Rings over Background) at the App Icon and App Store sizes,
and flat top-shelf images at both widths. Sizes are Apple's for tvOS; the 2x
variants are what a 4K set actually shows. Idempotent: rerun after changing
the drawing.
"""
import json, os, subprocess, shutil, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "TV" / "Assets.xcassets"
BRAND = CATALOG / "App Icon & Top Shelf Image.brandassets"
TOOL = "/tmp/thrumtvicon"

subprocess.run(["swiftc", "-O", "-o", TOOL, str(ROOT / "Tools/tvicon/main.swift")], check=True)

def write_json(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2) + "\n")

def render(path, w, h, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([TOOL, str(path), str(w), str(h), mode], check=True)

INFO = {"author": "xcode", "version": 1}
if CATALOG.exists():
    shutil.rmtree(CATALOG)
write_json(CATALOG / "Contents.json", {"info": INFO})

# Layer stacks. Front layer first in the list.
LAYERS = [("Rings", "rings"), ("Background", "background")]
def stack(name, w, h):
    folder = BRAND / f"{name}.imagestack"
    write_json(folder / "Contents.json",
               {"layers": [{"filename": f"{l}.imagestacklayer"} for l, _ in LAYERS], "info": INFO})
    for layer, mode in LAYERS:
        lf = folder / f"{layer}.imagestacklayer"
        write_json(lf / "Contents.json", {"info": INFO})
        cs = lf / "Content.imageset"
        write_json(cs / "Contents.json", {"images": [
            {"filename": "Content-1x.png", "idiom": "tv", "scale": "1x"},
            {"filename": "Content-2x.png", "idiom": "tv", "scale": "2x"}], "info": INFO})
        render(cs / "Content-1x.png", w, h, mode)
        render(cs / "Content-2x.png", w * 2, h * 2, mode)

def shelf(name, w, h):
    folder = BRAND / f"{name}.imageset"
    write_json(folder / "Contents.json", {"images": [
        {"filename": "Shelf-1x.png", "idiom": "tv", "scale": "1x"},
        {"filename": "Shelf-2x.png", "idiom": "tv", "scale": "2x"}], "info": INFO})
    render(folder / "Shelf-1x.png", w, h, "flat")
    render(folder / "Shelf-2x.png", w * 2, h * 2, "flat")

write_json(BRAND / "Contents.json", {"assets": [
    {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
    {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
    {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
], "info": INFO})
stack("App Icon", 400, 240)
stack("App Icon - App Store", 1280, 768)
shelf("Top Shelf Image", 1920, 720)
shelf("Top Shelf Image Wide", 2320, 720)
print("wrote", CATALOG)
