import Foundation

@main enum ProbeTests {
    static func main() throws {
        let root = ProcRow(id: 7, parent: 1, rss: 100, cpu: 0, path: "/usr/local/bin/codex")
        let node = ProcRow(id: 8, parent: 7, rss: 300, cpu: 2, path: "/usr/local/bin/node")
        let detached = ProcRow(id: 9, parent: 1, rss: 400, cpu: 0, path: "/usr/local/bin/node")
        precondition(families([node, root, detached]) == [7: "Codex", 8: "Codex"])

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = temporary.appendingPathComponent("test repo").path
        let checkout = temporary.appendingPathComponent("linked checkout").path
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try run("/usr/bin/git", ["init", "-q", repo])
        _ = try run("/usr/bin/git", ["-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "fixture"])
        _ = try run("/usr/bin/git", ["-C", repo, "worktree", "add", "--detach", checkout])
        _ = try run("/usr/bin/git", ["-C", repo, "worktree", "lock", checkout])
        let all = try trees(checkout)
        precondition(all.count == 2 && all.contains { $0.branch == "detached" && $0.flags == "locked" })
        let fake = temporary.appendingPathComponent("docker")
        try """
        #!/bin/sh
        test "$1" = --host && test "$2" = unix:///fixture.sock && test "$3" = ps || exit 1
        printf 'abc123\\tdemo db\\tUp 2 minutes\\n'
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let containers = try Engine(cli: fake.path, socket: "/fixture.sock").containers()
        precondition(containers.count == 1 && containers.first?.name == "demo db")
        print("Passed process ancestry, linked checkout, and pinned Docker endpoint checks.")
    }
}
