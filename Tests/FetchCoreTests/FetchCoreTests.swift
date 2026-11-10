import XCTest
@testable import FetchCore

final class URLValidatorTests: XCTestCase {
    func testAcceptsVideoLinks() {
        let samples = [
            "https://www.youtube.com/watch?v=BaW_jenozKc",
            "https://youtu.be/BaW_jenozKc",
            "https://www.tiktok.com/@hankgreen1/video/7047596209028074758",
            "https://www.instagram.com/reel/C9xT2mQp4Lk/",
            "https://x.com/nasa/status/123",
            "https://vimeo.com/1084537",
            "https://www.reddit.com/r/videos/comments/abc/watch/",
            "http://example.com/video",
        ]
        for sample in samples {
            guard case .success = URLValidator.validate(sample) else {
                return XCTFail("rejected \(sample)")
            }
        }
    }

    func testExtractsURLFromSurroundingText() {
        let result = URLValidator.validate("look at this https://youtu.be/BaW_jenozKc.")
        guard case .success(let url) = result else { return XCTFail("no url") }
        XCTAssertEqual(url.absoluteString, "https://youtu.be/BaW_jenozKc")
    }

    func testRejectsDangerousOrLocalURLs() {
        XCTAssertEqual(URLValidator.validate("").error, .empty)
        XCTAssertEqual(URLValidator.validate("   ").error, .empty)
        XCTAssertEqual(URLValidator.validate("not a link").error, .invalid)
        XCTAssertEqual(URLValidator.validate("file:///etc/passwd").error, .invalid)
        XCTAssertEqual(URLValidator.validate("javascript:alert(1)").error, .invalid)
        XCTAssertEqual(URLValidator.validate("ftp://example.com/a").error, .invalid)
        XCTAssertEqual(URLValidator.validate("https://localhost/video").error, .localOrPrivate)
        XCTAssertEqual(URLValidator.validate("https://printer.local/a").error, .localOrPrivate)
        XCTAssertEqual(URLValidator.validate("https://127.0.0.1/a").error, .localOrPrivate)
        XCTAssertEqual(URLValidator.validate("https://10.1.2.3/a").error, .localOrPrivate)
        XCTAssertEqual(URLValidator.validate("https://192.168.1.9/a").error, .localOrPrivate)
        XCTAssertEqual(URLValidator.validate("https://172.16.0.5/a").error, .localOrPrivate)
        XCTAssertEqual(URLValidator.validate("https://169.254.4.4/a").error, .localOrPrivate)
        XCTAssertEqual(URLValidator.validate("https://user:secret@example.com/a").error, .hasUserinfo)
        let split = URLValidator.validate("https://example.com/watch\n/../etc")
        guard case .success(let splitURL) = split else { return XCTFail("newline should not sink the url") }
        XCTAssertEqual(splitURL.host, "example.com")
        XCTAssertFalse(splitURL.absoluteString.contains("\n"))
    }

    func testRejectsOverlongInput() {
        let huge = "https://example.com/" + String(repeating: "a", count: URLValidator.maxLength)
        XCTAssertEqual(URLValidator.validate(huge).error, .tooLong)
    }
}

final class FilenameSanitizerTests: XCTestCase {
    func testStripsPathAndControlCharacters() {
        let name = FilenameSanitizer.sanitize(title: "../etc/passwd\n\u{202E}hidden:name", extension: "mp4")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains("\\"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("\n"))
        XCTAssertFalse(name.contains(".."))
        XCTAssertTrue(name.hasSuffix(".mp4"))
        XCTAssertNotEqual(name, ".mp4")
    }

    func testEmptyTitleFallsBack() {
        XCTAssertEqual(FilenameSanitizer.sanitize(title: "   ", extension: "mov"), "Video.mov")
        XCTAssertEqual(FilenameSanitizer.sanitize(title: "...", extension: "mkv"), "Video.mkv")
    }

