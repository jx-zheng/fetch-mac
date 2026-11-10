# Fetch

A small Mac app for saving a video from a link. Paste or drop a URL, check the preview, and download it to the folder you choose. Fetch is a native SwiftUI app for macOS 14 and later. It bundles [yt-dlp](https://github.com/yt-dlp/yt-dlp), ffmpeg, and [Deno](https://deno.com) (yt-dlp needs a JavaScript runtime for YouTube).

The first build is signed ad hoc, for the owner’s own Mac. It is not notarized.

## Install

1. Open the pull request’s **macOS** check and download the **Fetch-macOS** artifact (`Fetch.zip`). A `.dmg` is in the same artifact when the disk image was created.
2. Unzip it and move `Fetch.app` to `/Applications`.
3. The first time you open it, macOS Gatekeeper will refuse an ad-hoc app that came from the internet. Use one of these:

   **Right-click Open (this is the one that sticks)**

   - In Finder, right-click `Fetch.app` and choose **Open**.
   - Confirm **Open** in the dialog.
   - After that, a normal double-click works.

   **If the right-click dialog never offers Open**

   - Go to **System Settings → Privacy & Security**, scroll to the security section, and click **Open Anyway**.
   - Or, in Terminal:

     ```bash
     xattr -dr com.apple.quarantine /Applications/Fetch.app
     ```

4. Fetch copies yt-dlp, ffmpeg, ffprobe, and Deno into `~/Library/Application Support/Fetch/bin` on first launch, checks the SHA-256 that was recorded at build time, and clears the quarantine flag on those copies so yt-dlp can update itself later. The app checks for a new stable yt-dlp about once a day and verifies the published `SHA2-256SUMS` before it keeps the new binary.

Apple Silicon is the build that gets exercised on the macOS runner. The app binary is universal when the compiler allows it, and ffmpeg, ffprobe, and Deno are bundled for both Apple Silicon and Intel. If a universal app build is not possible on the runner, the artifact is Apple Silicon only.

## Using it

Paste a video link, or drop one on the window. Fetch shows the title, site, duration, size, and codecs. **No watermark** appears only when the chosen TikTok format is a Direct / `play_addr` stream, not the watermarked download. YouTube, Vimeo, Reddit, and X do not get that badge.

- **Format:** MP4/H.264, MP4/HEVC, MOV, WebM, MKV, M4A, or MP3.
- **Quality:** Best, 2160p, 1080p, 720p, or 480p.
- **Max size:** when the best file is larger than the cap, Fetch picks a smaller format that fits. If none does, it re-encodes with the Apple hardware encoder (`h264_videotoolbox` / `hevc_videotoolbox`) at a bitrate computed from the cap, checks the file size, and retries a little smaller if it is still over.
- **Save to:** Downloads, unless you pick another folder. The gear opens settings: clipboard watching, the menu bar extra, and engine updates.
- A sign-in error can optionally use your Safari cookies for that one download (`--cookies-from-browser safari`). macOS may ask for permission to read them. Nothing is sent anywhere except to the site you are downloading from.
- Cancel stops yt-dlp and any ffmpeg it started.

Clipboard watching reads the pasteboard change count about once a second, and only when the setting is on. It does not poll during a download’s progress; progress comes from the process pipes.

## Develop

The app is a Swift package. `FetchCore` (format choice, size math, URLs, file names, errors, progress parsing) builds on Linux with Swift 6. The Mac app target is macOS 14 only. Tests:

```bash
swift test
```

A real app, screenshots, and downloads are built on a Mac by GitHub Actions (`.github/workflows/macos.yml`, `macos-15`). That workflow downloads the engines, checks their published checksums, builds and ad-hoc signs `Fetch.app`, writes light and dark screenshots, samples idle and active memory and CPU, downloads a short public YouTube video, re-encodes it under a size cap, and tries TikTok when the runner can reach it.

From a Mac you can do the same locally:

```bash
python3 Scripts/fetch_engines.py
bash Scripts/build-app.sh
artifacts/Fetch.app/Contents/MacOS/Fetch --screenshots /tmp/fetch-screens
FETCH_SKIP_UPDATE=1 bash Scripts/e2e.sh
```

`Fetch --cli version`, `Fetch --cli metadata <url>`, and `Fetch --cli download <url> --output <dir> [--max-mb N]` drive the engine without the window.

## Limits

- One video at a time. Playlists are ignored (`--no-playlist`).
- A burned-in watermark cannot be removed. Some TikTok regions only offer a `play` format that may still have a watermark or end card; the badge stays off in that case.
- Some TikTok `bytevc1` files have no audio. Fetch probes the result and, when that happens, tries an H.264 format that includes audio.
- Instagram and other private posts need a browser sign-in. Safari cookies on recent macOS often require Full Disk Access for the app.
- WebM uses a software VP9 encoder. H.264 and HEVC use VideoToolbox, and fall back to libx264 / libx265 if VideoToolbox refuses the file.
- YouTube sometimes asks a datacenter address to sign in. Fetch then tries the TV, iOS, and mobile web clients. A home connection usually gets the normal web client. If every client asks for a sign-in, use the Safari button on the error. GitHub-hosted runners hit that wall, so the automated download test falls back to a public sample file there while still attempting YouTube.
- There is no telemetry. Fetch does not phone home except for the download itself, thumbnail images, the daily yt-dlp update check, and the YouTube solver scripts yt-dlp fetches from its own project (`ejs:github` / `ejs:npm`).
