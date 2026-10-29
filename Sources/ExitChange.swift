import Foundation

/// A launchd-owned watchdog survives a GUI crash or an internet outage. Successful changes
/// are committed only after the same HTTPS probes that worked beforehand still work.
enum ExitChange {
    struct Recovery: Codable {
        var previousNode: String
        var previousRunning: Bool
        var previousLAN: Bool
        var deadline: Date
        var token: String
    }
    #if EXIT_CHANGE_TESTS
    static let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TAILNET_TEST_DIRECTORY"]!)
    #else
    static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Tailnet/exit-change", isDirectory: true)
    #endif
    static let probes = ["https://www.apple.com/library/test/success.html", "https://www.cloudflare.com/cdn-cgi/trace"]

    static func failure(_ message: String) -> ShellResult {
        ShellResult(status: 1, stdout: "", stderr: message + "\n")
    }
    static func reachable(_ url: String, log: ExitDiagnostics? = nil, phase: String = "probe") -> Bool {
        let args = ["--noproxy", "*", "--fail", "--silent", "--show-error", "--output", "/dev/null",
                    "--write-out", "http=%{http_code} remote=%{remote_ip} dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} total=%{time_total}",
                    "--connect-timeout", "3", "--max-time", "6", url]
        if let log { return log.run(phase, "/usr/bin/curl", args, timeout: 8).ok }
        return Shell.run("/usr/bin/curl", args, timeout: 8).ok
    }
    static func perform(node: String? = nil, allowLAN: Bool? = nil, connect: Bool = false) -> ShellResult {
        let log = ExitDiagnostics()
        log.record("request", ["node": node ?? "unchanged", "LAN": allowLAN.map(String.init) ?? "unchanged", "connect": connect])
        func failed(_ message: String) -> ShellResult {
            log.record("failure", ["message": message])
            return failure(message + "\nDiagnostics: " + log.location)
        }
        let before = Tailscale.read()
        log.state("before", before)
        guard before.error == nil else { return failed(before.error ?? "Can't read Tailscale") }
        if (node != nil && node != "") || allowLAN != nil || (connect && node == nil && before.usingExitNode) {
            guard before.exitFix else { return failed("Install exitfix v4 before changing exit-node routing (see README).") }
        }
        guard node == "" || before.running || connect else { return failed("Connect Tailscale before choosing an exit node.") }
        guard node == "" || !before.usingExitNode || before.activeExitNode != nil || !before.exitNodeIP.isEmpty else {
            return failed("The previous exit node can't be resolved. Clear it using tailscale before trying another node.")
        }
        // Clearing an unusable exit node must remain available even when internet is already down.
        if node == "" && !before.usingExitNode && !connect { return ShellResult(status: 0, stdout: "No exit node selected.\n", stderr: "") }
        let working = probes.filter { reachable($0, log: log, phase: "baseline-https") }
        if working.isEmpty && node != "" { return failed("Internet check failed before the change; settings were left alone.") }
        let physical = log.physicalInterface()
        log.transportRoute(physical)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        } catch { return failed("Another exit-node change is pending, or recovery storage is unavailable: \(error.localizedDescription)") }
        let recovery = Recovery(previousNode: before.activeExitNode?.ip ?? before.exitNodeIP, previousRunning: before.running, previousLAN: before.allowLAN,
                                deadline: Date().addingTimeInterval(60), token: UUID().uuidString)
        let file = directory.appendingPathComponent("recovery.json")
        do { try JSONEncoder().encode(recovery).write(to: file, options: .atomic) }
        catch { try? fm.removeItem(at: directory); return failed("Couldn't save rollback settings: \(error)") }
        guard let executable = Bundle.main.executablePath else {
            try? fm.removeItem(at: directory); return failed("Can't locate the rollback worker.")
        }
        let label = "local.tailnet.rollback." + recovery.token
        let armed = Shell.run("/bin/launchctl", ["submit", "-l", label, "--", executable, "--rollback-worker", recovery.token])
        guard armed.ok else { try? fm.removeItem(at: directory); return failed("Couldn't arm rollback: " + armed.stderr) }
        // Wait for the independent worker to acknowledge that it has loaded the recovery data.
        let ready = directory.appendingPathComponent("ready")
        let deadline = Date().addingTimeInterval(5)
        while !fm.fileExists(atPath: ready.path) && Date() < deadline { usleep(50_000) }
        guard fm.fileExists(atPath: ready.path) else {
            // Keep recovery data: a delayed worker will still restore the unchanged prefs.
            return failed("Rollback worker didn't start. No network settings were changed.")
        }
        log.record("watchdog-ready", ["token": recovery.token, "deadline": ISO8601DateFormatter().string(from: recovery.deadline)])
        var args = ["set"]
        if let node { args.append("--exit-node=\(node)") }
        if let allowLAN { args.append("--exit-node-allow-lan-access=\(allowLAN)") }
        let result: ShellResult
        if connect {
            // Set the requested selection while stopped, then start; never briefly
            // reconnect through a stale saved exit node. Both steps share one watchdog.
            let settings = args.count > 1 ? log.run("prepare-connection", Tailscale.cli, args, timeout: 6)
                : ShellResult(status: 0, stdout: "", stderr: "")
            result = settings.ok ? log.run("connect", Tailscale.cli, ["up"], timeout: 10) : settings
        } else {
            result = log.run("change", Tailscale.cli, args, timeout: 12)
        }
        // Allow the router/peer transport a few seconds to converge.
        var validated = false
        var reason = "The change command failed."
        if result.ok {
            for _ in 0..<2 {
                // Reserve the worst-case command timeouts (37s) before the worker can fire.
                guard Date() < recovery.deadline.addingTimeInterval(-38) else {
                    reason = "Validation ran out of time; rollback was kept armed."
                    break
                }
                usleep(1_000_000)
                let state = Tailscale.read()
                log.state("validation-state", state)
                log.transportRoute(physical)
                let mismatch = validationFailure(state, node: node, lan: allowLAN, connect: connect, log: log)
                let checks = working.map { reachable($0, log: log, phase: "validation-https") }
                reason = mismatch ?? (checks.allSatisfy { $0 } ? "" : "HTTPS/DNS probes failed through the requested route.")
                log.record("validation", ["reason": reason])
                if reason.isEmpty {
                    validated = true; break
                }
            }
        }
        // Never commit after the watchdog's deadline; it may already be restoring settings.
        if validated && Date() < recovery.deadline.addingTimeInterval(-5) {
            do { try acknowledge(recovery) }
            catch { return failed("Could not commit the change; timed rollback remains armed.") }
            log.record("committed")
            return ShellResult(status: 0, stdout: "Routing updated; HTTPS and DNS checks passed.\nDiagnostics: \(log.location)\n", stderr: "")
        }
        if validated { reason = "Validation finished too close to the rollback deadline." }
        let restored = restore(recovery)
        log.record("restored", ["exitStatus": restored.status, "stderr": restored.stderr])
        // Worker is retained as a second recovery attempt if immediate restore failed.
        if restored.ok {
            do { try acknowledge(recovery) }
            catch { return failed("Previous settings restored; watchdog remains armed because acknowledgement failed.") }
        }
        return failed(result.ok ? "Connectivity check failed: \(reason) \(restored.ok ? "Previous settings restored." : "Timed rollback remains armed.")"
                       : "Change failed: \(result.stderr) \(restored.ok ? "Previous settings restored." : "Timed rollback remains armed.")")
    }
    static func acknowledge(_ recovery: Recovery) throws {
        try Data(recovery.token.utf8).write(to: directory.appendingPathComponent("committed"), options: .atomic)
    }
    static func matches(_ state: TailnetState, node: String?, lan: Bool?, connect: Bool) -> Bool {
        validationFailure(state, node: node, lan: lan, connect: connect) == nil
    }
    static func validationFailure(_ state: TailnetState, node: String?, lan: Bool?, connect: Bool, log: ExitDiagnostics? = nil) -> String? {
        if let error = state.error { return "Local daemon read failed: \(error)" }
        if let lan, state.allowLAN != lan { return "LAN preference did not match the request." }
        if let node {
            if node.isEmpty {
                if state.usingExitNode { return "Exit node was not cleared." }
            } else if state.activeExitNode?.ip != node { return "Selected exit node did not match the request." }
        }
        if connect && !state.running { return "The daemon did not reach Running." }
        if state.usingExitNode {
            guard state.running, state.activeExitNode?.online == true else { return "Selected exit node is offline or unresolved." }
            // Bind validation to the peer's tunnel, so a second VPN cannot satisfy it.
            guard let peer = state.activeExitNode,
                  let tunnel = routeInterface(peer.ip, log: log), tunnel.hasPrefix("utun") else { return "Peer route does not use a Tailscale tunnel." }
            for ip in ["1.1.1.1", "208.67.222.222"] {
                guard routeInterface(ip, log: log) == tunnel else { return "Route to \(ip) does not use the selected peer's tunnel (\(tunnel))." }
            }
        }
        return nil
    }
    static func routeInterface(_ ip: String, log: ExitDiagnostics? = nil) -> String? {
        let args = ["-n", "get", ip]
        let route = log?.run("validation-route", "/sbin/route", args, timeout: 3)
            ?? Shell.run("/sbin/route", args, timeout: 3)
        guard route.ok else { return nil }
        return route.stdout.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return fields.count == 2 && fields[0] == "interface" ? fields[1] : nil
        }.first
    }
    static func restore(_ recovery: Recovery) -> ShellResult {
        let result = Shell.run(Tailscale.cli, ["set", "--exit-node=\(recovery.previousNode)",
                                  "--exit-node-allow-lan-access=\(recovery.previousLAN)"], timeout: 12)
        if !recovery.previousRunning {
            let stopped = Shell.run(Tailscale.cli, ["down"], timeout: 8)
            if !stopped.ok { return stopped }
        }
        return result
    }
    static func worker(token: String) -> Int32 {
        // launchctl submit creates a KeepAlive job. Retire only our own job on
        // completion (including an exhausted recovery), rather than respawning forever.
        let label = "local.tailnet.rollback." + token
        defer {
            if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label {
                _ = Shell.run("/bin/launchctl", ["remove", label], timeout: 3)
            }
        }
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("recovery.json")),
              let recovery = try? JSONDecoder().decode(Recovery.self, from: data), recovery.token == token,
              recovery.deadline.timeIntervalSinceNow < 90 else { return 1 }
        let log = ExitDiagnostics()
        log.record("worker-ready", ["token": token])
        try? Data(token.utf8).write(to: directory.appendingPathComponent("ready"), options: .atomic)
        let committed = directory.appendingPathComponent("committed")
        while Date() < recovery.deadline {
            if (try? String(contentsOf: committed, encoding: .utf8)) == token {
                log.record("worker-committed")
                try? fm.removeItem(at: directory); return 0
            }
            usleep(200_000)
        }
        let result = restore(recovery)
        log.record("watchdog-restored", ["exitStatus": result.status, "stderr": result.stderr])
        // Retry transient local API failures. Persist recovery.json if all attempts fail.
        if !result.ok {
            for _ in 0..<3 {
                usleep(1_000_000)
                let retry = restore(recovery)
                log.record("watchdog-retry", ["exitStatus": retry.status, "stderr": retry.stderr])
                if retry.ok { try? fm.removeItem(at: directory); return 0 }
            }
            log.record("watchdog-exhausted", ["recoveryFile": directory.appendingPathComponent("recovery.json").path])
            return 1
        }
        try? fm.removeItem(at: directory)
        return 0
    }
}
