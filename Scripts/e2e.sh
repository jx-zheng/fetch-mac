#!/bin/bash
# Idle/active resource samples and real downloads against the built app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/artifacts/Fetch.app"
BIN="$APP/Contents/MacOS/Fetch"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) ENGINE_ARCH=arm64 ;;
  *) ENGINE_ARCH=x86_64 ;;
esac
FFPROBE="$APP/Contents/Resources/bin/$ENGINE_ARCH/ffprobe"
OUT="$ROOT/artifacts/e2e"
REPORT="$ROOT/artifacts/report.txt"
mkdir -p "$OUT"
: > "$REPORT"
export FETCH_SKIP_UPDATE=1

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }

log "Fetch end-to-end $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "Host: $(sw_vers -productVersion) $(uname -m)"
"$BIN" --cli version | tee -a "$REPORT"

log ""
log "Idle (window open, no clipboard watcher, no engine work)"
"$BIN" --idle-benchmark >/tmp/fetch-idle.log 2>&1 &
IDLE_PID=$!
sleep 4
if ! kill -0 "$IDLE_PID" 2>/dev/null; then
  log "Idle launch failed"
  cat /tmp/fetch-idle.log | tee -a "$REPORT"
  exit 1
fi
: > "$OUT/idle.csv"
for _ in 1 2 3 4 5 6 7 8; do
  ps -p "$IDLE_PID" -o rss=,%cpu= >> "$OUT/idle.csv"
  sleep 1
done
kill "$IDLE_PID" 2>/dev/null || true
wait "$IDLE_PID" 2>/dev/null || true

python3 - "$OUT/idle.csv" "$REPORT" << 'PY'
import sys
rows = []
for line in open(sys.argv[1]):
    parts = line.split()
    if len(parts) >= 2:
        rows.append((int(float(parts[0])), float(parts[1])))
# Drop the first three samples; they still include the launch.
tail = rows[3:] or rows
rss = [r for r, _ in tail]
cpu = [c for _, c in tail]
avg_rss = sum(rss) / len(rss) / 1024
peak_rss = max(rss) / 1024
avg_cpu = sum(cpu) / len(cpu)
peak_cpu = max(cpu)
text = f"Idle RSS avg {avg_rss:.1f} MB, peak {peak_rss:.1f} MB; CPU avg {avg_cpu:.1f}%, peak {peak_cpu:.1f}% (8s after 4s warmup)"
print(text)
open(sys.argv[2], "a").write(text + "\n")
if avg_cpu > 25 or peak_rss > 500:
    sys.exit("idle resource use is too high")
PY

log ""
log "YouTube metadata"
YOUTUBE_URL=""
for candidate in \
  "https://www.youtube.com/watch?v=jNQXAC9IVRw" \
  "https://www.youtube.com/watch?v=C0DPdy98e4c" \
  "https://www.youtube.com/watch?v=BaW_jenozKc"
do
  if "$BIN" --cli metadata "$candidate" > "$OUT/youtube-meta.json" 2>>"$REPORT"; then
    YOUTUBE_URL="$candidate"
    break
  fi
  log "metadata failed for $candidate"
done
MEDIA_URL="$YOUTUBE_URL"
if [[ -z "$MEDIA_URL" ]]; then
  log "YouTube asked this runner to sign in. The download and re-encode use a public sample file instead."
  for candidate in \
    "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4" \
    "https://filesamples.com/samples/video/mp4/sample_640x360.mp4"
  do
    if "$BIN" --cli metadata "$candidate" > "$OUT/sample-meta.json" 2>>"$REPORT"; then
      MEDIA_URL="$candidate"
      cat "$OUT/sample-meta.json" | tee -a "$REPORT"
      break
    fi
    log "metadata failed for $candidate"
  done
else
  log "Using $YOUTUBE_URL"
  cat "$OUT/youtube-meta.json" | tee -a "$REPORT"
fi
if [[ -z "$MEDIA_URL" ]]; then
  log "No public video could be read"
  exit 1
fi

download_to() {
  local url="$1"
  local dest="$2"
  local extra="${3:-}"
  local stdout="$OUT/${dest}.json"
  local stderr="$OUT/${dest}.err"
  ACTIVE="$OUT/${dest}-cpu.csv"
  : > "$ACTIVE"
  # shellcheck disable=SC2086
  "$BIN" --cli download "$url" --output "$OUT/$dest" --format mp4H264 $extra > "$stdout" 2>"$stderr" &
  local pid=$!
  for _ in $(seq 1 120); do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    ps -p "$pid" -o rss=,%cpu= >> "$ACTIVE" || true
    sleep 1
  done
  set +e
  wait "$pid"
  local status=$?
  set -e
  cat "$stderr" | tee -a "$REPORT" || true
  if [[ $status -ne 0 ]]; then
    return "$status"
  fi
  cat "$stdout" | tee -a "$REPORT"
  cp "$ACTIVE" "$OUT/active.csv"
  cp "$stdout" "$OUT/full.json"
  return 0
}

