import SwiftUI
import AppKit

struct Inspector: View {
    @ObservedObject var model: Model
    let page: Page
    @State private var sortCPU = false
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch page {
            case .processes: processView
            case .worktrees: diskView
            case .containers: containerView
            default: EmptyView()
            }
        }.padding(18)
    }
    @ViewBuilder var processView: some View {
        if let s = model.snapshot {
            let groups = Dictionary(grouping: s.rows.filter { s.labels[$0.id] != nil }, by: { s.labels[$0.id]! })
            ForEach(groups.keys.sorted(), id: \.self) { name in
                let members = groups[name] ?? []
                HStack {
                    Text(name).bold()
                    Text(L("%d processes", members.count)).foregroundStyle(.secondary)
                    Spacer()
                    Text(gib(members.reduce(0) { $0 + $1.rss }) + " RSS")
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
            Text(L("%d worktrees", model.worktrees.count)).font(.headline)
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
        if model.busy {
            ProgressView(L("Loading…")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.engine == nil {
            VStack(spacing: 10) {
                Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(.secondary)
                Text(L("Local Docker engine unavailable")).font(.headline)
                Text(L("Open your local container engine, then refresh.")).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.containers.isEmpty {
            Text(L("No running containers")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(L("%d running containers", model.containers.count)).font(.headline)
            List(model.containers) { container in
                HStack {
                    VStack(alignment: .leading) {
                        Text(container.name)
                        Text(container.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let socket = model.engine?.socket {
                        let enrolled = model.rules.containerIDs[socket] ?? []
                        Toggle(L("Stop on battery"), isOn: Binding(get: { enrolled.contains(container.id) }, set: { on in
                            model.rules.containerIDs[socket] = on ? enrolled + [container.id] : enrolled.filter { $0 != container.id }
                        })).toggleStyle(.checkbox)
                    }
                    Button("Stop…") { model.stop(container) }
                }
            }
        }
    }
}
