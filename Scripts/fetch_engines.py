#!/usr/bin/env python3
"""Download yt-dlp, ffmpeg, ffprobe, and Deno and verify published SHA-256 sums.

Nothing is executed. The manifest records the hash of each raw binary so the
app can check it again before the first run.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "engines"
BIN = OUT / "bin"

UA = "fetch-mac-engine-fetch"


def fetch(url: str, dest: Path | None = None) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/octet-stream"})
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token and "api.github.com" in url:
        request.add_header("Authorization", f"Bearer {token}")
        request.add_header("Accept", "application/vnd.github+json")
    context = ssl.create_default_context()
    with urllib.request.urlopen(request, context=context, timeout=180) as response:
        data = response.read()
    if dest is not None:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
    return data


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_hash(path: Path, expected: str, label: str) -> None:
    actual = sha256(path)
    if actual.lower() != expected.lower():
        sys.exit(f"{label} checksum mismatch\n expected {expected}\n actual   {actual}")
    print(f"verified {label} {actual}")


def parse_sums(text: str) -> dict[str, str]:
    found: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = re.split(r"[\s*]+", line, maxsplit=1)
        if len(parts) != 2:
            continue
        digest, name = parts
        if re.fullmatch(r"[0-9a-fA-F]{64}", digest):
            found[name.strip()] = digest.lower()
    return found


def unzip_one(archive: Path, dest_dir: Path, binary_name: str) -> Path:
    dest_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as zipped:
        names = [name for name in zipped.namelist() if Path(name).name == binary_name and not name.endswith("/")]
        if not names:
            sys.exit(f"{archive.name} does not contain {binary_name}: {zipped.namelist()[:12]}")
        member = names[0]
        target = dest_dir / binary_name
        with zipped.open(member) as source, target.open("wb") as dest:
            shutil.copyfileobj(source, dest)
        target.chmod(0o755)
        return target


def ytdlp(manifest: dict) -> None:
    sums = fetch("https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS").decode()
    expected = parse_sums(sums).get("yt-dlp_macos")
    if not expected:
        sys.exit("SHA2-256SUMS has no yt-dlp_macos entry")
    binary = BIN / "yt-dlp"
    fetch("https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos", binary)
    binary.chmod(0o755)
    require_hash(binary, expected, "yt-dlp_macos")
    payload = json.loads(fetch("https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"))
    version = payload["tag_name"]
    if not re.match(r"\d{4}\.\d{2}\.\d{2}", version):
        sys.exit(f"unexpected yt-dlp version tag {version}")
    manifest["ytDlpVersion"] = version
    manifest["binaries"]["yt-dlp"] = {"universal": expected}


def deno(manifest: dict) -> None:
    payload = json.loads(fetch("https://api.github.com/repos/denoland/deno/releases/latest"))
    tag = payload["tag_name"]
    version = tag[1:] if tag.startswith("v") else tag
    assets = {item["name"]: item["browser_download_url"] for item in payload["assets"]}
    manifest["denoVersion"] = version
    manifest["binaries"]["deno"] = {}
    mapping = {
        "arm64": "deno-aarch64-apple-darwin.zip",
        "x86_64": "deno-x86_64-apple-darwin.zip",
    }
    for arch, name in mapping.items():
        archive = OUT / name
        fetch(assets[name], archive)
        digest_name = name + ".sha256sum"
        digest_text = fetch(assets[digest_name]).decode()
        expected = parse_sums(digest_text).get(name) or digest_text.strip().split()[0]
        require_hash(archive, expected, name)
        binary = unzip_one(archive, BIN / arch, "deno")
        manifest["binaries"]["deno"][arch] = sha256(binary)
        print(f"deno {arch} {manifest['binaries']['deno'][arch]}")


def ffmpeg(manifest: dict) -> None:
    html = fetch("https://ffmpeg.martin-riedl.de/").decode()
    marker = "Download Release Build"
    if marker not in html:
        sys.exit("ffmpeg release section not found")
    release = html.split(marker, 1)[1]
    manifest["binaries"]["ffmpeg"] = {}
    manifest["binaries"]["ffprobe"] = {}
    version = None
    for arch in ("arm64", "amd64"):
        key = "x86_64" if arch == "amd64" else "arm64"
        for tool in ("ffmpeg", "ffprobe"):
            match = re.search(rf'href="(/download/macos/{arch}/[^"]+/{tool}\.zip)"', release)
            if not match:
                sys.exit(f"missing {arch} {tool}.zip")
            path = match.group(1)
            if version is None:
                found = re.search(r"_(\d+\.\d+(?:\.\d+)?)/", path)
                version = found.group(1) if found else "unknown"
            archive = OUT / f"{tool}-{key}.zip"
            base = "https://ffmpeg.martin-riedl.de"
            fetch(base + path, archive)
            digest_text = fetch(base + path + ".sha256").decode()
            expected = digest_text.strip().split()[0]
            require_hash(archive, expected, f"{tool}.zip {key}")
            binary = unzip_one(archive, BIN / key, tool)
            manifest["binaries"][tool][key] = sha256(binary)
            print(f"{tool} {key} {manifest['binaries'][tool][key]}")
    manifest["ffmpegVersion"] = version or "unknown"


def main() -> None:
    if OUT.exists():
        shutil.rmtree(OUT)
    BIN.mkdir(parents=True)
    manifest: dict = {"binaries": {}}
    ytdlp(manifest)
    deno(manifest)
    ffmpeg(manifest)
    (OUT / "engine-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({k: manifest[k] for k in ("ytDlpVersion", "denoVersion", "ffmpegVersion")}, indent=2))


if __name__ == "__main__":
    main()
