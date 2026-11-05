import Foundation

struct KnowledgeBaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A user-chosen plain text file that gives meeting notes the team's names and terms.
enum KnowledgeBase {
    static let maximumBytes = 50_000

    static func settingsURL(root: URL) -> URL {
        root.standardizedFileURL.deletingLastPathComponent().appendingPathComponent("settings.json")
    }

    static func path(root: URL) throws -> URL? {
        let url = settingsURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw KnowledgeBaseError(message: "settings.json must contain a JSON object.")
        }
        guard let path = object["knowledge_base"] as? String, !path.isEmpty else { return nil }
        guard path.hasPrefix("/") else { throw KnowledgeBaseError(message: "The knowledge base path must be absolute.") }
        return URL(fileURLWithPath: path)
    }

    static func setPath(_ path: URL?, root: URL) throws {
        let url = settingsURL(root: root)
        // A damaged settings file is replaced so the user can always reset the choice.
        var object = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        object["knowledge_base"] = path?.standardizedFileURL.path
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }

    static func read(_ url: URL) throws -> String {
        let name = url.lastPathComponent
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch { throw KnowledgeBaseError(message: "\(name) could not be opened.") }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw KnowledgeBaseError(message: "\(name) is not a regular file.")
        }
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
            throw KnowledgeBaseError(message: "\(name) is larger than 50 KB.")
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw KnowledgeBaseError(message: "\(name) could not be read.") }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw KnowledgeBaseError(message: "\(name) is not a UTF-8 text file.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
