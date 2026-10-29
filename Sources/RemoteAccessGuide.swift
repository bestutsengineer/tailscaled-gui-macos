import AppKit
import SwiftUI

enum GuideSection: String, CaseIterable, Identifiable {
    case connection, restart, remoteDesktop, sleep, test
    var id: String { rawValue }
    var title: String {
        switch self {
        case .connection: return "Tailscale connection"
        case .restart: return "Restart & FileVault"
        case .remoteDesktop: return "Remote control"
        case .sleep: return "Keep the Mac awake"
        case .test: return "Test your setup"
        }
    }
    var icon: String {
        switch self {
        case .connection: return "network"
        case .restart: return "lock.shield"
        case .remoteDesktop: return "desktopcomputer"
        case .sleep: return "moon.zzz"
        case .test: return "checkmark.shield"
        }
    }
}

struct GuideCheck {
    enum Level { case good, attention, unknown }
    var label: String
    var level: Level
    var evidence: String
}

/// Checks are read-only. An unknown result is never treated as a successful setup.
enum RemoteAccessChecks {
    static func fileVault(_ result: ShellResult) -> GuideCheck {
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.ok && text.localizedCaseInsensitiveContains("FileVault is On") {
            return GuideCheck(label: "FileVault on", level: .attention, evidence: "Startup disk needs an unlock after a normal restart.")
        }
        if result.ok && text.localizedCaseInsensitiveContains("FileVault is Off") {
            return GuideCheck(label: "FileVault off", level: .good, evidence: "No FileVault unlock is expected at startup. A restart test is still needed.")
        }
        return GuideCheck(label: "Could not check FileVault", level: .unknown, evidence: "Check Privacy & Security → FileVault in System Settings.")
    }

    static func collect() -> [GuideSection: GuideCheck] {
        let state = Tailscale.read()
        let service = Shell.run("/bin/launchctl", ["print", "system/com.tailscale.tailscaled"], timeout: 4)
        let serviceRunning = service.ok && service.stdout.contains("state = running")
        let connection: GuideCheck
        if state.running && serviceRunning {
            connection = GuideCheck(label: "Connected · service running", level: .good, evidence: "The system service is running and Tailscale reports a connection now.")
        } else if state.error != nil {
            connection = GuideCheck(label: "Connection not confirmed", level: .unknown, evidence: "tailscaled-gui could not read the Tailscale state. Check the main menu and service.")
        } else {
            connection = GuideCheck(label: state.running ? "Check system service" : "Not connected", level: .attention, evidence: "The connection or system service is not currently confirmed.")
        }
        let fv = fileVault(Shell.run("/usr/bin/fdesetup", ["status"], timeout: 5))
        let rustInstalled = appInstalled(bundle: "com.carriez.rustdesk", name: "RustDesk")
        let rust = GuideCheck(label: rustInstalled ? "Installed · setup to verify" : "Installation not found",
                              level: rustInstalled ? .unknown : .attention,
                              evidence: rustInstalled ? "RustDesk was found. Its permissions, password, direct access and startup behavior need a manual check." : "RustDesk was not found in the usual app locations. It may be installed elsewhere.")
        let caffeine = appInstalled(bundle: "local.caffeine", name: "Caffeine")
        let assertions = Shell.run("/usr/bin/pmset", ["-g", "assertions"], timeout: 5)
        let awake = assertions.ok && assertions.stdout.split(separator: "\n").contains {
            $0.contains("(Caffeine)") && $0.contains("PreventUserIdleSystemSleep")
        }
        let sleep: GuideCheck
        if awake {
            sleep = GuideCheck(label: "Caffeine keeping awake now", level: .good, evidence: "A current Caffeine idle-sleep assertion was found. It may not survive a restart or closed lid.")
        } else if caffeine {
            sleep = GuideCheck(label: "Installed · check keep awake", level: .unknown, evidence: "Caffeine is installed, but an active Caffeine idle-sleep assertion was not confirmed.")
        } else {
            sleep = GuideCheck(label: "Caffeine not found", level: .attention, evidence: "Caffeine is optional; use it or another suitable sleep-prevention setup.")
        }
        return [.connection: connection, .restart: fv, .remoteDesktop: rust, .sleep: sleep,
                .test: GuideCheck(label: "Manual test required", level: .unknown, evidence: "Only an actual restart and remote connection can confirm the end-to-end setup.")]
    }

