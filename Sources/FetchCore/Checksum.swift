import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum Checksum {
    /// Streaming SHA-256, hex encoded. The file is not loaded all at once.
    public static func sha256Hex(of url: URL) throws -> String {
        #if canImport(CryptoKit)
        try cryptoKitHex(of: url)
        #else
        try portableHex(of: url)
        #endif
    }

    public static func sha256Hex(of data: Data) -> String {
        #if canImport(CryptoKit)
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        var hasher = SHA256Hasher()
        hasher.update(data)
        return hasher.finalize().hex
        #endif
    }

    #if canImport(CryptoKit)
    /// Hardware SHA-256. Each chunk is drained inside an autorelease pool so a
    /// large binary does not stay resident as NSData.
    private static func cryptoKitHex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var finished = false
        while !finished {
            try autoreleasepool {
                let chunk = try handle.read(upToCount: 1024 * 1024)
                if let chunk, !chunk.isEmpty {
                    hasher.update(data: chunk)
                } else {
                    finished = true
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    #endif

    private static func portableHex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256Hasher()
        while true {
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            hasher.update(chunk)
        }
        return hasher.finalize().hex
    }

    /// Parse a `SHA2-256SUMS` line list. Names may be separated by two spaces or an asterisk.
    public static func parseSums(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "*" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let hash = parts[0].lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            let name = parts[1...].joined(separator: " ")
            result[name] = hash
        }
        return result
    }
}

/// Compact SHA-256 so FetchCore builds on Linux and macOS without CryptoKit.
struct SHA256Hasher {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var buffer = [UInt8]()
    private var bufferStart = 0
    private var bytes: UInt64 = 0

    mutating func update(_ data: Data) {
        bytes += UInt64(data.count)
        buffer.append(contentsOf: data)
        processAvailableBlocks()
    }

    mutating func finalize() -> [UInt8] {
        let bitLength = bytes &* 8
        buffer.append(0x80)
        while ((buffer.count - bufferStart) % 64) != 56 {
            buffer.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        processAvailableBlocks()
        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in state {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }

    private mutating func processAvailableBlocks() {
        while buffer.count - bufferStart >= 64 {
            let block = Array(buffer[bufferStart..<(bufferStart + 64)])
            bufferStart += 64
            compress(block)
        }
        if bufferStart > 4096 {
            buffer.removeFirst(bufferStart)
            bufferStart = 0
        }
    }

    private mutating func compress(_ block: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let j = i * 4
            w[i] = (UInt32(block[j]) << 24) | (UInt32(block[j + 1]) << 16) | (UInt32(block[j + 2]) << 8) | UInt32(block[j + 3])
        }
        for i in 16..<64 {
            let s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }
        state[0] = state[0] &+ a
        state[1] = state[1] &+ b
        state[2] = state[2] &+ c
        state[3] = state[3] &+ d
        state[4] = state[4] &+ e
        state[5] = state[5] &+ f
        state[6] = state[6] &+ g
        state[7] = state[7] &+ h
    }

    private func rotate(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value >> bits) | (value << (32 - bits))
    }
}

private extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
