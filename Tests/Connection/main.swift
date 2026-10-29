import Foundation

struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var ok: Bool { status == 0 }
}
var backend = "Stopped"
var selectedID = ""
var peers: [[String: Any]] = []
var shellCalls: [[String]] = []
func json(_ value: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
enum Shell {
    static func run(_ path: String, _ args: [String] = [], timeout: TimeInterval = 10) -> ShellResult {
        shellCalls.append(args)
        if args == ["debug", "prefs"] {
            return ShellResult(status: 0, stdout: json(["ExitNodeID": selectedID, "ExitNodeIP": "", "ExitNodeAllowLANAccess": false]), stderr: "")
        }
        if args == ["status", "--json"] {
            return ShellResult(status: 0, stdout: json(["BackendState": backend,
                "Peer": Dictionary(uniqueKeysWithValues: peers.enumerated().map { ("peer\($0.offset)", $0.element) })]), stderr: "")
        }
        if args == ["down"] { backend = "Stopped"; return ShellResult(status: 0, stdout: "", stderr: "") }
        return ShellResult(status: 1, stdout: "", stderr: "Unexpected command")
    }
}
enum ExitChange {
    struct Request { var node: String?; var connect: Bool }
    static var requests: [Request] = []
    static var succeed = true
    static func failure(_ message: String) -> ShellResult { ShellResult(status: 1, stdout: "", stderr: message) }
    static func perform(node: String? = nil, allowLAN: Bool? = nil, connect: Bool = false) -> ShellResult {
        requests.append(Request(node: node, connect: connect))
        guard succeed else { return failure("Simulated rollback") }
        if let node { selectedID = peers.first { ($0["TailscaleIPs"] as? [String])?.contains(node) == true }?["ID"] as? String ?? "" }
        if connect { backend = "Running" }
        return ShellResult(status: 0, stdout: "", stderr: "")
    }
}
func peer(id: String = "stable-example-exit", ip: String = "100.100.100.1", online: Bool = true) -> [String: Any] {
    ["ID": id, "HostName": "example-exit", "DNSName": "exit.example.invalid.", "TailscaleIPs": [ip], "OS": "linux", "Online": online, "ExitNodeOption": true]
}
let fm = FileManager.default
precondition(ExitNodeHistory.file.path.contains("tailnet-tests."))
var checks = 0, failures = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if value() { print("PASS \(message)") } else { print("FAIL \(message)"); failures += 1 }
}
func reset(keepHistory: Bool = false) {
    if !keepHistory { try? fm.removeItem(at: ExitNodeHistory.file) }
    backend = "Stopped"; selectedID = ""; peers = [peer()]; shellCalls = []
    ExitChange.requests = []; ExitChange.succeed = true
}
func savedNode() -> ExitNode { Tailscale.read().exitNodes[0] }

print("== Status click sequences")
var clicks = StatusClickSequence()
clicks.receive(clickCount: 1, at: 0, interval: 0.5)
expect(clicks.resolve(at: 0.49) == nil, "single click does not open the menu before a second can arrive")
clicks.receive(clickCount: 2, at: 0.2, interval: 0.5)
expect(clicks.resolve(at: 0.5) == nil, "double click does not toggle before the triple-click window closes")
clicks.receive(clickCount: 3, at: 0.4, interval: 0.5)
expect(clicks.resolve(at: 0.7) == nil, "superseded double-click deadline cannot toggle during a triple click")
expect(clicks.resolve(at: 0.91) == .connectLastExit, "triple click produces only the explicit exit-node action")
expect(clicks.resolve(at: 1.5) == nil, "a resolved sequence cannot fire twice")
clicks.receive(clickCount: 1, at: 2, interval: 0.5)
clicks.receive(clickCount: 2, at: 2.2, interval: 0.5)
expect(clicks.resolve(at: 2.71) == .toggle, "double click resolves to connection toggle")
clicks.receive(clickCount: 1, at: 3, interval: 0.5)
expect(clicks.resolve(at: 3.51) == .menu, "single click keeps menu access")
clicks.receive(clickCount: 2, at: 4, interval: 0.5); clicks.cancel()
expect(clicks.resolve(at: 5) == nil, "right click or a pending action can cancel a gesture")

