import Foundation

struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var ok: Bool { status == 0 }
}
enum Shell {
    static func run(_ path: String, _ args: [String] = [], timeout: TimeInterval = 10) -> ShellResult {
        ShellResult(status: 1, stdout: "", stderr: "unavailable")
    }
}
struct TailscaleState { var running = false; var error: String? = "unavailable" }
enum Tailscale { static func read() -> TailscaleState { TailscaleState() } }

func result(_ text: String, _ status: Int32 = 0) -> GuideCheck {
    RemoteAccessChecks.fileVault(ShellResult(status: status, stdout: text, stderr: ""))
}
precondition(result("FileVault is On.\n").level == .attention)
precondition(result("FileVault is Off.\n").level == .good)
precondition(result("Unknown volume").level == .unknown)
precondition(result("FileVault is Off.", 1).level == .unknown)
let checks = RemoteAccessChecks.collect()
precondition(checks[.restart]?.level == .unknown)
precondition(checks[.connection]?.level == .unknown)
precondition(checks[.test]?.level == .unknown)
print("7 guide checks passed; failed reads remain unverified.")
