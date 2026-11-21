import Foundation
import Darwin

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Drain stdout while the task runs. A slow filesystem or socket must not wedge the UI.
func run(_ path: String, _ args: [String], timeout: Double = 12) throws -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["LC_ALL"] = "C"
    p.environment = env
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    defer { timer.cancel() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw Failure("\(URL(fileURLWithPath: path).lastPathComponent) failed or timed out (\(p.terminationStatus))") }
    return String(decoding: data, as: UTF8.self)
}

func gib(_ bytes: Int64) -> String {
    String(format: "%.2f GiB", Double(bytes) / 1073741824)
}

struct ProcRow: Identifiable {
    let id: Int32, parent: Int32, rss: Int64, cpu: Double, path: String
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var family: String? {
        let key = path.lowercased(), base = name.lowercased()
        if base == "codex" || base.hasPrefix("codex-") || base.hasPrefix("codex (") { return "Codex" }
        if base == "claude" || key.contains("/claude/versions/") { return "Claude Code" }
        if key.contains("/docker.app/") || base.hasPrefix("com.docker.") { return "Docker Desktop" }
        return nil
    }
}

func processes() throws -> [ProcRow] {
    let raw = try run("/bin/ps", ["-U", NSUserName(), "-ww", "-o", "pid=,ppid=,rss=,%cpu=,comm="])
    return raw.split(separator: "\n").compactMap { line in
        let p = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 4, whereSeparator: { $0.isWhitespace })
        guard p.count == 5, let id = Int32(p[0]), let parent = Int32(p[1]), let kb = Int64(p[2]), let cpu = Double(p[3]) else { return nil }
        return ProcRow(id: id, parent: parent, rss: kb * 1024, cpu: cpu, path: String(p[4]))
    }.sorted { $0.rss > $1.rss }
}

func families(_ rows: [ProcRow]) -> [Int32: String] {
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    var result = [Int32: String]()
    for row in rows {
        var cursor: ProcRow? = row, visited = Set<Int32>()
        while let current = cursor, visited.insert(current.id).inserted {
            if let family = result[current.id] ?? current.family {
                for id in visited { result[id] = family }
                break
            }
            cursor = byID[current.parent]
        }
    }
    return result
}

struct Tree: Identifiable {
    let id: String, branch: String, flags: String
}

func trees(_ repo: String) throws -> [Tree] {
    let raw = try run("/usr/bin/git", ["-C", repo, "worktree", "list", "--porcelain", "-z"])
    return raw.components(separatedBy: "\0\0").compactMap { record in
        let fields = record.components(separatedBy: "\0")
        guard let path = fields.first, path.hasPrefix("worktree ") else { return nil }
        let branch = fields.first { $0.hasPrefix("branch ") }.map { String($0.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "", options: .anchored) }
        return Tree(id: String(path.dropFirst(9)), branch: branch ?? (fields.contains("bare") ? "bare" : "detached"),
                    flags: fields.filter { $0.hasPrefix("locked") || $0.hasPrefix("prunable") }.joined(separator: " · "))
    }
}

func usage(_ path: String) throws -> String {
    let text = try run("/usr/bin/du", ["-skx", path], timeout: 90)
    guard let head = text.split(whereSeparator: { $0.isWhitespace }).first, let size = Int64(head) else { throw Failure("Size unavailable") }
    return gib(size * 1024)
}

struct Engine {
    let cli: String, socket: String
    static func local() throws -> Engine {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["/Applications/Docker.app/Contents/Resources/bin/docker", "/opt/homebrew/bin/docker", "/usr/local/bin/docker"]
        guard let cli = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else { throw Failure("Docker CLI unavailable") }
        let sockets = [home + "/.docker/run/docker.sock", home + "/.colima/default/docker.sock", home + "/.orbstack/run/docker.sock", "/var/run/docker.sock"]
        guard let socket = sockets.first(where: { path in
            var s = stat()
            return stat(path, &s) == 0 && s.st_mode & S_IFMT == S_IFSOCK
        }) else { throw Failure("No local Docker socket found") }
        return Engine(cli: cli, socket: socket)
    }
    func command(_ args: [String]) throws -> String {
        try run(cli, ["--host", "unix://" + socket] + args, timeout: 20)
    }
    func containers() throws -> [Container] {
        let raw: String
        do { raw = try command(["ps", "--no-trunc", "--format", "{{.ID}}\t{{.Names}}\t{{.Status}}"])
        } catch {
            throw Failure("Cannot list containers at " + socket + ". Check that the local engine is running and accessible.")
        }
        return raw.split(separator: "\n").compactMap {
            let parts = $0.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            return Container(id: String(parts[0]), name: String(parts[1]), status: String(parts[2]))
        }
    }
}
struct Container: Identifiable { let id: String, name: String, status: String }

func memoryPressureLevel() -> Int32? {
    var level: Int32 = 0, size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? level : nil
}

struct Snapshot {
    let pressure = memoryPressureLevel()
    let rows: [ProcRow], labels: [Int32: String], disk: String, swap: String, power: String
    init() throws {
        rows = try processes()
        labels = families(rows)
        let fs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        disk = gib((fs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0)
        var swapInfo = xsw_usage(), length = MemoryLayout<xsw_usage>.size
        swap = sysctlbyname("vm.swapusage", &swapInfo, &length, nil, 0) == 0 ? gib(Int64(swapInfo.xsu_used)) : "Unavailable"
        let batt = try run("/usr/bin/pmset", ["-g", "batt"])
        power = batt.contains("'Battery Power'") ? "Battery" : batt.contains("'AC Power'") ? "AC power" : "Unknown power source"
    }
}
