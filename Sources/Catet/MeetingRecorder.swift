import Foundation
import AVFoundation
import ScreenCaptureKit
import Darwin
import AudioToolbox
import CoreMedia

final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onState: ((Bool, Bool) -> Void)?
    var onIssue: ((CaptureIssue) -> Void)?
    // All mutable capture state is protected by stateLock, including buffer writes.
    private let stateLock = NSLock()
    private let audioQueue = DispatchQueue(label: "catet.system.audio")
    private let lifecycle = DispatchQueue(label: "catet.capture.lifecycle")
    private var micEngine: AVAudioEngine?
    private var microphone: WaveWriter?
    private var systemAudio: WaveWriter?
    private var systemBuffer: AVAudioPCMBuffer?
    private var generation = UUID()
    private var stream: SCStream?
    private var directory: URL?
    private var micRunning = false
    private var systemRunning = false
    private var systemFailed = false
    private var stopped = true
    private var startHostTime: Double?
    private var recordingLockFD: Int32 = -1

    func start(directory: URL, includeSystemAudio: Bool = true, meetingLockHeld: Bool = false, completion: @escaping (Result<Void, Error>) -> Void) {
        let token = UUID()
        do {
            try stateLock.withLock {
                guard stopped, recordingLockFD < 0 else { throw AudioError.capture("A recording is already active.") }
                if !meetingLockHeld {
                    let locks = directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("runtime/locks")
                    try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
                    let path = locks.appendingPathComponent(directory.lastPathComponent + ".lock").path
                    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
                    guard fd >= 0 else { throw AudioError.capture("Could not create the recording lock.") }
                    guard catetFlock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw AudioError.capture("This meeting is already being processed.") }
                    var pid = "\(getpid())\n"
                    _ = ftruncate(fd, 0)
                    _ = pid.withUTF8 { Darwin.write(fd, $0.baseAddress, $0.count) }
                    recordingLockFD = fd
                }
                self.directory = directory; generation = token; stopped = false; systemFailed = false; startHostTime = nil
            }
        } catch { completion(.failure(error)); return }
        Task { [self] in
            do {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard allowed else { throw AudioError.capture("Microphone access is denied. Enable Catet in System Settings → Privacy & Security → Microphone, then retry.") }
                guard stateLock.withLock({ generation == token && !stopped }) else { return }
                try lifecycle.sync { try startMicrophone(directory: directory, token: token) }
                if !includeSystemAudio {
                    emit()
                    completion(.success(()))
                    return
                }
                emit()
                do { try await startSystemCapture(directory: directory, token: token) }
                catch {
                    guard stateLock.withLock({ generation == token && !stopped }) else { return }
                    stateLock.withLock { systemRunning = false; systemFailed = true }
                    reportIssue(CaptureIssue(source: .systemAudio, error: error))
                    completion(.success(()))
                    return
                }
                guard stateLock.withLock({ generation == token && !stopped }) else { return }
                emit()
                completion(.success(()))
            } catch {
                guard stateLock.withLock({ generation == token && !stopped }) else { return }
                completion(.failure(error))
            }
        }
    }

    private func startMicrophone(directory: URL, token: UUID) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw AudioError.capture("No microphone input is available.") }
        let writer = try WaveWriter(url: directory.appendingPathComponent("microphone.wav"), source: format)
        try stateLock.withLock {
            guard generation == token, !stopped else { throw AudioError.capture("Recording stopped.") }
            microphone = writer; micEngine = engine; micRunning = true
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self else { return }
            do {
                try self.stateLock.withLock {
                    guard self.generation == token, !self.stopped, self.micRunning else { return }
                    if self.startHostTime == nil {
                        self.startHostTime = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
                    }
                    try self.microphone?.append(buffer)
                }
            } catch {
                self.reportIssue(CaptureIssue(source: .microphone, error: error))
            }
        }
        engine.prepare()
        try engine.start()
    }

    private func startSystemCapture(directory: URL, token: UUID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AudioError.capture("No display is available for system audio capture.") }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        configuration.capturesAudio = true; configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000; configuration.channelCount = 2; configuration.showsCursor = false
        let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stateLock.withLock {
            guard generation == token, !stopped else { throw AudioError.capture("Recording stopped.") }
            stream = capture
        }
        try await capture.startCapture()
        let wasStopped = stateLock.withLock { () -> Bool in
            if generation == token && !stopped { systemRunning = true }
            return generation != token || stopped
        }
        if wasStopped { try? await capture.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        do {
            try stateLock.withLock {
                guard stream === self.stream, !stopped, !systemFailed, let directory, let startHostTime,
                      let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                      let format = AVAudioFormat(streamDescription: asbd) else { return }
                if systemAudio == nil { systemAudio = try WaveWriter(url: directory.appendingPathComponent("system.wav"), source: format) }
                guard let writer = systemAudio else { return }
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                guard pts.isFinite else { throw AudioError.capture("System audio timestamps are unavailable.") }
                let target = max(0, Int64(((pts - startHostTime) * format.sampleRate).rounded()))
                try writer.pad(to: target)
                let count = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
                if systemBuffer == nil || systemBuffer!.frameCapacity < count || systemBuffer!.format != format {
                    systemBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)
                }
                guard let pcm = systemBuffer else { throw AudioError.capture("Could not allocate a system audio buffer.") }
                pcm.frameLength = count
                let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList)
                guard result == noErr else { throw AudioError.capture("Could not read system audio (\(result)).") }
                try writer.append(pcm, skipping: Int(max(0, writer.framesWritten - target)))
            }
        } catch {
            reportIssue(CaptureIssue(source: .systemAudio, error: error))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let unexpected = stateLock.withLock { () -> Bool in
            guard stream === self.stream else { return false }
            systemRunning = false; systemFailed = true
            return !stopped
        }
        if unexpected { reportIssue(CaptureIssue(source: .systemAudio, error: error)) }
    }

    func stop(completion: @escaping (Result<Void, Error>) -> Void) {
        lifecycle.async { [self] in
            let capture = stateLock.withLock { () -> (AVAudioEngine?, SCStream?) in
                stopped = true
                let result = (micEngine, stream)
                micEngine = nil; stream = nil; micRunning = false; systemRunning = false
                return result
            }
            // Stop the hardware before closing writers.
            if let engine = capture.0 { engine.inputNode.removeTap(onBus: 0); engine.stop(); engine.reset() }
            Task { [self] in
                if let stream = capture.1 { try? await stream.stopCapture() }
                let result = self.finishRecording()
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private func finishRecording() -> Result<Void, Error> {
        stateLock.withLock {
            defer {
                microphone = nil; systemAudio = nil; systemBuffer = nil
                if recordingLockFD >= 0 { _ = catetFlock(recordingLockFD, LOCK_UN); close(recordingLockFD); recordingLockFD = -1 }
            }
            do {
                if let microphone, let systemAudio {
                    let duration = Double(microphone.framesWritten) / microphone.format.sampleRate
                    try systemAudio.pad(to: Int64((duration * systemAudio.format.sampleRate).rounded()))
                }
                try microphone?.finish(); try systemAudio?.finish()
                return .success(())
            } catch { return .failure(error) }
        }
    }

    private func reportIssue(_ issue: CaptureIssue) {
        let location = stateLock.withLock { () -> URL? in
            if issue.source == .microphone { micRunning = false }
            else { systemRunning = false; systemFailed = true }
            return directory
        }
        if let path = location?.appendingPathComponent("capture.log") {
            do {
                let fd = open(path.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
                guard fd >= 0 else { throw AudioError.capture("Could not save capture diagnostics.") }
                defer { close(fd) }
                let data = Array(issue.diagnostic.utf8)
                let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                guard written == data.count, fsync(fd) == 0 else { throw AudioError.capture("Could not finish saving capture diagnostics.") }
            } catch { fputs("Catet: \(error.localizedDescription)\n", stderr) }
        }
        emit()
        DispatchQueue.main.async { [weak self] in self?.onIssue?(issue) }
    }

    private func emit() {
        let state = stateLock.withLock { (micRunning, systemRunning) }
        DispatchQueue.main.async { [weak self] in self?.onState?(state.0, state.1) }
    }
}

enum AudioError: LocalizedError {
    case capture(String)
    var errorDescription: String? { switch self { case .capture(let message): return message } }
}
