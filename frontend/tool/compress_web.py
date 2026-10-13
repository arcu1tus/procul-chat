#!/usr/bin/env python3
"""Add Brotli/gzip sidecars to a Flutter web build for static HTTP serving."""

import argparse
import gzip
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="Flutter build/web directory")
    args = parser.parse_args()
    directory = args.directory.resolve()
    if not directory.is_dir() or not (directory / "flutter_bootstrap.js").is_file():
        parser.error("directory must contain a Flutter web build (flutter_bootstrap.js)")
    brotli = shutil.which("brotli")
    if brotli is None:
        parser.error("brotli CLI is required; on Debian/Ubuntu: sudo apt-get install brotli")

    extensions = {".js", ".mjs", ".wasm", ".html", ".css", ".json", ".svg", ".ttf", ".otf"}
    count = total = br_total = gz_total = 0
    for source in sorted(directory.rglob("*")):
        if not source.is_file() or source.is_symlink() or source.suffix not in extensions:
            continue
        # Replace previous sidecars, including when a changed file no longer compresses well.
        br_path = source.with_name(source.name + ".br")
        gz_path = source.with_name(source.name + ".gz")
        br_path.unlink(missing_ok=True)
        gz_path.unlink(missing_ok=True)
        data = source.read_bytes()
        if len(data) < 512:
            continue
        br = subprocess.run(
            [brotli, "--quality=9", "--stdout"], input=data, capture_output=True, check=True
        ).stdout
        gz = gzip.compress(data, compresslevel=9, mtime=0)
        if len(br) < len(data):
            br_path.write_bytes(br)
        if len(gz) < len(data):
            gz_path.write_bytes(gz)
        count += 1
        total += len(data)
        br_total += min(len(br), len(data))
        gz_total += min(len(gz), len(data))

    print(f"{count} assets: original {total:,} bytes; Brotli {br_total:,}; gzip {gz_total:,}")
    print("Deploy originals and sidecars together; configure the host to negotiate encoding.")


if __name__ == "__main__":
    main()
