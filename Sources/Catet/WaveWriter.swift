import Foundation
import AVFoundation
import Darwin

// PCM headers are checkpointed with every buffer, so a crash leaves readable audio.
final class WaveWriter {
    let format: AVAudioFormat
    private let converter: AVAudioConverter
    private var buffer: AVAudioPCMBuffer
    private var fd: Int32
    private(set) var framesWritten: Int64 = 0
    private var lastSync: TimeInterval = 0
    private let zeros = [UInt8](repeating: 0, count: 16_384)

    init(url: URL, source: AVAudioFormat) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: source.sampleRate, channels: source.channelCount, interleaved: true),
              let converter = AVAudioConverter(from: source, to: format),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw AudioError.capture("The audio input format is unsupported.")
        }
        self.format = format; self.converter = converter; self.buffer = buffer
        fd = open(url.path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AudioError.capture("Could not create audio file: \(String(cString: strerror(errno)))") }
        do {
            var header = Data()
            func text(_ value: String) { header.append(contentsOf: value.utf8) }
            func number<T: FixedWidthInteger>(_ value: T) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
            }
            let block = UInt16(format.channelCount * 2)
            text("RIFF"); number(UInt32(36)); text("WAVEfmt "); number(UInt32(16))
            number(UInt16(1)); number(UInt16(format.channelCount)); number(UInt32(format.sampleRate))
            number(UInt32(format.sampleRate) * UInt32(block)); number(block); number(UInt16(16))
            text("data"); number(UInt32(0))
            try header.withUnsafeBytes { try writeBytes($0.baseAddress!, count: $0.count) }
            guard fsync(fd) == 0 else { throw ioError() }
        } catch { close(fd); fd = -1; throw error }
    }

    func append(_ source: AVAudioPCMBuffer, skipping frames: Int = 0) throws {
        if source.frameLength > buffer.frameCapacity {
            guard let larger = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength) else {
                throw AudioError.capture("Could not allocate an audio conversion buffer.")
            }
            buffer = larger
        }
        try converter.convert(to: buffer, from: source)
        let skip = min(max(0, frames), Int(buffer.frameLength))
        let count = (Int(buffer.frameLength) - skip) * Int(format.channelCount) * 2
        guard count > 0, let data = buffer.audioBufferList.pointee.mBuffers.mData else { return }
        try appendBytes(data.advanced(by: skip * Int(format.channelCount) * 2), count: count)
    }

    func pad(to target: Int64) throws {
        while framesWritten < target {
            let frames = min(Int64(zeros.count / (Int(format.channelCount) * 2)), target - framesWritten)
            let count = Int(frames) * Int(format.channelCount) * 2
            try zeros.withUnsafeBytes { try appendBytes($0.baseAddress!, count: count) }
        }
    }

    private func appendBytes(_ bytes: UnsafeRawPointer, count: Int) throws {
        guard fd >= 0 else { throw AudioError.capture("The recording file is closed.") }
        let newSize = framesWritten * Int64(format.channelCount) * 2 + Int64(count)
        guard newSize <= Int64(UInt32.max) - 36 else { throw AudioError.capture("This WAV recording reached its size limit. Start a new recording.") }
        try writeBytes(bytes, count: count)
        framesWritten += Int64(count / (Int(format.channelCount) * 2))
        try checkpoint()
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSync >= 1 {
            guard fsync(fd) == 0 else { throw ioError() }
            lastSync = now
        }
    }

    private func writeBytes(_ pointer: UnsafeRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let result = Darwin.write(fd, pointer.advanced(by: offset), count - offset)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw ioError() }
            offset += result
        }
    }

    private func checkpoint() throws {
        let size = UInt32(framesWritten * Int64(format.channelCount) * 2)
        for (offset, value) in [(off_t(4), size + 36), (off_t(40), size)] {
            var value = value.littleEndian
            let result = withUnsafeBytes(of: &value) { pwrite(fd, $0.baseAddress, 4, offset) }
            guard result == 4 else { throw ioError() }
        }
    }

    func finish() throws {
        guard fd >= 0 else { return }
        defer { close(fd); fd = -1 }
        try checkpoint()
        guard fsync(fd) == 0 else { throw ioError() }
    }

    private func ioError() -> AudioError { .capture("Could not save recording: \(String(cString: strerror(errno)))") }
    deinit { try? finish() }
}
