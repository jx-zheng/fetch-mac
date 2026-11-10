import Foundation

/// Size math from the approved scope.
///
/// A format is a direct fit when its known size is at most `cap * fitFraction`.
/// Otherwise the video bitrate is `(cap * 8 * containerFactor / duration) - audio`,
/// and a retry multiplies that bitrate by `retryFactor`.
public enum SizeFitMath {
    public static let containerFactor = 0.96
    public static let fitFraction = 0.97
    public static let retryFactor = 0.92
    public static let bitsPerPixelFloor = 0.08

    public static func fits(bytes: Int, capBytes: Int) -> Bool {
        guard capBytes > 0, bytes > 0 else { return false }
        return bytes <= Int((Double(capBytes) * fitFraction).rounded(.down))
    }

    public static func videoBitrateKbps(capBytes: Int, durationSeconds: Double, audioKbps: Int) -> Int {
        guard capBytes > 0, durationSeconds > 0.25 else { return 800 }
        let totalKbps = (Double(capBytes) * 8.0 * containerFactor) / durationSeconds / 1000.0
        let video = Int((totalKbps - Double(max(0, audioKbps))).rounded(.down))
        return max(80, video)
    }

    /// 128 kbps normally, 96 kbps past 20 minutes, 64 kbps past an hour.
    /// Audio-only targets the cap instead, clamped to 64...320 kbps.
    public static func audioBitrateKbps(durationSeconds: Double, capBytes: Int?, audioOnly: Bool) -> Int {
        if audioOnly, let capBytes, capBytes > 0, durationSeconds > 0.25 {
            let kbps = (Double(capBytes) * 8.0 * containerFactor) / durationSeconds / 1000.0
            return min(320, max(64, Int(kbps.rounded(.down))))
        }
        if durationSeconds > 3600 { return 64 }
        if durationSeconds > 20 * 60 { return 96 }
        return 128
    }

    /// Even height that keeps bits-per-pixel above the floor, never upscaling.
    public static func scaledHeight(
        sourceWidth: Int,
        sourceHeight: Int,
        videoKbps: Int,
        fps: Double = 30,
        bitsPerPixelFloor: Double = SizeFitMath.bitsPerPixelFloor
    ) -> Int {
        guard sourceWidth > 0, sourceHeight > 0, videoKbps > 0 else {
            return max(144, sourceHeight - sourceHeight % 2)
        }
        let aspect = Double(sourceWidth) / Double(sourceHeight)
        let pixelsPerFrame = (Double(videoKbps) * 1000.0) / (bitsPerPixelFloor * max(fps, 1))
        let height = (pixelsPerFrame / aspect).squareRoot()
        var target = Int((height / 2.0).rounded(.down)) * 2
        let evenSource = sourceHeight - sourceHeight % 2
        target = min(target, max(evenSource, 2))
        return max(144, target)
    }

    public static func retryBitrate(previousKbps: Int) -> Int {
        max(64, Int((Double(previousKbps) * retryFactor).rounded(.down)))
    }
}
