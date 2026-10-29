import AppKit

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var state = TailscaleState()
    private var currentIcon = ""
    private var busy = false
    private var refreshing = false
    private var clickTimer: Timer?
    private var clicks = StatusClickSequence()
    private let work = DispatchQueue(label: "tailscaled-gui.work")
    private var remoteGuide: RemoteAccessGuideWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        work.async {
            do { try LoginItem.migrateLegacy() }
            catch { DispatchQueue.main.async { self.showAlert("Couldn't update the login item", error.localizedDescription) } }
        }

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
        let timer = Timer(timeInterval: 10, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Reads tailscaled off the main thread, then updates the icon.
    @objc private func refresh() {
        guard !refreshing && !busy else { return }
        refreshing = true
        work.async {
            let fresh = Tailscale.read()
            DispatchQueue.main.async {
                self.refreshing = false
                self.state = fresh
                self.updateIcon()
            }
        }
    }

    private func updateIcon() {
        let icon = MenuModel.icon(state)
        statusItem.button?.toolTip = "tailscaled-gui: " + MenuModel.headline(state)
            + "\nDouble-click: enable without exit node / disable"
            + "\nTriple-click: enable with last used exit node"
            + "\nSingle-click or right-click: menu"
        guard icon.rawValue != currentIcon else { return }
        currentIcon = icon.rawValue
        statusItem.button?.image = icon.menuBarImage
    }

    // MARK: Menu

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        guard !busy, let event = NSApp.currentEvent else { return }
        clickTimer?.invalidate()
        // Control-click is a secondary click for both mice and trackpads.
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            clicks.cancel()
            showMenu()
            return
        }
        let interval = NSEvent.doubleClickInterval
        clicks.receive(clickCount: event.clickCount, at: ProcessInfo.processInfo.systemUptime, interval: interval)
        let timer = Timer(timeInterval: interval + 0.02, repeats: false) { [weak self] _ in
            guard let self, !self.busy,
                  let action = self.clicks.resolve(at: ProcessInfo.processInfo.systemUptime) else { return }
            switch action {
            case .menu: self.showMenu()
            case .toggle: self.run("Couldn't change connection") { Tailscale.toggleConnection() }
            case .connectLastExit: self.run("Couldn't connect using the last exit node") { Tailscale.connect(useLastExit: true) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clickTimer = timer
    }

    private func showMenu() {
        // AppKit positions status-item menus below the menu bar and handles screen edges.
        // The temporary menu assignment preserves our single/double/triple click handler.
        guard let button = statusItem.button else { return }
        statusItem.menu = menu
        defer { statusItem.menu = nil }
        button.performClick(nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Render immediately; CLI reads stay on the worker queue.
        refresh()
        menu.removeAllItems()
        MenuModel.rows(state, loginItem: LoginItem.isEnabled).map(makeItem).forEach(menu.addItem)
    }

    private func makeItem(_ row: MenuRow) -> NSMenuItem {
        switch row.kind {
        case .separator: return .separator()
        case .section: return .sectionHeader(title: row.title)
        default: break
        }
        let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: row.key)
        if let command = row.command {
            item.target = self
            item.action = #selector(menuAction(_:))
            item.representedObject = CommandBox(command)
        }
        if let symbol = row.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        item.toolTip = row.tooltip
        item.isEnabled = row.enabled && !busy
        switch row.kind {
        case .headline:
            item.attributedTitle = NSAttributedString(string: row.title,
                                                      attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            item.isEnabled = false
        case .info:
            item.isEnabled = false
        case .warning:
            item.attributedTitle = NSAttributedString(string: row.title, attributes: [.foregroundColor: NSColor.systemOrange])
            item.isEnabled = false
        case .toggle(let on):
            item.state = on ? .on : .off
        case .submenu(let children):
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            children.map(makeItem).forEach(submenu.addItem)
            item.submenu = submenu
            item.isEnabled = true
        default:
            break
        }
        return item
    }

    // MARK: Actions

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard !busy, let command = (sender.representedObject as? CommandBox)?.command else { return }
        switch command {
        case .copyIP:
            guard let ip = state.selfIP else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ip, forType: .string)
        case .connect: run("Couldn't connect") { Tailscale.connect() }
        case .disconnect: run("Couldn't disconnect") { Tailscale.disconnect() }
        case .exitNode(let node): run("Couldn't change the exit node") { Tailscale.setExitNode(node) }
        case .toggleLAN:
            let allow = !state.allowLAN
            run("Couldn't change local network access") { Tailscale.setAllowLAN(allow) }
        case .login:
            busy = true
            Tailscale.login(onURL: { NSWorkspace.shared.open($0) },
                            done: { _ in self.busy = false; self.refresh() })
        case .adminConsole: NSWorkspace.shared.open(Tailscale.adminConsole)
        case .remoteAccessGuide:
            if remoteGuide == nil { remoteGuide = RemoteAccessGuideWindow() }
            remoteGuide?.show()
        case .diagnose:
            busy = true
            work.async {
                let result = ExitDiagnostics.collect()
                DispatchQueue.main.async {
                    self.busy = false
                    self.showAlert("Network Diagnostics", result.stdout)
                    if result.ok { NSWorkspace.shared.open(ExitDiagnostics.directory) }
                }
            }
        case .refresh: refresh()
        case .toggleLoginItem: toggleLoginItem()
        case .quit: NSApp.terminate(nil)
        }
    }

    /// Runs one tailscale change in the background; shows the CLI's own error if it fails.
    private func run(_ failureTitle: String, _ change: @escaping () -> ShellResult) {
        clickTimer?.invalidate()
        clicks.cancel()
        busy = true
        work.async {
            let result = change()
            let fresh = Tailscale.read()
            DispatchQueue.main.async {
                self.busy = false
                self.state = fresh
                self.updateIcon()
                if !result.ok {
                    let message = [result.stderr, result.stdout]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first(where: { !$0.isEmpty }) ?? "tailscale exited with \(result.status)"
                    self.showAlert(failureTitle, message)
                }
            }
        }
    }

    private func toggleLoginItem() {
        if LoginItem.isEnabled {
            LoginItem.disable()
        } else {
            do { try LoginItem.enable() } catch { showAlert("Couldn't add the login item", error.localizedDescription) }
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

}

/// NSMenuItem.representedObject needs a class; MenuRow.Command is an enum with payloads.
final class CommandBox {
    let command: MenuRow.Command
    init(_ command: MenuRow.Command) { self.command = command }
}
