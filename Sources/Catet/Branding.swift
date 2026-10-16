import AppKit

// Load bundled artwork directly instead of reusing the system's cached app icon.
enum CatetBrand {
    static let applicationIcon: NSImage = {
        guard let url = Bundle.main.url(forResource: "Catet", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { preconditionFailure("Missing bundled Catet.icns") }
        return image
    }()

    static let mark: NSImage = {
        guard let image = NSImage(named: "CatetMark") else { preconditionFailure("Missing bundled CatetMark.png") }
        return image
    }()
}
