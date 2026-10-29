import Foundation

/// What the menu should show, built from a TailscaleState alone so `tailscaled-gui --menu` can print it.
struct MenuRow {
    enum Kind {
        case headline, section, info, warning, action, separator
        case toggle(Bool)
        case submenu([MenuRow])
    }

    enum Command: Equatable {
        case copyIP, connect, disconnect, login, exitNode(ExitNode?), toggleLAN
        case adminConsole, diagnose, refresh, toggleLoginItem, quit
        case remoteAccessGuide
    }

    var title: String
    var kind: Kind
    var symbol: String? = nil
    var command: Command? = nil
    var key: String = ""
    var tooltip: String? = nil
    var enabled = true

    static let separator = MenuRow(title: "—", kind: .separator)

    var flatTitles: [String] {
        let mark = enabled ? "" : " (disabled)"
        switch kind {
        case .separator: return ["—"]
        case .toggle(let on): return ["[\(on ? "x" : " ")] \(title)\(mark)"]
        case .warning: return ["! \(title)"]
        case .submenu(let children): return ["\(title) ▸"] + children.flatMap { $0.flatTitles.map { "    " + $0 } }
        default: return [title + mark]
        }
    }
}

enum MenuModel {
    static func headline(_ s: TailscaleState) -> String {
        if let error = s.error, !s.running { return "Tailscale: \(error)" }
        switch s.backendState {
        case "Running":
            if let node = s.activeExitNode { return "Connected · exit node \(node.name)" }
            if s.usingExitNode { return "Connected · exit node unavailable" }
            return "Connected"
        case "Stopped": return "Disconnected"
        case "NeedsLogin": return "Signed out"
        case "Starting", "NoState": return "Connecting…"
        default: return "Tailscale: \(s.backendState)"
        }
    }

    /// Menu bar icon: solid sword while connected (with an outward arrow when an exit node carries traffic),
    /// empty sword while not; errors stay in the menu and tooltip.
    static func icon(_ s: TailscaleState) -> SwordIcon {
        if !s.running { return .empty }
        return s.usingExitNode ? .exitNode : .solid
    }

    static func rows(_ s: TailscaleState, loginItem: Bool) -> [MenuRow] {
        var rows: [MenuRow] = []
        let headSymbol = s.running ? (s.exitNodeUnreachable ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                   : (s.needsLogin ? "person.crop.circle.badge.exclamationmark" : "pause.circle")
        rows.append(MenuRow(title: headline(s), kind: .headline, symbol: headSymbol))
        if let ip = s.selfIP {
            rows.append(MenuRow(title: "\(s.selfName ?? "This Mac") · \(ip)", kind: .action, symbol: "doc.on.doc",
                                command: .copyIP, tooltip: "Copy \(ip)"))
        }
        if s.exitNodeUnreachable {
            rows.append(MenuRow(title: "Exit node offline: internet traffic is blocked", kind: .warning,
                                symbol: "exclamationmark.triangle"))
        }

        rows.append(.separator)
        if s.needsLogin {
            rows.append(MenuRow(title: "Log In…", kind: .action, symbol: "person.crop.circle", command: .login))
        } else {
            rows.append(MenuRow(title: "Connected", kind: .toggle(s.running),
                                command: s.running ? .disconnect : .connect, key: "t",
                                enabled: s.error == nil || s.backendState == "Stopped"))
        }
        rows.append(MenuRow(title: "Exit Node", kind: .submenu(exitNodeRows(s)), symbol: "arrow.up.forward.circle"))

        rows.append(.separator)
        rows.append(MenuRow(title: "This Mac", kind: .section))
        rows.append(MenuRow(title: s.daemonInstalled ? "tailscaled daemon: system service\(s.exitFix ? " · exit-node fix" : "")"
                                                     : "tailscaled daemon: not installed",
                            kind: s.daemonInstalled ? .info : .warning, symbol: "lock.open.laptopcomputer",
                            tooltip: "The system service starts after the startup disk is unlocked. FileVault requires an unlock after restart."))
        if s.operatorUser == nil && s.error == nil {
            rows.append(MenuRow(title: "Changes need sudo: no operator set (see README)", kind: .warning))
        }
        for message in s.health.prefix(3) {
            rows.append(MenuRow(title: message, kind: .warning))
        }

        rows.append(.separator)
        rows.append(MenuRow(title: "Unattended Remote Access Guide…", kind: .action,
                            symbol: "desktopcomputer", command: .remoteAccessGuide))
        rows.append(MenuRow(title: "Open Admin Console", kind: .action, symbol: "safari", command: .adminConsole))
        rows.append(MenuRow(title: "Save Network Diagnostics…", kind: .action, symbol: "stethoscope", command: .diagnose))
        rows.append(MenuRow(title: "Refresh", kind: .action, symbol: "arrow.clockwise", command: .refresh, key: "r"))
        rows.append(MenuRow(title: "Start at Login", kind: .toggle(loginItem), command: .toggleLoginItem))
        rows.append(.separator)
        rows.append(MenuRow(title: "Quit tailscaled-gui", kind: .action, command: .quit, key: "q"))
        return rows
    }

    static func exitNodeRows(_ s: TailscaleState) -> [MenuRow] {
        let works = s.exitFix
        var rows: [MenuRow] = []
        if !works {
            rows.append(MenuRow(title: "Exit-node repair required (exitfix v4)", kind: .warning,
                                symbol: "exclamationmark.triangle",
                                tooltip: "Stock tailscaled on macOS doesn't route exit-node traffic, and clearing an exit node drops the network for a minute."))
            rows.append(.separator)
        }
        rows.append(MenuRow(title: "None", kind: .toggle(!s.usingExitNode), command: .exitNode(nil),
                            tooltip: works ? nil : "Clearing an exit node can remove this Mac's default route for a minute.",
                            enabled: s.running && (works || s.usingExitNode)))
        rows.append(.separator)
        if s.exitNodes.isEmpty {
            rows.append(MenuRow(title: s.running ? "No devices offer an exit node" : "Connect to see exit nodes", kind: .info))
        }
        for node in s.exitNodes {
            let detail = node.online ? node.ip : "offline"
            rows.append(MenuRow(title: "\(node.name)  (\(detail))", kind: .toggle(node.selected),
                                command: .exitNode(node), tooltip: node.dnsName,
                                enabled: works && s.running && (node.online || node.selected)))
        }
        if s.usingExitNode && s.activeExitNode == nil {
            rows.append(MenuRow(title: "Selected node isn't in the tailnet list", kind: .warning))
        }
        rows.append(.separator)
        rows.append(MenuRow(title: "Allow Local Network Access", kind: .toggle(s.allowLAN), command: .toggleLAN,
                            tooltip: "While an exit node is in use: on keeps printers, NAS and the router reachable; "
                                + "off sends everything through the exit node. Tailscale peers work either way.",
                            enabled: works && s.error == nil))
        return rows
    }
}