    func testRejectsUnknownExtension() {
        XCTAssertEqual(FilenameSanitizer.sanitize(title: "Clip", extension: "exe"), "Clip.mp4")
        XCTAssertEqual(FilenameSanitizer.sanitize(title: "Clip", extension: ".MP3"), "Clip.mp3")
    }

    func testLimitsLength() {
        let long = String(repeating: "A", count: 500)
        let name = FilenameSanitizer.sanitize(title: long, extension: "webm")
        XCTAssertLessThanOrEqual(name.count, FilenameSanitizer.maxStemLength + ".webm".count)
        XCTAssertTrue(name.hasSuffix(".webm"))
    }

    func testKeepsUnicodeLetters() {
        let name = FilenameSanitizer.sanitize(title: "京都の夕方", extension: "m4a")
        XCTAssertEqual(name, "京都の夕方.m4a")
    }

    func testOutputPathCannotEscape() {
        let directory = URL(fileURLWithPath: "/tmp/Fetch Downloads", isDirectory: true)
        XCTAssertEqual(OutputPath.fileURL(directory: directory, filename: "Clip.mp4").value?.lastPathComponent, "Clip.mp4")
        XCTAssertEqual(OutputPath.fileURL(directory: directory, filename: "../Clip.mp4").error, .escaped)
        XCTAssertEqual(OutputPath.fileURL(directory: directory, filename: "a/b.mp4").error, .escaped)
        XCTAssertEqual(OutputPath.fileURL(directory: directory, filename: "..").error, .emptyName)
        XCTAssertEqual(OutputPath.fileURL(directory: directory, filename: "").error, .emptyName)
    }
}

final class SizeFitTests: XCTestCase {
    func testVideoBitrateFormula() {
        // 25 MB, 47 seconds, 128 kbps audio.
        // (25_000_000 * 8 * 0.96) / 47 / 1000 - 128 = 3957
        let bitrate = SizeFitMath.videoBitrateKbps(capBytes: 25_000_000, durationSeconds: 47, audioKbps: 128)
        XCTAssertEqual(bitrate, 3957)
    }

    func testAudioBitrateDropsForLongVideos() {
        XCTAssertEqual(SizeFitMath.audioBitrateKbps(durationSeconds: 60, capBytes: nil, audioOnly: false), 128)
        XCTAssertEqual(SizeFitMath.audioBitrateKbps(durationSeconds: 20 * 60 + 1, capBytes: nil, audioOnly: false), 96)
        XCTAssertEqual(SizeFitMath.audioBitrateKbps(durationSeconds: 3601, capBytes: nil, audioOnly: false), 64)
    }

    func testAudioOnlyBitrateFollowsTheCap() {
        let bitrate = SizeFitMath.audioBitrateKbps(durationSeconds: 60, capBytes: 1_000_000, audioOnly: true)
        // (1_000_000 * 8 * 0.96) / 60 / 1000 = 128
        XCTAssertEqual(bitrate, 128)
        let tiny = SizeFitMath.audioBitrateKbps(durationSeconds: 600, capBytes: 200_000, audioOnly: true)
        XCTAssertGreaterThanOrEqual(tiny, 64)
        XCTAssertLessThanOrEqual(tiny, 320)
    }

    func testScaledHeightRespectsFloorAndDoesNotUpscale() {
        let height = SizeFitMath.scaledHeight(sourceWidth: 1920, sourceHeight: 1080, videoKbps: 400, fps: 30)
        XCTAssertEqual(height, 306)
        XCTAssertEqual(height % 2, 0)
        let plenty = SizeFitMath.scaledHeight(sourceWidth: 1280, sourceHeight: 720, videoKbps: 20_000, fps: 30)
        XCTAssertEqual(plenty, 720)
    }

    func testRetryDropsEightPercent() {
        XCTAssertEqual(SizeFitMath.retryBitrate(previousKbps: 1000), 920)
        XCTAssertEqual(SizeFitMath.retryBitrate(previousKbps: 80), 73)
    }

