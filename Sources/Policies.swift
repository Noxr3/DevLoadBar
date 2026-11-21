import Foundation
import Darwin
import IOKit.ps

struct Rules: Codable, Equatable {
    var enabled = true
    var memory = false
    var trimCaches = false
    var groupGiB = 20
    var limitGiB = 8
    var includeAgentCLI = false
    var docker = true
    var repository = ""
    var disk = false
    var containerIDs: [String: [String]] = [:]
}

func batteryPower() -> Bool? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return nil }
    switch source as String {
    case kIOPSBatteryPowerValue: return true
    case kIOPSACPowerValue: return false
    default: return nil
    }
}

struct ProcessInstance: Hashable {
    let pid: Int32, seconds: UInt64, micros: UInt64
    static func read(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        let n = Int32(MemoryLayout.size(ofValue: info))
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, n) == n,
              info.pbi_uid == getuid() else { return nil }
        return Self(pid: pid, seconds: info.pbi_start_tvsec, micros: info.pbi_start_tvusec)
    }
}

struct MemoryGuard {
    var consecutive = [ProcessInstance: Int]()
    var signalled = Set<ProcessInstance>()
    var pressureSamples = 0

    mutating func apply(_ rows: [ProcRow], limit: Int64, includeAgentCLI: Bool = false, groupLimit: Int64 = .max, pressured: Bool = false) throws -> [String] {
        let owners = families(rows)
        let total = rows.filter { ["Codex", "Claude Code"].contains(owners[$0.id] ?? "") }.reduce(Int64(0)) { $0 + $1.rss }
        pressureSamples = pressured && total >= groupLimit ? min(3, pressureSamples + 1) : 0
        var next = [ProcessInstance: Int]()
        var events = [String]()
        for r in rows.sorted(by: { $0.rss > $1.rss }) {
            guard ["Codex", "Claude Code"].contains(owners[r.id] ?? "") else { continue }
            let name = r.name.lowercased()
            let worker = ["node", "bun", "deno", "esbuild", "vite", "next-server"].contains(name) || name.hasPrefix("next-server (")
            let cli = name == "codex" || name == "claude" || r.path.lowercased().contains("/claude/versions/")
            guard worker || (includeAgentCLI && cli), let instance = ProcessInstance.read(r.id) else { continue }
            next[instance] = r.rss >= limit ? min(3, (consecutive[instance] ?? 0) + 1) : 0
            guard events.isEmpty, (next[instance]! >= 3 || (pressureSamples >= 3 && r.rss >= 256 * 1024 * 1024)), !signalled.contains(instance) else { continue }
            try Task.checkCancellation()
            guard ProcessInstance.read(r.id) == instance else { continue }
            if kill(r.id, SIGTERM) == 0 {
                signalled.insert(instance)
                pressureSamples = 0
                events.append("Sent SIGTERM to \(r.name) (\(r.id)), RSS \(gib(r.rss))")
            } else { events.append("Could not signal \(r.name) (\(r.id)): errno \(errno)") }
        }
        consecutive = next
        signalled.formIntersection(Set(next.keys))
        return events
    }
}

func memoryPressured() -> Bool {
    (memoryPressureLevel() ?? 0) >= 2
}

struct DiskGuard {
    var cursor = 0
    let maxPerPass = 8
    func canonical(_ path: String) -> String {
        guard let physical = realpath(path, nil) else { return path }
        defer { free(physical) }
        return String(cString: physical)
    }

    func inUse(_ path: String, paths: [String]) -> Bool {
        var roots = Set([path, canonical(path)])
        for root in Array(roots) where root.hasPrefix("/private/") { roots.insert(String(root.dropFirst(8))) }
        return paths.contains { file in roots.contains { file == $0 || file.hasPrefix($0 + "/") } }
    }

    func openPaths() throws -> [String] {
        let raw = try run("/usr/sbin/lsof", ["-nP", "-F0n", "-u", NSUserName()], timeout: 30)
        let paths = raw.split(separator: "\0").compactMap { entry -> String? in
            guard entry.hasPrefix("n/") else { return nil }
            return String(entry.dropFirst())
        }
        guard !paths.isEmpty else { throw Failure("Open-file inventory unavailable") }
        return paths
    }

