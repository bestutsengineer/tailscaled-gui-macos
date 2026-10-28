import Foundation

/// The same reads and changes the menu makes, for scripts and for testing without clicking.
enum CLI {
    static let usage = """
        Tailnet: menu bar control for the open-source tailscaled daemon.

        Usage: Tailnet [command]
          (no command)            run the menu bar app
          --status                connection, exit node and LAN access
          --menu                  print the menu as text
          --exit-node NAME|IP     use that exit node (needs tailscaled-exitfix, or --force)
          --exit-node none        stop using an exit node (can drop the default route briefly)
          --lan on|off            allow local network access while using an exit node
          --connect | --disconnect
          --login-item on|off     start Tailnet at login (LaunchAgent)
        """

    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "--status":
            let s = Tailscale.read()
            print(MenuModel.headline(s))
            print("backend:    \(s.backendState)")
            print("icon:       \(MenuModel.icon(s).rawValue) sword")
            print("this Mac:   \(s.selfName ?? "-") \(s.selfIP ?? "")")
            print("exit node:  \(s.activeExitNode.map { "\($0.name) (\($0.ip))\($0.online ? "" : " offline")" } ?? (s.usingExitNode ? s.exitNodeID : "none"))")
            print("LAN access: \(s.allowLAN ? "allowed" : "blocked") while using an exit node")
            print("offered by: \(s.exitNodes.map { "\($0.name)\($0.online ? "" : " (offline)")" }.joined(separator: ", "))")
            print("operator:   \(s.operatorUser ?? "none (changes need sudo)")")
            print("exit fix:   \(s.exitFix ? "installed" : "not installed (stock tailscaled)")")
            if let error = s.error { print("error:      \(error)") }
            return 0
        case "--menu":
            MenuModel.rows(Tailscale.read(), loginItem: LoginItem.isEnabled).flatMap(\.flatTitles).forEach { print($0) }
            return 0
        case "--exit-node":
            guard args.count >= 2 else { return fail(usage) }
            if args[1] == "none" { return report(Tailscale.setExitNode(nil)) }
            guard Tailscale.daemonHasExitFix() || args.dropFirst(2).contains("--force") else {
                return fail("Stock tailscaled on macOS can't use exit nodes; install tailscaled-exitfix (see README) or add --force.")
            }
            let wanted = args[1].lowercased()
            let nodes = Tailscale.read().exitNodes
            guard let node = nodes.first(where: { $0.name.lowercased() == wanted || $0.ip == wanted
                                                  || $0.dnsName.lowercased().hasPrefix(wanted + ".") }) else {
                return fail("No exit node \"\(args[1])\". Offered: \(nodes.map(\.name).joined(separator: ", "))")
            }
            return report(Tailscale.setExitNode(node))
        case "--lan":
            guard args.count == 2, ["on", "off"].contains(args[1]) else { return fail(usage) }
            return report(Tailscale.setAllowLAN(args[1] == "on"))
        case "--login-item":
            guard args.count == 2, ["on", "off"].contains(args[1]) else { return fail(usage) }
            if args[1] == "off" { LoginItem.disable(); return 0 }
            do { try LoginItem.enable(); return 0 } catch { return fail(error.localizedDescription) }
        case "--connect": return report(Tailscale.connect())
        case "--disconnect": return report(Tailscale.disconnect())
        default:
            print(usage)
            return args.first == "--help" || args.first == "-h" ? 0 : 2
        }
    }

    private static func report(_ r: ShellResult) -> Int32 {
        if !r.ok { fputs(r.stderr.isEmpty ? r.stdout : r.stderr, stderr) }
        return r.ok ? 0 : 1
    }

    private static func fail(_ message: String) -> Int32 {
        fputs(message + "\n", stderr)
        return 2
    }
}