    func testFitFraction() {
        XCTAssertTrue(SizeFitMath.fits(bytes: 9_700_000, capBytes: 10_000_000))
        XCTAssertFalse(SizeFitMath.fits(bytes: 9_800_000, capBytes: 10_000_000))
    }
}

final class FormatSelectorTests: XCTestCase {
    func testYouTubePrefersHighestH264ThatMatchesTheContainer() {
        let plan = FormatSelector.plan(SelectionInput(
            extractorKey: "youtube",
            duration: 12,
            formats: youtubeFormats,
            container: .mp4H264,
            quality: .best,
            maxBytes: nil
        ))
        XCTAssertEqual(plan?.selector, "137+140")
        XCTAssertEqual(plan?.needsTranscode, false)
        XCTAssertEqual(plan?.noWatermark, false)
        XCTAssertEqual(plan?.vcodecLabel, "H.264")
        XCTAssertEqual(plan?.acodecLabel, "AAC")
        XCTAssertEqual(plan?.estimatedBytes, 82_000_000)
        XCTAssertEqual(plan?.height, 1080)
    }

    func testQualityCapSkipsTallerFormats() {
        let plan = FormatSelector.plan(SelectionInput(
            extractorKey: "youtube",
            duration: 12,
            formats: youtubeFormats,
            container: .mp4H264,
            quality: .p720,
            maxBytes: nil
        ))
        XCTAssertEqual(plan?.selector, "22")
        XCTAssertEqual(plan?.height, 720)
    }

    func testSizeCapPicksAFormatThatFitsBeforeTranscoding() {
        let plan = FormatSelector.plan(SelectionInput(
            extractorKey: "youtube",
            duration: 728,
            formats: youtubeFormats,
            container: .mp4H264,
            quality: .best,
            maxBytes: 50_000_000
        ))
        XCTAssertEqual(plan?.selector, "22")
        XCTAssertEqual(plan?.needsTranscode, false)
        XCTAssertEqual(plan?.estimatedBytes, 40_000_000)
    }

    func testSizeCapTranscodesWhenNothingFits() {
        let plan = FormatSelector.plan(SelectionInput(
            extractorKey: "youtube",
            duration: 728,
            formats: youtubeFormats,
            container: .mp4H264,
            quality: .best,
            maxBytes: 8_000_000
        ))
        XCTAssertEqual(plan?.needsTranscode, true)
        guard case .transcode(let recipe) = plan?.delivery else { return XCTFail("expected transcode") }
        XCTAssertEqual(recipe.videoEncoder, "h264_videotoolbox")
        XCTAssertEqual(recipe.hardware, true)
        XCTAssertTrue(recipe.constrainedBySize)
        XCTAssertGreaterThan(recipe.videoBitrateKbps ?? 0, 0)
        XCTAssertNil(plan?.estimatedBytes)
    }

    func testTikTokPrefersDirectH264AndShowsTheBadge() {
        let plan = FormatSelector.plan(SelectionInput(
            extractorKey: "TikTok",
            duration: 47,
            formats: tiktokFormats,
            container: .mp4H264,
            quality: .best,
            maxBytes: nil
        ))
        XCTAssertEqual(plan?.selector, "play_addr_h264")
        XCTAssertEqual(plan?.noWatermark, true)
        XCTAssertEqual(plan?.needsTranscode, false)
        XCTAssertEqual(plan?.estimatedBytes, 18_600_000)
    }

    func testTikTokWithoutADirectFormatDoesNotShowTheBadge() {
        let formats = tiktokFormats.filter { $0.formatID != "play_addr_h264" && $0.formatID != "play_addr_bytevc1" }
        let plan = FormatSelector.plan(SelectionInput(
            extractorKey: "TikTok",
            duration: 47,
            formats: formats,
            container: .mp4H264,
            quality: .best,
            maxBytes: nil
        ))
        XCTAssertEqual(plan?.selector, "play")
        XCTAssertEqual(plan?.noWatermark, false)
    }

