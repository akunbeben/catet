import Foundation
import Darwin

@_silgen_name("flock")
private func codexAccountsFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

struct CodexAccount: Codable, Identifiable, Equatable {
    let id: String
    var label: String
    var retryAt: Date?
    var isAuthenticated: Bool

    init(id: String, label: String, retryAt: Date? = nil, isAuthenticated: Bool = false) {
        self.id = id
        self.label = label
        self.retryAt = retryAt
        self.isAuthenticated = isAuthenticated
    }

    private enum CodingKeys: String, CodingKey { case id, label, retryAt, isAuthenticated }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        retryAt = try values.decodeIfPresent(Date.self, forKey: .retryAt)
        isAuthenticated = try values.decodeIfPresent(Bool.self, forKey: .isAuthenticated) ?? false
    }
}

struct CodexAccountSnapshot {
    let account: CodexAccount
    let home: URL?
}

final class CodexAccounts {
    private struct Registry: Codable {
        var accounts: [CodexAccount]
        var selectedID: String
    }

    private let root: URL
    private let fileManager = FileManager.default
    private let lockURL: URL
    private let registryURL: URL

    init(root: URL) {
        self.root = root.deletingLastPathComponent().appendingPathComponent("runtime/codex-accounts", isDirectory: true)
        registryURL = self.root.appendingPathComponent("registry.json")
        lockURL = self.root.appendingPathComponent("registry.lock")
    }

    func accounts() throws -> [CodexAccount] {
        try withRegistry { registry in registry.accounts }
    }

    func selected() throws -> CodexAccountSnapshot {
        try withRegistry { registry in
            guard let account = registry.accounts.first(where: { $0.id == registry.selectedID }) else {
                throw CodexAccountsError.invalidRegistry
            }
            return try makeSnapshot(account)
        }
    }

    func snapshot(id: String) throws -> CodexAccountSnapshot {
        try withRegistry { registry in
            guard let account = registry.accounts.first(where: { $0.id == id }) else { throw CodexAccountsError.unknownAccount }
            return try makeSnapshot(account)
        }
    }

    @discardableResult
    func add(label: String) throws -> CodexAccountSnapshot {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty else { throw CodexAccountsError.emptyLabel }
        return try withRegistry(mutate: true) { registry in
            let id = UUID().uuidString.lowercased()
            let home = accountHome(id: id)
            try fileManager.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
            let account = CodexAccount(id: id, label: cleanLabel)
            registry.accounts.append(account)
            return CodexAccountSnapshot(account: account, home: home)
        }
    }

    func select(id: String) throws {
        try withRegistry(mutate: true) { registry in
            guard let account = registry.accounts.first(where: { $0.id == id }) else { throw CodexAccountsError.unknownAccount }
            if id != "default", !account.isAuthenticated { throw CodexAccountsError.needsSignIn }
            registry.selectedID = id
        }
    }

    func setRetryAt(_ date: Date?, for id: String) throws {
        try withRegistry(mutate: true) { registry in
            guard let index = registry.accounts.firstIndex(where: { $0.id == id }) else { throw CodexAccountsError.unknownAccount }
            registry.accounts[index].retryAt = date
        }
    }

    func setAuthenticated(_ authenticated: Bool, for id: String) throws {
        try withRegistry(mutate: true) { registry in
            guard let index = registry.accounts.firstIndex(where: { $0.id == id }), id != "default" else { throw CodexAccountsError.unknownAccount }
            registry.accounts[index].isAuthenticated = authenticated
        }
    }

    private func accountHome(id: String) -> URL { root.appendingPathComponent("homes", isDirectory: true).appendingPathComponent(id, isDirectory: true) }

    private func makeSnapshot(_ account: CodexAccount) throws -> CodexAccountSnapshot {
        guard account.id != "default" else { return CodexAccountSnapshot(account: account, home: nil) }
        guard account.isAuthenticated else { throw CodexAccountsError.needsSignIn }
        let home = accountHome(id: account.id)
        guard fileManager.fileExists(atPath: home.path) else { throw CodexAccountsError.missingHome }
        return CodexAccountSnapshot(account: account, home: home)
    }

    private func withRegistry<T>(mutate: Bool = false, _ body: (inout Registry) throws -> T) throws -> T {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let descriptor = lockURL.path.withCString { Darwin.open($0, O_CREAT | O_RDWR, mode_t(0o600)) }
        guard descriptor >= 0 else { throw CodexAccountsError.storage("Could not open the account registry lock.") }
        defer { _ = codexAccountsFlock(descriptor, LOCK_UN); _ = Darwin.close(descriptor) }
        guard codexAccountsFlock(descriptor, LOCK_EX) == 0 else { throw CodexAccountsError.storage("Could not lock the account registry.") }
        var registry = try loadRegistry()
        let result = try body(&registry)
        if mutate { try saveRegistry(registry) }
        return result
    }

    private func loadRegistry() throws -> Registry {
        guard fileManager.fileExists(atPath: registryURL.path) else {
            return Registry(accounts: [CodexAccount(id: "default", label: "Terminal account", isAuthenticated: true)], selectedID: "default")
        }
        do {
            var registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: registryURL))
            if !registry.accounts.contains(where: { $0.id == "default" }) {
                registry.accounts.insert(CodexAccount(id: "default", label: "Terminal account", isAuthenticated: true), at: 0)
            }
            let ids = registry.accounts.map(\.id)
            guard Set(ids).count == ids.count,
                  ids.allSatisfy({ $0 == "default" || UUID(uuidString: $0) != nil }),
                  ids.contains(registry.selectedID) else { throw CodexAccountsError.invalidRegistry }
            return registry
        } catch let error as CodexAccountsError { throw error }
        catch { throw CodexAccountsError.storage("The account registry could not be read.") }
    }

    private func saveRegistry(_ registry: Registry) throws {
        do {
            let data = try JSONEncoder().encode(registry)
            try data.write(to: registryURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registryURL.path)
        } catch { throw CodexAccountsError.storage("The account registry could not be saved.") }
    }
}

enum CodexAccountsError: LocalizedError {
    case emptyLabel, unknownAccount, needsSignIn, missingHome, invalidRegistry, storage(String)
    var errorDescription: String? {
        switch self {
        case .emptyLabel: return "Enter a name for this account."
        case .unknownAccount: return "That account is no longer available."
        case .needsSignIn: return "Sign in to this account before selecting it."
        case .missingHome: return "This account's sign-in data is missing. Sign in again."
        case .invalidRegistry: return "The selected account is no longer available."
        case .storage(let message): return message
        }
    }
}

func codexAccountEnvironment(base: [String: String], snapshot: CodexAccountSnapshot) -> [String: String] {
    var environment = base
    environment.removeValue(forKey: "OPENAI_API_KEY")
    environment.removeValue(forKey: "CODEX_API_KEY")
    environment.removeValue(forKey: "CODEX_ACCESS_TOKEN")
    if let home = snapshot.home { environment["CODEX_HOME"] = home.path }
    return environment
}

func codexAccountLockURL(root: URL, accountID: String) -> URL {
    let runtime = root.standardizedFileURL.resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .appendingPathComponent("runtime/codex-account-locks", isDirectory: true)
    let name = accountID.utf8.map { String(format: "%02x", $0) }.joined()
    return runtime.appendingPathComponent("\(name).lock")
}
