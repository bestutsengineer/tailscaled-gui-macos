import Foundation

// These stubs replace all process/network access. The actual ExitChange.swift is compiled
// unchanged apart from its EXIT_CHANGE_TESTS-only directory injection.
struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var ok: Bool { status == 0 }
}
struct ExitNode { var ip: String; var online = true }
struct TailnetState {
    var error: String?
    var exitFix = true
    var running = true
    var usingExitNode = false
    var activeExitNode: ExitNode?
    var exitNodeIP = ""
    var allowLAN = false
}
enum Tailscale {
    static let cli = "/test/tailscale"
    static var state = TailnetState()
    static func read() -> TailnetState { state }
}
struct Call { var path: String; var args: [String] }
enum Shell {
    static var calls: [Call] = []
    static var handler: (Call) -> ShellResult = { _ in bad("Unstubbed call") }
    static func run(_ path: String, _ args: [String] = [], timeout: TimeInterval = 10) -> ShellResult {
        let call = Call(path: path, args: args)
        calls.append(call)
        return handler(call)
    }
}
func ok(_ output: String = "") -> ShellResult { ShellResult(status: 0, stdout: output, stderr: "") }
func bad(_ message: String = "mock failure") -> ShellResult { ShellResult(status: 1, stdout: "", stderr: message) }
var failures = 0
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if condition() { print("PASS \(message)") }
    else { print("FAIL \(message)"); failures += 1 }
}
let fm = FileManager.default
let environmentDirectory = ProcessInfo.processInfo.environment["TAILNET_TEST_DIRECTORY"]
precondition(environmentDirectory != nil && ExitChange.directory.path == environmentDirectory!, "Tests require an isolated injected directory")
precondition(ExitChange.directory.path.contains("tailnet-tests."), "Refuse to remove anything outside a test directory")
func reset() {
    try? fm.removeItem(at: ExitChange.directory)
    Shell.calls = []
    Shell.handler = { _ in bad("Unstubbed call") }
    Tailscale.state = TailnetState()
}
func selected(_ ip: String = "100.100.100.1") -> TailnetState {
    var state = TailnetState()
    state.usingExitNode = true
    state.activeExitNode = ExitNode(ip: ip)
    state.exitNodeIP = ip
    return state
}
func recovery(deadline: Date = Date().addingTimeInterval(-1), running: Bool = true) -> ExitChange.Recovery {
    ExitChange.Recovery(previousNode: "100.100.100.9", previousRunning: running, previousLAN: true,
                        deadline: deadline, token: "test-token")
}
func save(_ recovery: ExitChange.Recovery) {
    try! fm.createDirectory(at: ExitChange.directory, withIntermediateDirectories: true)
    try! JSONEncoder().encode(recovery).write(to: ExitChange.directory.appendingPathComponent("recovery.json"))
}
func pending() -> ExitChange.Recovery {
    try! JSONDecoder().decode(ExitChange.Recovery.self,
        from: Data(contentsOf: ExitChange.directory.appendingPathComponent("recovery.json")))
}
func mockRoutes(_ first: String = "utun7", _ second: String = "utun7") {
    Shell.handler = { call in
        guard call.path == "/sbin/route" else { return bad("Unexpected \(call.path)") }
        let interface = call.args.last == "1.1.1.1" ? first : second
        return ok("   route to: \(call.args.last!)\n  interface: \(interface)\n")
    }
}

