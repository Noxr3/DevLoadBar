import Foundation
import Darwin

@main enum PolicyTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message) }
    }
    static func main() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let repo = folder.appendingPathComponent("repo").path
        let checkout = folder.appendingPathComponent("linked").path
        func git(_ args: [String]) throws { _ = try run("/usr/bin/git", args) }
        try git(["init", "-q", "-b", "main", repo])
        try git(["-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "fixture"])
        try git(["-C", repo, "worktree", "add", "-b", "merged-job", checkout])
        var guardrail = DiskGuard()
        func pass(ac: Bool = true, low: Bool = true, open: [String] = [], cache: Bool = false, cutoff: Date = .distantFuture) throws -> String? {
            try guardrail.sweep(repo, cutoff: cutoff, pressure: { _ in low }, externalPower: { ac }, trimCaches: cache, inventory: { open })
        }
        try require(try pass(ac: false) == nil, "Battery must defer disk cleanup")
        try require(try pass(low: false) == nil, "Healthy volume must defer cleanup")
        try require(try pass(cutoff: .distantPast) == nil, "Fresh checkout")
        try require(try pass(open: [checkout + "/source"]) == nil, "Open checkout")
        let reader = Process()
        reader.executableURL = URL(fileURLWithPath: "/bin/sleep")
        reader.arguments = ["60"]
        reader.currentDirectoryURL = URL(fileURLWithPath: checkout)
        try reader.run()
        do {
            defer { reader.terminate(); reader.waitUntilExit() }
            let live = try guardrail.openPaths()
            try require(guardrail.inUse(checkout, paths: live), "Real open checkout missing from inventory")
        }
        try git(["-C", repo, "worktree", "lock", checkout])
        try require(try pass() == nil, "Locked checkout")
        try git(["-C", repo, "worktree", "unlock", checkout])
        let ignored = URL(fileURLWithPath: repo + "/.git/info/exclude")
        try ".next/\n".write(to: ignored, atomically: true, encoding: .utf8)
        let cache = checkout + "/.next/cache"
        try fm.createDirectory(atPath: cache, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: cache + "/generated"))
        try Data([42]).write(to: URL(fileURLWithPath: checkout + "/draft"))
        try require(try pass() == nil, "Dirty and ignored data protects checkout")
        try require(try pass(cache: true)?.hasPrefix("Removed ignored") == true, "Cold ignored cache must be reclaimed")
        try require(fm.fileExists(atPath: checkout + "/draft") && !fm.fileExists(atPath: cache), "Preserve draft while removing cache")
        try fm.removeItem(atPath: checkout + "/draft")
        try fm.removeItem(atPath: checkout + "/.next")
        try git(["-C", checkout, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "pending work"])
        try require(try pass() == nil, "Unmerged commit must protect checkout")
        try git(["-C", repo, "merge", "--ff-only", "merged-job"])
        try require(try pass()?.hasPrefix("Removed merged") == true, "Merged checkout should be removed")
        try require(!fm.fileExists(atPath: checkout), "Checkout still exists")
        try git(["-C", repo, "show-ref", "--verify", "refs/heads/merged-job"])
        print("Disk: reclaimed cache and checkout, preserved branch and draft, verified skip conditions.")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["20"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let root = ProcRow(id: getpid(), parent: 1, rss: 5, cpu: 0, path: "/fixture/codex")
        let worker = ProcRow(id: child.processIdentifier, parent: getpid(), rss: 10, cpu: 0, path: "/fixture/node")
        var memory = MemoryGuard()
        for _ in 0..<2 { try require(try memory.apply([root, worker], limit: 100, groupLimit: 12, pressured: true).isEmpty, "Pressure grace") }
        try require(try memory.apply([root, worker], limit: 100, groupLimit: 12, pressured: false).isEmpty, "Pressure reset")
        for _ in 0..<2 { try require(try memory.apply([root, worker], limit: 9).isEmpty, "RSS grace") }
        try require(try memory.apply([root, worker], limit: 9).count == 1, "Expected signal")
        child.waitUntilExit()
        try require(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM, "Incorrect signal")
        print("Memory: confirmed real SIGTERM after three controlled samples.")

        let second = Process()
        second.executableURL = URL(fileURLWithPath: "/bin/sleep")
        second.arguments = ["20"]
        try second.run()
        defer { if second.isRunning { second.terminate() } }
        let aggregateWorker = ProcRow(id: second.processIdentifier, parent: getpid(), rss: 512 * 1024 * 1024, cpu: 0, path: "/fixture/node")
        var aggregate = MemoryGuard()
        for _ in 0..<2 {
            try require(try aggregate.apply([root, aggregateWorker], limit: .max, groupLimit: 1, pressured: true).isEmpty, "Combined budget grace")
        }
        try require(try aggregate.apply([root, aggregateWorker], limit: .max, groupLimit: 1, pressured: true).count == 1, "Combined budget action")
        second.waitUntilExit()
        try require(second.terminationStatus == SIGTERM, "Combined budget signal")
        let selected = String(repeating: "a", count: 64), labeled = String(repeating: "b", count: 64), other = String(repeating: "c", count: 64)
        let disposable = String(repeating: "d", count: 64)
        let fake = folder.appendingPathComponent("docker"), stopped = fake.path + ".stopped"
        try """
        #!/bin/sh
        test "$1" = --host && test "$2" = unix:///fixture.sock || exit 2
        case "$3" in
          ps) printf '%s\\n' '\(selected) ' '\(labeled) true' '\(other) ' '\(disposable) true' ;;
          inspect) if test "$6" = '\(disposable)'; then echo true; else echo false; fi ;;
          stop) echo "$4" >> "$0.stopped" ;;
          *) exit 1 ;;
        esac
        """.write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let engine = Engine(cli: fake.path, socket: "/fixture.sock")
        try batteryStops(engine, enrolled: [selected], onBattery: { false }) { _ in }
        try require(!fm.fileExists(atPath: stopped), "AC must skip stop")
        try batteryStops(engine, enrolled: [selected], onBattery: { true }) { _ in }
        try require(try String(contentsOfFile: stopped, encoding: .utf8) == selected + "\n" + labeled + "\n", "Incorrect battery stop targets")
        print("Battery: fixture verified socket, enrolled IDs, Compose label and AC exclusion.")
    }
}
