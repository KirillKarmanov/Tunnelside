import AppKit
import RouteShared
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var client: HelperClient
    @State private var confirmUninstall = false
    @State private var customServersText = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var config: HelperConfig { client.config ?? HelperConfig() }

    var body: some View {
        Form {
            Section(L("General", "Основные")) {
                Toggle(L("Launch Tunnelside at login", "Запускать Tunnelside при входе"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Text(L("This applies only to the menu bar app. The system starts the background service at boot, and routes stay maintained after you quit the app.", "Касается только приложения в строке меню. Фоновую службу система запускает при загрузке, и после выхода из приложения маршруты продолжают поддерживаться."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("Physical gateway", "Физический шлюз")) {
                Picker(L("Outgoing interface", "Интерфейс выхода"), selection: Binding(get: { config.interface }, set: { value in client.mutateConfig { $0.interface = value } })) {
                    Text(L("Automatic (follows Wi-Fi / cable switching, recommended)", "Автоматически (следует за переключением Wi-Fi / кабель, рекомендуется)")).tag(HelperConfig.automaticInterface)
                    ForEach(physicalInterfaceOptions, id: \.self) { Text($0).tag($0) }
                }
                Text(L("In automatic mode VPN tunnels (utun, ipsec, ppp, etc.) are skipped, and the physical interface gateway is picked by the system's network service order. This is used for rules routed via “Physical gateway”.", "В автоматическом режиме VPN-туннели (utun, ipsec, ppp и т. п.) пропускаются, а шлюз физического интерфейса выбирается по порядку сетевых служб системы. Этот результат используется, когда у правила выход — «Физический шлюз»."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!client.canModify)

            Section(L("Domain Resolution", "Разрешение доменов")) {
                Picker("DNS", selection: Binding(get: { config.dnsMode }, set: { value in client.mutateConfig { $0.dnsMode = value } })) {
                    ForEach(DNSMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if config.dnsMode == .custom {
                    TextField(L("DNS servers (comma-separated)", "DNS-серверы (через запятую)"), text: $customServersText, prompt: Text("1.1.1.1, 8.8.8.8"))
                        .onSubmit(saveCustomServers)
                }
                Text(dnsModeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(value: Binding(get: { config.dnsRefreshMinutes }, set: { value in client.mutateConfig { $0.dnsRefreshMinutes = value } }), in: 1...1440) {
                    LabeledContent(L("Refresh addresses every", "Обновлять адреса каждые"), value: L("\(config.dnsRefreshMinutes) min", "\(config.dnsRefreshMinutes) мин"))
                }
                Stepper(value: Binding(get: { config.dnsRetentionHours }, set: { value in client.mutateConfig { $0.dnsRetentionHours = value } }), in: 0...168) {
                    LabeledContent(L("Keep old IPs", "Удерживать старые IP"), value: config.dnsRetentionHours == 0 ? L("Don't keep", "Не удерживать") : L("\(config.dnsRetentionHours) h", "\(config.dnsRetentionHours) ч"))
                }
                Text(L("CDN domains change IP addresses often. When a domain's addresses are refreshed, routes to the old IPs are kept for a while so open connections don't suddenly move into the VPN.", "IP-адреса CDN-доменов часто меняются. Когда адреса домена обновляются, маршруты к старым IP удерживаются ещё какое-то время, чтобы уже открытые соединения не ушли внезапно в VPN."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!client.canModify)

            Section(L("Rules", "Правила")) {
                HStack {
                    Button(L("Import…", "Импортировать…"), action: importConfig)
                    Button(L("Export…", "Экспортировать…"), action: exportConfig)
                }
                Text(L("Import JSON exported by this app, or plain text with one IP / subnet / domain per line. Existing addresses are skipped.", "Импортируется JSON, экспортированный этим приложением, или обычный текст: по одному IP / подсети / домену в строке. Уже существующие адреса пропускаются."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!client.canModify)

            Section(L("About", "О программе")) {
                LabeledContent(L("Version", "Версия"), value: Self.versionText)
                LabeledContent(L("Source code", "Исходный код")) {
                    Link("GitHub", destination: Self.sourceCodeURL)
                }
            }

            Section(L("Background Service", "Фоновая служба")) {
                HStack(spacing: 12) {
                    HelperIconImage()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Tunnelside Background Service", "Фоновая служба Tunnelside")).font(.headline)
                        Text(L("Runs as root, watches network changes and maintains routes. Shown as Tunnelside in System Settings → General → Login Items & Extensions.", "Работает от имени root, отслеживает изменения сети и поддерживает маршруты. В «Системные настройки → Основные → Объекты входа и расширения» отображается как Tunnelside."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent(L("Status", "Состояние"), value: statusText)
                LabeledContent(L("Required version", "Требуемая версия"), value: RouteConstants.helperVersion)
                LabeledContent(L("Settings folder", "Папка настроек"), value: RouteConstants.supportDirectory)
                LabeledContent(L("Log", "Журнал"), value: RouteConstants.helperLogPath)
                HStack {
                    Button(client.isInstalled ? L("Reinstall", "Переустановить") : L("Install", "Установить")) { client.installHelper() }
                    Button(L("Uninstall…", "Удалить…"), role: .destructive) { confirmUninstall = true }
                        .disabled(!client.isInstalled)
                }
                .disabled(client.isBusy)
            }
        }
        .formStyle(.grouped)
        .onAppear { customServersText = config.customDNSServers.joined(separator: ", ") }
        .onChange(of: config.customDNSServers) { _, servers in customServersText = servers.joined(separator: ", ") }
        .confirmationDialog(L("Uninstall the background service?", "Удалить фоновую службу?"), isPresented: $confirmUninstall) {
            Button(L("Remove Added Routes and the Service", "Удалить добавленные маршруты и службу"), role: .destructive) { client.uninstallHelper() }
        } message: {
            Text(L("After uninstalling, the rules stop taking effect. The rules themselves are kept and everything comes back after reinstalling.", "После удаления правила маршрутов перестанут действовать. Сами правила сохранятся — после повторной установки всё восстановится."))
        }
    }

    private static let sourceCodeURL = URL(string: "https://github.com/KirillKarmanov/Tunnelside")!

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    private var dnsModeHelp: String {
        switch config.dnsMode {
        case .physical:
            return L("Queries the current network's DNS through the physical interface, falling back to public DNS on error. Bypasses VPN DNS and Surge / Clash Fake-IP, returning IPs suitable for the physical network.", "Запрос к DNS текущей сети через физический интерфейс, при ошибке — к публичному DNS. Обходит DNS от VPN и Fake-IP от Surge / Clash и даёт IP, подходящие для физической сети.")
        case .system:
            return L("The system resolver. With a VPN or proxy enhanced mode on, it may return a remote node's IP or a Fake-IP (198.18.x.x — those are ignored automatically).", "Системный резолвер. При включённом VPN или расширенном режиме прокси может вернуть IP зарубежного узла или Fake-IP (198.18.x.x — такие игнорируются автоматически).")
        case .custom:
            return L("Queries the given DNS servers through the physical interface. Press Return to save.", "Запрос к указанным DNS-серверам через физический интерфейс. Нажмите Return, чтобы сохранить.")
        }
    }

    private var physicalInterfaceOptions: [String] {
        var names = (client.state?.interfaces ?? []).filter { !$0.isVirtual && $0.router != nil }.map(\.name)
        if config.interface != HelperConfig.automaticInterface, !names.contains(config.interface) {
            names.append(config.interface)
        }
        return names
    }

    private var statusText: String {
        switch client.status {
        case .checking: return L("Checking…", "Проверка…")
        case .notInstalled: return L("Not installed", "Не установлена")
        case .running: return L("Running (\(client.state?.version ?? ""))", "Работает (\(client.state?.version ?? ""))")
        case .outdated(let v): return L("Needs update (installed: \(v))", "Нужно обновить (установлена: \(v))")
        case .unreachable(let msg): return L("Unreachable: \(msg)", "Нет связи: \(msg)")
        }
    }

    private func saveCustomServers() {
        let servers = TargetParser.splitInput(customServersText).filter { TargetParser.ipv4Value($0) != nil }
        client.mutateConfig { $0.customDNSServers = servers }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            client.alertMessage = L("Could not set up launch at login: \(error.localizedDescription)", "Не удалось настроить запуск при входе: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func exportConfig() {
        guard var config = client.config else { return }
        config.revision = 0
        guard let data = try? RouteJSON.encoder().encode(config) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Tunnelside-rules.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            client.alertMessage = L("Could not export: \(error.localizedDescription)", "Не удалось экспортировать: \(error.localizedDescription)")
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        if let imported = try? RouteJSON.decoder().decode(HelperConfig.self, from: data) {
            client.mutateConfig { config in
                let existing = Set(config.rules.map { $0.target.lowercased() })
                let added = imported.rules
                    .filter { !existing.contains($0.target.lowercased()) }
                    .map { RouteRule(target: $0.target, enabled: $0.enabled, note: $0.note, group: $0.group, via: $0.via) }
                config.rules.append(contentsOf: added)
            }
        } else {
            let invalid = client.addTargets(from: String(decoding: data, as: UTF8.self))
            if !invalid.isEmpty {
                client.alertMessage = L("Not recognized (or subnet wider than /8), skipped: \(invalid.prefix(20).joined(separator: ", "))", "Не распознано (или подсеть шире /8), пропущено: \(invalid.prefix(20).joined(separator: ", "))")
            }
        }
    }
}
