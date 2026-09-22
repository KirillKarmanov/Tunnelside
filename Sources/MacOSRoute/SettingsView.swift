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
            Section("Основные") {
                Toggle("Запускать MacOSRoute при входе", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Text("Касается только приложения в строке меню. Фоновую службу система запускает при загрузке, и после выхода из приложения маршруты продолжают поддерживаться.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Физический шлюз") {
                Picker("Интерфейс выхода", selection: Binding(get: { config.interface }, set: { value in client.mutateConfig { $0.interface = value } })) {
                    Text("Автоматически (следует за переключением Wi-Fi / кабель, рекомендуется)").tag(HelperConfig.automaticInterface)
                    ForEach(physicalInterfaceOptions, id: \.self) { Text($0).tag($0) }
                }
                Text("В автоматическом режиме VPN-туннели (utun, ipsec, ppp и т. п.) пропускаются, а шлюз физического интерфейса выбирается по порядку сетевых служб системы. Этот результат используется, когда у правила выход — «Физический шлюз».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!client.canModify)

            Section("Разрешение доменов") {
                Picker("DNS", selection: Binding(get: { config.dnsMode }, set: { value in client.mutateConfig { $0.dnsMode = value } })) {
                    ForEach(DNSMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if config.dnsMode == .custom {
                    TextField("DNS-серверы (через запятую)", text: $customServersText, prompt: Text("1.1.1.1, 8.8.8.8"))
                        .onSubmit(saveCustomServers)
                }
                Text(dnsModeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(value: Binding(get: { config.dnsRefreshMinutes }, set: { value in client.mutateConfig { $0.dnsRefreshMinutes = value } }), in: 1...1440) {
                    LabeledContent("Обновлять адреса каждые", value: "\(config.dnsRefreshMinutes) мин")
                }
                Stepper(value: Binding(get: { config.dnsRetentionHours }, set: { value in client.mutateConfig { $0.dnsRetentionHours = value } }), in: 0...168) {
                    LabeledContent("Удерживать старые IP", value: config.dnsRetentionHours == 0 ? "Не удерживать" : "\(config.dnsRetentionHours) ч")
                }
                Text("IP-адреса CDN-доменов часто меняются. Когда адреса домена обновляются, маршруты к старым IP удерживаются ещё какое-то время, чтобы уже открытые соединения не ушли внезапно в VPN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!client.canModify)

            Section("Правила") {
                HStack {
                    Button("Импортировать…", action: importConfig)
                    Button("Экспортировать…", action: exportConfig)
                }
                Text("Импортируется JSON, экспортированный этим приложением, или обычный текст: по одному IP / подсети / домену в строке. Уже существующие адреса пропускаются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!client.canModify)

            Section("О программе") {
                LabeledContent("Версия", value: Self.versionText)
                LabeledContent("Разработчик", value: "Chongqing Hyperits Network Technology Co., Ltd.")
                LabeledContent("Политика конфиденциальности") {
                    Link("Открыть", destination: Self.privacyPolicyURL)
                }
            }

            Section("Фоновая служба") {
                HStack(spacing: 12) {
                    HelperIconImage()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Фоновая служба MacOSRoute").font(.headline)
                        Text("Работает от имени root, отслеживает изменения сети и поддерживает маршруты. В «Системные настройки → Основные → Объекты входа и расширения» отображается как MacOSRoute.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Состояние", value: statusText)
                LabeledContent("Требуемая версия", value: RouteConstants.helperVersion)
                LabeledContent("Папка настроек", value: RouteConstants.supportDirectory)
                LabeledContent("Журнал", value: RouteConstants.helperLogPath)
                HStack {
                    Button(client.isInstalled ? "Переустановить" : "Установить") { client.installHelper() }
                    Button("Удалить…", role: .destructive) { confirmUninstall = true }
                        .disabled(!client.isInstalled)
                }
                .disabled(client.isBusy)
            }
        }
        .formStyle(.grouped)
        .onAppear { customServersText = config.customDNSServers.joined(separator: ", ") }
        .onChange(of: config.customDNSServers) { _, servers in customServersText = servers.joined(separator: ", ") }
        .confirmationDialog("Удалить фоновую службу?", isPresented: $confirmUninstall) {
            Button("Удалить добавленные маршруты и службу", role: .destructive) { client.uninstallHelper() }
        } message: {
            Text("После удаления правила маршрутов перестанут действовать. Сами правила сохранятся — после повторной установки всё восстановится.")
        }
    }

    private static let privacyPolicyURL = URL(string: "https://github.com/castorworks/Privacy/blob/main/MacOSRoute/privacy-zh.md")!

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    private var dnsModeHelp: String {
        switch config.dnsMode {
        case .physical:
            return "Запрос к DNS текущей сети через физический интерфейс, при ошибке — к публичному DNS. Обходит DNS от VPN и Fake-IP от Surge / Clash и даёт IP, подходящие для физической сети."
        case .system:
            return "Системный резолвер. При включённом VPN или расширенном режиме прокси может вернуть IP зарубежного узла или Fake-IP (198.18.x.x — такие игнорируются автоматически)."
        case .custom:
            return "Запрос к указанным DNS-серверам через физический интерфейс. Нажмите Return, чтобы сохранить."
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
        case .checking: return "Проверка…"
        case .notInstalled: return "Не установлена"
        case .running: return "Работает (\(client.state?.version ?? ""))"
        case .outdated(let v): return "Нужно обновить (установлена: \(v))"
        case .unreachable(let msg): return "Нет связи: \(msg)"
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
            client.alertMessage = "Не удалось настроить запуск при входе: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func exportConfig() {
        guard var config = client.config else { return }
        config.revision = 0
        guard let data = try? RouteJSON.encoder().encode(config) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MacOSRoute-rules.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            client.alertMessage = "Не удалось экспортировать: \(error.localizedDescription)"
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
                client.alertMessage = "Не распознано (или подсеть шире /8), пропущено: \(invalid.prefix(20).joined(separator: ", "))"
            }
        }
    }
}
