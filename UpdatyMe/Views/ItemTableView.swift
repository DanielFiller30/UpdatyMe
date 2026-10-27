import AppKit
import SwiftUI
import UpdatyMeCore

/// Ruhige Liste der Einträge einer Kategorie.
struct ItemTableView: View {
    let model: InventoryModel
    let flow: UpdateFlow
    let category: InventoryCategory
    @Binding var selection: InstalledItem.ID?
    let searchText: String

    @State private var sortOrder = [KeyPathComparator(\InstalledItem.name, comparator: .localizedStandard)]

    private var rows: [InstalledItem] {
        model.visibleItems(in: category)
            .filter { searchText.isEmpty || $0.name.localizedStandardContains(searchText) }
            // Name als zweites Kriterium, damit gleiche Werte (z. B. gleicher Status) stabil sortiert sind.
            .sorted(using: sortOrder + [KeyPathComparator(\InstalledItem.name, comparator: .localizedStandard)])
    }

    var body: some View {
        let rows = rows
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 8) {
                    FavoriteButton(isFavorite: model.isFavorite(item.id)) {
                        model.toggleFavorite(item.id)
                    }
                    ItemIcon(item: item)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                        Text(item.source.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 240, ideal: 320)

            TableColumn("Installed", value: \.installedVersion, comparator: VersionSortComparator()) { item in
                Text(item.installedVersion.isEmpty ? "–" : item.installedVersion)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(item.installedVersion)
            }
            .width(min: 90, ideal: 130)

            TableColumn("Latest", value: \.latestVersionSortKey, comparator: VersionSortComparator()) { item in
                Text(item.latestVersion ?? "–")
                    .monospacedDigit()
                    .foregroundStyle(item.latestVersion == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .help(item.latestVersion ?? "")
            }
            .width(min: 90, ideal: 130)

            TableColumn("Status", value: \.statusSortRank) { item in
                StatusChip(status: item.status, isMajor: item.isMajorUpdate)
            }
            .width(min: 110, ideal: 140)

            TableColumn("Action") { item in
                UpdateActionView(item: item, model: model, flow: flow)
            }
            .width(min: 110, ideal: 130)
        }
        .contextMenu(forSelectionType: InstalledItem.ID.self) { ids in
            if let id = ids.first {
                Button(model.isFavorite(id) ? "Remove from Favorites" : "Add to Favorites",
                       systemImage: model.isFavorite(id) ? "star.slash" : "star") {
                    model.toggleFavorite(id)
                }
                if model.item(id: id)?.isPinnedInBrew != true {
                    Button(model.isPinnedInApp(id) ? "Unpin" : "Pin",
                           systemImage: model.isPinnedInApp(id) ? "pin.slash" : "pin") {
                        model.togglePin(id)
                    }
                }
                if let item = model.item(id: id), item.adoptableCaskToken(remote: model.remotes[id]) != nil {
                    Button("Adopt into Homebrew…", systemImage: "mug") {
                        flow.requestAdoption(item)
                    }
                }
                if let item = model.item(id: id), !model.isUpdateActive(id),
                   RuntimeGuide.guide(for: item)?.uninstall != nil {
                    Button("Uninstall…", systemImage: "trash", role: .destructive) {
                        flow.requestRuntimeScript(item, action: .uninstall)
                    }
                }
                if let path = model.item(id: id)?.installPath, FileManager.default.fileExists(atPath: path) {
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
            }
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .overlay {
            if rows.isEmpty {
                emptyState
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            FailureBanner(failures: model.failures)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if model.hiddenCount(in: category) > 0 {
            ContentUnavailableView {
                Label("No Matching Items", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("All items in this category are hidden by the current filters.")
            } actions: {
                Button("Reset Filters") { model.resetFilter() }
            }
        } else if category == .favorites {
            ContentUnavailableView(
                "No Favorites",
                systemImage: "star",
                description: Text("Click the star next to an item to add it to your favorites.")
            )
        } else if model.isRefreshing && model.items.isEmpty {
            ProgressView("Scanning inventory…")
        } else if category == .runtimes {
            ContentUnavailableView(
                "No Runtimes",
                systemImage: category.systemImage,
                description: Text("No Node.js, Python, Java or Rust installations were found.")
            )
        } else {
            ContentUnavailableView("No Items", systemImage: category.systemImage)
        }
    }
}

/// Stern zum Markieren als Favorit.
struct FavoriteButton: View {
    let isFavorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? AnyShapeStyle(.brandOrange) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.borderless)
        .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
    }
}

/// Zeigt fehlgeschlagene Quellen. Netzwerkfehler werden zu einem Hinweis zusammengefasst.
struct FailureBanner: View {
    let failures: [EcosystemID: InventoryScanner.ScanFailure]

    private var offline: [EcosystemID] {
        failures.filter { ErrorText.isNetworkError($0.value.error) }.keys.sorted { $0.rawValue < $1.rawValue }
    }

    private var others: [(key: EcosystemID, value: InventoryScanner.ScanFailure)] {
        failures.filter { !ErrorText.isNetworkError($0.value.error) }.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    var body: some View {
        if !failures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !offline.isEmpty {
                    Label {
                        Text("No internet connection. Not checked: \(offline.map(\.title).formatted(.list(type: .and)))")
                    } icon: {
                        Image(systemName: "wifi.slash").foregroundStyle(.yellow)
                    }
                }
                ForEach(others, id: \.key) { ecosystem, failure in
                    Label {
                        Text(verbatim: "\(ecosystem.title): \(ErrorText.message(for: failure.error))")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                }
                if failures.keys.contains(where: { !$0.isLatestSource }) {
                    Text("Items from failed sources show the last known state.")
                        .foregroundStyle(.secondary)
                }
                if failures.keys.contains(where: \.isLatestSource) {
                    Text("Latest versions from failed sources are shown as unknown.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.background.secondary)
        }
    }
}