    private static func appInstalled(bundle: String, name: String) -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil { return true }
        let paths = ["/Applications/\(name).app", NSHomeDirectory() + "/Applications/\(name).app"]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }
}

final class RemoteAccessGuideModel: ObservableObject {
    @Published var checks: [GuideSection: GuideCheck] = [:]
    @Published var checking = false
    @Published var selected: GuideSection = .connection
    private var generation = 0

    func refresh() {
        generation += 1
        let request = generation
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let checks = RemoteAccessChecks.collect()
            DispatchQueue.main.async {
                guard request == self.generation else { return }
                self.checks = checks
                self.checking = false
            }
        }
    }
}

final class RemoteAccessGuideWindow {
    private let model = RemoteAccessGuideModel()
    private let window: NSWindow

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Unattended Remote Access Guide"
        window.minSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RemoteAccessGuideView(model: model))
        window.center()
    }

    func show() {
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct RemoteAccessGuideView: View {
    @ObservedObject var model: RemoteAccessGuideModel
    @State private var technical = false
    @State private var security = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("UNATTENDED ACCESS").font(.caption.weight(.bold)).foregroundColor(.secondary)
                Text("Your setup").font(.title2.weight(.bold))
                Text("Select a step to see what to do.").font(.callout).foregroundColor(.secondary)
                ForEach(GuideSection.allCases) { section in
                    Button {
                        model.selected = section
                        technical = false
                        security = false
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.icon).frame(width: 22).font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(section.title).fontWeight(.medium)
                                Text(model.checks[section]?.label ?? "Checking…").font(.caption).foregroundColor(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            statusIcon(model.checks[section]?.level)
                        }
                        .padding(10).contentShape(Rectangle())
                        .background(model.selected == section ? Color.accentColor.opacity(0.14) : Color.clear)
                        .cornerRadius(8)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Button(action: model.refresh) {
                    Label(model.checking ? "Checking…" : "Check again", systemImage: "arrow.clockwise")
                }.disabled(model.checking)
                Text("Checks are read-only.").font(.caption).foregroundColor(.secondary)
            }
            .padding(22).frame(width: 280).frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(model.selected.title, systemImage: model.selected.icon)
                        .font(.largeTitle.weight(.semibold))
                    if let check = model.checks[model.selected] {
                        HStack(alignment: .top, spacing: 10) {
                            statusIcon(check.level)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(check.label).font(.headline)
                                Text(check.evidence).font(.callout).foregroundColor(.secondary)
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(10)
                    } else {
                        Text("Checking this Mac…").foregroundColor(.secondary)
                    }
                    content
                    Spacer(minLength: 0)
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func statusIcon(_ level: GuideCheck.Level?) -> some View {
        let symbol = level == .good ? "checkmark.circle.fill" : level == .attention ? "exclamationmark.circle.fill" : "questionmark.circle.fill"
        let color: Color = level == .good ? .green : level == .attention ? .orange : .secondary
        return Image(systemName: symbol).foregroundColor(color).accessibilityLabel(level == .good ? "Checked" : level == .attention ? "Needs attention" : "Needs verification")
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.callout.weight(.bold)).foregroundColor(.accentColor)
                .frame(width: 25, height: 25).background(Color.accentColor.opacity(0.12)).clipShape(Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func link(_ label: String, _ url: String) -> some View {
        Link(label, destination: URL(string: url)!)
    }

    @ViewBuilder private var content: some View {
        switch model.selected {
        case .connection:
            Text("Keep this Mac connected to your tailnet so your other device can reach it.")
            step(1, "Connect tailscaled-gui using the menu bar icon. Leave it connected before restarting.")
            step(2, "Make sure your other device is signed in to the same tailnet and allowed to reach this Mac.")
            DisclosureGroup("Technical details", isExpanded: $technical) {
                Text("The check reads Tailscale status and launchctl's system service state. A running service today does not prove it will start after a restart, retain its connection preference, or be reachable through your network and tailnet policy.")
                    .font(.callout).foregroundColor(.secondary).padding(.top, 8)
            }
        case .restart:
            Text("A normal restart may need someone at the Mac to unlock its startup disk before remote services can start.")
            step(1, "Choose whether the convenience of starting without that unlock is worth reducing protection for files on a lost or stolen Mac.")
            step(2, "If you choose to turn FileVault off, open System Settings → Privacy & Security → FileVault, then follow Apple's prompts.")
            link("Open FileVault settings", "x-apple.systempreferences:com.apple.preference.security?FileVault")
            DisclosureGroup("What are the security concerns?", isExpanded: $security) {
                Text("FileVault adds protection for data when the Mac is shut down. Turning it off makes data easier to access if the Mac is lost or stolen. Your login password still protects the account if automatic login is off. iCloud Keychain uses its own encryption, but this does not replace protection for all local files. Keep FileVault on if these risks outweigh the convenience.")
                    .font(.callout).padding(.top, 8)
            }
            DisclosureGroup("Technical details", isExpanded: $technical) {
                Text("Apple silicon and T2 Macs use hardware encryption; FileVault adds protection tied to user credentials. FileVault does not prevent access by malware running in an unlocked account. One-time authenticated restart and physical unlock are alternatives, with their own constraints.")
                    .font(.callout).foregroundColor(.secondary).padding(.top, 8)
            }
            link("Apple: FileVault explained", "https://support.apple.com/guide/mac-help/mh11785/mac")
        case .remoteDesktop:
            Text("RustDesk lets you see and control this Mac from another device.")
            step(1, "Install RustDesk on both devices. On this Mac, grant the requested screen recording and accessibility permissions.")
            step(2, "In RustDesk security settings, enable direct IP access and set a strong, unique permanent password.")
            step(3, "Restrict access to trusted devices using RustDesk's IP allowlist or a firewall. Connect using this Mac's Tailscale IP.")
            HStack { link("Get RustDesk", "https://rustdesk.com/"); link("Mac setup", "https://rustdesk.com/docs/en/client/mac/") }
            DisclosureGroup("Security & technical details", isExpanded: $technical) {
                Text("Direct IP may listen on other network interfaces too; Tailscale alone does not make that listener private. Do not expose the port to the public internet. The usual direct port is 21118. Verify the allowlist, service, macOS permissions and login-screen access yourself; finding the app does not verify any of them.")
                    .font(.callout).padding(.top, 8)
            }
        case .sleep:
            Text("A sleeping Mac may be unreachable. Caffeine is an optional way to keep it awake.")
            step(1, "Install Caffeine, turn on its keep-awake mode, and review its power and battery settings.")
            step(2, "Check how it starts after a restart. Keep the Mac powered and connected to the internet.")
            link("Open Caffeine project", "https://github.com/bestutsengineer/caffeine")
            DisclosureGroup("Technical details", isExpanded: $technical) {
                Text("The check looks for a current Caffeine idle-system-sleep assertion. It does not prove a setting persists after reboot. A closed lid, power loss, battery protection, network changes or system sleep can still interrupt access. Caffeine cannot unlock FileVault.")
                    .font(.callout).foregroundColor(.secondary).padding(.top, 8)
            }
        case .test:
            Text("The only reliable way to know is to try the full journey while you can still reach the Mac in person.")
            step(1, "Leave tailscaled-gui connected and restart this Mac. Do not sign in or unlock it locally.")
            step(2, "From another device, connect to this Mac over Tailscale and try RustDesk with its unattended password.")
            step(3, "Confirm you can see and control the login screen, then repeat after your usual idle period.")
            Text("If it fails, use the steps on the left to review the connection, disk unlock, remote-control service and sleep settings.")
                .font(.callout).foregroundColor(.secondary)
            DisclosureGroup("Technical details", isExpanded: $technical) {
                Text("A check of installed apps and running services is only a snapshot. Startup behavior, login-screen permissions, firewall and tailnet rules, DNS, power and connectivity must be tested end to end. Keep a local recovery option available.")
                    .font(.callout).foregroundColor(.secondary).padding(.top, 8)
            }
        }
    }
}
