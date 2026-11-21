import SwiftUI
import AppKit
import IOKit.ps
import ServiceManagement

@MainActor final class Model: ObservableObject {
    @Published var rules: Rules = {
        guard let data = UserDefaults.standard.data(forKey: "managementRules"),
              let rules = try? JSONDecoder().decode(Rules.self, from: data) else { return Rules() }
        return rules
    }() {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: "managementRules")
            policyTask?.cancel()
        }
    }
    @Published var audit = UserDefaults.standard.stringArray(forKey: "managementAudit") ?? []
    @Published var lastCheck = "Waiting for first check"
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    let runner = PolicyRunner()
    var policyTask: Task<Void, Never>?
    var timer: Timer?

    func startManager() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkRules() }
        }
        timer?.tolerance = 5
        checkRules()
    }
    func checkRules() {
        guard policyTask == nil else { return }
        let policy = rules
        policyTask = Task {
            let events = await runner.tick(policy)
            let stamp = Date().formatted(date: .abbreviated, time: .standard)
            audit.insert(contentsOf: events.map { stamp + " · " + $0 }, at: 0)
            audit = Array(audit.prefix(100))
            if !events.isEmpty { UserDefaults.standard.set(audit, forKey: "managementAudit") }
            lastCheck = stamp
            policyTask = nil
        }
    }
    func toggleLogin() {
        do {
            if loginEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { self.error = error.localizedDescription }
    }
    func enrollRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        load({ try trees(path).first?.id }) { primary in
            guard let primary else { self.error = "Choose a Git checkout"; return }
            self.rules.disk = false
            self.rules.repository = primary
        }
    }
    @Published var snapshot: Snapshot?
    @Published var power = "Checking power…"
    @Published var processDetail = ""
    func updatePower() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return }
        power = (source as String == kIOPSBatteryPowerValue) ? "Battery" : source as String
    }
    func locate(_ row: ProcRow) {
        load({
            let output = try run("/usr/sbin/lsof", ["-a", "-p", String(row.id), "-d", "cwd", "-Fn"])
            guard let cwd = output.split(separator: "\n").first(where: { $0.hasPrefix("n") }) else {
                throw Failure("Working directory unavailable")
            }
            return "\(row.name) · PID \(row.id) · " + String(cwd.dropFirst())
        }) { self.processDetail = $0 }
    }
    @Published var worktrees = [Tree]()
    @Published var containers = [Container]()
    @Published var engine: Engine?
    @Published var sizes = [String: String]()
    @Published var repo = UserDefaults.standard.string(forKey: "repository") ?? ""
    @Published var busy = false
    @Published var error = ""

    func load<T>(_ job: @escaping () throws -> T, then: @escaping (T) -> Void) {
        guard !busy else { return }
        busy = true
        error = ""
        Task {
            do {
                let value = try await Task.detached(priority: .utility) { try job() }.value
                then(value)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    func refresh() { load({ try Snapshot() }) { self.snapshot = $0 } }
    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        list(path)
    }
    func list(_ path: String) {
        load({ try trees(path) }) {
            self.repo = path
            self.worktrees = $0
            self.sizes = [:]
            UserDefaults.standard.set(path, forKey: "repository")
        }
    }
    func inspect(_ path: String, git: Bool = false) {
        load({
            if git {
                let status = try run("/usr/bin/git", ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", path, "status", "--porcelain=v1", "-z", "--untracked-files=normal"])
                return try usage(path) + (status.isEmpty ? " · clean" : " · local changes")
            }
            return try usage(path)
        }) { self.sizes[path] = $0 }
    }
    func listContainers() {
        engine = nil
        containers = []
        load({
            let engine = try Engine.local()
            return try (engine, engine.containers())
        }) { self.engine = $0.0; self.containers = $0.1 }
    }
    func stop(_ c: Container) {
        guard let engine else { return }
        let alert = NSAlert()
        alert.messageText = "Stop " + c.name + "?"
        alert.informativeText = "Services in this local container will be interrupted. Docker removes containers created with --rm when they stop."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Stop container")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        load({
            _ = try engine.command(["stop", c.id])
            return try engine.containers()
        }) { self.containers = $0 }
    }
}

