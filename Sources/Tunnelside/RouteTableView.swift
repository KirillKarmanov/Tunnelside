import AppKit
import RouteHelperCore
import RouteShared
import SwiftUI

struct RouteTableView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, staticRoutes, stale, managed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L("All", "Все")
            case .staticRoutes: return L("Static", "Статические")
            case .stale: return L("Stale", "Устаревшие")
            case .managed: return L("Managed by Tunnelside", "Управляет Tunnelside")
            }
        }
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

    /// Устаревшие маршруты, которые можно удалить (кроме управляемых Tunnelside — их фоновая служба исправит сама)
    private var staleAddresses: [String] {
        Array(Set(allRows.filter { $0.staleReason != nil && !$0.managed }.map(\.entry.address))).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
        }
        .searchable(text: $search, prompt: L("Search by destination, gateway or interface", "Поиск по адресу назначения, шлюзу или интерфейсу"))
        .onAppear(perform: reload)
        .onReceive(timer) { _ in reload() }
        .confirmationDialog(L("Delete static routes (\(pendingDeletion?.count ?? 0))?", "Удалить статические маршруты (\(pendingDeletion?.count ?? 0))?"), isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button(L("Delete", "Удалить"), role: .destructive) {
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
                        Text("\(f.title) (\(staleAddresses.count))").tag(f)
                    } else {
                        Text(f.title).tag(f)
                    }
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Toggle(L("Show cache / ARP entries", "Показывать кэш / записи ARP"), isOn: $showCloned)
                .disabled(filter != .all)
            Spacer()
            Text(L("Entries: \(rows.count) · \(updatedAt.formatted(date: .omitted, time: .standard))", "Записей: \(rows.count) · \(updatedAt.formatted(date: .omitted, time: .standard))"))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                pendingDeletion = staleAddresses
            } label: {
                Label(L("Delete Stale", "Удалить устаревшие"), systemImage: "trash")
            }
            .disabled(staleAddresses.isEmpty || !client.canModify || client.isBusy)
            .help(L("Delete static routes whose gateway is no longer in any current network — for example, leftovers from scripts after a network change", "Удалить статические маршруты, шлюз которых больше не входит ни в одну текущую сеть — например, оставшиеся от скриптов после смены сети"))
        }
        .controlSize(.small)
        .padding(12)
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn(L("Destination", "Назначение")) { row in
                HStack(spacing: 6) {
                    Text(row.entry.displayDestination).monospaced()
                    if row.managed {
                        Text("Tunnelside").font(.caption2).padding(.horizontal, 4).background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                    if row.staleReason != nil {
                        Text(L("stale", "устарел")).font(.caption2).foregroundStyle(.white).padding(.horizontal, 4).background(Color.red, in: Capsule())
                    }
                }
                .help(row.staleReason ?? "")
            }
            .width(min: 160, ideal: 240)
            TableColumn(L("Gateway", "Шлюз")) { row in
                Text(row.entry.gateway ?? "link").monospaced().foregroundStyle(row.entry.gateway == nil ? .secondary : .primary)
            }
            .width(min: 100, ideal: 140)
            TableColumn(L("Interface", "Интерфейс")) { row in Text(row.entry.interface) }
                .width(min: 50, ideal: 70)
            TableColumn(L("Source", "Источник")) { row in
                Text(row.entry.interfaceAddress ?? "—").monospaced().foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130)
            TableColumn(L("Flags", "Флаги")) { row in
                Text(row.entry.flagString).monospaced().help(flagHelp)
            }
            .width(min: 50, ideal: 70)
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            let selected = allRows.filter { ids.contains($0.id) }
            if let first = selected.first, selected.count == 1 {
                Button(L("Diagnose \(first.entry.destination)", "Диагностика \(first.entry.destination)")) { navigation.diagnose(first.entry.destination) }
            }
            let convertible = selected.filter { $0.entry.prefix > 0 && !$0.managed }.map(\.entry.address)
            Button(L("Add as Rule (via Physical Gateway)", "Добавить как правило (через физический шлюз)")) {
                client.addTargets(from: convertible.joined(separator: " "))
            }
            .disabled(convertible.isEmpty || !client.canModify)
            Button(L("Copy", "Копировать")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selected.map { "\($0.entry.displayDestination) \($0.entry.gateway ?? "link") \($0.entry.interface) \($0.entry.flagString)" }.joined(separator: "\n"), forType: .string)
            }
            Divider()
            let deletable = selected.filter { $0.entry.isStatic && !$0.managed && !$0.entry.isScoped }.map(\.entry.address)
            Button(L("Delete Static Route…", "Удалить статический маршрут…"), role: .destructive) { pendingDeletion = deletable }
                .disabled(deletable.isEmpty || !client.canModify)
        }
    }

    private let flagHelp = L("U up · G gateway · H host · S static · C cloning · W cloned · L link layer · I bound to interface", "U активен · G через шлюз · H хост · S статический · C клонируемый · W клонирован · L канальный уровень · I привязан к интерфейсу")

    private func reload() {
        entries = RoutingTable.dump()
        localAddresses = LocalAddress.current()
        updatedAt = Date()
    }
}