print("== Desired state and kernel routing")
reset()
mockRoutes()
expect(ExitChange.matches(selected(), node: "100.100.100.1", lan: false, connect: true), "desired selected online node with both utun routes passes")
expect(Shell.calls.filter { $0.path == "/sbin/route" }.map { $0.args.last! } == ["1.1.1.1", "208.67.222.222"], "both IPv4 halves are probed")
var state = selected()
state.activeExitNode = ExitNode(ip: "100.100.100.2")
expect(!ExitChange.matches(state, node: "100.100.100.1", lan: nil, connect: false), "wrong selected exit node cannot report success")
state = selected(); state.allowLAN = true
expect(!ExitChange.matches(state, node: nil, lan: false, connect: false), "wrong LAN preference cannot report success")
state = selected(); state.running = false
expect(!ExitChange.matches(state, node: nil, lan: nil, connect: true), "stopped backend cannot report reconnect success")
state = selected(); state.activeExitNode?.online = false
expect(!ExitChange.matches(state, node: nil, lan: nil, connect: false), "offline selected node cannot report success")
state = selected(); state.activeExitNode = nil
expect(!ExitChange.matches(state, node: nil, lan: nil, connect: false), "unresolved selected node cannot report success")
state = selected(); state.error = "local API unavailable"
expect(!ExitChange.matches(state, node: nil, lan: nil, connect: false), "local API errors cannot report success")
mockRoutes("utun7", "en0")
expect(!ExitChange.matches(selected(), node: nil, lan: nil, connect: false), "upper-half Wi-Fi fallback is rejected")
mockRoutes("en0", "utun7")
expect(!ExitChange.matches(selected(), node: nil, lan: nil, connect: false), "lower-half Wi-Fi fallback is rejected")
Shell.handler = { _ in bad("route lookup failed") }
expect(!ExitChange.matches(selected(), node: nil, lan: nil, connect: false), "failed route lookup is rejected")
expect(ExitChange.matches(TailnetState(), node: "", lan: false, connect: false), "cleared node does not require tunnel routes")
expect(!ExitChange.matches(selected(), node: "", lan: nil, connect: false), "still-selected node cannot report clear success")

print("== Change preflight")
reset(); Tailscale.state.exitFix = false
expect(!ExitChange.perform(node: "100.100.100.1").ok, "new exit-node selection requires v3 capability")
expect(Shell.calls.isEmpty, "unsupported selection does not run a command")
expect(!ExitChange.perform(allowLAN: true).ok, "LAN routing change requires v3 capability")
Tailscale.state = selected(); Tailscale.state.exitFix = false; Tailscale.state.running = false
expect(!ExitChange.perform(connect: true).ok, "reconnect with saved exit node requires v3 capability")
expect(Shell.calls.isEmpty, "unsupported reconnect does not run a command")
reset(); Tailscale.state.running = false
expect(!ExitChange.perform(node: "100.100.100.1").ok, "selection while stopped is rejected")
reset(); Tailscale.state.error = "bad prefs"
expect(ExitChange.perform(node: "100.100.100.1").stderr.contains("bad prefs"), "unreadable original preferences block a change")
reset(); Tailscale.state.usingExitNode = true
expect(!ExitChange.perform(node: "100.100.100.1").ok, "unresolved previous exit node blocks switching")
expect(ExitChange.perform(node: "").stderr.contains("Internet check failed") == false, "emergency clear can proceed without baseline internet")
reset()
expect(ExitChange.perform(node: "").ok && Shell.calls.isEmpty, "clear with nothing selected is a no-op")
Shell.handler = { _ in bad("offline") }
expect(!ExitChange.perform(node: "100.100.100.1").ok, "no working baseline HTTPS probe blocks selection")
expect(!Shell.calls.contains { $0.path == Tailscale.cli || $0.path == "/bin/launchctl" }, "failed baseline leaves preferences and launchd untouched")