print("== Connection behavior and persistent history")
reset(); selectedID = "stable-example-exit"
expect(Tailscale.connect().ok, "normal enable succeeds with a saved daemon exit node")
expect(ExitChange.requests.last?.node == "" && ExitChange.requests.last?.connect == true, "normal enable explicitly requests no exit node")
expect(selectedID.isEmpty && backend == "Running", "normal enable leaves the backend running without an exit node")
expect((try? ExitNodeHistory.load())?.id == "stable-example-exit", "clearing a saved selection retains last-used history")
expect(Tailscale.disconnect().ok && backend == "Stopped", "disconnect stops the daemon")
expect((try? ExitNodeHistory.load())?.id == "stable-example-exit", "disconnect without an exit node does not erase history")
reset(keepHistory: true)
expect(Tailscale.connect(useLastExit: true).ok, "explicit restore reads history after process state is reset")
expect(ExitChange.requests.last?.node == "100.100.100.1" && ExitChange.requests.last?.connect == true, "explicit restore requests the remembered node and enable together")
expect(selectedID == "stable-example-exit" && backend == "Running", "explicit restore enables with the remembered exit node")
expect(Tailscale.toggleConnection().ok && backend == "Stopped", "double-click toggle disables an enabled exit-node connection")
expect(Tailscale.toggleConnection().ok && backend == "Running" && selectedID.isEmpty, "double-click toggle re-enables without the saved exit node")

reset()
expect(Tailscale.connect(useLastExit: true).ok && ExitChange.requests.last?.node == "", "triple click with no history enables without an exit node")
reset(); try! ExitNodeHistory.save(savedNode()); peers = [peer(ip: "100.100.100.2")]
expect(Tailscale.connect(useLastExit: true).ok && ExitChange.requests.last?.node == "100.100.100.2", "stable identity resolves a remembered node at its current address")
reset(); try! ExitNodeHistory.save(savedNode()); peers = [peer(id: "different-device")]
expect(!Tailscale.connect(useLastExit: true).ok && ExitChange.requests.isEmpty, "an address reused by another device is not silently selected")
reset(); try! ExitNodeHistory.save(savedNode()); peers = [peer(online: false)]
expect(!Tailscale.connect(useLastExit: true).ok && ExitChange.requests.isEmpty && backend == "Stopped", "offline history produces an error without enabling")
reset(); backend = "Running"
expect(Tailscale.setExitNode(savedNode()).ok && (try? ExitNodeHistory.load())?.id == "stable-example-exit", "successful manual selection records last-used history")
ExitChange.succeed = false
let other = ExitNode(id: "other", name: "other", dnsName: "other.example", ip: "100.100.100.3", os: "linux", online: true, selected: false)
expect(!Tailscale.setExitNode(other).ok && (try? ExitNodeHistory.load())?.id == "stable-example-exit", "failed manual selection cannot replace successful history")
ExitChange.succeed = true
expect(Tailscale.setExitNode(nil).ok && (try? ExitNodeHistory.load())?.id == "stable-example-exit", "choosing None retains last-used history")
reset(); try! fm.createDirectory(at: ExitNodeHistory.file.deletingLastPathComponent(), withIntermediateDirectories: true)
try! Data("corrupt".utf8).write(to: ExitNodeHistory.file)
expect(!Tailscale.connect(useLastExit: true).ok && ExitChange.requests.isEmpty, "unreadable history never silently falls back to a direct connection")
reset()
print("\n\(checks) connection/gesture checks; \(failures) failures. No live network commands executed.")
exit(failures == 0 ? 0 : 1)
