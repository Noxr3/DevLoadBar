import SwiftUI
import AppKit

func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return arguments.isEmpty ? format : String(format: format, locale: Locale.current, arguments: arguments)
}

enum Page {
    case overview, disk, memory, battery, activity, settings, processes, worktrees, containers

    var title: String {
        switch self {
        case .overview: return "DevLoadBar"
        case .disk: return L("Disk")
        case .memory: return L("Memory")
        case .battery: return L("Battery")
        case .activity: return L("Activity")
        case .settings: return L("DevLoadBar Settings")
        case .processes: return L("Processes")
        case .worktrees: return L("Worktrees")
        case .containers: return L("Containers")
        }
    }
    var parent: Page {
        switch self {
        case .processes: return .memory
        case .worktrees: return .disk
        case .containers: return .battery
        default: return .overview
        }
    }
    var size: NSSize {
        switch self {
        case .overview: return NSSize(width: 440, height: 284)
        case .processes, .worktrees, .containers: return NSSize(width: 660, height: 510)
        case .settings: return NSSize(width: 440, height: 230)
        default: return NSSize(width: 492, height: 404)
        }
    }
}

@MainActor final class Navigation: ObservableObject {
    @Published private(set) var page = Page.overview
    var changed: ((Page) -> Void)?
    func show(_ value: Page) {
        guard value != page else { return }
        page = value
        changed?(value)
    }
}

struct Dashboard: View {
    @ObservedObject var model: Model
    @ObservedObject var navigation: Navigation
    @State private var advanced = false
    @State private var waitingToRefresh = false

    var body: some View {
        VStack(spacing: 0) {
            if navigation.page == .overview {
                overview
            } else {
                HStack {
                    Button { navigation.show(navigation.page.parent) } label: {
                        Label(L("Back"), systemImage: "chevron.backward")
                    }.keyboardShortcut("[", modifiers: .command)
                    Spacer()
                    if [.processes, .worktrees, .containers].contains(navigation.page) {
                        Button { refreshInspector() } label: {
                            Label(L("Refresh"), systemImage: "arrow.clockwise")
                        }.disabled(model.busy).keyboardShortcut("r")
                    }
                }.padding(.horizontal, 18).padding(.vertical, 10)
                Divider()
                detail
            }
            if !model.error.isEmpty && !(navigation.page == .containers && model.engine == nil) {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                    Text(model.error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button(L("Dismiss")) { model.error = "" }
                }.padding(10)
            }
        }
        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { model.refresh() }
        .onChange(of: model.busy) { busy in
            if !busy && waitingToRefresh { waitingToRefresh = false; refreshInspector() }
        }
        .onChange(of: navigation.page) { page in
            model.error = ""
            waitingToRefresh = false
            advanced = false
            if [.processes, .containers, .worktrees].contains(page) { refreshInspector() }
        }
    }

    func refreshInspector() {
        guard !model.busy else { waitingToRefresh = true; return }
        switch navigation.page {
        case .containers: model.listContainers()
        case .worktrees:
            let path = model.repo.isEmpty ? model.rules.repository : model.repo
            if !path.isEmpty { model.list(path) }
        default: model.refresh()
        }
    }

