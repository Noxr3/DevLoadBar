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
        panel.prompt = L("Choose")
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
        panel.prompt = L("Choose")
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
        alert.messageText = L("Stop %@?", c.name)
        alert.informativeText = L("Stopping interrupts this service. Docker deletes containers created with --rm.")
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Stop Container"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        load({
            _ = try engine.command(["stop", c.id])
            return try engine.containers()
        }) { self.containers = $0 }
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var window: NSWindow!
    let navigation = Navigation()
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
        item.button?.target = self
        item.button?.action = #selector(display)
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Settings…"), action: #selector(settings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit DevLoadBar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        powerChanged()
        model.startManager()
        powerSource = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let delegate = Unmanaged<Delegate>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { delegate.powerChanged() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        window = NSWindow(contentViewController: NSHostingController(rootView: Dashboard(model: model, navigation: navigation)))
        window.title = "DevLoadBar"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        navigation.changed = { [weak self] page in self?.resize(for: page) }
        window.contentMinSize = NSSize(width: 410, height: 280)
        window.setContentSize(Page.overview.size)
        window.isReleasedWhenClosed = false
        window.center()
        display()
    }
    func resize(for page: Page) {
        window.contentMinSize = NSSize(width: page == .overview ? 410 : min(492, page.size.width), height: min(280, page.size.height))
        window.title = page.title
        let size = page.size
        let old = window.frame
        var next = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        next.origin = NSPoint(x: old.midX - next.width / 2, y: old.maxY - next.height)
        window.setFrame(window.constrainFrameRect(next, to: window.screen), display: true)
    }
    @objc func settings() { display(); navigation.show(.settings) }
    @objc func display() {
        navigation.show(.overview)
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
