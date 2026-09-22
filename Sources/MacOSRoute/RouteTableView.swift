import AppKit
import RouteHelperCore
import RouteShared
import SwiftUI

struct RouteTableView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "Все"
        case staticRoutes = "Статические"
        case stale = "Устаревшие"
        case managed = "Управляет MacOSRoute"
        var id: String { rawValue }
    }

    struct Row: Identifiable {
        var entry: RouteEntry
        var staleReason: String?
        var managed: Bool
        var id: String { entry.id }
    }

    @EnvironmentObject private var client: HelperClient
    @EnvironmentObject private var navigation: AppNavigation
    @State private var entries: [RouteEntry] = []
    @State private var localAddresses: [LocalAddress] = []
    @State private var filter: Filter = .all
    @State private var showCloned = false
    @State private var search = ""
    @State private var selection = Set<Row.ID>()
    @State private var pendingDeletion: [String]?
    @State private var updatedAt = Date()

    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var managedAddresses: Set<String> {
        Set(client.state?.managedRoutes.map(\.address) ?? [])
    }

    private var allRows: [Row] {
        let managed = managedAddresses
        return entries.map { entry in
            Row(entry: entry,
                staleReason: RouteAnalyzer.staleReason(entry, localAddresses: localAddresses),
                managed: managed.contains(entry.address) && entry.isStatic && !entry.isScoped)
        }
    }

    private var rows: [Row] {
        allRows.filter { row in
            if !showCloned, filter == .all, row.entry.isCloned || row.entry.isLinkLayer { return false }
            switch filter {
            case .all: break
            case .staticRoutes: if !row.entry.isStatic { return false }
            case .stale: if row.staleReason == nil { return false }
            case .managed: if !row.managed { return false }
            }
            guard !search.isEmpty else { return true }
            return [row.entry.displayDestination, row.entry.gateway ?? "", row.entry.interface].contains { $0.localizedCaseInsensitiveContains(search) }
        }
        .sorted { ($0.entry.prefix, $0.entry.destination) < ($1.entry.prefix, $1.entry.destination) }
    }

    /// Устаревшие маршруты, которые можно удалить (кроме управляемых MacOSRoute — их фоновая служба исправит сама)
    private var staleAddresses: [String] {
        Array(Set(allRows.filter { $0.staleReason != nil && !$0.managed }.map(\.entry.address))).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
        }
        .searchable(text: $search, prompt: "Поиск по адресу назначения, шлюзу или интерфейсу")
        .onAppear(perform: reload)
        .onReceive(timer) { _ in reload() }
        .confirmationDialog("Удалить статические маршруты (\(pendingDeletion?.count ?? 0))?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Удалить", role: .destructive) {
                if let addresses = pendingDeletion { client.deleteSystemRoutes(addresses) { reload() } }
                pendingDeletion = nil
            }
        } message: {
            Text((pendingDeletion ?? []).prefix(12).joined(separator: "\n") + ((pendingDeletion?.count ?? 0) > 12 ? "\n…" : ""))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { f in
                    if f == .stale, !staleAddresses.isEmpty {
                        Text("\(f.rawValue) (\(staleAddresses.count))").tag(f)
                    } else {
                        Text(f.rawValue).tag(f)
                    }
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Toggle("Показывать кэш / записи ARP", isOn: $showCloned)
                .disabled(filter != .all)
            Spacer()
            Text("Записей: \(rows.count) · \(updatedAt.formatted(date: .omitted, time: .standard))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                pendingDeletion = staleAddresses
            } label: {
                Label("Удалить устаревшие", systemImage: "trash")
            }
            .disabled(staleAddresses.isEmpty || !client.canModify || client.isBusy)
            .help("Удалить статические маршруты, шлюз которых больше не входит ни в одну текущую сеть — например, оставшиеся от скриптов после смены сети")
        }
        .controlSize(.small)
        .padding(12)
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Назначение") { row in
                HStack(spacing: 6) {
                    Text(row.entry.displayDestination).monospaced()
                    if row.managed {
                        Text("MacOSRoute").font(.caption2).padding(.horizontal, 4).background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                    if row.staleReason != nil {
                        Text("устарел").font(.caption2).foregroundStyle(.white).padding(.horizontal, 4).background(Color.red, in: Capsule())
                    }
                }
                .help(row.staleReason ?? "")
            }
            .width(min: 160, ideal: 240)
            TableColumn("Шлюз") { row in
                Text(row.entry.gateway ?? "link").monospaced().foregroundStyle(row.entry.gateway == nil ? .secondary : .primary)
            }
            .width(min: 100, ideal: 140)
            TableColumn("Интерфейс") { row in Text(row.entry.interface) }
                .width(min: 50, ideal: 70)
            TableColumn("Источник") { row in
                Text(row.entry.interfaceAddress ?? "—").monospaced().foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130)
            TableColumn("Флаги") { row in
                Text(row.entry.flagString).monospaced().help(flagHelp)
            }
            .width(min: 50, ideal: 70)
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            let selected = allRows.filter { ids.contains($0.id) }
            if let first = selected.first, selected.count == 1 {
                Button("Диагностика \(first.entry.destination)") { navigation.diagnose(first.entry.destination) }
            }
            let convertible = selected.filter { $0.entry.prefix > 0 && !$0.managed }.map(\.entry.address)
            Button("Добавить как правило (через физический шлюз)") {
                client.addTargets(from: convertible.joined(separator: " "))
            }
            .disabled(convertible.isEmpty || !client.canModify)
            Button("Копировать") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selected.map { "\($0.entry.displayDestination) \($0.entry.gateway ?? "link") \($0.entry.interface) \($0.entry.flagString)" }.joined(separator: "\n"), forType: .string)
            }
            Divider()
            let deletable = selected.filter { $0.entry.isStatic && !$0.managed && !$0.entry.isScoped }.map(\.entry.address)
            Button("Удалить статический маршрут…", role: .destructive) { pendingDeletion = deletable }
                .disabled(deletable.isEmpty || !client.canModify)
        }
    }

    private let flagHelp = "U активен · G через шлюз · H хост · S статический · C клонируемый · W клонирован · L канальный уровень · I привязан к интерфейсу"

    private func reload() {
        entries = RoutingTable.dump()
        localAddresses = LocalAddress.current()
        updatedAt = Date()
    }
}
