#!/bin/bash
# Assemble Fetch.app from a release build and the verified engines.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f engines/engine-manifest.json ]]; then
  echo "engines/ is missing. Run Scripts/fetch_engines.py first." >&2
  exit 1
fi

echo "Building Fetch"
set +e
swift build -c release --product Fetch --arch arm64 --arch x86_64
status=$?
set -e
if [[ $status -ne 0 ]]; then
  echo "Universal build failed; building for this Mac only."
  swift build -c release --product Fetch
fi

BIN=""
if [[ -x .build/apple/Products/Release/Fetch ]]; then
  BIN=".build/apple/Products/Release/Fetch"
elif [[ -x .build/release/Fetch ]]; then
  BIN=".build/release/Fetch"
else
  BIN="$(find .build -type f -name Fetch -perm -111 ! -path '*.dSYM/*' | head -n 1)"
fi
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
  echo "Could not find the Fetch binary" >&2
  exit 1
fi
echo "Binary: $BIN"
lipo -info "$BIN" || true

APP="$ROOT/artifacts/Fetch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Fetch"
cp Fetch/Info.plist "$APP/Contents/Info.plist"
cp -R engines/bin "$APP/Contents/Resources/bin"
cp engines/engine-manifest.json "$APP/Contents/Resources/engine-manifest.json"
cp -R Fetch/AppIcon.appiconset "$APP/Contents/Resources/AppIcon.appiconset"
iconutil -c icns Fetch/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Downloaded engines arrive quarantined. The app copies them out and clears
# quarantine itself; strip it here too so codesign can see the binaries.
xattr -cr "$APP" || true
chmod 755 "$APP/Contents/MacOS/Fetch"
find "$APP/Contents/Resources/bin" -type f -exec chmod 755 {} \;

sign() {
  codesign --force --sign - --timestamp=none "$@"
}

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Fetch engines are arm64-only"
  exit 1
fi
ENGINE_ARCH=arm64

sign --options runtime --entitlements Fetch/deno.entitlements "$APP/Contents/Resources/bin/arm64/deno"
sign --options runtime --entitlements Fetch/ytdlp.entitlements "$APP/Contents/Resources/bin/yt-dlp"
for tool in ffmpeg ffprobe; do
  sign --options runtime --entitlements Fetch/Fetch.entitlements "$APP/Contents/Resources/bin/arm64/$tool"
done
# codesign rewrites each binary. Keep the upstream yt-dlp digest and record the signed digest separately.
python3 - "$APP/Contents/Resources" << 'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
manifest = json.loads((root / "engine-manifest.json").read_text())

def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    hasher.update(path.read_bytes())
    return hasher.hexdigest()

entry = manifest["binaries"].get("yt-dlp", {})
upstream = entry.get("upstream") or entry.get("universal")
signed = digest(root / "bin" / "yt-dlp")
manifest["binaries"]["yt-dlp"] = {"upstream": upstream, "signed": signed, "universal": signed}
for tool in ("ffmpeg", "ffprobe", "deno"):
    path = root / "bin" / "arm64" / tool
    manifest["binaries"].setdefault(tool, {})
    manifest["binaries"][tool] = {"arm64": digest(path)}
(root / "engine-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("recorded upstream and signed engine checksums")
PY
sign --options runtime --entitlements Fetch/Fetch.entitlements "$APP/Contents/MacOS/Fetch"
sign --options runtime --entitlements Fetch/Fetch.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

HOST_BIN="$APP/Contents/Resources/bin/$ENGINE_ARCH"
echo "Smoke: engines start"
"$HOST_BIN/ffmpeg" -hide_banner -version | head -n 1
"$HOST_BIN/ffprobe" -version | head -n 1
"$HOST_BIN/deno" --version
"$APP/Contents/Resources/bin/yt-dlp" --version
"$APP/Contents/MacOS/Fetch" --cli version

rm -f "$ROOT/artifacts/Fetch.zip" "$ROOT/artifacts/Fetch.dmg"
ditto -c -k --keepParent "$APP" "$ROOT/artifacts/Fetch.zip"
if hdiutil create -volname Fetch -srcfolder "$APP" -ov -format UDZO "$ROOT/artifacts/Fetch.dmg"; then
  echo "DMG written"
else
  echo "DMG skipped"
fi
echo "App: $APP"
ls -lh "$ROOT/artifacts/Fetch.zip"