    func testTikTokWatermarkedOnlyStillDownloadsWithoutTheBadge() {
        let formats = tiktokFormats.filter { $0.formatID == "download" }
        let plan = FormatSelector.plan(SelectionInput(
            extractorKey: "TikTok",
            duration: 47,
            formats: formats,
            container: .mp4H264,
            quality: .best,
            maxBytes: nil
        ))
        XCTAssertEqual(plan?.selector, "download")
        XCTAssertEqual(plan?.noWatermark, false)
    }

    func testUnsafeFormatIDsAreIgnored() {
        var evil = youtubeFormats[0]
        evil.formatID = "137;rm"
        let plan = FormatSelector.plan(SelectionInput(
            extractorKey: "youtube",
            duration: 12,
            formats: [evil],
            container: .mp4H264,
            quality: .best,
            maxBytes: nil
        ))
        XCTAssertNil(plan)
    }

    func testAudioOnlyPicksAACForM4A() {
        let plan = FormatSelector.plan(SelectionInput(
            extractorKey: "youtube",
            duration: 180,
            formats: youtubeFormats,
            container: .m4a,
            quality: .best,
            maxBytes: nil
        ))
        XCTAssertEqual(plan?.selector, "140")
        XCTAssertEqual(plan?.fileExtension, "m4a")
        XCTAssertEqual(plan?.needsTranscode, false)
    }

    func testDirectMP4WithUnknownCodecsStreamsCopy() {
        let plan = FormatSelector.plan(SelectionInput(
            extractorKey: "generic",
            duration: 10,
            formats: [MediaFormat(formatID: "mp4", ext: "mp4", filesize: 1_000_000)],
            container: .mp4H264,
            quality: .best,
            maxBytes: nil
        ))
        XCTAssertEqual(plan?.selector, "mp4")
        XCTAssertEqual(plan?.needsTranscode, false)
    }

    func testMP3TranscodesFromAAC() {
        let plan = FormatSelector.plan(SelectionInput(
            extractorKey: "youtube",
            duration: 180,
            formats: youtubeFormats,
            container: .mp3,
            quality: .best,
            maxBytes: nil
        ))
        XCTAssertEqual(plan?.needsTranscode, true)
        guard case .transcode(let recipe) = plan?.delivery else { return XCTFail("expected transcode") }
        XCTAssertEqual(recipe.audioEncoder, "libmp3lame")
        XCTAssertNil(recipe.videoEncoder)
    }

    private var youtubeFormats: [MediaFormat] {
        [
            MediaFormat(formatID: "137", ext: "mp4", vcodec: "avc1.640028", acodec: "none", width: 1920, height: 1080, filesize: 80_000_000, tbr: 4500, formatNote: "1080p"),
            MediaFormat(formatID: "303", ext: "webm", vcodec: "vp9", acodec: "none", width: 1920, height: 1080, filesize: 60_000_000, tbr: 3500, formatNote: "1080p"),
            MediaFormat(formatID: "22", ext: "mp4", vcodec: "avc1.64001F", acodec: "mp4a.40.2", width: 1280, height: 720, filesize: 40_000_000, tbr: 1500, formatNote: "720p"),
            MediaFormat(formatID: "140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", filesize: 2_000_000, abr: 128, formatNote: "medium"),
        ]
    }

    private var tiktokFormats: [MediaFormat] {
        [
            MediaFormat(formatID: "download", ext: "mp4", vcodec: "h264", acodec: "aac", width: 1080, height: 1920, filesize: 19_000_000, tbr: 2800, formatNote: "watermarked"),
            MediaFormat(formatID: "play", ext: "mp4", vcodec: "h264", acodec: "aac", width: 1080, height: 1920, filesize: 18_000_000, tbr: 2600, formatNote: nil),
            MediaFormat(formatID: "play_addr_bytevc1", ext: "mp4", vcodec: "h265", acodec: "none", width: 1080, height: 1920, filesize: 12_000_000, tbr: 2200, formatNote: "Direct video"),
            MediaFormat(formatID: "play_addr_h264", ext: "mp4", vcodec: "h264", acodec: "aac", width: 1080, height: 1920, filesize: 18_600_000, tbr: 2700, formatNote: "Direct video"),
        ]
    }
}