struct Dashboard: View {
    @ObservedObject var model: Model
    @State private var tab = "Automation"
    @State private var search = ""
    @State private var sortCPU = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("DevLoadBar").font(.title2.bold())
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Refresh") { refresh() }
            }
            if let s = model.snapshot {
                HStack(spacing: 20) {
                    Label(model.power, systemImage: "bolt")
                    Text(s.swap + " swap used")
                    Text(s.disk + " disk free")
                }.monospacedDigit()
            }
            Picker("View", selection: $tab) {
                ForEach(["Automation", "Processes", "Disk", "Containers"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if !model.error.isEmpty { Text(model.error).foregroundStyle(.red).textSelection(.enabled) }
            if tab == "Automation" { managementView }
            if tab == "Processes" { processView }
            if tab == "Disk" { diskView }
            if tab == "Containers" { containerView }
        }.disabled(model.busy).padding(20).frame(minWidth: 590, minHeight: 490)
        .onAppear { model.refresh() }
        .onChange(of: tab) { value in
            if value == "Disk" && model.worktrees.isEmpty && !model.repo.isEmpty { model.list(model.repo) }
        }
    }
    @ViewBuilder var managementView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Toggle("Run background rules", isOn: $model.rules.enabled).font(.headline)
                Text("Last check · " + model.lastCheck).font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    Toggle("Limit memory of agent development workers", isOn: $model.rules.memory)
                    Stepper("Per-process RSS limit · " + String(model.rules.limitGiB) + " GiB", value: $model.rules.limitGiB, in: 1...64)
                    Stepper("Combined agent RSS under memory pressure · " + String(model.rules.groupGiB) + " GiB", value: $model.rules.groupGiB, in: 2...128)
                    Toggle("Include Codex and Claude CLI sessions", isOn: $model.rules.includeAgentCLI).disabled(!model.rules.memory)
                    Text("Three high samples send SIGTERM to one worker. Under system memory pressure the combined budget also applies. Active jobs may be interrupted.").font(.caption)
                    Divider()
                    Toggle("Stop managed containers after 5 minutes on battery", isOn: $model.rules.docker)
                    Text("Enroll containers in the Containers tab, or use the Docker label devloadbar.stop-on-battery=true.").font(.caption)
                    Divider()
                    HStack {
                        Text("Worktree cleanup").font(.headline)
                        Spacer()
                        Button("Choose repository…") { model.enrollRepository() }
                    }
                    if !model.rules.repository.isEmpty {
                        Text(model.rules.repository).font(.caption).textSelection(.enabled)
                    }
                    Toggle("Automatically remove eligible worktrees", isOn: $model.rules.disk).disabled(model.rules.repository.isEmpty)
                    Toggle("Also clear old ignored .next/cache and node_modules/.cache", isOn: $model.rules.trimCaches).disabled(!model.rules.disk)
                    Text("On AC, when free space falls below 10% or 25 GiB, remove at most one clean, merged checkout per 15 minutes. Requires 7-day-old checkout metadata and no detected open files. Branches are retained.").font(.caption)
                }.disabled(!model.rules.enabled)
                Divider()
                Button(model.loginEnabled ? "Disable launch at login" : "Launch at login") { model.toggleLogin() }
                Text("Activity").font(.headline)
                if model.audit.isEmpty { Text("No background actions recorded.").foregroundStyle(.secondary) }
                ForEach(Array(model.audit.enumerated()), id: \.offset) { _, line in Text(line).font(.caption).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    func refresh() {
        if tab == "Containers" { model.listContainers() }
        else if tab == "Disk" && !model.repo.isEmpty { model.list(model.repo) }
        else { model.refresh() }
    }
    @ViewBuilder var processView: some View {
        if let s = model.snapshot {
            let groups = Dictionary(grouping: s.rows.filter { s.labels[$0.id] != nil }, by: { s.labels[$0.id]! })
            ForEach(groups.keys.sorted(), id: \.self) { name in
                let members = groups[name] ?? []
                HStack {
                    Text(name).bold()
                    Text("\(members.count) processes").foregroundStyle(.secondary)
                    Spacer()
                    Text(gib(members.reduce(0) { $0 + $1.rss }) + " summed RSS")
                }
            }
            HStack {
                Text("Your processes").font(.headline)
                Spacer()
                Picker("Sort", selection: $sortCPU) {
                    Text("Memory").tag(false)
                    Text("CPU").tag(true)
                }.fixedSize()
            }
            if !model.processDetail.isEmpty { Text(model.processDetail).font(.caption).textSelection(.enabled) }
            List(sortCPU ? s.rows.sorted { $0.cpu > $1.cpu } : s.rows) { row in
                HStack {
                    VStack(alignment: .leading) {
                        Text(row.name).lineLimit(1)
                        Text(["PID \(row.id)", s.labels[row.id]].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.1f%% CPU", row.cpu))
                    Text(gib(row.rss)).frame(width: 88, alignment: .trailing)
                    Button("Locate") { model.locate(row) }
                }.monospacedDigit().textSelection(.enabled)
            }
            Button("Open Activity Monitor") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
        } else { Spacer() }
    }
    @ViewBuilder var diskView: some View {
        HStack {
            Text("Agent storage").font(.headline)
            Spacer()
            Menu("Measure folder") {
                ForEach([".codex/sessions", ".codex/archived_sessions", ".codex/worktrees", ".claude/projects", ".claude/worktrees"], id: \.self) { dir in
                    Button("~/" + dir) { model.inspect(NSHomeDirectory() + "/" + dir) }
                }
            }
        }
        ForEach(model.sizes.keys.sorted().filter { path in !model.worktrees.contains { $0.id == path } }, id: \.self) { path in
            Text((path as NSString).abbreviatingWithTildeInPath + "   " + (model.sizes[path] ?? ""))
        }
        HStack {
            Text("\(model.worktrees.count) registered worktrees").font(.headline)
            Spacer()
            Button("Choose repository…") { model.chooseRepository() }
        }
        if !model.repo.isEmpty { Text(model.repo).font(.caption).textSelection(.enabled) }
        TextField("Filter by branch or path", text: $search)
        List(model.worktrees.filter { search.isEmpty || ($0.id + $0.branch).localizedCaseInsensitiveContains(search) }) { tree in
            HStack {
                VStack(alignment: .leading) {
                    Text([tree.branch, tree.flags, model.sizes[tree.id] ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    Text(tree.id).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.help(tree.id)
                Spacer()
                Button("Inspect") { model.inspect(tree.id, git: true) }
                Button("Reveal") { NSWorkspace.shared.selectFile(tree.id, inFileViewerRootedAtPath: "") }
            }
        }
    }
    @ViewBuilder var containerView: some View {
        if model.power == "Battery" {
            Label("On battery · review running services", systemImage: "battery.50").foregroundStyle(.orange)
        }
        HStack {
            Text(model.engine == nil ? "Local Docker engine" : "\(model.containers.count) running containers").font(.headline)
            Spacer()
            Button("Inspect local engine") { model.listContainers() }
        }
        if let engine = model.engine { Text(engine.socket).font(.caption).textSelection(.enabled) }
        List(model.containers) { container in
            HStack {
                VStack(alignment: .leading) {
                    Text(container.name)
                    Text(container.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let socket = model.engine?.socket {
                    let enrolled = model.rules.containerIDs[socket] ?? []
                    Button(enrolled.contains(container.id) ? "Unmanage" : "Manage on battery") {
                        model.rules.containerIDs[socket] = enrolled.contains(container.id)
                            ? enrolled.filter { $0 != container.id } : enrolled + [container.id]
                    }
                }
                Button("Stop…") { model.stop(container) }
            }
        }
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var window: NSWindow!
    let model = Model()
    var powerSource: CFRunLoopSource?
    func powerChanged() {
        let oldSource = model.power
        model.updatePower()
        if oldSource != model.power { Task { await model.runner.resetBatteryGrace() } }
        item.button?.toolTip = "DevLoadBar · " + model.power
        let symbol = model.power == "Battery" ? "battery.50" : "gauge.with.dots.needle.67percent"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "DevLoadBar")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "DevLoadBar")
        item.button?.toolTip = "DevLoadBar"
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "Open DevLoadBar", action: #selector(display), keyEquivalent: "")
        show.target = self
        menu.addItem(withTitle: "Quit DevLoadBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        powerChanged()
        model.startManager()
        powerSource = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let delegate = Unmanaged<Delegate>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { delegate.powerChanged() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        window = NSWindow(contentViewController: NSHostingController(rootView: Dashboard(model: model)))
        window.title = "DevLoadBar"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 680, height: 575))
        window.isReleasedWhenClosed = false
        window.center()
        display()
    }
    @objc func display() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if model.snapshot != nil { model.refresh() }
    }
}

@main enum Launcher {
    @MainActor static func main() {
        do { try launch() }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    @MainActor static func launch() throws {
        let args = CommandLine.arguments
        if args.count > 1 {
            switch args[1] {
            case "--snapshot":
                let snap = try Snapshot()
                print("\(snap.power) | swap \(snap.swap) | disk free \(snap.disk)")
                for r in snap.rows.prefix(10) { print(r.id, r.name, gib(r.rss), snap.labels[r.id] ?? "") }
            case "--worktrees" where args.count == 3:
                let rows = try trees(args[2])
                print("\(rows.count) registered worktrees")
                for r in rows { print(r.branch, r.id, r.flags) }
            case "--containers":
                let e = try Engine.local()
                let rows = try e.containers()
                print("\(rows.count) running containers")
                for c in rows { print(c.name, c.status) }
            default: throw Failure("Expected --snapshot, --worktrees PATH or --containers")
            }
            return
        }
        let app = NSApplication.shared, delegate = Delegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
