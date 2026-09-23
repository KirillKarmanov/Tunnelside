import AppKit
import RouteShared
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var client: HelperClient
    @EnvironmentObject private var navigation: AppNavigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if client.canModify {
                HStack {
                    TextField(L("Add IP / domain", "Добавить IP / домен"), text: $input)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button(L("Add", "Добавить"), action: add)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !client.groups.isEmpty {
                    groupToggles
                }

                if !client.rules.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(client.rules) { rule in
                                ruleRow(rule)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            } else {
                Text(statusMessage).foregroundStyle(.secondary)
                Button(client.status == .notInstalled ? L("Install Background Service", "Установить фоновую службу") : L("Update Background Service", "Обновить фоновую службу")) { client.installHelper() }
                    .disabled(client.isBusy)
            }

            Divider()

            HStack {
                Button(L("Open Main Window", "Открыть главное окно"), action: openMainWindow)
                Button(L("Reapply", "Применить заново")) { client.reapply() }
                    .disabled(!client.canModify || client.isBusy)
                Spacer()
                Button(L("Quit", "Выйти")) { NSApp.terminate(nil) }
            }
            Text(L("Quitting the app does not affect routes — the background service keeps maintaining them.", "Выход из приложения не затрагивает маршруты — фоновая служба продолжит их поддерживать."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 360)
    }

    private var statusMessage: String {
        switch client.status {
        case .notInstalled: return L("Background service is not installed", "Фоновая служба не установлена")
        case .outdated(let v): return L("Background service needs an update (installed: \(v))", "Нужно обновить фоновую службу (установлена: \(v))")
        case .checking: return L("Connecting to the background service…", "Подключение к фоновой службе…")
        default: return L("Background service is not running", "Фоновая служба не работает")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tunnelside").font(.headline)
                Spacer()
                if client.canModify {
                    Toggle(client.isPaused ? L("Paused", "На паузе") : L("Running", "Работает"), isOn: Binding(get: { !client.isPaused }, set: { client.setPaused(!$0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
            if client.canModify {
                GatewayLabel().font(.callout)
                let enabled = client.rules.filter(\.enabled)
                let ok = enabled.filter { RuleRow(rule: $0, status: client.status(for: $0), paused: client.isPaused).health == .ok }.count
                Text(L("Rules enabled: \(enabled.count), fully working: \(ok)", "Включено правил: \(enabled.count), полностью работают: \(ok)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var groupToggles: some View {
        HStack(spacing: 6) {
            Text(L("Groups", "Группы")).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(client.groups, id: \.self) { group in
                        let rules = client.rules.filter { $0.group == group }
                        let on = rules.contains(where: \.enabled)
                        Button {
                            client.setGroupEnabled(group, enabled: !on)
                        } label: {
                            Text(group)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(on ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(on ? L("Click to turn off group “\(group)”", "Нажмите, чтобы выключить группу «\(group)»") : L("Click to turn on group “\(group)”", "Нажмите, чтобы включить группу «\(group)»"))
                    }
                }
            }
        }
    }

    private func ruleRow(_ rule: RouteRule) -> some View {
        let row = RuleRow(rule: rule, status: client.status(for: rule), paused: client.isPaused)
        return HStack {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { client.setEnabled($0, for: [rule.id]) }))
                .labelsHidden()
                .controlSize(.mini)
                .toggleStyle(.switch)
            Text(rule.target).monospaced().lineLimit(1)
            if rule.via != .physical {
                Text(rule.via.label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(row: row)
                .labelStyle(.iconOnly)
        }
        .help(row.detailText)
        .contextMenu {
            Button(L("Diagnostics", "Диагностика")) {
                navigation.diagnose(rule.target)
                openMainWindow()
            }
        }
    }

    private func openMainWindow() {
        dismiss() // Close the menu bar panel first so it doesn't cover the main window or steal focus
        AppWindow.showMain(openWindow)
    }

    private func add() {
        let invalid = client.addTargets(from: input)
        input = invalid.joined(separator: " ")
    }
}
