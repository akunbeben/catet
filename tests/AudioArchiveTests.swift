import Foundation
import Darwin

@_silgen_name("flock")
private func archiveTestFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

struct AudioArchiveFailure: Error { let message: String }

@main
struct AudioArchiveTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw AudioArchiveFailure(message: message) }
    }

    static func run(_ executable: URL, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw AudioArchiveFailure(message: "Usage: AudioArchiveTests ENGINE FFMPEG") }
        let engine = URL(fileURLWithPath: CommandLine.arguments[1])
        let ffmpeg = URL(fileURLWithPath: CommandLine.arguments[2])
        guard FileManager.default.isExecutableFile(atPath: engine.path), FileManager.default.isExecutableFile(atPath: ffmpeg.path) else {
            print("SKIP: ffmpeg or engine executable is unavailable")
            return
        }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("catet-audio-archive-\(UUID().uuidString)")
        let temp = workspace.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        func meeting(_ name: String) throws -> URL {
            let directory = temp.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let metadata: [String: Any] = ["id": name, "title": name, "status": "recorded"]
            try JSONSerialization.data(withJSONObject: metadata).write(to: directory.appendingPathComponent("meeting.json"))
            return directory
        }
        func makeWav(_ directory: URL, _ name: String, _ frequency: String) throws {
            let result = try run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=\(frequency):sample_rate=48000:duration=2", "-ac", "1", "-c:a", "pcm_s16le", directory.appendingPathComponent(name).path, "-y"])
            guard result.0 == 0 else { throw AudioArchiveFailure(message: "Could not generate WAV fixture: \(result.1)") }
        }
        func compact(_ directory: URL) throws -> Int32 {
            try run(engine, ["--root", temp.path, "compact", directory.path]).0
        }
        func exists(_ directory: URL, _ name: String) -> Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        func decodedSampleBytes(_ directory: URL, _ name: String) throws -> Int {
            let output = temp.appendingPathComponent(UUID().uuidString + ".pcm")
            defer { try? FileManager.default.removeItem(at: output) }
            let result = try run(ffmpeg, ["-v", "error", "-i", directory.appendingPathComponent(name).path, "-f", "s16le", "-ac", "1", "-ar", "48000", output.path, "-y"])
            guard result.0 == 0 else { throw AudioArchiveFailure(message: "Archived Opus did not fully decode: \(result.1)") }
            return try Data(contentsOf: output).count
        }

        let recovered = try meeting("mixed-recovery")
        try makeWav(recovered, "microphone.wav", "440")
        try makeWav(recovered, "system.wav", "660")
        // One captured channel was already archived before the interrupted compaction.
        let microphoneArchive = recovered.appendingPathComponent("microphone.ogg")
        let archiveResult = try run(ffmpeg, ["-v", "error", "-i", recovered.appendingPathComponent("microphone.wav").path, "-ac", "1", "-c:a", "libopus", "-b:a", "32k", microphoneArchive.path, "-y"])
        guard archiveResult.0 == 0 else { throw AudioArchiveFailure(message: "Could not generate mixed-channel fixture: \(archiveResult.1)") }
        try FileManager.default.removeItem(at: recovered.appendingPathComponent("microphone.wav"))
        try Data("obsolete".utf8).write(to: recovered.appendingPathComponent("audio.wav"))
        try check(try compact(recovered) == 0, "Mixed archived/WAV compaction should succeed")
        for channel in ["microphone", "system"] {
            try check(exists(recovered, channel + ".ogg") && !exists(recovered, channel + ".wav"), "\(channel) must publish validated Opus before removing WAV")
            try check(try decodedSampleBytes(recovered, channel + ".ogg") == 192000, "\(channel) Opus must retain two seconds of mono 48 kHz samples")
        }
        try check(!exists(recovered, "audio.wav"), "Obsolete derived audio.wav must be removed after usable channel publication")
        try check(try compact(recovered) == 0, "Repeated compaction should be idempotent")
        try check(try decodedSampleBytes(recovered, "microphone.ogg") == 192000, "Repeated compaction must retain the archive")
        print("PASS: mixed archive recovery, aligned channel duration, validated conversion, and idempotent cleanup")

        let failed = try meeting("failed-conversion")
        try Data("not a WAV".utf8).write(to: failed.appendingPathComponent("microphone.wav"))
        try check(try compact(failed) != 0, "Invalid WAV conversion must fail")
        try check(exists(failed, "microphone.wav") && !exists(failed, "microphone.ogg"), "Failed conversion must preserve the source WAV and publish no archive")
        print("PASS: conversion failure preserves source WAV")
        let conflicting = try meeting("existing-invalid-archive")
        try makeWav(conflicting, "microphone.wav", "510")
        try Data("invalid archive".utf8).write(to: conflicting.appendingPathComponent("microphone.ogg"))
        try check(try compact(conflicting) == 0, "A valid WAV source must replace a stale invalid Ogg")
        try check(!exists(conflicting, "microphone.wav"), "The WAV should be removed only after its replacement archive validates")
        try check(try decodedSampleBytes(conflicting, "microphone.ogg") == 192000,
                  "Replacement of an invalid prior Ogg must preserve the WAV's full duration")
        print("PASS: stale Ogg is replaced from authoritative WAV and validated before source removal")

        let locked = try meeting("lock-held")
        try makeWav(locked, "microphone.wav", "720")
        let locks = workspace.appendingPathComponent("runtime/locks", isDirectory: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let lockURL = locks.appendingPathComponent("lock-held.lock")
        let lockFD = lockURL.path.withCString { Darwin.open($0, O_CREAT | O_RDWR, mode_t(0o600)) }
        guard lockFD >= 0, archiveTestFlock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw AudioArchiveFailure(message: "Could not hold the canonical meeting lock fixture")
        }
        defer { _ = archiveTestFlock(lockFD, LOCK_UN); _ = Darwin.close(lockFD) }
        try check(try compact(locked) != 0, "Compaction must reject a meeting with its canonical lock held")
        try check(exists(locked, "microphone.wav") && !exists(locked, "microphone.ogg"), "Lock rejection must leave source audio untouched")
        print("PASS: held canonical meeting lock rejects compaction without changing sources")
    }
}
