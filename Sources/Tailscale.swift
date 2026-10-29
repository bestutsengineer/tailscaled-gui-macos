import Foundation

struct ExitNode: Equatable {
    var id: String          // stable node ID, matches prefs' ExitNodeID
    var name: String        // short host name, e.g. "vps"
    var dnsName: String     // exit.example.invalid
    var ip: String          // first Tailscale IPv4; what we pass to --exit-node
    var os: String
    var online: Bool
    var selected: Bool
}

/// One reading of tailscaled: `tailscale status --json` plus `tailscale debug prefs`.
struct TailnetState: Equatable {
    var daemonInstalled = false
    var backendState = "unknown"        // Running, Stopped, NeedsLogin, Starting, NoState
    var selfName: String?
    var selfIP: String?
    var tailnet: String?
    var exitNodes: [ExitNode] = []
    var exitNodeID = ""                 // from prefs; set even while that node is offline or we're stopped
    var exitNodeIP = ""
    var allowLAN = false
    var operatorUser: String?
    var exitFix = false                 // installed tailscaled has tailscaled-exitfix (see Tailscale.exitFixMarker)
    var health: [String] = []
    var error: String?

    var running: Bool { backendState == "Running" }
    var needsLogin: Bool { backendState == "NeedsLogin" }
    var activeExitNode: ExitNode? { exitNodes.first(where: \.selected) }
    var usingExitNode: Bool { !exitNodeID.isEmpty || !exitNodeIP.isEmpty }
    /// Tailscale fails closed: with the chosen exit node offline, internet traffic is dropped.
    var exitNodeUnreachable: Bool { running && usingExitNode && activeExitNode?.online != true }
}

enum Tailscale {
    /// Homebrew's tailscale CLI: /opt/homebrew on Apple silicon, /usr/local on Intel.
    static let cli = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        .first(where: FileManager.default.isExecutableFile(atPath:)) ?? "/opt/homebrew/bin/tailscale"
    static let daemonPlist = "/Library/LaunchDaemons/com.tailscale.tailscaled.plist"
    static let adminConsole = URL(string: "https://login.tailscale.com/admin/machines")!

    static let daemonBinary = "/usr/local/bin/tailscaled"

    /// Stock open-source tailscaled on macOS can't use an exit node (checked on 1.104.1): it adds
    /// `0.0.0.0/0 -iface utunX`, which macOS refuses while Wi-Fi's default route exists, and clearing
    /// the exit node then deletes Wi-Fi's default route. tailscaled-exitfix/exitfix.patch fixes that;
    /// a daemon built with it carries this marker, and only then does the menu change exit nodes.
    static let exitFixMarker = "tailscaled-darwin-exitfix-v4"   // v3 lacks scoped defaults for remote-peer transport
    private static let markerLock = NSLock()
    private static var markerCache: (mtime: Date, found: Bool)?