final class ProgressParserTests: XCTestCase {
    func testDownloadTemplate() {
        let sample = ProgressParser.parse(line: "FETCH\tdownloading\t450000\t1000000\tNA\t125000\t4")
        guard case .download(let status, let downloaded, let total, let speed, let eta) = sample?.kind else {
            return XCTFail("missing sample")
        }
        XCTAssertEqual(status, "downloading")
        XCTAssertEqual(downloaded, 450_000)
        XCTAssertEqual(total, 1_000_000)
        XCTAssertEqual(speed, 125_000)
        XCTAssertEqual(eta, 4)
        XCTAssertEqual(ProgressParser.fraction(downloaded: downloaded, total: total), 0.45)
    }

    func testNADoesNotBecomeANumber() {
        let sample = ProgressParser.parse(line: "FETCH\tdownloading\tNA\tNA\tNA\tNA\tNA")
        guard case .download(_, let downloaded, let total, _, _) = sample?.kind else { return XCTFail() }
        XCTAssertNil(downloaded)
        XCTAssertNil(total)
        XCTAssertNil(ProgressParser.fraction(downloaded: downloaded, total: total))
    }

    func testIgnoresUnrelatedLines() {
        XCTAssertNil(ProgressParser.parse(line: "[youtube] Extracting URL: https://example.com"))
        XCTAssertNil(ProgressParser.parse(line: ""))
    }

    func testPostprocessAndFFmpeg() {
        guard case .postprocess(let status) = ProgressParser.parse(line: "FETCHPP\tstarted")?.kind else { return XCTFail() }
        XCTAssertEqual(status, "started")
        guard case .ffmpegTime(let seconds) = ProgressParser.parse(line: "out_time_us=2500000")?.kind else { return XCTFail() }
        XCTAssertEqual(seconds, 2.5)
        XCTAssertEqual(ProgressParser.fraction(seconds: 2.5, duration: 10), 0.25)
        XCTAssertEqual(ProgressParser.parse(line: "progress=end")?.kind, .ffmpegEnded)
    }

    func testFractionClamps() {
        XCTAssertEqual(ProgressParser.fraction(downloaded: 50, total: 10), 1)
        XCTAssertEqual(ProgressParser.fraction(downloaded: -5, total: 10), 0)
        XCTAssertNil(ProgressParser.fraction(seconds: 1, duration: 0))
    }
}

final class ErrorMapperTests: XCTestCase {
    func testSignIn() {
        let mapped = ErrorMapper.map(output: "ERROR: [Instagram] C9x: Login required", exitCode: 1)
        XCTAssertEqual(mapped.kind, .signIn)
        XCTAssertTrue(mapped.detail.lowercased().contains("login required"))
    }

    func testPrivateRegionBotAndAge() {
        XCTAssertEqual(ErrorMapper.map(output: "ERROR: Private video", exitCode: 1).kind, .private)
        XCTAssertEqual(ErrorMapper.map(output: "Video unavailable. This video is not available in your country", exitCode: 1).kind, .region)
        XCTAssertEqual(ErrorMapper.map(output: "Sign in to confirm you're not a bot", exitCode: 1).kind, .botCheck)
        XCTAssertEqual(ErrorMapper.map(output: "ERROR: This video is age-restricted", exitCode: 1).kind, .ageRestricted)
    }

