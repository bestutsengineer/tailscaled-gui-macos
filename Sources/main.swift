import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
if let first = arguments.first, first.hasPrefix("--") || first == "-h" {
    exit(CLI.run(arguments))
}

// One instance at a time.
let bundleID = Bundle.main.bundleIdentifier ?? "local.tailnet"
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
