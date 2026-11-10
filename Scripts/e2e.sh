#!/bin/bash
# Idle/active resource samples and real downloads against the built app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/artifacts/Fetch.app"
BIN="$APP/Contents/MacOS/Fetch"
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Fetch engines are arm64-only"
  exit 1
fi
ENGINE_ARCH=arm64
FFPROBE="$APP/Contents/Resources/bin/$ENGINE_ARCH/ffprobe"
OUT="$ROOT/artifacts/e2e"
REPORT="$ROOT/artifacts/report.txt"
mkdir -p "$OUT"
: > "$REPORT"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }

log "Fetch end-to-end $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "Host: $(sw_vers -productVersion) $(uname -m)"
"$BIN" --cli version | tee -a "$REPORT"

log ""
log "Engine update (already current is success)"
if "$BIN" --cli update stable > "$OUT/update.txt" 2>"$OUT/update.err"; then
  log "Update path: success"
  cat "$OUT/update.txt" | tee -a "$REPORT"
else
  log "Update path failed"
  cat "$OUT/update.err" | tee -a "$REPORT"
  exit 1
fi

measure_launch() {
  local name="$1"
  local take_sample="$2"
  log ""
  log "Launch $name (clipboard watcher and menu bar on)"
  "$BIN" --launch-sample >"/tmp/fetch-launch-$name.log" 2>&1 &
  local pid=$!
  local csv="$OUT/launch-$name.csv"
  : > "$csv"
  local start now elapsed sampled=0 sample_pid=""
  start=$(date +%s)
  while true; do
    now=$(date +%s)
    elapsed=$((now - start))
    if (( elapsed >= 30 )); then
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      log "Launch $name exited at ${elapsed}s"
      cat "/tmp/fetch-launch-$name.log" | tee -a "$REPORT"
      exit 1
    fi
    ps -p "$pid" -o rss=,%cpu= | awk -v t="$elapsed" 'NF >= 2 {print t, $1, $2}' >> "$csv" || true
    if (( take_sample == 1 && elapsed >= 5 && sampled == 0 )); then
      sampled=1
      sample "$pid" 3 > "$OUT/launch-$name.sample.txt" 2>&1 &
      sample_pid=$!
    fi
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [[ -n "$sample_pid" ]]; then
    for _ in 1 2 3 4 5; do
      if ! kill -0 "$sample_pid" 2>/dev/null; then
        break
      fi
      sleep 1
    done
    kill "$sample_pid" 2>/dev/null || true
    wait "$sample_pid" 2>/dev/null || true
  fi
  python3 - "$csv" "$REPORT" "$name" "$OUT/launch-$name.sample.txt" << 'PY'
import sys
rows = []
for line in open(sys.argv[1]):
    parts = line.split()
    if len(parts) >= 3:
        rows.append((int(parts[0]), int(float(parts[1])), float(parts[2])))
name = sys.argv[3]
window = [row for row in rows if 10 <= row[0] < 30]
if len(window) < 15:
    sys.exit(f"{name} launch has {len(window)} samples in t=10..30")
cpus = [cpu for _, _, cpu in window]
rss = [kb / 1024 for _, kb, _ in window]
mean_cpu = sum(cpus) / len(cpus)
growth = rss[-1] - rss[0]
span = max(rss) - min(rss)
text = (
    f"{name} launch t=10..30 mean CPU {mean_cpu:.2f}% (peak {max(cpus):.1f}%); "
    f"RSS {rss[0]:.1f} -> {rss[-1]:.1f} MB (span {span:.1f} MB); "
    f"whole-run peak {max(kb for _, kb, _ in rows) / 1024:.1f} MB"
)
print(text)
open(sys.argv[2], "a").write(text + "\n")
sample_path = sys.argv[4]
try:
    sample = open(sample_path, errors="replace").read().splitlines()
except FileNotFoundError:
    sample = []
if sample:
    interesting = []
    for i, line in enumerate(sample):
        if "Call graph" in line or "Heaviest stack" in line or line.strip().startswith("Call graph"):
            interesting = sample[i:i + 40]
            break
    if not interesting:
        interesting = sample[:40]
    open(sys.argv[2], "a").write(name + " sample:\n" + "\n".join(interesting) + "\n")
if mean_cpu > 2:
    sys.exit(f"{name} mean CPU {mean_cpu:.2f}% between 10s and 30s is over 2%")
if growth > 8 or span > 15:
    sys.exit(f"{name} RSS is not flat (growth {growth:.1f} MB, span {span:.1f} MB)")
PY
}

