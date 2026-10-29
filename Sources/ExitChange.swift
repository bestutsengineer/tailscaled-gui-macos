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
    static func reachable(_ url: String) -> Bool {
        Shell.run("/usr/bin/curl", ["--noproxy", "*", "--fail", "--silent", "--output", "/dev/null",
                                    "--connect-timeout", "3", "--max-time", "6", url], timeout: 8).ok
    }
    static func perform(node: String? = nil, allowLAN: Bool? = nil, connect: Bool = false) -> ShellResult {
        let before = Tailscale.read()
        guard before.error == nil else { return failure(before.error ?? "Can't read Tailscale") }
        if (node != nil && node != "") || allowLAN != nil || (connect && before.usingExitNode) {
            guard before.exitFix else { return failure("Install exitfix v3 before changing exit-node routing (see README).") }
        }
        guard node == "" || before.running || connect else { return failure("Connect Tailscale before choosing an exit node.") }
        guard node == "" || !before.usingExitNode || before.activeExitNode != nil || !before.exitNodeIP.isEmpty else {
            return failure("The previous exit node can't be resolved. Clear it using tailscale before trying another node.")
        }
        // Clearing an unusable exit node must remain available even when internet is already down.
        if node == "" && !before.usingExitNode { return ShellResult(status: 0, stdout: "No exit node selected.\n", stderr: "") }
        let working = probes.filter(reachable)
        if working.isEmpty && node != "" { return failure("Internet check failed before the change; settings were left alone.") }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        } catch { return failure("Another exit-node change is pending. Wait up to 60 seconds and retry.") }
        let recovery = Recovery(previousNode: before.activeExitNode?.ip ?? before.exitNodeIP, previousRunning: before.running, previousLAN: before.allowLAN,
                                deadline: Date().addingTimeInterval(60), token: UUID().uuidString)
        let file = directory.appendingPathComponent("recovery.json")
        do { try JSONEncoder().encode(recovery).write(to: file, options: .atomic) }
        catch { try? fm.removeItem(at: directory); return failure("Couldn't save rollback settings: \(error)") }
        guard let executable = Bundle.main.executablePath else {
            try? fm.removeItem(at: directory); return failure("Can't locate the rollback worker.")
        }
        let label = "local.tailnet.rollback." + recovery.token
        let armed = Shell.run("/bin/launchctl", ["submit", "-l", label, "--", executable, "--rollback-worker", recovery.token])
        guard armed.ok else { try? fm.removeItem(at: directory); return failure("Couldn't arm rollback: " + armed.stderr) }
        // Wait for the independent worker to acknowledge that it has loaded the recovery data.
        let ready = directory.appendingPathComponent("ready")
        let deadline = Date().addingTimeInterval(5)
        while !fm.fileExists(atPath: ready.path) && Date() < deadline { usleep(50_000) }
        guard fm.fileExists(atPath: ready.path) else {
            // Keep recovery data: a delayed worker will still restore the unchanged prefs.
            return failure("Rollback worker didn't start. No network settings were changed.")
        }
        var args = ["set"]
        if let node { args.append("--exit-node=\(node)") }
        if let allowLAN { args.append("--exit-node-allow-lan-access=\(allowLAN)") }
        let result = Shell.run(Tailscale.cli, connect ? ["up"] : args, timeout: 12)
        // Allow the router/peer transport a few seconds to converge.
        var validated = false
        if result.ok {
            for _ in 0..<2 {
                usleep(1_000_000)
                if working.allSatisfy(reachable) && matches(Tailscale.read(), node: node, lan: allowLAN, connect: connect) {
                    validated = true; break
                }
            }
        }
        // Never commit after the watchdog's deadline; it may already be restoring settings.
        if validated && Date() < recovery.deadline.addingTimeInterval(-5) {
            do { try acknowledge(recovery) }
            catch { return failure("Could not commit the change; timed rollback remains armed.") }
            return ShellResult(status: 0, stdout: "Routing updated; HTTPS and DNS checks passed.\n", stderr: "")
        }
        let restored = restore(recovery)
        // Worker is retained as a second recovery attempt if immediate restore failed.
        if restored.ok {
            do { try acknowledge(recovery) }
            catch { return failure("Previous settings restored; watchdog remains armed because acknowledgement failed.") }
        }
        return failure(result.ok ? "Connectivity check failed. \(restored.ok ? "Previous settings restored." : "Timed rollback remains armed.")"
                       : "Change failed: \(result.stderr) \(restored.ok ? "Previous settings restored." : "Timed rollback remains armed.")")
    }
    static func acknowledge(_ recovery: Recovery) throws {
        try Data(recovery.token.utf8).write(to: directory.appendingPathComponent("committed"), options: .atomic)
    }
    static func matches(_ state: TailnetState, node: String?, lan: Bool?, connect: Bool) -> Bool {
        guard state.error == nil else { return false }
        if let lan, state.allowLAN != lan { return false }
        if let node {
            if node.isEmpty { return !state.usingExitNode }
            if state.activeExitNode?.ip != node { return false }
        }
        if connect && !state.running { return false }
        if state.usingExitNode {
            guard state.running, state.activeExitNode?.online == true else { return false }
            // Bind validation to the peer's tunnel, so a second VPN cannot satisfy it.
            guard let peer = state.activeExitNode,
                  let tunnel = routeInterface(peer.ip), tunnel.hasPrefix("utun") else { return false }
            for ip in ["1.1.1.1", "208.67.222.222"] {
                guard routeInterface(ip) == tunnel else { return false }
            }
        }
        return true
    }
    static func routeInterface(_ ip: String) -> String? {
        let route = Shell.run("/sbin/route", ["-n", "get", ip], timeout: 3)
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
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("recovery.json")),
              let recovery = try? JSONDecoder().decode(Recovery.self, from: data), recovery.token == token,
              recovery.deadline.timeIntervalSinceNow < 90 else { return 1 }
        try? Data(token.utf8).write(to: directory.appendingPathComponent("ready"), options: .atomic)
        let committed = directory.appendingPathComponent("committed")
        while Date() < recovery.deadline {
            if (try? String(contentsOf: committed, encoding: .utf8)) == token {
                try? fm.removeItem(at: directory); return 0
            }
            usleep(200_000)
        }
        let result = restore(recovery)
        // Retry transient local API failures. Persist recovery.json if all attempts fail.
        if !result.ok {
            for _ in 0..<3 {
                usleep(1_000_000)
                if restore(recovery).ok { try? fm.removeItem(at: directory); return 0 }
            }
            return 1
        }
        try? fm.removeItem(at: directory)
        return 0
    }
}
