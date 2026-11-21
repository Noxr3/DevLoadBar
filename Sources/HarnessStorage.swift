import Foundation

struct StorageRoot: Identifiable, Codable {
    let tool: String, path: String, kind: String
    var id: String { path }
}

struct StorageMeasurement: Identifiable, Codable {
    let root: StorageRoot
    let bytes: Int64?
    let categories: [String: Int64]
    var id: String { root.path }
}

struct HarnessStorage {
    let home: URL
    let env: [String: String]
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, env: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.env = env
    }

    func discover(repositories: [String], extra: [String]) -> [StorageRoot] {
        let fm = FileManager.default
        var roots = [String: StorageRoot]()
        func add(_ tool: String, _ path: String, _ kind: String = "Tool data") {
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { return }
            let physical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            guard physical != "/", physical != home.standardizedFileURL.path, roots[physical] == nil else { return }
            roots[physical] = StorageRoot(tool: tool, path: physical, kind: kind)
        }
        func local(_ name: String, _ path: String, _ kind: String = "Tool data") {
            add(name, home.appendingPathComponent(path).path, kind)
        }
        let markers = [("Claude Code",".claude"), ("Codex",".codex"), ("Gemini CLI",".gemini"),
                       ("Cursor",".cursor"), ("OpenCode",".opencode"), ("GitHub Copilot",".copilot"),
                       ("Windsurf",".windsurf"), ("Kiro",".kiro"), ("Continue",".continue"),
                       ("Cline",".cline"), ("Roo Code",".roo"), ("Goose",".goose"), ("Amp",".amp"),
                       ("Factory",".factory"), ("Pi",".pi"), ("Kilo Code",".kilocode"), ("Aider",".aider"),
                       ("Grok",".grok"), ("GrokBot",".grokbot"), ("Hermes",".hermes"), ("Qwen Code",".qwen"),
                       ("OpenHands",".openhands"), ("OpenClaw",".openclaw"), ("Kimi CLI",".kimi"),
                       ("Crush",".crush"), ("Augment",".augment"), ("Shared agent files",".agents")]
        for (name, marker) in markers { local(name, marker) }
        for (tool, path) in [("Codex",".codex-workspaces"), ("Cursor",".cursor-tutor"),
                             ("Agent Browser",".agent-browser"), ("Windsurf",".codeium/windsurf")] { local(tool, path) }
        let overrides = [("Codex","CODEX_HOME"), ("Claude Code","CLAUDE_CONFIG_DIR"),
                         ("OpenCode","OPENCODE_CONFIG_DIR"), ("Pi","PI_CODING_AGENT_DIR"),
                         ("GitHub Copilot","COPILOT_HOME")]
        for (tool, variable) in overrides {
            if let path = env[variable], path.hasPrefix("/") { add(tool, path) }
        }
        let xdg = [("XDG_CONFIG_HOME",".config","Configuration"), ("XDG_DATA_HOME",".local/share","Tool data"),
                   ("XDG_CACHE_HOME",".cache","Cache"), ("XDG_STATE_HOME",".local/state","Tool data")]
        for (variable, fallback, kind) in xdg {
            let base = env[variable].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? home.appendingPathComponent(fallback).path
            for (tool, sub) in [("OpenCode","opencode"), ("Claude Code","claude"), ("Cursor","cursor-agent"),
                                ("Amp","amp"), ("Goose","goose"), ("Codex","codex-runtimes"), ("Kilo Code","kilo")] {
                add(tool, base + "/" + sub, kind)
            }
        }
        let apps = [("Claude","Claude"), ("Claude","Claude-3p"), ("Codex","Codex"), ("Codex","com.openai.codex"),
                    ("Cursor","Cursor"), ("OpenCode","ai.opencode.desktop"), ("Antigravity","Antigravity"),
                    ("Windsurf","Windsurf"), ("Kiro","Kiro"), ("Trae","Trae")]
        for (tool, app) in apps {
            local(tool, "Library/Application Support/" + app, "Desktop data")
            local(tool, "Library/Caches/" + app, "Cache")
        }
        for (tool, cache) in [("Claude","com.anthropic.claudefordesktop"), ("Claude Code","claude-cli-nodejs"),
                              ("Antigravity","com.google.antigravity"), ("GitHub Copilot","copilot")] {
            local(tool, "Library/Caches/" + cache, "Cache")
        }
        for editor in ["Code", "Code - Insiders", "VSCodium", "Cursor", "Windsurf"] {
            for (tool, ext) in [("GitHub Copilot","github.copilot-chat"), ("Cline","saoudrizwan.claude-dev"),
                                ("Roo Code","rooveterinaryinc.roo-cline"), ("Kilo Code","kilocode.kilo-code"),
                                ("Continue","continue.continue")] {
                local(tool, "Library/Application Support/" + editor + "/User/globalStorage/" + ext, "Extension data")
            }
        }

        // Probe repository markers in common project locations; Git supplies linked checkout paths.
        var projects = Set(repositories.filter { !$0.isEmpty })
        for folder in ["", "Developer", "Projects", "src", "code", "repos", "Documents", "Documents/ChatGPT", "Documents/GitHub"] {
            let parent = home.appendingPathComponent(folder)
            guard let entries = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for entry in entries where fm.fileExists(atPath: entry.path + "/.git") { projects.insert(entry.path) }
        }
        var seen = Set<String>()
        for repo in projects.sorted() where !seen.contains(repo) {
            let checkouts = (try? trees(repo).map(\.id)) ?? [repo]
            for checkout in checkouts where seen.insert(checkout).inserted {
                for (tool, marker) in markers { add(tool, checkout + "/" + marker, "Project data") }
            }
        }
        for path in extra { add("Custom", path) }
        // Attribute nested roots to the encompassing store once, including embedded worktrees.
        var outer = Set<String>()
        return roots.values.sorted { $0.path.count < $1.path.count }.filter { item in
            var ancestor = URL(fileURLWithPath: item.path).deletingLastPathComponent()
            while ancestor.path.count > 1 {
                if outer.contains(ancestor.path) { return false }
                ancestor.deleteLastPathComponent()
            }
            outer.insert(item.path)
            return true
        }.sorted { ($0.kind == "Project data" ? 1 : 0, $0.tool, $0.path) < ($1.kind == "Project data" ? 1 : 0, $1.tool, $1.path) }
    }

    static func measure(_ root: StorageRoot) -> StorageMeasurement {
        do {
            let result = try run("/usr/bin/du", ["-k", "-x", "-d", "1", root.path], timeout: 300)
            var total: Int64?, classified = [String: Int64]()
            for line in result.split(separator: "\n") {
                let fields = line.split(separator: "\t", maxSplits: 1)
                guard fields.count == 2, let kb = Int64(fields[0]) else { continue }
                let path = String(fields[1])
                if path == root.path { total = kb * 1024; continue }
                let key = URL(fileURLWithPath: path).lastPathComponent.lowercased()
                let category: String?
                switch key {
                case "worktrees": category = "Worktrees"
                case "sessions", "archived_sessions", "session-state", "agent-transcripts", "file-history": category = "Session history"
                case "projects": category = root.tool == "Claude Code" ? "Projects and session history" : "Project data"
                case "cache", "caches", "code cache", "gpucache": category = "Cache"
                case "log", "logs": category = "Logs"
                case "tmp" where root.tool == "Gemini CLI": category = "Sessions and temporary data"
                default: category = nil
                }
                if let category { classified[category, default: 0] += kb * 1024 }
            }
            if let total {
                let other = total - classified.values.reduce(0, +)
                if other > 0 { classified[root.kind, default: 0] += other }
            }
            return StorageMeasurement(root: root, bytes: total, categories: classified)
        } catch { return StorageMeasurement(root: root, bytes: nil, categories: [:]) }
    }
}
