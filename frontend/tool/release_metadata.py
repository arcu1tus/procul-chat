"""Validate v-prefixed SemVer tags and emit GitHub Actions job outputs."""

import os
import re
import sys


# SemVer 2.0.0: no leading zeroes in core or numeric prerelease identifiers.
NUMBER = r"(?:0|[1-9][0-9]*)"
PRERELEASE_ID = rf"(?:{NUMBER}|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
TAG = re.compile(
    rf"v(?P<core>{NUMBER}\.{NUMBER}\.{NUMBER})"
    rf"(?:-(?P<prerelease>{PRERELEASE_ID}(?:\.{PRERELEASE_ID})*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


def release_metadata(tag: str) -> dict[str, str]:
    match = TAG.fullmatch(tag)
    if match is None:
        return {"valid": "false"}
    core = match["core"]
    prerelease = match["prerelease"]
    return {
        "valid": "true",
        "version": tag[1:],
        # Native version fields need a numeric MAJOR.MINOR.PATCH.
        "build_name": core,
        "prerelease": str(prerelease is not None).lower(),
        # nFPM encodes prereleases for dpkg/RPM. Ignore build metadata for
        # package versions, as it has no effect on SemVer precedence.
        "package_version": tag[1:].split("+", 1)[0],
    }


if __name__ == "__main__":
    metadata = release_metadata(sys.argv[1])
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        for key, value in metadata.items():
            print(f"{key}={value}", file=output)
    if metadata["valid"] == "false":
        print(f"Skipping non-SemVer tag: {sys.argv[1]!r}")