log ""
log "Download $MEDIA_URL"
if ! download_to "$MEDIA_URL" full; then
  log "Download failed for $MEDIA_URL. Falling back to a public sample file."
  MEDIA_URL=""
  for candidate in \
    "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4" \
    "https://filesamples.com/samples/video/mp4/sample_640x360.mp4"
  do
    if "$BIN" --cli metadata "$candidate" > "$OUT/sample-meta.json" 2>>"$REPORT"; then
      log "Sample metadata:"
      cat "$OUT/sample-meta.json" | tee -a "$REPORT"
      if download_to "$candidate" sample; then
        MEDIA_URL="$candidate"
        break
      fi
    fi
    log "sample failed for $candidate"
  done
fi
if [[ -z "$MEDIA_URL" || ! -f "$OUT/full.json" ]]; then
  log "No video could be saved"
  exit 1
fi
python3 - "$OUT/full.json" "$FFPROBE" "$REPORT" "$OUT/active.csv" << 'PY'
import json, subprocess, sys
line = open(sys.argv[1]).read().strip().split("FETCH_RESULT ", 1)[-1]
result = json.loads(line)
path = result["path"]
probe = subprocess.run([sys.argv[2], "-v", "error", "-show_entries", "stream=codec_type,codec_name", "-of", "json", path], capture_output=True, text=True, check=True)
streams = json.loads(probe.stdout).get("streams", [])
kinds = {s.get("codec_type") for s in streams}
assert "video" in kinds, streams
assert "audio" in kinds, streams
assert result["bytes"] > 10_000
rows = []
for raw in open(sys.argv[4]):
    parts = raw.split()
    if len(parts) >= 2:
        rows.append((int(float(parts[0])), float(parts[1])))
if rows:
    avg_cpu = sum(c for _, c in rows) / len(rows)
    peak_rss = max(r for r, _ in rows) / 1024
    text = f"Active download RSS peak {peak_rss:.1f} MB, CPU avg {avg_cpu:.1f}% over {len(rows)}s; file {result['bytes']} bytes"
else:
    text = f"Active download finished before a sample; file {result['bytes']} bytes"
print(text)
open(sys.argv[3], "a").write(text + "\n")
open("/tmp/fetch-full-bytes", "w").write(str(result["bytes"]))
PY

BYTES="$(cat /tmp/fetch-full-bytes)"
# Force a re-encode: cap at about 45% of the file we just saved, but keep a floor the encoder can hit.
MAX_MB="$(python3 -c "print(f'{max(0.12, ($BYTES/1_000_000)*0.45):.2f}')")"
log ""
log "YouTube max-size re-encode at ${MAX_MB} MB"
"$BIN" --cli download "$MEDIA_URL" --output "$OUT/small" --format mp4H264 --max-mb "$MAX_MB" > "$OUT/small.json" 2>"$OUT/small.err"
cat "$OUT/small.err" | tee -a "$REPORT"
cat "$OUT/small.json" | tee -a "$REPORT"
python3 - "$OUT/small.json" "$MAX_MB" "$FFPROBE" "$REPORT" << 'PY'
import json, subprocess, sys
result = json.loads(open(sys.argv[1]).read().strip().split("FETCH_RESULT ", 1)[-1])
cap = float(sys.argv[2]) * 1_000_000
assert result["transcoded"], result
assert result["bytes"] <= cap, (result["bytes"], cap)
assert result["video"], result
probe = subprocess.run([sys.argv[3], "-v", "error", "-show_entries", "stream=codec_type", "-of", "json", result["path"]], capture_output=True, text=True, check=True)
kinds = {s.get("codec_type") for s in json.loads(probe.stdout).get("streams", [])}
assert "video" in kinds
text = f"Re-encode {result['bytes']} bytes under cap {int(cap)} (hardware={result['hardware']})"
print(text)
open(sys.argv[4], "a").write(text + "\n")
PY

log ""
log "TikTok (skipped when the runner cannot reach it)"
set +e
"$BIN" --cli metadata "https://www.tiktok.com/@tatemcrae/video/7107337212743830830" > "$OUT/tiktok.json" 2>"$OUT/tiktok.err"
TIKTOK=$?
set -e
if [[ $TIKTOK -eq 0 ]]; then
  log "TikTok metadata:"
  cat "$OUT/tiktok.json" | tee -a "$REPORT"
  "$BIN" --cli download "https://www.tiktok.com/@tatemcrae/video/7107337212743830830" --output "$OUT/tiktok" --format mp4H264 > "$OUT/tiktok-dl.json" 2>"$OUT/tiktok-dl.err" || {
    log "TikTok download failed"
    cat "$OUT/tiktok-dl.err" | tee -a "$REPORT"
    # A metadata success followed by a download failure is our bug.
    exit 1
  }
  cat "$OUT/tiktok-dl.json" | tee -a "$REPORT"
  python3 - "$OUT/tiktok-dl.json" "$FFPROBE" << 'PY'
import json, subprocess, sys
result = json.loads(open(sys.argv[1]).read().strip().split("FETCH_RESULT ", 1)[-1])
probe = subprocess.run([sys.argv[2], "-v", "error", "-show_entries", "stream=codec_type", "-of", "json", result["path"]], capture_output=True, text=True, check=True)
kinds = {s.get("codec_type") for s in json.loads(probe.stdout).get("streams", [])}
assert "video" in kinds and "audio" in kinds, kinds
print("TikTok file has video and audio; noWatermark =", result["noWatermark"])
PY
else
  log "TikTok not completed from this runner (exit $TIKTOK). stderr:"
  cat "$OUT/tiktok.err" | tee -a "$REPORT"
fi

log ""
log "Done"
