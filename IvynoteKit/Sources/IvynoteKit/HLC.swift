import Foundation

/// Hybrid logical clock compatible with the server:
/// `<13-digit ms>-<4-hex counter>-<node>`, compared as strings.
struct HLC: Sendable {
    let node: String
    private(set) var wall: Int64 = 0
    private(set) var counter: Int = 0

    init(node: String) { self.node = node }

    mutating func tick(now: Int64) -> String {
        if now > wall {
            wall = now
            counter = 0
        } else {
            counter += 1
        }
        return Self.format(wall: wall, counter: counter, node: node)
    }

    mutating func observe(_ ts: String) {
        guard let p = Self.parse(ts) else { return }
        if p.wall > wall || (p.wall == wall && p.counter > counter) {
            wall = p.wall
            counter = p.counter
        }
    }

    static func format(wall: Int64, counter: Int, node: String) -> String {
        let w = String(wall)
        let c = String(counter & 0xffff, radix: 16)
        return String(repeating: "0", count: max(0, 13 - w.count)) + w + "-"
            + String(repeating: "0", count: max(0, 4 - c.count)) + c + "-" + node
    }

    static func parse(_ ts: String) -> (wall: Int64, counter: Int, node: String)? {
        let parts = ts.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 13, parts[1].count == 4,
              let wall = Int64(parts[0]), let counter = Int(parts[1], radix: 16) else { return nil }
        return (wall, counter, String(parts[2]))
    }
}