    func eligible(_ tree: Tree, primary: String, cutoff: Date) throws -> Bool {
        let path = tree.id
        guard tree.flags.isEmpty, canonical(primary) != canonical(path),
              tree.branch != "bare", FileManager.default.fileExists(atPath: path + "/.git") else { return false }
        func git(_ args: [String], at target: String) throws -> String {
            try run("/usr/bin/git", ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", target] + args)
        }
        let admin = try git(["rev-parse", "--absolute-git-dir"], at: path).trimmingCharacters(in: .newlines)
        for part in ["rebase-apply", "rebase-merge", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_START", "sequencer"] {
            if FileManager.default.fileExists(atPath: admin + "/" + part) { return false }
        }
        for item in [path, path + "/.git", admin + "/index", admin + "/HEAD", admin + "/logs/HEAD"] {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: item),
                  let date = attrs[.modificationDate] as? Date, date < cutoff else { return false }
        }
        let remote = try? git(["symbolic-ref", "refs/remotes/origin/HEAD"], at: primary).trimmingCharacters(in: .newlines)
        let ref: String
        if let remote, remote.hasPrefix("refs/remotes/origin/") { ref = remote }
        else if (try? git(["show-ref", "--verify", "refs/heads/main"], at: primary)) != nil { ref = "refs/heads/main" }
        else { ref = "refs/heads/master" }
        let protected = [String(ref.split(separator: "/").dropFirst(3).joined(separator: "/")), "main", "master", "staging", "develop"]
        guard !protected.contains(tree.branch) else { return false }
        let head = try git(["rev-parse", "HEAD"], at: path).trimmingCharacters(in: .newlines)
        // Any unknown merge relationship protects the checkout.
        guard (try? git(["merge-base", "--is-ancestor", head, ref], at: primary)) != nil else { return false }
        let status = try git(["status", "--porcelain=v1", "-z", "--ignored=matching", "--untracked-files=all", "--ignore-submodules=none"], at: path)
        guard status.isEmpty else { return false }
        let index = try git(["ls-files", "-v", "-z"], at: path)
        return index.split(separator: "\0").allSatisfy { $0.hasPrefix("H ") }
    }

    // Only these regenerable directories are covered by the separate cache policy.
    func coldCache(_ tree: Tree, cutoff: Date) throws -> URL? {
        guard tree.flags.isEmpty else { return nil }
        let base = URL(fileURLWithPath: canonical(tree.id))
        for name in [".next/cache", "node_modules/.cache"] {
            let candidate = base.appendingPathComponent(name)
            guard canonical(candidate.path) == candidate.path,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: candidate.path),
                  attrs[.type] as? FileAttributeType == .typeDirectory,
                  let changed = attrs[.modificationDate] as? Date, changed < cutoff else { continue }
            let git = ["--no-optional-locks", "-C", tree.id]
            guard (try? run("/usr/bin/git", git + ["check-ignore", "-q", "--", name + "/"])) != nil,
                  try run("/usr/bin/git", git + ["ls-files", "-z", "--", name]).isEmpty else { continue }
            // Reject nested repositories, mounted volumes and recent cache writes.
            let values: [URLResourceKey] = [.contentModificationDateKey, .isSymbolicLinkKey, .volumeIdentifierKey]
            let volume = try candidate.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
            guard let volume, volume.isEqual(try base.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) else { continue }
            var complete = true
            guard let scan = FileManager.default.enumerator(at: candidate, includingPropertiesForKeys: values, errorHandler: { _, _ in complete = false; return false }) else { continue }
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            for case let entry as URL in scan {
                try Task.checkCancellation()
                let info = try entry.resourceValues(forKeys: Set(values))
                if ProcessInfo.processInfo.systemUptime >= deadline || entry.lastPathComponent == ".git" ||
                    info.contentModificationDate.map({ $0 >= cutoff }) != false ||
                    (info.isSymbolicLink != true && !volume.isEqual(info.volumeIdentifier)) {
                    complete = false
                    break
                }
            }
            if complete { return candidate }
        }
        return nil
    }

    mutating func sweep(_ repo: String, cutoff: Date, pressure: (String) throws -> Bool,
                        externalPower: () -> Bool, trimCaches: Bool = false, inventory: () throws -> [String]) throws -> String? {
        guard externalPower(), try pressure(repo) else { return nil }
        let all = try trees(repo)
        guard let primary = all.first?.id, all.count > 1 else { return nil }
        let candidates = Array(all.dropFirst())
        var paths: [String]?
        for _ in 0..<min(maxPerPass, candidates.count) {
            let t = candidates[cursor % candidates.count]
            cursor = (cursor + 1) % candidates.count
            try Task.checkCancellation()
            let clean = try eligible(t, primary: primary, cutoff: cutoff)
            let cache = !clean && trimCaches ? try coldCache(t, cutoff: cutoff) : nil
            guard clean || cache != nil else { continue }
            if paths == nil { paths = try inventory() }
            guard !inUse(t.id, paths: paths ?? []), externalPower(), try pressure(t.id) else { continue }
            if let cache {
                guard try coldCache(t, cutoff: cutoff) == cache else { continue }
                try Task.checkCancellation()
                try FileManager.default.removeItem(at: cache)
                return "Removed ignored build cache: " + cache.path
            }
            // Recheck Git state after collecting open files. Git also checks the checkout on removal.
            guard try eligible(t, primary: primary, cutoff: cutoff) else { continue }
            try Task.checkCancellation()
            _ = try run("/usr/bin/git", ["-C", primary, "worktree", "remove", "--", t.id], timeout: 90)
            return "Removed merged checkout: " + t.id
        }
        return nil
    }
}

