import AppKit
import RouteShared
import SwiftUI

struct RuleRow: Identifiable {
    var rule: RouteRule
    var status: RuleStatus?
    var paused: Bool
    var id: UUID { rule.id }

    var kind: String { TargetParser.parse(rule.target)?.kindLabel ?? L("Invalid", "Некорректно") }
    var addressesText: String { status?.addresses.joined(separator: ", ") ?? "" }

    enum Health { case ok, warning, partial, error, pending, disabled }

    var health: Health {
        guard rule.enabled, !paused else { return .disabled }
        guard let status else { return .pending }
        if status.addresses.isEmpty { return status.error == nil ? .pending : .error }
        let applied = status.appliedAddresses.count
        if applied == status.addresses.count { return status.warning == nil && status.error == nil ? .ok : .warning }
        if applied == 0 { return status.error == nil ? .pending : .error }
        return .partial
    }

    var statusText: String {
        switch health {
        case .disabled: return paused ? L("Paused", "На паузе") : L("Off", "Выключено")
        case .pending: return status?.error ?? L("Pending", "Ожидание")
        case .ok: return L("Working", "Работает")
        case .warning: return status?.warning ?? status?.error ?? L("Working", "Работает")
        case .partial: return status?.error ?? L("Partially working \(status?.appliedAddresses.count ?? 0)/\(status?.addresses.count ?? 0)", "Работает частично \(status?.appliedAddresses.count ?? 0)/\(status?.addresses.count ?? 0)")
        case .error: return status?.error ?? L("Not working", "Не работает")
        }
    }

    var detailText: String {
        var lines = [statusText]
        if let hop = status?.nextHop { lines.append(L("Next hop: \(hop)", "Следующий узел: \(hop)")) }
        if let status, !status.addresses.isEmpty { lines.append(L("Addresses: \(status.addresses.joined(separator: ", "))", "Адреса: \(status.addresses.joined(separator: ", "))")) }
        if let retained = status?.retainedAddresses, !retained.isEmpty { lines.append(L("Old domain addresses still kept: \(retained.joined(separator: ", "))", "Удерживаются старые адреса домена: \(retained.joined(separator: ", "))")) }
        if let date = status?.resolvedAt { lines.append(L("Addresses resolved at \(date.formatted(date: .omitted, time: .standard))", "Адреса получены в \(date.formatted(date: .omitted, time: .standard))")) }
        return lines.joined(separator: "\n")
    }
}

struct RulesView: View {
    enum GroupFilter: Hashable {
        case all, ungrouped, group(String)
    }

    @EnvironmentObject private var client: HelperClient
    @EnvironmentObject private var navigation: AppNavigation
    @State private var input = ""
    @State private var note = ""
    @State private var newGroup = ""
    @State private var newVia: RouteVia = .physical
    @State private var selection = Set<RouteRule.ID>()
    @State private var search = ""
    @State private var groupFilter: GroupFilter = .all
    @State private var editingRule: RouteRule?
    @State private var groupPrompt: GroupPrompt?

    struct GroupPrompt: Identifiable {
        enum Kind { case assign(Set<RouteRule.ID>), rename(String) }
        let id = UUID()
        var kind: Kind
        var text: String
    }

