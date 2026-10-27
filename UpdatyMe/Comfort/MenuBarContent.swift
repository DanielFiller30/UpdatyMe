import SwiftUI
import UpdatyMeCore

/// Symbol in der Menüleiste: Anzahl verfügbarer Updates wie „Übersicht“ (mit aktuellem Filter).
struct MenuBarLabel: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Image(systemName: "arrow.down.circle.fill")
            Text(verbatim: "\(count)")
        } else {
            Image(systemName: "checkmark.circle")
        }
    }
}

/// Menü des Menüleisten-Extras: Updates, Prüfen, Fenster öffnen, Einstellungen, Beenden.
struct MenuBarContent: View {
    let model: InventoryModel
    static let maximumListed = 12

    @Environment(\.openWindow) private var openWindow

    private var updates: [InstalledItem] {
        model.visibleItems(in: .overview).filter { $0.status == .outdated }
    }

    var body: some View {
        let updates = updates
        Section {
            if updates.isEmpty {
                Text("Everything is up to date")
            } else {
                ForEach(updates.prefix(Self.maximumListed)) { item in
                    Button {
                        openMainWindow()
                    } label: {
                        Text(verbatim: "\(item.name)  \(item.installedVersion) → \(item.latestVersion ?? "–")")
                    }
                }
                if updates.count > Self.maximumListed {
                    Text("and \(updates.count - Self.maximumListed) more")
                }
            }
        } header: {
            if model.isRefreshing {
                Text("Checking…")
            } else if updates.isEmpty {
                Text("No Updates")
            } else {
                Text("\(updates.count) Updates Available")
            }
        }

        Divider()
        Button("Check All") {
            Task { await model.refresh() }
        }
        .disabled(model.isRefreshing)
        Button("Open UpdatyMe") {
            openMainWindow()
        }
        SettingsLink {
            Text("Settings…")
        }
        Divider()
        Button("Quit UpdatyMe") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func openMainWindow() {
        openWindow(id: UpdatyMeApp.mainWindowID)
        NSApplication.shared.activate()
    }
}
