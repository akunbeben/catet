import AppKit
import Foundation
import CoreServices
import Darwin

@_silgen_name("flock")
func installerFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

struct InstallError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw InstallError("\(executable) failed (\(process.terminationStatus)).") }
}

func install() throws {
    guard CommandLine.arguments.count == 3 else { throw InstallError("Usage: install.swift SOURCE_APP SIGNING_IDENTITY_FILE") }
    let fm = FileManager.default
    let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let target = URL(fileURLWithPath: "/Applications/Catet.app", isDirectory: true)
    let identifier = "id.benny.catet"
    guard Bundle(url: source)?.bundleIdentifier == identifier else { throw InstallError("The source is not a Catet app bundle.") }
    if fm.fileExists(atPath: target.path) {
        guard Bundle(url: target)?.bundleIdentifier == identifier else { throw InstallError("/Applications/Catet.app belongs to another app. It was not replaced.") }
    }
    guard fm.isWritableFile(atPath: "/Applications") else { throw InstallError("Applications is not writable for this user.") }
    let runtime = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Catet/runtime")
    try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
    let updaterFD = open(runtime.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard updaterFD >= 0 else { throw InstallError("Could not open the installation lock.") }
    defer { close(updaterFD) }
    guard installerFlock(updaterFD, LOCK_EX | LOCK_NB) == 0 else { throw InstallError("Another Catet installation is running.") }
    defer { _ = installerFlock(updaterFD, LOCK_UN) }

    let locks = runtime.appendingPathComponent("locks")
    for file in (try? fm.contentsOfDirectory(at: locks, includingPropertiesForKeys: nil)) ?? [] {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { throw InstallError("Could not check whether a recording is running.") }
        defer { close(fd) }
        guard installerFlock(fd, LOCK_EX | LOCK_NB) == 0 else { throw InstallError("Stop the active recording or wait for processing to finish, then run install.sh again. Nothing was replaced.") }
        _ = installerFlock(fd, LOCK_UN)
    }

    let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
    for app in running { guard app.terminate() else { throw InstallError("Catet could not quit safely. Close it and try again.") } }
    let deadline = Date().addingTimeInterval(10)
    while running.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard running.allSatisfy(\.isTerminated) else { throw InstallError("Catet is still running. Finish the pending dialog or recording, then run install.sh again. Nothing was replaced.") }

    let staging = target.deletingLastPathComponent().appendingPathComponent(".catet-install-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: staging) }
    let replacement = staging.appendingPathComponent("Catet.app")
    let backup = staging.appendingPathComponent("Previous.app")
    try fm.copyItem(at: source, to: replacement)
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", replacement.path])
    let hadPrevious = fm.fileExists(atPath: target.path)
    if hadPrevious { try fm.moveItem(at: target, to: backup) }
    do {
        try fm.moveItem(at: replacement, to: target)
        let status = LSRegisterURL(target as CFURL, true)
        guard status == noErr else { throw InstallError("LaunchServices registration failed (\(status)).") }
        let signer = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        try signer.write(to: runtime.appendingPathComponent("signing-identity"), options: .atomic)
    } catch {
        try? fm.removeItem(at: target)
        if hadPrevious { try? fm.moveItem(at: backup, to: target); _ = LSRegisterURL(target as CFURL, true) }
        throw error
    }
    print("Installed and registered: \(target.path)")
    print("Recording data and models were left in Application Support/Catet.")
}

do { try install() }
catch { fputs("Catet installation failed: \(error)\n", stderr); exit(1) }
