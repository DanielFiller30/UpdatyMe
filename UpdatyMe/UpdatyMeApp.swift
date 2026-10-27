//
//  UpdatyMeApp.swift
//  UpdatyMe
//
//  Created by Filler, Daniel on 26.10.26.
//

import SwiftUI
import UpdatyMeCore

@main
struct UpdatyMeApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = InventoryModel.live()
    @AppStorage(AppSettings.showMenuBarExtraKey) private var showsMenuBarExtra = true

    var body: some Scene {
        // Ein einzelnes Hauptfenster: „Öffnen“ aus der Menüleiste holt es nach vorn statt ein zweites zu erzeugen.
        Window("UpdatyMe", id: Self.mainWindowID) {
            ContentView(model: model)
                .task { await model.start() }
        }
        .commands {
            InventoryCommands(model: model)
            DiagnosticsCommands()
        }

        MenuBarExtra(isInserted: $showsMenuBarExtra) {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(count: model.updateCount(in: .overview))
                .task { await model.start() }
        }

        Settings {
            SettingsView(model: model)
        }

        Window("Diagnostics", id: DiagnosticsCommands.windowID) {
            NavigationStack {
                DiagnosticsView()
            }
            .frame(minWidth: 640, minHeight: 480)
        }
    }
}

/// Die App läuft mit dem Menüleisten-Extra weiter, wenn das Fenster geschlossen wird.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Start als Anmeldeobjekt: nur Menüleiste, ohne Hauptfenster. Ist das Menüleisten-Symbol aus,
    /// bleibt das Fenster offen – sonst wäre die App nicht erreichbar.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard LaunchAtLogin.isCurrentLaunchAtLogin(),
              AppSettings.bool(AppSettings.showMenuBarExtraKey, in: .standard) else { return }
        // Das SwiftUI-Fenster entsteht erst nach diesem Aufruf.
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows where window.identifier?.rawValue.hasPrefix(UpdatyMeApp.mainWindowID) == true {
                window.close()
            }
        }
    }
}

/// Menü „Inventory“: Prüfen mit Cache (⌘R) und ohne Cache (⇧⌘R).
struct InventoryCommands: Commands {
    let model: InventoryModel

    var body: some Commands {
        CommandMenu("Inventory") {
            Button("Check All") {
                Task { await model.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isRefreshing)

            Button("Check Without Cache") {
                Task { await model.refresh(ignoringCache: true) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.isRefreshing)
        }
    }
}

/// Menü „Window → Diagnostics“.
struct DiagnosticsCommands: Commands {
    static let windowID = "diagnostics"

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("Diagnostics") {
                openWindow(id: Self.windowID)
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            Divider()
        }
    }
}