measure_launch cold 1
measure_launch warm 0

log ""
log "Title bar is opaque in light and dark, and a drag moves it"
mkdir -p "$ROOT/artifacts/screenshots"
if "$BIN" --titlebar-check "$OUT/titlebar.png" > "$OUT/titlebar.txt" 2>"$OUT/titlebar.err"; then
  cat "$OUT/titlebar.txt" | tee -a "$REPORT"
  cp "$OUT"/titlebar-light.png "$OUT"/titlebar-dark.png "$ROOT/artifacts/screenshots/" 2>/dev/null || true
else
  log "Title bar check failed"
  cat "$OUT/titlebar.err" | tee -a "$REPORT" || true
  exit 1
fi

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

log ""
log "Quality menus from resolved media: $MEDIA_URL"
if "$BIN" --menu-shots "$ROOT/artifacts/screenshots" "$MEDIA_URL" > "$OUT/menus.txt" 2>"$OUT/menus.err"; then
  cat "$OUT/menus.txt" | tee -a "$REPORT"
else
  log "Quality menu screenshots failed"
  cat "$OUT/menus.err" | tee -a "$REPORT" || true
  exit 1
fi
for shot in quality-video-light quality-video-dark quality-audio-light quality-audio-dark; do
  if [[ ! -s "$ROOT/artifacts/screenshots/${shot}.png" ]]; then
    log "missing $shot.png"
    exit 1
  fi
done

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
  if [[ "$ACTIVE" != "$OUT/active.csv" ]]; then
    cp "$ACTIVE" "$OUT/active.csv"
  fi
  if [[ "$stdout" != "$OUT/full.json" ]]; then
    cp "$stdout" "$OUT/full.json"
  fi
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
assert result["bytes"] > 10_000
if result.get("audio"):
    assert "audio" in kinds, streams
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
log "Cancel during ffmpeg"
"$BIN" --cli download "$MEDIA_URL" --output "$OUT/cancel" --format webm --limit-rate 400K > "$OUT/cancel.json" 2>"$OUT/cancel.err" &
CANCEL_PID=$!
SEEN_FFMPEG=0
for _ in $(seq 1 90); do
  if pgrep -x ffmpeg >/dev/null; then
    SEEN_FFMPEG=1
    break
  fi
  if ! kill -0 "$CANCEL_PID" 2>/dev/null; then
    log "Download ended before ffmpeg started"
    cat "$OUT/cancel.err" | tee -a "$REPORT" || true
    exit 1
  fi
  sleep 0.5
done
if [[ "$SEEN_FFMPEG" != 1 ]]; then
  log "ffmpeg never started"
  cat "$OUT/cancel.err" | tee -a "$REPORT" || true
  exit 1
fi
log "ffmpeg is running; cancelling"
kill -INT "$CANCEL_PID" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if ! kill -0 "$CANCEL_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done
if kill -0 "$CANCEL_PID" 2>/dev/null; then
  log "CLI did not exit after cancel"
  kill -KILL "$CANCEL_PID" 2>/dev/null || true
  exit 1
fi
wait "$CANCEL_PID" 2>/dev/null || true
sleep 1
if pgrep -x yt-dlp >/dev/null || pgrep -x ffmpeg >/dev/null; then
  log "yt-dlp or ffmpeg still running after cancel"
  pgrep -lf 'yt-dlp|ffmpeg' | tee -a "$REPORT" || true
  exit 1
fi
log "Cancel test passed: CLI exited and no yt-dlp or ffmpeg was left"

log ""
log "Done"
