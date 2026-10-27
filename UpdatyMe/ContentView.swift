//
//  ContentView.swift
//  UpdatyMe
//
//  Created by Filler, Daniel on 26.10.26.
//

import SwiftUI
import UpdatyMeCore

/// Hauptfenster: Sidebar mit Kategorien, Liste, ausblendbarer Inspector.
/// Liquid Glass für Toolbar, Sidebar und Inspector liefert macOS 26 über die Systemcontainer;
/// die Inhalte liegen auf ruhigem Hintergrund.
struct ContentView: View {
    let model: InventoryModel
    @State private var flow: UpdateFlow

    @State private var category: InventoryCategory?
    @State private var selection: InstalledItem.ID?
    @State private var showsInspector: Bool
    @State private var searchText = ""

    /// Startzustand ist für Previews und Snapshot-Tests einstellbar.
    init(
        model: InventoryModel,
        category: InventoryCategory = .overview,
        selection: InstalledItem.ID? = nil,
        showsInspector: Bool = true
    ) {
        self.model = model
        _flow = State(initialValue: UpdateFlow(model: model))
        _category = State(initialValue: category)
        _selection = State(initialValue: selection)
        _showsInspector = State(initialValue: showsInspector)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, selection: $category)
        } detail: {
            detail
                .navigationTitle(category.map { Text($0.title) } ?? Text("UpdatyMe"))
                .navigationSubtitle(subtitle)
        }
        .inspector(isPresented: $showsInspector) {
            InspectorView(
                item: model.item(id: selection),
                remote: selection.flatMap { model.remotes[$0] },
                lookupError: selection.flatMap { model.itemErrors[$0] }.map { ErrorText.message(for: $0.error) },
                logLines: selection.flatMap { model.updateLogs[$0] } ?? [],
                updateState: selection.flatMap { model.updateStates[$0] },
                lastRun: selection.flatMap { id in model.updateRuns.first { $0.itemID == id } },
                isPinnedInApp: selection.map(model.isPinnedInApp) ?? false,
                onTogglePin: { selection.map(model.togglePin) },
                onAdopt: selection.flatMap { id in
                    model.item(id: id).flatMap { item in
                        item.adoptableCaskToken(remote: model.remotes[id]) == nil || model.isUpdateActive(id) ? nil : { flow.requestAdoption(item) }
                    }
                },
                isFavorite: selection.map(model.isFavorite) ?? false,
                onToggleFavorite: { selection.map(model.toggleFavorite) }
            )
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            if let category, category.showsItems, !updatable(in: category).isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        flow.requestUpdateAll(updatable(in: category))
                    } label: {
                        Label("Update All (\(updatable(in: category).count))", systemImage: "arrow.down.circle")
                    }
                    .tint(.updateOrange)
                    .help("Update all items with an update in this list")
                    .disabled(flow.isQuittingApps)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Check All", systemImage: "arrow.clockwise")
                    }
                }
                .help("Scan the inventory and check for updates")
                .disabled(model.isRefreshing)
            }
            ToolbarItem(placement: .primaryAction) {
                FilterMenu(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help(showsInspector ? "Hide Details" : "Show Details")
            }
        }
        .onChange(of: category) { selection = nil }
        .updatePrompts(flow: flow)
        .frame(minWidth: 820, minHeight: 480)
    }

    @ViewBuilder
    private var detail: some View {
        switch category {
        case .history:
            HistoryView(runs: model.updateRuns)
        case let category?:
            ItemTableView(model: model, flow: flow, category: category, selection: $selection, searchText: searchText)
        case nil:
            ContentUnavailableView("No Category Selected", systemImage: "sidebar.left")
        }
    }

    private func updatable(in category: InventoryCategory) -> [InstalledItem] {
        model.updatableItems(in: category)
    }

    /// Bindung für Dialoge, die zu einem bestimmten `UpdateFlow.Prompt` gehören.
    private var subtitle: Text {
        switch model.refreshStep {
        case .scanning: return Text("Scanning inventory…")
        case .checkingVersions: return Text("Checking for updates…")
        case nil: break
        }
        guard let lastRefresh = model.lastRefresh else {
            return Text(verbatim: "")
        }
        let count = category.map { model.visibleItems(in: $0).count } ?? 0
        let hidden = category.map { model.hiddenCount(in: $0) } ?? 0
        let checked = lastRefresh.formatted(.relative(presentation: .named))
        return hidden > 0
            ? Text("\(count) items · \(hidden) hidden by filters · checked \(checked)")
            : Text("\(count) items · checked \(lastRefresh, format: .relative(presentation: .named))")
    }
}

#Preview {
    ContentView(model: .fixed(SampleInventory.items, lastRefresh: Date()))
}
