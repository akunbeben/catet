import Foundation

struct RuntimeConfigurationError: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
    init(_ description: String) { self.description = description }
}

struct RuntimeConfig {
    let ffmpeg: URL
    let whisper: URL
    let model: URL
    let vad: URL
    let codex: URL

    static func load() throws -> RuntimeConfig {
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            executableDirectory.appendingPathComponent("../Resources/runtime.json").standardizedFileURL,
            executableDirectory.appendingPathComponent("runtime.json"),
            executableDirectory.deletingLastPathComponent().appendingPathComponent("runtime.json"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("runtime.json")
        ]
        guard let configURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw RuntimeConfigurationError("runtime.json was not found in the app Resources directory or beside the development executable.")
        }
        let data: Data
        do { data = try Data(contentsOf: configURL) }
        catch { throw RuntimeConfigurationError("Cannot read \(configURL.path): \(error)") }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw RuntimeConfigurationError("Cannot parse \(configURL.path): \(error)") }
        guard let raw = object as? [String: Any] else { throw RuntimeConfigurationError("runtime.json must contain a JSON object.") }
        func path(_ key: String) throws -> URL {
            guard let value = raw[key] as? String, !value.isEmpty else {
                throw RuntimeConfigurationError("runtime.json must define an absolute \(key) path.")
            }
            guard value.hasPrefix("/") else { throw RuntimeConfigurationError("runtime.json \(key) path must be absolute: \(value)") }
            return URL(fileURLWithPath: value)
        }
        return try RuntimeConfig(ffmpeg: path("ffmpeg"), whisper: path("whisper"), model: path("model"), vad: path("vad"), codex: path("codex"))
    }
}