    private var rows: [RuleRow] {
        client.rules
            .filter { rule in
                switch groupFilter {
                case .all: return true
                case .ungrouped: return rule.group.isEmpty
                case .group(let g): return rule.group == g
                }
            }
            .filter { search.isEmpty || $0.target.localizedCaseInsensitiveContains(search) || $0.note.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) }
            .map { RuleRow(rule: $0, status: client.status(for: $0), paused: client.isPaused) }
    }

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()
            filterBar
            table
        }
        .searchable(text: $search, prompt: L("Search by address, note or group", "Поиск по адресу, заметке или группе"))
        .sheet(item: $editingRule) { rule in
            RuleEditor(rule: rule, groups: client.groups, interfaces: client.state?.interfaces ?? []) { client.updateRule($0) }
        }
        .sheet(item: $groupPrompt) { prompt in
            GroupNameSheet(prompt: prompt, groups: client.groups) { name in
                switch prompt.kind {
                case .assign(let ids): client.setGroup(name, for: ids)
                case .rename(let old):
                    client.renameGroup(old, to: name)
                    groupFilter = name.isEmpty ? .ungrouped : .group(name)
                }
            }
        }
    }

    // MARK: Добавление

    private var addBar: some View {
        HStack(spacing: 8) {
            TextField(L("IP, subnet (CIDR) or domain — several at once is fine", "IP, подсеть (CIDR) или домен — можно несколько сразу"), text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            ViaMenu(via: $newVia, interfaces: client.state?.interfaces ?? [])
                .frame(width: 150)
            GroupField(text: $newGroup, groups: client.groups)
                .frame(width: 120)
            TextField(L("Note", "Заметка"), text: $note)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onSubmit(add)
            Button(L("Add", "Добавить"), action: add)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || !client.canModify)
        }
        .padding(12)
    }

    private func add() {
        let group: String
        if case .group(let g) = groupFilter, newGroup.isEmpty { group = g } else { group = newGroup.trimmingCharacters(in: .whitespaces) }
        let invalid = client.addTargets(from: input, note: note.trimmingCharacters(in: .whitespaces), group: group, via: newVia)
        if invalid.isEmpty {
            input = ""
            note = ""
        } else {
            input = invalid.joined(separator: " ")
            client.alertMessage = L("Not recognized (or subnet wider than /8): \(invalid.joined(separator: ", "))", "Не распознано (или подсеть шире /8): \(invalid.joined(separator: ", "))")
        }
    }

    // MARK: Фильтр

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker(L("Group", "Группа"), selection: $groupFilter) {
                Text(L("All Groups", "Все группы")).tag(GroupFilter.all)
                Text(L("No Group", "Без группы")).tag(GroupFilter.ungrouped)
                if !client.groups.isEmpty { Divider() }
                ForEach(client.groups, id: \.self) { Text($0).tag(GroupFilter.group($0)) }
            }
            .fixedSize()
            .frame(maxWidth: 220)

            if case .group(let group) = groupFilter {
                Button(L("Turn On Group", "Включить группу")) { client.setGroupEnabled(group, enabled: true) }
                Button(L("Turn Off Group", "Выключить группу")) { client.setGroupEnabled(group, enabled: false) }
                Button(L("Rename…", "Переименовать…")) { groupPrompt = GroupPrompt(kind: .rename(group), text: group) }
            }
            Spacer()
            let all = client.rules.filter(\.enabled)
            let ok = all.filter { RuleRow(rule: $0, status: client.status(for: $0), paused: client.isPaused).health == .ok }.count
            Text(L("Total: \(client.rules.count) · enabled: \(all.count) · fully working: \(ok)", "Всего: \(client.rules.count) · включено: \(all.count) · работают полностью: \(ok)"))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onChange(of: client.groups) { _, groups in
            if case .group(let g) = groupFilter, !groups.contains(g) { groupFilter = .all }
        }
    }

    // MARK: Таблица

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn(L("On", "Вкл.")) { row in
                Toggle("", isOn: Binding(get: { row.rule.enabled }, set: { client.setEnabled($0, for: [row.id]) }))
                    .labelsHidden()
                    .disabled(!client.canModify)
            }
            .width(36)

            TableColumn(L("Address", "Адрес")) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.rule.target).monospaced()
                    Text(row.kind).font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(min: 140, ideal: 190)

            TableColumn(L("Via", "Выход")) { row in
                Text(row.rule.via.label).foregroundStyle(row.rule.via == .physical ? .secondary : .primary)
            }
            .width(min: 80, ideal: 110)

            TableColumn(L("Addresses", "Адреса")) { row in
                Text(row.addressesText.isEmpty ? "—" : row.addressesText)
                    .monospaced()
                    .foregroundStyle(row.addressesText.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .help(row.detailText)
            }
            .width(min: 150, ideal: 240)

            TableColumn(L("Status", "Состояние")) { row in
                StatusBadge(row: row).help(row.detailText)
            }
            .width(min: 90, ideal: 160)

            TableColumn(L("Group", "Группа")) { row in
                Text(row.rule.group.isEmpty ? "—" : row.rule.group).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 80)

            TableColumn(L("Note", "Заметка")) { row in
                Text(row.rule.note).foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: RouteRule.ID.self) { ids in
            if !ids.isEmpty { contextMenu(ids) }
        } primaryAction: { ids in
            editingRule = client.rules.first { ids.contains($0.id) }
        }
        .onDeleteCommand { client.removeRules(selection) }
        .overlay {
            if client.rules.isEmpty && client.canModify {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").font(.largeTitle).foregroundStyle(.secondary)
                    Text(L("No rules yet", "Правил пока нет")).font(.headline)
                    Text(L("Added IPs / subnets / domains always go through the chosen route,\nand rules are reapplied automatically after a Wi‑Fi or network change.", "Добавленные IP / подсети / домены всегда идут через выбранный выход,\nпосле смены Wi‑Fi или сети правила применяются заново автоматически."))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<RouteRule.ID>) -> some View {
        let selected = client.rules.filter { ids.contains($0.id) }
        Button(L("Edit…", "Изменить…")) { editingRule = selected.first }
            .disabled(selected.count != 1)
        if let first = selected.first, selected.count == 1 {
            Button(L("Diagnose “\(first.target)”", "Диагностика «\(first.target)»")) { navigation.diagnose(first.target) }
        }
        Divider()
        Button(L("Turn On", "Включить")) { client.setEnabled(true, for: ids) }
        Button(L("Turn Off", "Выключить")) { client.setEnabled(false, for: ids) }
        Menu(L("Via", "Выход")) {
            Button(L("Physical Gateway (Automatic)", "Физический шлюз (автоматически)")) { client.setVia(.physical, for: ids) }
            ForEach(client.state?.interfaces ?? [], id: \.name) { info in
                Button(ViaMenu.label(for: info)) { client.setVia(.interface(info.name), for: ids) }
            }
        }
        Menu(L("Group", "Группа")) {
            ForEach(client.groups, id: \.self) { group in
                Button(group) { client.setGroup(group, for: ids) }
            }
            if !client.groups.isEmpty { Divider() }
            Button(L("New Group…", "Новая группа…")) { groupPrompt = GroupPrompt(kind: .assign(ids), text: "") }
            Button(L("Remove from Group", "Убрать из группы")) { client.setGroup("", for: ids) }
        }
        Menu(L("Priority", "Приоритет")) {
            Button(L("Move to Top", "В начало")) { client.moveRules(ids, toTop: true) }
            Button(L("Move to Bottom", "В конец")) { client.moveRules(ids, toTop: false) }
        }
        Button(L("Copy Addresses", "Копировать адреса")) { copyAddresses(ids) }
        Divider()
        Button(L("Delete", "Удалить"), role: .destructive) { client.removeRules(ids) }
    }

    private func copyAddresses(_ ids: Set<RouteRule.ID>) {
        let text = rows.filter { ids.contains($0.id) }
            .flatMap { ($0.status?.addresses.isEmpty ?? true) ? [$0.rule.target] : $0.status!.addresses }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct StatusBadge: View {
    let row: RuleRow

    var body: some View {
        Label {
            Text(row.statusText).lineLimit(1)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    private var symbol: String {
        switch row.health {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "checkmark.circle.trianglebadge.exclamationmark"
        case .partial: return "exclamationmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .pending: return "clock"
        case .disabled: return "pause.circle"
        }
    }

    private var color: Color {
        switch row.health {
        case .ok: return .green
        case .warning, .partial: return .orange
        case .error: return .red
        case .pending, .disabled: return .secondary
        }
    }
}

/// Меню выбора выхода
struct ViaMenu: View {
    @Binding var via: RouteVia
    let interfaces: [NetworkInterfaceInfo]
    @State private var askGateway = false
    @State private var gatewayText = ""

    static func label(for info: NetworkInterfaceInfo) -> String {
        if info.isVirtual { return L("\(info.name) (VPN / virtual interface)", "\(info.name) (VPN / виртуальный интерфейс)") }
        return L("\(info.name) (\(info.router ?? info.localAddress ?? "no gateway"))", "\(info.name) (\(info.router ?? info.localAddress ?? "нет шлюза"))")
    }

    var body: some View {
        Menu {
            Button(L("Physical Gateway (Automatic)", "Физический шлюз (автоматически)")) { via = .physical }
            if !interfaces.isEmpty {
                Section(L("Specific Interface", "Выбранный интерфейс")) {
                    ForEach(interfaces, id: \.name) { info in
                        Button(Self.label(for: info)) { via = .interface(info.name) }
                    }
                }
            }
            Divider()
            Button(L("Specify Gateway…", "Указать шлюз…")) {
                if case .gateway(let ip) = via { gatewayText = ip }
                askGateway = true
            }
        } label: {
            Label(via.label, systemImage: via == .physical ? "wifi" : "arrow.turn.up.right")
        }
        .help(L("Physical gateway: the Wi‑Fi or wired network gateway is picked automatically (bypassing the VPN)\nSpecific interface: always through that interface, including a VPN tunnel\nSpecified gateway: always through the gateway with the given IP", "Физический шлюз: шлюз Wi‑Fi или проводной сети выбирается автоматически (мимо VPN)\nВыбранный интерфейс: всегда через конкретный интерфейс, можно и через VPN-туннель\nУказанный шлюз: всегда через шлюз с заданным IP"))
        .alert(L("Specify Gateway", "Указать шлюз"), isPresented: $askGateway) {
            TextField(L("For example, 192.168.1.254", "Например, 192.168.1.254"), text: $gatewayText)
            Button(L("OK", "ОК")) {
                let ip = gatewayText.trimmingCharacters(in: .whitespaces)
                if TargetParser.ipv4Value(ip) != nil { via = .gateway(ip) }
            }
            Button(L("Cancel", "Отмена"), role: .cancel) {}
        } message: {
            Text(L("The gateway must be in the subnet of one of the connected networks.", "Шлюз должен находиться в подсети одной из подключённых сетей."))
        }
    }
}

/// Можно ввести новую группу или выбрать существующую
struct GroupField: View {
    @Binding var text: String
    let groups: [String]

    var body: some View {
        HStack(spacing: 2) {
            TextField(L("Group", "Группа"), text: $text)
                .textFieldStyle(.roundedBorder)
            if !groups.isEmpty {
                Menu {
                    ForEach(groups, id: \.self) { g in Button(g) { text = g } }
                    Divider()
                    Button(L("No Group", "Без группы")) { text = "" }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

struct GroupNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: RulesView.GroupPrompt
    let groups: [String]
    let onDone: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isRename ? L("Rename Group", "Переименовать группу") : L("Move to New Group", "Переместить в новую группу")).font(.headline)
            GroupField(text: $name, groups: groups)
            HStack {
                Spacer()
                Button(L("Cancel", "Отмена")) { dismiss() }
                Button(L("OK", "ОК")) {
                    onDone(name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { name = prompt.text }
    }

    private var isRename: Bool {
        if case .rename = prompt.kind { return true }
        return false
    }
}

struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: RouteRule
    let groups: [String]
    let interfaces: [NetworkInterfaceInfo]
    let onSave: (RouteRule) -> Void

    var body: some View {
        Form {
            TextField(L("Address", "Адрес"), text: $rule.target)
            if TargetParser.parse(rule.target) == nil {
                Text(L("Could not recognize the IP / subnet / domain", "Не удалось распознать IP / подсеть / домен")).foregroundStyle(.red).font(.caption)
            }
            LabeledContent(L("Via", "Выход")) {
                ViaMenu(via: $rule.via, interfaces: interfaces).fixedSize()
            }
            LabeledContent(L("Group", "Группа")) {
                GroupField(text: $rule.group, groups: groups)
            }
            TextField(L("Note", "Заметка"), text: $rule.note)
            Toggle(L("Enabled", "Включено"), isOn: $rule.enabled)
            HStack {
                Spacer()
                Button(L("Cancel", "Отмена")) { dismiss() }
                Button(L("Save", "Сохранить")) {
                    rule.target = rule.target.trimmingCharacters(in: .whitespaces)
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(TargetParser.parse(rule.target) == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