print("== Restore and worker")
reset(); Shell.handler = { _ in ok() }
expect(ExitChange.restore(recovery(running: false)).ok, "restore handles an originally stopped backend")
expect(Shell.calls.map(\.args) == [["set", "--exit-node=100.100.100.9", "--exit-node-allow-lan-access=true"], ["down"]], "restore writes original node/LAN then restores stopped state")
reset(); Shell.handler = { call in call.args == ["down"] ? bad("cannot stop") : ok() }
expect(!ExitChange.restore(recovery(running: false)).ok, "failure to restore stopped state is propagated")
reset()
expect(ExitChange.worker(token: "test-token") == 1 && Shell.calls.isEmpty, "worker with no recovery does nothing")
save(recovery())
expect(ExitChange.worker(token: "wrong-token") == 1 && Shell.calls.isEmpty, "worker refuses another transaction's token")
reset(); save(recovery(deadline: Date().addingTimeInterval(100)))
expect(ExitChange.worker(token: "test-token") == 1 && Shell.calls.isEmpty, "worker rejects implausibly distant deadline")
reset(); save(recovery()); Shell.handler = { _ in ok() }
expect(ExitChange.worker(token: "test-token") == 0, "expired watchdog restores successfully")
expect(Shell.calls.count == 1 && !fm.fileExists(atPath: ExitChange.directory.path), "successful watchdog restore removes recovery state")
reset(); save(recovery(deadline: Date().addingTimeInterval(2)))
try! ExitChange.acknowledge(pending())
expect(ExitChange.worker(token: "test-token") == 0 && Shell.calls.isEmpty, "matching commit marker cancels rollback")
expect(!fm.fileExists(atPath: ExitChange.directory.path), "committed worker cleans up transaction files")
reset(); save(recovery())
var attempts = 0
Shell.handler = { _ in attempts += 1; return attempts < 3 ? bad("transient local API error") : ok() }
expect(ExitChange.worker(token: "test-token") == 0 && attempts == 3, "watchdog retries transient restore errors")
reset(); save(recovery()); Shell.handler = { _ in bad("daemon unavailable") }
expect(ExitChange.worker(token: "test-token") == 1, "watchdog reports exhausted recovery attempts")
expect(fm.fileExists(atPath: ExitChange.directory.appendingPathComponent("recovery.json").path), "failed watchdog retains recovery information")
reset(); save(recovery())
try! fm.createDirectory(at: ExitChange.directory.appendingPathComponent("committed"), withIntermediateDirectories: false)
do { try ExitChange.acknowledge(pending()); expect(false, "commit marker write failure throws") }
catch { expect(true, "commit marker write failure throws") }

// A mock launchctl submit acknowledges the watchdog immediately. No real process is launched.
func performMocks(failChange: Bool = false, breakConnectivity: Bool = false, breakCommit: Bool = false,
                  emergency: Bool = false) {
    var changed = false
    Shell.handler = { call in
        if call.path == "/usr/bin/curl" { return emergency || (changed && breakConnectivity) ? bad("offline") : ok() }
        if call.path == "/bin/launchctl" {
            let r = pending()
            try! Data(r.token.utf8).write(to: ExitChange.directory.appendingPathComponent("ready"))
            return ok()
        }
        if call.path == "/sbin/route" { return ok("interface: utun7\n") }
        if call.path == Tailscale.cli {
            if !changed {
                changed = true
                if failChange { return bad("mock change failed") }
                if emergency { Tailscale.state = TailnetState() }
                else { Tailscale.state = selected() }
                if breakCommit {
                    try! fm.createDirectory(at: ExitChange.directory.appendingPathComponent("committed"), withIntermediateDirectories: false)
                }
                return ok()
            }
            return ok() // restore
        }
        return bad("Unexpected call \(call.path)")
    }
}
print("== Guarded transaction")
reset(); performMocks()
expect(ExitChange.perform(node: "100.100.100.1").ok, "verified node/routing/HTTPS transaction commits")
expect((try? String(contentsOf: ExitChange.directory.appendingPathComponent("committed"), encoding: .utf8)) == pending().token, "successful transaction writes the correct commit token")
reset(); performMocks(failChange: true)
expect(!ExitChange.perform(node: "100.100.100.1").ok, "failed CLI change reports failure")
expect(Shell.calls.filter { $0.path == Tailscale.cli }.count == 2, "failed CLI change immediately restores original preferences")
reset(); performMocks(breakConnectivity: true)
expect(!ExitChange.perform(node: "100.100.100.1").ok, "lost HTTPS connectivity cannot falsely commit")
expect(Shell.calls.filter { $0.path == Tailscale.cli }.count == 2, "failed connectivity immediately restores original preferences")
reset(); performMocks(breakCommit: true)
expect(!ExitChange.perform(node: "100.100.100.1").ok, "commit marker failure does not falsely report success")
expect(fm.fileExists(atPath: ExitChange.directory.appendingPathComponent("recovery.json").path), "commit marker failure leaves watchdog recovery armed")
reset(); Tailscale.state.usingExitNode = true; Tailscale.state.exitFix = false
performMocks(emergency: true)
expect(ExitChange.perform(node: "").ok, "emergency clear of unresolved old exit node works without internet or v3")
reset()
print("\n\(checks) checks; \(failures) failures. No live commands or network changes executed.")
exit(failures == 0 ? 0 : 1)
