import Foundation

@main enum StorageTests {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        for folder in [".claude/projects", "profiles/claude/worktrees", ".codex/sessions", ".gemini/tmp", ".hermes", "src/test/.claude/worktrees", "xdg/opencode/cache"] {
            try fm.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        _ = try run("/usr/bin/git", ["init", "-q", base.appendingPathComponent("src/test").path])
        try fm.createSymbolicLink(at: base.appendingPathComponent("alias"), withDestinationURL: base.appendingPathComponent(".codex"))
        let scan = HarnessStorage(home: base, env: ["CLAUDE_CONFIG_DIR":base.appendingPathComponent("profiles/claude").path,"XDG_DATA_HOME":base.appendingPathComponent("xdg").path])
        let roots = scan.discover(repositories: [], extra: [base.appendingPathComponent("alias").path, base.appendingPathComponent(".gemini/tmp").path])
        precondition(roots.count == 7)
        precondition(roots.filter { $0.tool == "Claude Code" }.count == 3)
        for root in roots {
            let row = HarnessStorage.measure(root)
            precondition(row.bytes != nil && row.categories.values.reduce(0,+) == row.bytes)
            if root.path.hasSuffix(".gemini") { precondition(row.categories["Sessions and temporary data"] != nil) }
            if root.path.hasSuffix("test/.claude") { precondition(row.categories["Worktrees"] != nil) }
        }
        print("Harness inventory: user and repository folders, Claude overrides, XDG, overlapping roots, and storage categories passed.")
    }
}
