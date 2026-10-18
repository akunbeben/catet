import Foundation
import Darwin

private let archiveSources = ["microphone.wav", "system.wav", "input.wav"]

private func archiveError(_ operation: String, at url: URL) -> EngineError {
    let code = errno
    return EngineError("\(operation) \(url.path): \(String(cString: strerror(code)))")
}

private func decodedSampleCount(_ input: URL, config: RuntimeConfig, directory: URL) throws -> Int64 {
    let pcm = directory.appendingPathComponent(".archive-\(UUID().uuidString).pcm")
    defer { try? FileManager.default.removeItem(at: pcm) }
    let args = ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-y", "-i", input.path,
                "-map", "0:a:0", "-f", "s16le", "-ac", "1", "-ar", "48000", pcm.path]
    try checkCommand(runCommand(config.ffmpeg, arguments: args), label: "audio archive validation")
    let attrs: [FileAttributeKey: Any]
    do { attrs = try FileManager.default.attributesOfItem(atPath: pcm.path) }
    catch { throw EngineError("Audio could not be fully decoded for archive validation: \(input.path): \(error)") }
    guard let size = attrs[.size] as? NSNumber, size.int64Value > 0, size.int64Value.isMultiple(of: 2) else {
        throw EngineError("Audio archive validation produced no complete samples: \(input.path)")
    }
    return size.int64Value / 2
}

private func publishArchive(_ temporary: URL, to destination: URL) throws {
    let fd = temporary.path.withCString { Darwin.open($0, O_RDONLY) }
    guard fd >= 0 else { throw archiveError("Cannot open audio archive for syncing", at: temporary) }
    guard Darwin.fsync(fd) == 0 else {
        let error = archiveError("Cannot sync audio archive", at: temporary)
        _ = Darwin.close(fd)
        throw error
    }
    _ = Darwin.close(fd)
    let result = temporary.path.withCString { source in
        destination.path.withCString { target in Darwin.rename(source, target) }
    }
    guard result == 0 else { throw archiveError("Cannot publish audio archive", at: destination) }
    let directoryFD = destination.deletingLastPathComponent().path.withCString { Darwin.open($0, O_RDONLY) }
    if directoryFD >= 0 {
        _ = Darwin.fsync(directoryFD)
        _ = Darwin.close(directoryFD)
    }
}

private func archive(_ source: URL, config: RuntimeConfig, directory: URL) throws -> URL {
    let destination = source.deletingPathExtension().appendingPathExtension("ogg")
    let sourceSamples = try decodedSampleCount(source, config: config, directory: directory)
    let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let args = ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-y", "-i", source.path,
                "-map", "0:a:0", "-ac", "1", "-c:a", "libopus", "-b:a", "32k", "-f", "ogg", temporary.path]
    try checkCommand(runCommand(config.ffmpeg, arguments: args), label: "audio archive conversion")
    let archivedSamples = try decodedSampleCount(temporary, config: config, directory: directory)
    guard archivedSamples == sourceSamples else {
        throw EngineError("Audio archive sample count does not match its source (\(sourceSamples) vs \(archivedSamples)): \(source.path)")
    }
    try publishArchive(temporary, to: destination)
    do { try FileManager.default.removeItem(at: source) }
    catch { throw EngineError("Validated audio archive is ready, but the source could not be removed at \(source.path): \(error)") }
    return destination
}

private func importedAudio(in directory: URL) -> [URL] {
    let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
    return entries.filter {
        $0.lastPathComponent.hasPrefix("input.") && audioExtensions.contains($0.pathExtension.lowercased()) &&
            ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true)
    }.sorted { lhs, rhs in
        if lhs.pathExtension.lowercased() == "wav" && rhs.pathExtension.lowercased() == "ogg" { return true }
        if lhs.pathExtension.lowercased() == "ogg" && rhs.pathExtension.lowercased() == "wav" { return false }
        return lhs.lastPathComponent < rhs.lastPathComponent
    }
}

func compactAudio(in directory: URL, config: RuntimeConfig) throws {
    var validatedArchives = Set<String>()
    for name in archiveSources {
        let source = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: source.path) else { continue }
        let output = try archive(source, config: config, directory: directory)
        validatedArchives.insert(output.lastPathComponent)
    }

    var hasUsableCanonicalAudio = false
    for name in ["microphone.ogg", "system.ogg", "input.ogg"] {
        let audio = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: audio.path) else { continue }
        if !validatedArchives.contains(name) { _ = try decodedSampleCount(audio, config: config, directory: directory) }
        hasUsableCanonicalAudio = true
    }
    if let imported = importedAudio(in: directory).first, imported.pathExtension.lowercased() != "wav",
       !validatedArchives.contains(imported.lastPathComponent) {
        _ = try decodedSampleCount(imported, config: config, directory: directory)
        hasUsableCanonicalAudio = true
    }
    guard hasUsableCanonicalAudio else { return }
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("audio.wav"))
}

func compactMeeting(_ directory: URL, root: URL, config: RuntimeConfig) throws -> URL {
    let meeting = try validateMeeting(directory)
    let lock = try MeetingLock(directory: meeting, root: root)
    defer { lock.unlock() }
    try compactAudio(in: meeting, config: config)
    return meeting
}
