import AppKit
import RouteShared
import SwiftUI

struct RuleRow: Identifiable {
    var rule: RouteRule
    var status: RuleStatus?
    var paused: Bool
    var id: UUID { rule.id }

    var kind: String { TargetParser.parse(rule.target)?.kindLabel ?? "Некорректно" }
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
        case .disabled: return paused ? "На паузе" : "Выключено"
        case .pending: return status?.error ?? "Ожидание"
        case .ok: return "Работает"
        case .warning: return status?.warning ?? status?.error ?? "Работает"
        case .partial: return status?.error ?? "Работает частично \(status?.appliedAddresses.count ?? 0)/\(status?.addresses.count ?? 0)"
        case .error: return status?.error ?? "Не работает"
        }
    }

    var detailText: String {
        var lines = [statusText]
        if let hop = status?.nextHop { lines.append("Следующий узел: \(hop)") }
        if let status, !status.addresses.isEmpty { lines.append("Адреса: \(status.addresses.joined(separator: ", "))") }
        if let retained = status?.retainedAddresses, !retained.isEmpty { lines.append("Удерживаются старые адреса домена: \(retained.joined(separator: ", "))") }
        if let date = status?.resolvedAt { lines.append("Адреса получены в \(date.formatted(date: .omitted, time: .standard))") }
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
        .searchable(text: $search, prompt: "Поиск по адресу, заметке или группе")
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
            TextField("IP, подсеть (CIDR) или домен — можно несколько сразу", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            ViaMenu(via: $newVia, interfaces: client.state?.interfaces ?? [])
                .frame(width: 150)
            GroupField(text: $newGroup, groups: client.groups)
                .frame(width: 120)
            TextField("Заметка", text: $note)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onSubmit(add)
            Button("Добавить", action: add)
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
            client.alertMessage = "Не распознано (или подсеть шире /8): \(invalid.joined(separator: ", "))"
        }
    }

    // MARK: Фильтр

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("Группа", selection: $groupFilter) {
                Text("Все группы").tag(GroupFilter.all)
                Text("Без группы").tag(GroupFilter.ungrouped)
                if !client.groups.isEmpty { Divider() }
                ForEach(client.groups, id: \.self) { Text($0).tag(GroupFilter.group($0)) }
            }
            .fixedSize()
            .frame(maxWidth: 220)

            if case .group(let group) = groupFilter {
                Button("Включить группу") { client.setGroupEnabled(group, enabled: true) }
                Button("Выключить группу") { client.setGroupEnabled(group, enabled: false) }
                Button("Переименовать…") { groupPrompt = GroupPrompt(kind: .rename(group), text: group) }
            }
            Spacer()
            let all = client.rules.filter(\.enabled)
            let ok = all.filter { RuleRow(rule: $0, status: client.status(for: $0), paused: client.isPaused).health == .ok }.count
            Text("Всего: \(client.rules.count) · включено: \(all.count) · работают полностью: \(ok)")
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
            TableColumn("Вкл.") { row in
                Toggle("", isOn: Binding(get: { row.rule.enabled }, set: { client.setEnabled($0, for: [row.id]) }))
                    .labelsHidden()
                    .disabled(!client.canModify)
            }
            .width(36)

            TableColumn("Адрес") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.rule.target).monospaced()
                    Text(row.kind).font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(min: 140, ideal: 190)

            TableColumn("Выход") { row in
                Text(row.rule.via.label).foregroundStyle(row.rule.via == .physical ? .secondary : .primary)
            }
            .width(min: 80, ideal: 110)

            TableColumn("Адреса") { row in
                Text(row.addressesText.isEmpty ? "—" : row.addressesText)
                    .monospaced()
                    .foregroundStyle(row.addressesText.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .help(row.detailText)
            }
            .width(min: 150, ideal: 240)

            TableColumn("Состояние") { row in
                StatusBadge(row: row).help(row.detailText)
            }
            .width(min: 90, ideal: 160)

            TableColumn("Группа") { row in
                Text(row.rule.group.isEmpty ? "—" : row.rule.group).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 80)

            TableColumn("Заметка") { row in
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
                    Text("Правил пока нет").font(.headline)
                    Text("Добавленные IP / подсети / домены всегда идут через выбранный выход,\nпосле смены Wi‑Fi или сети правила применяются заново автоматически.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<RouteRule.ID>) -> some View {
        let selected = client.rules.filter { ids.contains($0.id) }
        Button("Изменить…") { editingRule = selected.first }
            .disabled(selected.count != 1)
        if let first = selected.first, selected.count == 1 {
            Button("Диагностика «\(first.target)»") { navigation.diagnose(first.target) }
        }
        Divider()
        Button("Включить") { client.setEnabled(true, for: ids) }
        Button("Выключить") { client.setEnabled(false, for: ids) }
        Menu("Выход") {
            Button("Физический шлюз (автоматически)") { client.setVia(.physical, for: ids) }
            ForEach(client.state?.interfaces ?? [], id: \.name) { info in
                Button(ViaMenu.label(for: info)) { client.setVia(.interface(info.name), for: ids) }
            }
        }
        Menu("Группа") {
            ForEach(client.groups, id: \.self) { group in
                Button(group) { client.setGroup(group, for: ids) }
            }
            if !client.groups.isEmpty { Divider() }
            Button("Новая группа…") { groupPrompt = GroupPrompt(kind: .assign(ids), text: "") }
            Button("Убрать из группы") { client.setGroup("", for: ids) }
        }
        Menu("Приоритет") {
            Button("В начало") { client.moveRules(ids, toTop: true) }
            Button("В конец") { client.moveRules(ids, toTop: false) }
        }
        Button("Копировать адреса") { copyAddresses(ids) }
        Divider()
        Button("Удалить", role: .destructive) { client.removeRules(ids) }
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
        if info.isVirtual { return "\(info.name) (VPN / виртуальный интерфейс)" }
        return "\(info.name) (\(info.router ?? info.localAddress ?? "нет шлюза"))"
    }

    var body: some View {
        Menu {
            Button("Физический шлюз (автоматически)") { via = .physical }
            if !interfaces.isEmpty {
                Section("Выбранный интерфейс") {
                    ForEach(interfaces, id: \.name) { info in
                        Button(Self.label(for: info)) { via = .interface(info.name) }
                    }
                }
            }
            Divider()
            Button("Указать шлюз…") {
                if case .gateway(let ip) = via { gatewayText = ip }
                askGateway = true
            }
        } label: {
            Label(via.label, systemImage: via == .physical ? "wifi" : "arrow.turn.up.right")
        }
        .help("Физический шлюз: шлюз Wi‑Fi или проводной сети выбирается автоматически (мимо VPN)\nВыбранный интерфейс: всегда через конкретный интерфейс, можно и через VPN-туннель\nУказанный шлюз: всегда через шлюз с заданным IP")
        .alert("Указать шлюз", isPresented: $askGateway) {
            TextField("Например, 192.168.1.254", text: $gatewayText)
            Button("ОК") {
                let ip = gatewayText.trimmingCharacters(in: .whitespaces)
                if TargetParser.ipv4Value(ip) != nil { via = .gateway(ip) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Шлюз должен находиться в подсети одной из подключённых сетей.")
        }
    }
}

/// Можно ввести новую группу или выбрать существующую
struct GroupField: View {
    @Binding var text: String
    let groups: [String]

    var body: some View {
        HStack(spacing: 2) {
            TextField("Группа", text: $text)
                .textFieldStyle(.roundedBorder)
            if !groups.isEmpty {
                Menu {
                    ForEach(groups, id: \.self) { g in Button(g) { text = g } }
                    Divider()
                    Button("Без группы") { text = "" }
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
            Text(isRename ? "Переименовать группу" : "Переместить в новую группу").font(.headline)
            GroupField(text: $name, groups: groups)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("ОК") {
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
            TextField("Адрес", text: $rule.target)
            if TargetParser.parse(rule.target) == nil {
                Text("Не удалось распознать IP / подсеть / домен").foregroundStyle(.red).font(.caption)
            }
            LabeledContent("Выход") {
                ViaMenu(via: $rule.via, interfaces: interfaces).fixedSize()
            }
            LabeledContent("Группа") {
                GroupField(text: $rule.group, groups: groups)
            }
            TextField("Заметка", text: $rule.note)
            Toggle("Включено", isOn: $rule.enabled)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
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
