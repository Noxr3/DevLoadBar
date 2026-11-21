import SwiftUI

@MainActor final class StorageInventory: ObservableObject {
    @Published var entries = [StorageMeasurement]()
    @Published var running = false
    @Published var count = 0
    private let defaults = UserDefaults.standard
    private var lastScan: Date?
    init() {
        if let data = defaults.data(forKey: "harnessInventory"),
           let saved = try? JSONDecoder().decode([StorageMeasurement].self, from: data) {
            entries = saved
            lastScan = defaults.object(forKey: "harnessScanTime") as? Date
        }
    }
    func scan(repositories: [String], force: Bool = false) {
        guard !running, force || Date().timeIntervalSince(lastScan ?? .distantPast) >= 86400 else { return }
        let extra = defaults.stringArray(forKey: "additionalHarnessRoots") ?? []
        running = true
        count = 0
        Task {
            let roots = await Task.detached(priority: .utility) { HarnessStorage().discover(repositories: repositories, extra: extra) }.value
            count = roots.count
            entries = []
            for root in roots {
                let row = await Task.detached(priority: .utility) { HarnessStorage.measure(root) }.value
                entries.append(row)
            }
            lastScan = Date()
            defaults.set(try? JSONEncoder().encode(entries), forKey: "harnessInventory")
            defaults.set(lastScan, forKey: "harnessScanTime")
            running = false
        }
    }
    func addFolder(repositories: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        let current = defaults.stringArray(forKey: "additionalHarnessRoots") ?? []
        defaults.set(Array(Set(current + [path])), forKey: "additionalHarnessRoots")
        scan(repositories: repositories, force: true)
    }
}

struct StorageView: View {
    @ObservedObject var inventory: StorageInventory
    let repositories: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if inventory.running {
                    ProgressView().controlSize(.small)
                    Text(inventory.count == 0 ? L("Finding folders…") : L("Measured %d of %d folders", inventory.entries.count, inventory.count))
                } else {
                    Text(L("%d folders", inventory.entries.count))
                }
                Spacer()
                Button(L("Add folder…")) { inventory.addFolder(repositories: repositories) }.disabled(inventory.running)
            }
            List {
                let groups = Dictionary(grouping: inventory.entries, by: { $0.root.tool })
                ForEach(groups.keys.sorted(), id: \.self) { name in
                    let rows = groups[name] ?? []
                    DisclosureGroup {
                        ForEach(rows.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }) { row in
                            VStack(alignment: .leading) {
                                Text((row.root.path as NSString).abbreviatingWithTildeInPath).textSelection(.enabled)
                                Text(row.bytes == nil ? L("Measurement unavailable") : row.categories.keys.sorted().map {
                                    L($0) + " " + gib(row.categories[$0] ?? 0)
                                }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        HStack {
                            Text(name)
                            Spacer()
                            Text(gib(rows.compactMap(\.bytes).reduce(0,+)))
                            if rows.contains(where: { $0.bytes == nil }) { Text(L("Partial")).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }.padding(16)
    }
}
