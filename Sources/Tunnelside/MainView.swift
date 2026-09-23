import RouteShared
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var client: HelperClient
    @EnvironmentObject private var navigation: AppNavigation

    var body: some View {
        NavigationSplitView {
            List(AppNavigation.Section.allCases, selection: $navigation.section) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                HelperBanner()
                switch navigation.section ?? .rules {
                case .rules: RulesView()
                case .routeTable: RouteTableView()
                case .diagnostics: DiagnosticsView()
                case .logs: LogsView()
                case .settings: SettingsView()
                }
            }
        }
        #if DEBUG
        .onAppear { ScreenshotMode.startIfRequested(navigation: navigation) }
        #endif
        .alert(L("Attention", "Внимание"), isPresented: Binding(get: { client.alertMessage != nil }, set: { if !$0 { client.alertMessage = nil } })) {
            Button(L("OK", "ОК")) { client.alertMessage = nil }
        } message: {
            Text(client.alertMessage ?? "")
        }
    }
}

/// Top of the window: helper state, current physical gateway and the main switch
struct HelperBanner: View {
    @EnvironmentObject private var client: HelperClient

    var body: some View {
        HStack(spacing: 12) {
            switch client.status {
            case .checking:
                ProgressView().controlSize(.small)
                Text(L("Connecting to the background service…", "Подключение к фоновой службе…"))
                Spacer()
            case .notInstalled:
                helperIcon
                Text(L("Install the background service to change system routes — you will need the administrator password once.", "Чтобы менять системные маршруты, установите фоновую службу — пароль администратора понадобится один раз."))
                Spacer()
                installButton(L("Install Background Service", "Установить фоновую службу"))
            case .outdated(let installed):
                helperIcon
                Text(L("The background service needs an update (installed: \(installed), required: \(RouteConstants.helperVersion)). Rules cannot be changed until it is updated.", "Фоновую службу нужно обновить (установлена: \(installed), нужна: \(RouteConstants.helperVersion)). До обновления правила менять нельзя."))
                Spacer()
                installButton(L("Update Background Service", "Обновить фоновую службу"))
            case .unreachable(let message):
                Image(systemName: "xmark.octagon").foregroundStyle(.red)
                Text(L("Cannot reach the background service: \(message)", "Нет связи с фоновой службой: \(message)")).lineLimit(1)
                Spacer()
                installButton(L("Reinstall", "Переустановить"))
            case .running:
                GatewayLabel()
                Spacer()
                if let date = client.state?.lastApplyAt {
                    Text(L("Synced at \(date.formatted(date: .omitted, time: .standard))", "Синхронизировано в \(date.formatted(date: .omitted, time: .standard))"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Toggle(isOn: Binding(get: { !client.isPaused }, set: { client.setPaused(!$0) })) {
                    Text(client.isPaused ? L("Paused", "На паузе") : L("Running", "Работает"))
                }
                .toggleStyle(.switch)
                .help(L("Pausing removes all routes added by Tunnelside; they are applied again when you resume", "Пауза убирает все маршруты, добавленные Tunnelside; при продолжении они применяются заново"))
                Button {
                    client.reapply()
                } label: {
                    Label(L("Reapply", "Применить заново"), systemImage: "arrow.clockwise")
                }
                .help(L("Detect the gateway again, refresh domain addresses and check all routes", "Заново определить шлюз, обновить адреса доменов и проверить все маршруты"))
                .disabled(client.isBusy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(client.isPaused && client.status == .running ? AnyShapeStyle(Color.orange.opacity(0.12)) : AnyShapeStyle(.bar))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var helperIcon: some View {
        HelperIconImage()
            .frame(width: 28, height: 28)
    }

    private func installButton(_ title: String) -> some View {
        Button(title) { client.installHelper() }
            .buttonStyle(.borderedProminent)
            .disabled(client.isBusy)
    }
}

struct GatewayLabel: View {
    @EnvironmentObject private var client: HelperClient

    var body: some View {
        if let gw = client.state?.gateway {
            Label {
                Text(L("Physical gateway ", "Физический шлюз ")) + Text(gw.router).monospaced().bold() + Text("  ·  \(gw.interface)").foregroundColor(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            Label(L("Physical gateway not found, current routes are left unchanged", "Физический шлюз не найден, текущие маршруты не меняются"), systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        }
    }
}
