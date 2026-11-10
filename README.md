# Fetch

A small Mac app for saving a video from a link. Paste or drop a URL, check the preview, and download it to the folder you choose. Fetch is a native SwiftUI app for macOS 14 and later. It bundles [yt-dlp](https://github.com/yt-dlp/yt-dlp), ffmpeg, and [Deno](https://deno.com) (yt-dlp needs a JavaScript runtime for YouTube).

The first build is signed ad hoc, for the owner’s own Mac. It is not notarized.

## Install

1. Open the pull request’s **macOS** check and download the **Fetch-macOS** artifact. GitHub wraps it as `Fetch-macOS.zip`. Inside that zip are `Fetch.zip` (the app) and `Fetch.dmg` (the same app on a disk image). Unzip `Fetch.zip` to get `Fetch.app`. Actions artifacts expire after 90 days.
2. Move `Fetch.app` to `/Applications`.
3. The first time you open it, macOS Gatekeeper will refuse an ad-hoc app that came from the internet. On macOS 15 and later, right-click **Open** no longer bypasses that. Do one of these:

   **Open Anyway**

   - Double-click `Fetch.app` once so Gatekeeper records the refusal.
   - Go to **System Settings → Privacy & Security**, scroll to the security section, and click **Open Anyway**.

   **Or clear quarantine in Terminal**

   ```bash
   xattr -dr com.apple.quarantine /Applications/Fetch.app
   ```

4. Fetch copies yt-dlp, ffmpeg, ffprobe, and Deno into `~/Library/Application Support/Fetch/bin` the first time, and again after an update. It checks the signed SHA-256 recorded at build time, then remembers the file’s path, size, modification time, and inode so later launches do not hash the tools again. A new yt-dlp is checked against the published `SHA2-256SUMS` before Fetch keeps it. “Already up to date” is a successful check. The engines are Apple Silicon only.

## Using it

Clipboard watching is off until you turn it on in Settings. When it is on, copying a link from YouTube, TikTok, Instagram, X, Reddit, or Vimeo offers **Fetch this?** Fetch does not start the download until you accept.

Safari cookies are off unless you choose them on a sign-in error, and that choice applies to the next request only. Reading Safari’s cookies needs Full Disk Access: **System Settings → Privacy & Security → Full Disk Access**, then turn Fetch on. The error card opens that pane.

Paste a video link, or drop one on the window. Fetch shows the title, site, duration, size, and codecs. **No watermark** appears only when the chosen TikTok format is a Direct / `play_addr` stream, not the watermarked download. YouTube, Vimeo, Reddit, and X do not get that badge.

- **Format:** MP4/H.264, MP4/HEVC, MOV, WebM, MKV, M4A, or MP3.
- **Quality:** Best, 2160p, 1080p, 720p, or 480p.
- **Max size:** when the best file is larger than the cap, Fetch picks a smaller format that fits. If none does, or the file is small but is not already H.264/AAC (or HEVC/AAC for the HEVC choice), it re-encodes with the Apple hardware encoder (`h264_videotoolbox` / `hevc_videotoolbox`) at a bitrate computed from the cap, checks the file size, and retries a little smaller if it is still over.
- **Save to:** Downloads, unless you pick another folder. The gear opens settings: clipboard watching, the menu bar extra, and engine updates. The update buttons remember stable or nightly for the daily check.
- A sign-in error can use your Safari cookies for that one request (`--cookies-from-browser safari`). Nothing is sent anywhere except to the site you are downloading from.
- Cancel puts yt-dlp in its own process group and stops that group, including ffmpeg.

Clipboard watching reads the pasteboard change count about once a second, and only when the setting is on. It does not poll during a download’s progress; progress comes from the process pipes.

## Develop

The app is a Swift package. `FetchCore` (format choice, size math, URLs, file names, errors, progress parsing) builds on Linux with Swift 6. The Mac app target is macOS 14 only. Tests:

```bash
swift test
```

A real app, screenshots, and downloads are built on a Mac by GitHub Actions (`.github/workflows/macos.yml`, `macos-15`). That workflow downloads the arm64 engines, checks their published checksums before signing, builds and ad-hoc signs `Fetch.app`, writes light and dark screenshots, runs the yt-dlp update once, samples launch memory and CPU with the clipboard watcher and menu bar on, downloads a short public video, re-encodes it under a size cap, tries TikTok when the runner can reach it, and cancels a download to confirm yt-dlp and ffmpeg are gone.

From a Mac you can do the same locally:

```bash
python3 Scripts/fetch_engines.py
bash Scripts/build-app.sh
artifacts/Fetch.app/Contents/MacOS/Fetch --screenshots /tmp/fetch-screens
bash Scripts/e2e.sh
```

`Fetch --cli version`, `Fetch --cli metadata <url>`, `Fetch --cli update stable`, and `Fetch --cli download <url> --output <dir> [--max-mb N] [--limit-rate 80K]` drive the engine without the window.

## Limits

- One video at a time. Playlists are ignored (`--no-playlist`).
- A burned-in watermark cannot be removed. Some TikTok regions only offer a `play` format that may still have a watermark or end card; the badge stays off in that case.
- Some TikTok `bytevc1` files have no audio. Fetch probes the result and, when that happens, tries an H.264 format that includes audio.
- Instagram and other private posts need a browser sign-in. Safari cookies on recent macOS often require Full Disk Access for the app.
- WebM uses a software VP9 encoder. H.264 and HEVC use VideoToolbox, and fall back to libx264 / libx265 if VideoToolbox refuses the file.
- YouTube sometimes asks a datacenter address to sign in. Fetch then tries the TV, iOS, and mobile web clients. A home connection usually gets the normal web client. If every client asks for a sign-in, use the Safari button on the error. GitHub-hosted runners hit that wall, so the automated download test falls back to a public sample file there while still attempting YouTube.
- There is no telemetry. Fetch does not phone home except for the download itself, thumbnail images, and the daily yt-dlp update check. Remote YouTube solver components (`ejs:github`, `ejs:npm`) are not requested; the bundled yt-dlp already includes its script runtime.
