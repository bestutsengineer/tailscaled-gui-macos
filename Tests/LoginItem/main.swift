import Foundation

enum Shell {
    static func run(_ path: String, _ args: [String] = [], timeout: TimeInterval = 10) -> Int { 0 }
}
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TAILSCALED_GUI_TEST_DIRECTORY"]!)
precondition(root.path.contains("tailscaled-gui-tests."))
let fm = FileManager.default
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
let legacy = root.appendingPathComponent("old.plist")
let current = root.appendingPathComponent("new.plist")
func write(_ url: URL) { try! Data("test".utf8).write(to: url) }
var stopped = false
try! LoginItem.migrateLegacy(legacy: legacy, current: current, create: { fatalError("should not create") }, stopLegacy: { stopped = true })
precondition(!stopped)
write(legacy)
do {
    try LoginItem.migrateLegacy(legacy: legacy, current: current, create: { throw NSError(domain: "test", code: 1) }, stopLegacy: { stopped = true })
    fatalError("failed creation must throw")
} catch {}
precondition(fm.fileExists(atPath: legacy.path) && !stopped)
try! LoginItem.migrateLegacy(legacy: legacy, current: current, create: { write(current) }, stopLegacy: { stopped = true })
precondition(stopped && fm.fileExists(atPath: current.path) && !fm.fileExists(atPath: legacy.path))
write(legacy); stopped = false
try! LoginItem.migrateLegacy(legacy: legacy, current: current, create: { fatalError("must preserve existing item") }, stopLegacy: { stopped = true })
precondition(stopped && !fm.fileExists(atPath: legacy.path) && fm.fileExists(atPath: current.path))
print("4 login-item migration checks passed.")