    var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("Automatic Management")).font(.system(size: 21, weight: .semibold))
                Spacer()
                Toggle(L("Automatic Management"), isOn: $model.rules.enabled)
                    .toggleStyle(.switch).labelsHidden()
            }
            VStack(spacing: 0) {
                resource(.disk, icon: "internaldrive.fill", color: .blue,
                         value: model.snapshot.map { L("%@ available", $0.disk) } ?? "—",
                         status: model.rules.repository.isEmpty ? L("Set Up") : state(model.rules.disk))
                Divider().padding(.leading, 53)
                resource(.memory, icon: "memorychip.fill", color: .purple,
                         value: pressureDescription,
                         status: state(model.rules.memory))
                Divider().padding(.leading, 53)
                resource(.battery, icon: model.power == "Battery" ? "battery.75" : "bolt.fill", color: .green,
                         value: model.power == "Battery" ? L("On battery") : model.power == "AC Power" ? L("Connected to power") : model.power,
                         status: model.rules.docker && model.rules.enabled ? (model.power == "AC Power" ? L("Standby") : L("Selected containers")) : state(model.rules.docker))
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.09)))
            HStack {
                Button { navigation.show(.activity) } label: { Label(L("Activity"), systemImage: "clock.arrow.circlepath") }
                Spacer()
                Menu {
                    Button(L("Settings…")) { navigation.show(.settings) }.keyboardShortcut(",")
                    Divider()
                    Button(L("Quit DevLoadBar")) { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L("More options")).help(L("More options"))
            }.buttonStyle(.link)
        }.padding(.horizontal, 22).padding(.vertical, 18)
    }

    var pressureDescription: String {
        switch model.snapshot?.pressure {
        case 1: return L("Normal memory pressure")
        case 2: return L("Elevated memory pressure")
        case 4: return L("Critical memory pressure")
        default: return model.snapshot.map { L("%@ swap used", $0.swap) } ?? "—"
        }
    }

    func state(_ enabled: Bool) -> String {
        guard enabled else { return L("Off") }
        return model.rules.enabled ? L("On") : L("Paused")
    }

    func resource(_ page: Page, icon: String, color: Color, value: String, status: String) -> some View {
        Button { navigation.show(page) } label: {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(color)
                    .frame(width: 32, height: 32).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(page.title).font(.headline)
                    Text(value).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(status).font(.callout).foregroundStyle(.secondary)
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 13).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel(Text([page.title, value, status].joined(separator: ", ")))
    }

    @ViewBuilder var detail: some View {
        switch navigation.page {
        case .processes, .worktrees, .containers:
            Inspector(model: model, page: navigation.page)
        case .activity:
            Text(L("Last check · %@", model.lastCheck)).font(.caption).foregroundStyle(.secondary).padding(.top, 12)
            if model.audit.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.secondary)
                    Text(L("No activity yet")).font(.headline)
                    Text(L("Automatic actions will appear here.")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { List(Array(model.audit.enumerated()), id: \.offset) { _, line in Text(line).textSelection(.enabled) } }
        default:
            Form {
                if !model.rules.enabled && [.disk, .memory, .battery].contains(navigation.page) {
                    Text(L("Automatic management is paused.")).foregroundStyle(.secondary)
                }
                switch navigation.page {
                case .disk: disk
                case .memory: memory
                case .battery: battery
                case .settings:
                    Toggle(L("Launch at login"), isOn: Binding(get: { model.loginEnabled }, set: { _ in model.toggleLogin() }))
                    LabeledContent(L("Version"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                default: EmptyView()
                }
            }.formStyle(.grouped)
        }
    }
    var disk: some View {
        Group {
            Section {
                LabeledContent(L("Repository")) {
                    Button(model.rules.repository.isEmpty ? L("Choose…") : URL(fileURLWithPath: model.rules.repository).lastPathComponent) {
                        model.enrollRepository()
                    }.disabled(model.busy).help(model.rules.repository)
                }
                Toggle(L("Clean up worktrees"), isOn: $model.rules.disk).toggleStyle(.switch).disabled(model.rules.repository.isEmpty)
            } footer: { Text(L("When storage runs low on AC power, remove old, clean worktrees whose changes have been merged. Branches are kept.")) }
            Section {
                DisclosureGroup(L("Options"), isExpanded: $advanced) {
                    Toggle(L("Also clear old build caches"), isOn: $model.rules.trimCaches).disabled(!model.rules.disk)
                    Text(L("Checks start below 10% or 25 GiB free. Eligible checkouts are at least seven days old and have no detected open files.")).font(.callout)
                }
            }
            Button(L("Inspect worktrees…")) { navigation.show(.worktrees) }
        }
    }
    var memory: some View {
        Group {
            Section {
                Toggle(L("Limit agent memory"), isOn: $model.rules.memory).toggleStyle(.switch)
            } footer: { Text(L("Stops a development worker after three high readings. Running jobs can be interrupted.")) }
            DisclosureGroup(L("Memory limits"), isExpanded: $advanced) {
                Stepper(L("Per process · %d GiB", model.rules.limitGiB), value: $model.rules.limitGiB, in: 1...64)
                Stepper(L("Under system pressure · %d GiB total", model.rules.groupGiB), value: $model.rules.groupGiB, in: 2...128)
                Toggle(L("Include Codex and Claude sessions"), isOn: $model.rules.includeAgentCLI)
            }
            Button(L("Inspect processes…")) { navigation.show(.processes) }
        }
    }
    var battery: some View {
        Group {
            Section {
                Toggle(L("Stop containers on battery"), isOn: $model.rules.docker).toggleStyle(.switch)
            } footer: { Text(L("After five minutes on battery, stop selected local containers. You can restart them when you need them.")) }
            Button(L("Choose containers…")) { navigation.show(.containers) }
            DisclosureGroup(L("Docker label"), isExpanded: $advanced) {
                Text("devloadbar.stop-on-battery=true").font(.body.monospaced()).textSelection(.enabled)
            }
        }
    }
}