    static func daemonHasExitFix() -> Bool {
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: daemonBinary))?[.modificationDate] as? Date
        else { return false }
        markerLock.lock()
        defer { markerLock.unlock() }
        if let cache = markerCache, cache.mtime == mtime { return cache.found }
        let data = try? Data(contentsOf: URL(fileURLWithPath: daemonBinary), options: .alwaysMapped)
        let found = data?.range(of: Data(exitFixMarker.utf8)) != nil
        markerCache = (mtime, found)
        return found
    }

    static func read() -> TailnetState {
        var state = TailnetState()
        state.daemonInstalled = FileManager.default.fileExists(atPath: daemonPlist)
        state.exitFix = daemonHasExitFix()
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            state.error = "\(cli) not found (brew install tailscale)"
            return state
        }

        let prefs = Shell.run(cli, ["debug", "prefs"], timeout: 4)
        if prefs.ok, let json = object(prefs.stdout) {
            state.exitNodeID = json["ExitNodeID"] as? String ?? ""
            let pendingIP = json["ExitNodeIP"] as? String ?? ""
            state.exitNodeIP = ["", "invalid IP"].contains(pendingIP) ? "" : pendingIP
            state.allowLAN = json["ExitNodeAllowLANAccess"] as? Bool ?? false
            state.operatorUser = (json["OperatorUser"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        else {
            state.error = firstLine(prefs.stderr) ?? "Could not read Tailscale preferences"
            return state
        }

        let status = Shell.run(cli, ["status", "--json"], timeout: 4)
        guard status.ok, let json = object(status.stdout), json["BackendState"] is String else {
            state.error = firstLine(status.stderr) ?? "tailscale status failed (is tailscaled running?)"
            return state
        }
        state.backendState = json["BackendState"] as? String ?? "unknown"
        // "--accept-routes is false" is advice about other peers' subnets, not a fault on this Mac.
        state.health = (json["Health"] as? [String] ?? []).filter { !$0.contains("--accept-routes is false") }
        state.tailnet = (json["CurrentTailnet"] as? [String: Any])?["Name"] as? String
        if let me = json["Self"] as? [String: Any] {
            state.selfName = me["HostName"] as? String
            state.selfIP = ipv4(me["TailscaleIPs"])
        }
        let peers = (json["Peer"] as? [String: [String: Any]] ?? [:]).values
        state.exitNodes = peers.compactMap { peer -> ExitNode? in
            guard peer["ExitNodeOption"] as? Bool == true, let ip = ipv4(peer["TailscaleIPs"]) else { return nil }
            let id = peer["ID"] as? String ?? ""
            let dns = (peer["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return ExitNode(id: id,
                            name: peer["HostName"] as? String ?? dns,
                            dnsName: dns,
                            ip: ip,
                            os: peer["OS"] as? String ?? "",
                            online: peer["Online"] as? Bool ?? false,
                            selected: peer["ExitNode"] as? Bool == true || (!id.isEmpty && id == state.exitNodeID) || ip == state.exitNodeIP)
        }
        .sorted { ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased()) }
        return state
    }

    // MARK: Changes (need root or the operator user; see README)

    static func setExitNode(_ node: ExitNode?) -> ShellResult {
        if node == nil { try? ExitNodeHistory.rememberSelection(read()) }
        let result = ExitChange.perform(node: node?.ip ?? "")
        if result.ok, let node {
            do { try ExitNodeHistory.save(node) }
            catch { return ExitChange.failure("Exit node was applied, but its history could not be saved: \(error.localizedDescription)") }
        }
        return result
    }

    static func setAllowLAN(_ allow: Bool) -> ShellResult {
        ExitChange.perform(allowLAN: allow)
    }

    /// A normal enable always clears the daemon's saved selection. Only an explicit
    /// restore gesture/command reapplies history, using the same independent watchdog.
    static func connect(useLastExit: Bool = false) -> ShellResult {
        let state = read()
        guard state.error == nil else { return ExitChange.failure(state.error ?? "Cannot read preferences") }
        do {
            // Adopt selections made before this version or through another client.
            try ExitNodeHistory.rememberSelection(state)
            if useLastExit, let saved = try ExitNodeHistory.load() {
                guard let node = saved.resolve(in: state), node.online else {
                    return ExitChange.failure("Last used exit node \(saved.name) is offline or unavailable. Settings were left unchanged.")
                }
                let result = ExitChange.perform(node: node.ip, connect: true)
                if result.ok { try ExitNodeHistory.save(node) }
                return result
            }
        } catch { return ExitChange.failure("Couldn't read or save exit-node history: \(error.localizedDescription)") }
        return ExitChange.perform(node: "", connect: true)
    }

    static func disconnect() -> ShellResult {
        try? ExitNodeHistory.rememberSelection(read())
        return Shell.run(cli, ["down"], timeout: 15)
    }

    static func toggleConnection() -> ShellResult {
        let state = read()
        guard state.error == nil else { return ExitChange.failure(state.error ?? "Cannot read connection state") }
        return state.running ? disconnect() : connect()
    }

    /// Starts `tailscale login` and hands the auth URL to `onURL` as soon as the CLI prints it.
    /// The process keeps running until the browser sign-in finishes (or 10 minutes pass).
    static func login(onURL: @escaping (URL) -> Void, done: @escaping (Int32) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["login"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        var reported = false
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !reported, let range = text.range(of: #"https://\S+"#, options: .regularExpression),
                  let url = URL(string: String(text[range])) else { return }
            reported = true
            DispatchQueue.main.async { onURL(url) }
        }
        process.terminationHandler = { p in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { done(p.terminationStatus) }
        }
        do { try process.run() } catch { done(-1); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600) { if process.isRunning { process.terminate() } }
    }

    // MARK: Helpers

    private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func ipv4(_ value: Any?) -> String? {
        (value as? [String])?.first(where: { !$0.contains(":") })
    }

    static func firstLine(_ text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { !$0.isEmpty })
    }
}
