import Foundation

/// Local, bounded diagnostics. Never serialize raw prefs: they can contain credentials.
final class ExitDiagnostics {
    #if EXIT_CHANGE_TESTS
    static var directory: URL { ExitChange.directory.deletingLastPathComponent().appendingPathComponent("diagnostics") }
    #else
    static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/tailscaled-gui", isDirectory: true)
    #endif
    let file = directory.appendingPathComponent(UUID().uuidString + ".json")
    private let started = Date()
    private var events: [[String: Any]] = []
    private(set) var saved = false
    var location: String { saved ? file.path : "unavailable (could not write local log)" }

    init() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.directory.path)
            // Keep the 12 newest reports, including this one. Recovery files live elsewhere.
            let old = (try fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.contentModificationDateKey]))
                .filter { $0.pathExtension == "json" }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            for url in old.dropFirst(11) { try? fm.removeItem(at: url) }
        } catch { return }
        record("started")
    }

    func record(_ event: String, _ fields: [String: Any] = [:]) {
        var entry = fields
        entry["event"] = event
        entry["elapsedSeconds"] = Date().timeIntervalSince(started)
        events.append(entry)
        let report: [String: Any] = ["schema": 1, "startedAt": ISO8601DateFormatter().string(from: started), "events": events]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            // Create a private temporary file first; the atomic rename never exposes mode 0644.
            let temporary = Self.directory.appendingPathComponent("." + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                                  attributes: [.posixPermissions: 0o600]) else { return }
            guard rename(temporary.path, file.path) == 0 else { return }
            saved = true
        } catch { /* Diagnostic failure must not disable recovery. */ }
    }

    func state(_ event: String, _ s: TailscaleState) {
        record(event, ["running": s.running, "usingExitNode": s.usingExitNode,
                       "exitNodeIP": s.activeExitNode?.ip ?? s.exitNodeIP,
                       "exitNodeOnline": s.activeExitNode?.online ?? false,
                       "allowLAN": s.allowLAN, "exitFix": s.exitFix,
                       "error": s.error ?? ""])
        #if !EXIT_CHANGE_TESTS
        record(event + "-health", ["backend": s.backendState, "health": s.health])
        #endif
    }

    func physicalInterface() -> String? {
        let result = Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet"], timeout: 3)
        let defaults = result.stdout.split(separator: "\n").map(String.init).filter {
            $0.split(whereSeparator: \.isWhitespace).first == "default"
        }
        record("physical-defaults", ["exitStatus": result.status, "routes": defaults, "stderr": result.stderr])
        return defaults.compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 4, !fields[3].hasPrefix("utun"), fields[3] != "lo0" else { return nil }
            return String(fields[3])
        }.first
    }

    func transportRoute(_ physical: String?) {
        guard let physical else { record("scoped-transport-route", ["error": "No physical IPv4 default found"]); return }
        run("scoped-transport-route", "/sbin/route", ["-n", "get", "-ifscope", physical, "1.1.1.1"], timeout: 3)
    }

    func command(_ event: String, path: String, args: [String], result: ShellResult, seconds: TimeInterval) {
        record(event, ["executable": path, "arguments": args, "exitStatus": result.status,
                       "seconds": seconds, "stdout": String(result.stdout.prefix(24_000)),
                       "stderr": String(result.stderr.prefix(4_000))])
    }

    @discardableResult
    func run(_ event: String, _ path: String, _ args: [String], timeout: TimeInterval = 5) -> ShellResult {
        let start = Date()
        let result = Shell.run(path, args, timeout: timeout)
        command(event, path: path, args: args, result: result, seconds: Date().timeIntervalSince(start))
        return result
    }

    static func collect() -> ShellResult {
        let log = ExitDiagnostics()
        let s = Tailscale.read()
        log.state("current-state", s)
        #if !EXIT_CHANGE_TESTS
        log.record("daemon-health", ["backend": s.backendState, "health": s.health])
        #endif
        let physical = log.physicalInterface()
        for ip in ["1.1.1.1", "208.67.222.222"] + (s.activeExitNode.map { [$0.ip] } ?? []) {
            log.run("route", "/sbin/route", ["-n", "get", ip])
            if let physical { log.run("scoped-route", "/sbin/route", ["-n", "get", "-ifscope", physical, ip]) }
        }
        log.run("dns", "/usr/sbin/scutil", ["--dns"])
        log.run("proxy", "/usr/sbin/scutil", ["--proxy"])
        log.run("netcheck", Tailscale.cli, ["netcheck"], timeout: 12)
        if s.running, let peer = s.activeExitNode {
            log.run("peer-transport", Tailscale.cli,
                    ["ping", "--until-direct=false", "--c=1", "--timeout=3s", peer.ip], timeout: 4)
            log.run("peer-encrypted-ping", Tailscale.cli,
                    ["ping", "--tsmp", "--c=1", "--timeout=3s", peer.ip], timeout: 4)
        }
        for url in ExitChange.probes { _ = ExitChange.reachable(url, log: log, phase: "diagnose") }
        return ShellResult(status: log.saved ? 0 : 1, stdout: "Diagnostics: \(log.location)\n", stderr: "")
    }
}
