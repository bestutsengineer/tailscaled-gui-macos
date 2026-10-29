import Foundation

enum StatusClickAction: Equatable {
    case menu, toggle, connectLastExit
}

/// Wait for the whole sequence: the second click must not toggle before a third arrives.
struct StatusClickSequence {
    private var count = 0
    private var deadline: TimeInterval?

    mutating func receive(clickCount: Int, at now: TimeInterval, interval: TimeInterval) {
        count = min(max(clickCount, 1), 3)
        deadline = now + interval
    }

    mutating func resolve(at now: TimeInterval) -> StatusClickAction? {
        guard let deadline, now >= deadline else { return nil }
        let action: StatusClickAction = count >= 3 ? .connectLastExit : (count == 2 ? .toggle : .menu)
        cancel()
        return action
    }

    mutating func cancel() { count = 0; deadline = nil }
}

/// Separate from daemon prefs so a normal connection can clear ExitNodeID without forgetting it.
enum ExitNodeHistory {
    struct Saved: Codable, Equatable {
        var id: String
        var ip: String
        var name: String

        func resolve(in state: TailnetState) -> ExitNode? {
            state.exitNodes.first { id.isEmpty ? $0.ip == ip : $0.id == id }
        }
    }
    #if CONNECTION_TESTS
    static let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TAILNET_TEST_DIRECTORY"]!)
        .appendingPathComponent("last-exit-node.json")
    #else
    static let file = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Tailnet/last-exit-node.json")
    #endif

    static func load() throws -> Saved? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
    }

    static func save(_ node: ExitNode) throws {
        try save(Saved(id: node.id, ip: node.ip, name: node.name))
    }

    private static func save(_ saved: Saved) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func rememberSelection(_ state: TailnetState) throws {
        if let node = state.activeExitNode { try save(node) }
        else if state.usingExitNode {
            try save(Saved(id: state.exitNodeID, ip: state.exitNodeIP, name: state.exitNodeIP.isEmpty ? state.exitNodeID : state.exitNodeIP))
        }
    }
}
