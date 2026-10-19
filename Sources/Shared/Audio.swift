import Foundation

struct AudioFileError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Opus granule positions count 48 kHz samples, independently of the input device rate.
/// Only complete, checksummed pages are published. A partly written final page is ignored.
enum AudioFile {
    private static let maximumPageSize = 65_307
    private static let checksumTable: [UInt32] = (0..<256).map { value in
        var remainder = UInt32(value) << 24
        for _ in 0..<8 {
            remainder = (remainder << 1) ^ ((remainder & 0x8000_0000) != 0 ? 0x04c1_1db7 : 0)
        }
        return remainder
    }

    static func duration(at url: URL) throws -> TimeInterval {
        Double(try frameCount(at: url)) / 48_000
    }

    static func frameCount(at url: URL) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 27 else { return 0 }
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: Int(min(size, UInt64(maximumPageSize)))) ?? Data()
        return try head.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard hasSignature(bytes, at: 0) else {
                throw AudioFileError(message: "\(url.lastPathComponent) is not an Ogg recording.")
            }
            guard let firstPage = pageLength(bytes, at: 0) else { return 0 }
            guard checksumIsValid(bytes, at: 0, length: firstPage) else {
                throw AudioFileError(message: "\(url.lastPathComponent) has a damaged Ogg header.")
            }
            let packet = 27 + Int(bytes[26])
            let opusHead: [UInt8] = [79, 112, 117, 115, 72, 101, 97, 100]
            guard packet + 19 <= firstPage,
                  (0..<8).allSatisfy({ bytes[packet + $0] == opusHead[$0] }) else {
                throw AudioFileError(message: "\(url.lastPathComponent) is not an Ogg Opus recording.")
            }
            let preSkip = Int64(bytes[packet + 10]) | (Int64(bytes[packet + 11]) << 8)
            let serial = uint32(bytes, at: 14)
            // A partial page plus its preceding complete page fits in this bounded tail read.
            let tailSize = Int(min(size, UInt64(maximumPageSize * 2)))
            try handle.seek(toOffset: size - UInt64(tailSize))
            let tail = try handle.read(upToCount: tailSize) ?? Data()
            return tail.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                var offset = 0
                var granule: Int64 = 0
                while offset + 27 <= bytes.count {
                    guard hasSignature(bytes, at: offset), uint32(bytes, at: offset + 14) == serial,
                          let length = pageLength(bytes, at: offset),
                          checksumIsValid(bytes, at: offset, length: length) else {
                        offset += 1
                        continue
                    }
                    var position: UInt64 = 0
                    for byte in 0..<8 { position |= UInt64(bytes[offset + 6 + byte]) << (byte * 8) }
                    if position <= UInt64(Int64.max) { granule = Int64(position) }
                    offset += length
                }
                return max(0, granule - preSkip)
            }
        }
    }

    private static func hasSignature(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Bool {
        offset + 27 <= bytes.count && bytes[offset] == 79 && bytes[offset + 1] == 103
            && bytes[offset + 2] == 103 && bytes[offset + 3] == 83 && bytes[offset + 4] == 0
    }

    private static func pageLength(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Int? {
        guard offset + 27 <= bytes.count else { return nil }
        let segments = Int(bytes[offset + 26])
        guard offset + 27 + segments <= bytes.count else { return nil }
        var length = 27 + segments
        for index in 0..<segments { length += Int(bytes[offset + 27 + index]) }
        return offset + length <= bytes.count ? length : nil
    }

    private static func uint32(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func checksumIsValid(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int, length: Int) -> Bool {
        let expected = uint32(bytes, at: offset + 22)
        var checksum: UInt32 = 0
        for index in 0..<length {
            let byte: UInt8 = (22..<26).contains(index) ? 0 : bytes[offset + index]
            checksum = (checksum << 8) ^ checksumTable[Int(((checksum >> 24) ^ UInt32(byte)) & 0xff)]
        }
        return checksum == expected
    }
}
