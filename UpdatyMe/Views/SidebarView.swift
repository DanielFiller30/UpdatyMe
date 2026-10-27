import SwiftUI
import UpdatyMeCore

struct SidebarView: View {
    let model: InventoryModel
    @Binding var selection: InventoryCategory?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label(InventoryCategory.favorites.title, systemImage: InventoryCategory.favorites.systemImage)
                    .badge(model.updateCount(in: .favorites))
                    .tag(InventoryCategory.favorites)
            }
            Section("Inventory") {
                ForEach(InventoryCategory.allCases.filter { $0.showsItems && $0 != .favorites }) { category in
                    Label(category.title, systemImage: category.systemImage)
                        .badge(model.updateCount(in: category))
                        .tag(category)
                }
            }
            Section {
                Label(InventoryCategory.history.title, systemImage: InventoryCategory.history.systemImage)
                    .tag(InventoryCategory.history)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    }
}
