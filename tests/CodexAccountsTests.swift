import Foundation
import Darwin

struct AccountTestFailure: Error { let message: String }

@main struct CodexAccountsRegressionTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw AccountTestFailure(message: message) }
    }
    static func rejects(_ action: () throws -> Void, _ message: String) throws {
        do { try action() } catch { return }
        throw AccountTestFailure(message: message)
    }
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 5, args[1] == "--set-cooldown" {
            let registry = CodexAccounts(root: URL(fileURLWithPath: args[2]))
            for _ in 0..<30 { try registry.setRetryAt(Date(timeIntervalSince1970: Double(args[4])!), for: args[3]) }
            return
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("catet-accounts-regression-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("meetings")
        let registry = CodexAccounts(root: root)
        let terminal = try registry.selected()
        try check(terminal.account.id == "default" && terminal.home == nil, "Existing terminal sign-in remains available without copying credentials")
        let first = try registry.add(label: "Personal"), second = try registry.add(label: "Work")
        try rejects({ try registry.select(id: first.account.id) }, "An account cannot be selected before sign-in")
        try registry.setAuthenticated(true, for: first.account.id)
        try registry.setAuthenticated(true, for: second.account.id)
        try registry.select(id: first.account.id)
        let selected = try CodexAccounts(root: root).selected()
        try check(selected.account.id == first.account.id && selected.home != second.home, "Saved selection survives reopen and account credential homes remain isolated")
        let base = ["OPENAI_API_KEY": "never-use-api", "CODEX_API_KEY": "never-use-api", "CODEX_ACCESS_TOKEN": "never-use-token", "CODEX_HOME": "/terminal-home", "PATH": "/usr/bin"]
        let isolated = codexAccountEnvironment(base: base, snapshot: selected)
        try check(isolated["CODEX_HOME"] == selected.home?.path && isolated["OPENAI_API_KEY"] == nil && isolated["CODEX_API_KEY"] == nil && isolated["CODEX_ACCESS_TOKEN"] == nil, "Isolated requests use their own login and cannot fall back to paid API credentials")
        try check(codexAccountEnvironment(base: base, snapshot: terminal)["CODEX_HOME"] == "/terminal-home", "Default account preserves the terminal's credential location")
        try rejects({ _ = try registry.snapshot(id: "../outside") }, "Unknown account IDs never resolve an arbitrary credential home")
        print("PASS: Persisted manual selection, credential isolation, and API-key exclusion")

        let executable = URL(fileURLWithPath: args[0]).standardizedFileURL
        let values: [(String, Int)] = [(first.account.id, 2_000_000_000), (second.account.id, 2_000_000_500)]
        let processes = try values.map { id, timestamp -> Process in
            let process = Process(); process.executableURL = executable
            process.arguments = ["--set-cooldown", root.path, id, String(timestamp)]
            try process.run(); return process
        }
        for process in processes { process.waitUntilExit(); try check(process.terminationStatus == 0, "Concurrent account registry writer must finish") }
        for (id, timestamp) in values {
            try check(try registry.snapshot(id: id).account.retryAt == Date(timeIntervalSince1970: Double(timestamp)), "Concurrent updates must preserve both account cooldowns")
        }
        try check(try registry.selected().account.id == first.account.id, "Cooldown updates must not rotate the selected account")
        let runtime = temporary.appendingPathComponent("runtime/codex-accounts")
        let attributes = try FileManager.default.attributesOfItem(atPath: runtime.path)
        let registryAttributes = try FileManager.default.attributesOfItem(atPath: runtime.appendingPathComponent("registry.json").path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 && (registryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Account directory and registry must remain private")
        try registry.setAuthenticated(false, for: first.account.id)
        try rejects({ _ = try registry.selected() }, "Expired selected account must fail explicitly rather than switching to another account")
        print("PASS: Cross-process cooldown updates, private storage, and no silent account fallback")
        let registryURL = runtime.appendingPathComponent("registry.json")
        let malformed: [String: Any] = [
            "selectedID": "../outside",
            "accounts": [["id": "../outside", "label": "Invalid", "isAuthenticated": true]]
        ]
        try JSONSerialization.data(withJSONObject: malformed).write(to: registryURL)
        try rejects({ _ = try registry.accounts() }, "Persisted account IDs must not escape private credential storage")
        print("PASS: Malformed stored account identities cannot escape account storage")
    }
}
