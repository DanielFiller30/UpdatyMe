import AppKit
import SwiftUI
import UpdatyMeCore

/// App-Icon aus dem Bundle, sonst ein SF Symbol nach Art des Eintrags.
struct ItemIcon: View {
    let item: InstalledItem
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let image = Self.appIcon(for: item) {
                Image(nsImage: image)
                    .resizable()
            } else {
                Image(systemName: item.kind.systemImage)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.15)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static let cache = NSCache<NSString, NSImage>()

    private static func appIcon(for item: InstalledItem) -> NSImage? {
        guard let path = item.installPath, path.hasSuffix(".app"),
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