func lowDisk(_ path: String) throws -> Bool {
    let fs = try FileManager.default.attributesOfFileSystem(forPath: path)
    guard let available = fs[.systemFreeSize] as? NSNumber, let total = fs[.systemSize] as? NSNumber, total.doubleValue > 0 else { throw Failure("Disk capacity unavailable") }
    return available.doubleValue < max(25 * 1073741824, 0.10 * total.doubleValue)
}

func batteryStops(_ engine: Engine, enrolled: [String], onBattery: () -> Bool, record: (String) -> Void) throws {
    guard onBattery() else { return }
    let raw = try engine.command(["ps", "--no-trunc", "--format", "{{.ID}} {{.Label \"devloadbar.stop-on-battery\"}}"])
    for line in raw.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard let first = fields.first else { continue }
        let id = String(first)
        guard id.count == 64, id.allSatisfy(\.isHexDigit),
              enrolled.contains(id) || fields.dropFirst().first == "true" else { continue }
        try Task.checkCancellation()
        guard onBattery() else { break }
        let disposable = try engine.command(["inspect", "--format", "{{.HostConfig.AutoRemove}}", id]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard disposable == "false", onBattery() else { continue }
        try Task.checkCancellation()
        _ = try engine.command(["stop", id])
        record("Stopped battery-managed container " + id.prefix(12))
    }
}

actor PolicyRunner {
    var memory = MemoryGuard(), disk = DiskGuard()
    var batterySince: Date?, lastDisk = Date.distantPast
    var previous: Rules?
    func resetBatteryGrace() { batterySince = nil }
    func tick(_ rules: Rules) -> [String] {
        if previous != rules {
            memory = MemoryGuard()
            disk = DiskGuard()
            batterySince = nil
            lastDisk = .distantPast
            previous = rules
        }
        guard rules.enabled else { return [] }
        var events = [String]()
        if rules.memory {
            do { events += try memory.apply(processes(), limit: Int64(rules.limitGiB) * 1073741824, includeAgentCLI: rules.includeAgentCLI, groupLimit: Int64(rules.groupGiB) * 1073741824, pressured: memoryPressured()) }
            catch { events.append("Memory: " + error.localizedDescription) }
        }
        if rules.docker && batteryPower() == true {
            if batterySince == nil { batterySince = Date() }
            if Date().timeIntervalSince(batterySince!) >= 300 {
                do {
                    let engine = try Engine.local()
                    try batteryStops(engine, enrolled: rules.containerIDs[engine.socket] ?? [], onBattery: { batteryPower() == true }) { events.append($0) }
                } catch { events.append("Containers: " + error.localizedDescription) }
            }
        } else { batterySince = nil }
        if rules.disk && !rules.repository.isEmpty && Date().timeIntervalSince(lastDisk) >= 900 {
            lastDisk = Date()
            do {
                let path = rules.repository
                let probe = DiskGuard()
                let event = try disk.sweep(path, cutoff: Date().addingTimeInterval(-7 * 86400), pressure: lowDisk, externalPower: { batteryPower() == false }, trimCaches: rules.trimCaches, inventory: probe.openPaths)
                if let event { events.append(event) }
            } catch { events.append("Worktrees: " + error.localizedDescription) }
        }
        return events
    }
}
