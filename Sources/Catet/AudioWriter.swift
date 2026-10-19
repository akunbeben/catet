import Foundation
import AVFoundation
import Darwin

private final class EncoderDiagnostics {
    private let lock = NSLock()
    private var tail = Data()

    func append(_ data: Data) {
        lock.withLock {
            let remaining = max(0, 4096 - data.count)
            if tail.count > remaining { tail.removeFirst(tail.count - remaining) }
            tail.append(data.suffix(4096))
        }
    }

    var message: String {
        lock.withLock { String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

final class AudioWriter {
    let format: AVAudioFormat
    private let converter: AVAudioConverter
    private var buffer: AVAudioPCMBuffer
    private let process: Process
    private let input: FileHandle
    private let fileFD: Int32
    private let diagnostics = EncoderDiagnostics()
    private let exited = DispatchSemaphore(value: 0)
    private let silence: [Float]
    private var finished = false
    private(set) var framesWritten: Int64 = 0
    private var lastSync = ProcessInfo.processInfo.systemUptime

    init(url: URL, source: AVAudioFormat) throws {
        let executable = try RuntimeConfig.load().ffmpeg
        let output: AVAudioFormat?
        if let layout = source.channelLayout {
            output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate,
                                   interleaved: true, channelLayout: layout)
        } else {
            output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate,
                                   channels: source.channelCount, interleaved: true)
        }
        guard let format = output, format.channelCount > 0, format.sampleRate > 0,
              let converter = AVAudioConverter(from: source, to: format),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw AudioError.capture("The audio input format is unsupported.")
        }
        self.format = format
        self.converter = converter
        self.buffer = buffer
        silence = [Float](repeating: 0, count: 2048 * Int(format.channelCount))

        let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AudioError.capture("Could not create audio file: \(String(cString: strerror(errno)))") }
        fileFD = fd
        var sockets: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            close(fd)
            throw AudioError.capture("Could not create an Opus encoder input: \(String(cString: strerror(errno)))")
        }
        var noSignal: Int32 = 1
        guard setsockopt(sockets[1], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(sockets[0]); close(sockets[1]); close(fd)
            throw AudioError.capture("Could not protect the Opus encoder input pipe.")
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        guard setsockopt(sockets[1], SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            close(sockets[0]); close(sockets[1]); close(fd)
            throw AudioError.capture("Could not configure the audio encoder input.")
        }
        _ = fcntl(sockets[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(sockets[1], F_SETFD, FD_CLOEXEC)
        let childInput = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
        input = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)

        let errors = Pipe()
        let process = Process()
        self.process = process
        let exited = self.exited
        process.terminationHandler = { _ in exited.signal() }
        process.executableURL = executable
        let channels = (0..<format.channelCount).map { "c\($0)" }.joined(separator: "+")
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-f", "f32le", "-ar", String(Int(format.sampleRate)), "-ac", String(format.channelCount),
            "-probesize", "32", "-analyzeduration", "0", "-i", "pipe:0",
            "-map", "0:a:0", "-af", "pan=mono|c0<\(channels)", "-ac", "1", "-ar", "48000",
            "-c:a", "libopus", "-b:a", "32k", "-application", "audio",
            "-frame_duration", "20", "-page_duration", "20000", "-flush_packets", "1", "-avioflags", "direct", "-f", "ogg", url.path
        ]
        process.standardInput = childInput
        process.standardError = errors
        do {
            try process.run()
            childInput.closeFile()
        } catch {
            finished = true
            childInput.closeFile()
            input.closeFile()
            errors.fileHandleForReading.closeFile()
            close(fileFD)
            try? FileManager.default.removeItem(at: url)
            throw AudioError.capture("Could not start the Opus encoder: \(error.localizedDescription)")
        }
        errors.fileHandleForWriting.closeFile()
        let diagnostics = self.diagnostics
        DispatchQueue.global(qos: .utility).async {
            let handle = errors.fileHandleForReading
            defer { handle.closeFile() }
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                diagnostics.append(data)
            }
        }
        guard process.isRunning else {
            finished = true
            input.closeFile()
            process.waitUntilExit()
            _ = fsync(fileFD)
            close(fileFD)
            try? FileManager.default.removeItem(at: url)
            throw encoderError("The Opus encoder could not start.")
        }
    }

    func append(_ source: AVAudioPCMBuffer, skipping frames: Int = 0) throws {
        guard !finished else { throw AudioError.capture("The recording is closed.") }
        if source.frameLength > buffer.frameCapacity {
            guard let larger = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength) else {
                throw AudioError.capture("Could not allocate an audio conversion buffer.")
            }
            buffer = larger
        }
        // Only the PCM representation changes here. Preserve each callback's exact frame count.
        try converter.convert(to: buffer, from: source)
        let skip = min(max(0, frames), Int(buffer.frameLength))
        let frameCount = Int(buffer.frameLength) - skip
        let count = frameCount * Int(format.channelCount) * MemoryLayout<Float>.size
        guard count > 0, let data = buffer.audioBufferList.pointee.mBuffers.mData else { return }
        try write(data.advanced(by: skip * Int(format.channelCount) * MemoryLayout<Float>.size), count: count)
        framesWritten += Int64(frameCount)
        try syncIfNeeded()
    }

    func pad(to target: Int64) throws {
        guard !finished else { throw AudioError.capture("The recording is closed.") }
        let chunkFrames = 2048
        while framesWritten < target {
            let frames = min(Int64(chunkFrames), target - framesWritten)
            let count = Int(frames) * Int(format.channelCount) * MemoryLayout<Float>.size
            try silence.withUnsafeBytes { try write($0.baseAddress!, count: count) }
            framesWritten += frames
            try syncIfNeeded()
        }
    }

    private func write(_ bytes: UnsafeRawPointer, count: Int) throws {
        guard !finished, process.isRunning else { throw encoderError("The Opus encoder stopped unexpectedly.") }
        let fd = input.fileDescriptor
        var offset = 0
        while offset < count {
            let result = Darwin.write(fd, bytes.advanced(by: offset), count - offset)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw encoderError("Could not send audio to the Opus encoder: \(String(cString: strerror(errno)))") }
            offset += result
            guard process.isRunning else { throw encoderError("The Opus encoder stopped unexpectedly.") }
        }
    }

    private func syncIfNeeded() throws {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSync >= 1 else { return }
        guard fsync(fileFD) == 0 else { throw ioError() }
        lastSync = now
    }

    func finish() throws {
        guard !finished else { return }
        finished = true
        input.closeFile()
        defer { close(fileFD) }
        if exited.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            _ = fsync(fileFD)
            throw encoderError("The audio encoder did not finish. Available audio was preserved.")
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
            _ = fsync(fileFD)
            throw encoderError("The audio encoder failed to finalize the recording.")
        }
        guard fsync(fileFD) == 0 else { throw ioError() }
    }

    private func encoderError(_ message: String) -> AudioError {
        let details = diagnostics.message
        if !details.isEmpty { fputs("catet: audio encoder: \(details)\n", stderr) }
        return .capture(message)
    }

    private func ioError() -> AudioError { .capture("Could not save recording: \(String(cString: strerror(errno)))") }
    deinit { try? finish() }
}