    func testEngineOutdatedAndUnsupported() {
        XCTAssertEqual(ErrorMapper.map(output: "ERROR: Unable to extract player response", exitCode: 1).kind, .engineOutdated)
        XCTAssertTrue(ErrorMapper.map(output: "ERROR: Unable to extract", exitCode: 1).suggestsEngineUpdate)
        XCTAssertEqual(ErrorMapper.map(output: "ERROR: Unsupported URL: https://example.com", exitCode: 1).kind, .unsupported)
    }

    func testNetworkCancelledAndGeneric() {
        XCTAssertEqual(ErrorMapper.map(output: "ERROR: urlopen error [Errno 60] timed out", exitCode: 1).kind, .network)
        XCTAssertEqual(ErrorMapper.map(output: "ERROR: Interrupted by the user", exitCode: 130).kind, .cancelled)
        let generic = ErrorMapper.map(output: "ERROR: something unexpected happened", exitCode: 1)
        XCTAssertEqual(generic.kind, .generic)
        XCTAssertFalse(generic.detail.contains("https://"))
    }

    func testDetailDropsURLs() {
        let mapped = ErrorMapper.map(output: "ERROR: boom https://cdn.example.com/secret-token?x=1 more", exitCode: 1)
        XCTAssertFalse(mapped.detail.contains("secret-token"))
        XCTAssertFalse(mapped.detail.contains("https://"))
    }
}

final class VideoJSONTests: XCTestCase {
    func testDecodesYTDLPDocument() throws {
        let json = """
        {"id":"abc","title":"A walk","uploader":"Kyoto","uploader_id":"kyotowalks","duration":47,
         "thumbnail":"https://cdn.example.com/a.jpg","webpage_url":"https://www.tiktok.com/x",
         "extractor":"TikTok","extractor_key":"TikTok","width":1080,"height":1920,
         "formats":[
            {"format_id":"play_addr_h264","ext":"mp4","vcodec":"h264","acodec":"aac","width":1080,"height":1920,"filesize":18600000,"format_note":"Direct video","tbr":2700},
            {"format_id":"skip-me","not":"a format"},
            "not an object",
            {"ext":"mp4"}
         ],
         "unused": true}
        """.data(using: .utf8)!
        let info = try VideoInfo.decode(json: json)
        XCTAssertEqual(info.title, "A walk")
        XCTAssertEqual(info.siteName, "TikTok")
        XCTAssertEqual(info.authorLine, "@kyotowalks")
        XCTAssertEqual(info.duration, 47)
        XCTAssertEqual(info.formats.count, 2)
        XCTAssertEqual(info.formats[0].formatID, "play_addr_h264")
        XCTAssertEqual(info.thumbnailURL?.scheme, "https")
    }

    func testDropsInsecureThumbnail() throws {
        let json = #"{"id":"a","title":"T","thumbnail":"http://insecure.example/a.jpg","formats":[]}"#.data(using: .utf8)!
        let info = try VideoInfo.decode(json: json)
        XCTAssertNil(info.thumbnailURL)
    }
}

final class ChecksumTests: XCTestCase {
    func testParsesPublishedSums() {
        let text = """
        # comment
        0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa  yt-dlp_macos
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa *yt-dlp_macos.zip
        not-a-hash  ignored
        """
        let sums = Checksum.parseSums(text)
        XCTAssertEqual(sums["yt-dlp_macos"], "0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa")
        XCTAssertEqual(sums["yt-dlp_macos.zip"]?.hasPrefix("aaa"), true)
        XCTAssertNil(sums["ignored"])
    }

    func testSHA256OfData() {
        let digest = Checksum.sha256Hex(of: Data("fetch".utf8))
        XCTAssertEqual(digest, "e7d3799ecc09f5cbc446aa0a79bb1fb9d0126395fa19a5903b7425f42e5e92e7")
        XCTAssertEqual(digest.count, 64)
    }
}

private extension Result where Failure == URLValidationError {
    var error: URLValidationError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

private extension Result where Failure == OutputPathError {
    var error: OutputPathError? {
        if case .failure(let error) = self { return error }
        return nil
    }

    var value: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
