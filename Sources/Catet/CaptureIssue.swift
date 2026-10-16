import Foundation
import ScreenCaptureKit

struct CaptureIssue {
    enum Source { case microphone, systemAudio }
    let source: Source
    let error: NSError

    init(source: Source, error: Error) {
        self.source = source
        self.error = error as NSError
    }

    var permissionDenied: Bool {
        source == .systemAudio && error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
    }

    var warning: String {
        "System audio was not fully captured. This recording may contain only microphone audio."
    }

    var recovery: String {
        if permissionDenied {
            return "Allow Catet in System Settings → Privacy & Security → Screen & System Audio Recording. Then reopen Catet and start a new recording."
        }
        return "System audio stopped: \(error.localizedDescription)\n\nYou can keep recording the microphone, or stop and save the available audio."
    }

    var diagnostic: String {
        "\(ISO8601DateFormatter().string(from: Date())) source=\(source) domain=\(error.domain) code=\(error.code) \(error.localizedDescription)\n"
    }
}
