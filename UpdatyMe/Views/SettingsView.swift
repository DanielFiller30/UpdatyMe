import ServiceManagement
import SwiftUI
import UpdatyMeCore

/// Einstellungen (⌘,): Allgemein (Autostart, Menüleiste, Prüfintervall), Mitteilungen, Node.js-Kanal, tools.json.
struct SettingsView: View {
    let model: InventoryModel

    @AppStorage(InventoryModel.nodeChannelDefaultsKey) private var nodeChannel = NodeLatestProvider.Channel.lts.rawValue
    @AppStorage(AppSettings.showMenuBarExtraKey) private var showsMenuBarExtra = true
    @AppStorage(AppSettings.checkIntervalKey) private var checkInterval = CheckInterval.default
    @AppStorage(AppSettings.notifyNewUpdatesKey) private var notifiesNewUpdates = true
    @AppStorage(AppSettings.notifyUpdatesFinishedKey) private var notifiesUpdatesFinished = true

    /// Der Zustand gehört dem System (Anmeldeobjekte); er wird beim Erscheinen neu gelesen.
    @State private var loginStatus = LaunchAtLogin.status
    @State private var loginError: String?

    var body: some View {
        Form {
            generalSection
            notificationsSection
            Section {
                Picker("Node.js", selection: $nodeChannel) {
                    Text("LTS").tag(NodeLatestProvider.Channel.lts.rawValue)
                    Text("Current").tag(NodeLatestProvider.Channel.current.rawValue)
                }
                .pickerStyle(.radioGroup)
                Text("LTS: newest version of your own line while it is a supported LTS line, otherwise the newest LTS. Current: newest version overall.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Latest Version")
            }
            Section {
                LabeledContent("Additional tools") {
                    Button("Show in Finder") {
                        let url = InventoryModel.toolsConfigurationURL
                        let target = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
                        NSWorkspace.shared.activateFileViewerSelecting([target])
                    }
                }
                Text("Add tools to tools.json without changing the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Configuration")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onChange(of: nodeChannel) {
            // Bewertung neu berechnen; nodejs.org-Daten kommen aus dem Cache.
            Task { await model.refresh() }
        }
        .onChange(of: checkInterval) {
            model.scheduleAutomaticChecks()
        }
        .onAppear {
            loginStatus = LaunchAtLogin.status
        }
    }

    private var generalSection: some View {
        Section {
            Toggle("Open at login", isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: { setLaunchAtLogin($0) }
            ))
            if loginStatus == .requiresApproval {
                LabeledContent {
                    Button("Open Login Items") {
                        LaunchAtLogin.openSystemSettings()
                    }
                } label: {
                    Text("Allow UpdatyMe in System Settings to open it at login.")
                        .foregroundStyle(.secondary)
                }
            }
            if let loginError {
                Text(loginError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Show in menu bar", isOn: $showsMenuBarExtra)
            Text(showsMenuBarExtra
                 ? "At login, UpdatyMe starts in the menu bar without opening its window."
                 : "Without the menu bar icon, UpdatyMe opens its window at login.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Check automatically", selection: $checkInterval) {
                Text("Every 6 hours").tag(CheckInterval.sixHours)
                Text("Every 12 hours").tag(CheckInterval.twelveHours)
                Text("Daily").tag(CheckInterval.daily)
                Text("Weekly").tag(CheckInterval.weekly)
                Text("Never").tag(CheckInterval.never)
            }
        } header: {
            Text("General")
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle("New updates available", isOn: $notifiesNewUpdates)
            Toggle("Updates finished in the background", isOn: $notifiesUpdatesFinished)
        } header: {
            Text("Notifications")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = LaunchAtLogin.status
    }
}
