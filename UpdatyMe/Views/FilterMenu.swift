import SwiftUI
import UpdatyMeCore

/// Toolbar-Menü für den Inventar-Filter. Das Symbol ist gefüllt, sobald ein Filter vom Standard abweicht.
struct FilterMenu: View {
    @Bindable var model: InventoryModel

    var body: some View {
        Menu {
            Toggle("Show System Apps", isOn: $model.filter.showsSystemApps)
            Toggle("Favorites Only", isOn: $model.filter.favoritesOnly)

            Picker("Status", selection: $model.filter.status) {
                ForEach(InventoryFilter.StatusFilter.allCases, id: \.self) { status in
                    Text(status.title).tag(status)
                }
            }
            .pickerStyle(.inline)

            Section("Source") {
                ForEach(InventoryFilter.selectableSources, id: \.self) { source in
                    Toggle(source.title, isOn: sourceBinding(source))
                }
            }

            Divider()
            Button("Reset Filters") { model.resetFilter() }
                .disabled(!model.filter.isActive)
        } label: {
            Label("Filter", systemImage: model.filter.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .help("Filter the list")
    }

    /// Leere Quellenauswahl bedeutet „alle“; ein Haken schränkt auf die gewählten Quellen ein.
    private func sourceBinding(_ source: ItemSource) -> Binding<Bool> {
        Binding {
            model.filter.sources.contains(source)
        } set: { isOn in
            if isOn {
                model.filter.sources.insert(source)
            } else {
                model.filter.sources.remove(source)
            }
        }
    }
}
