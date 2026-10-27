import SwiftUI
import UpdatyMeCore

/// Leiser Status: grüner Punkt (aktuell), oranger Chip (Update), grau (unbekannt), Pin (fixiert).
/// Grün und Orange stammen aus dem App-Icon (Asset-Katalog `BrandGreen`, `UpdateOrange`).
/// `UpdateOrange` ist für Text abgedunkelt (WCAG 4,5:1); Grafik nutzt das hellere `BrandOrange` (3:1).
struct StatusChip: View {
    let status: InstalledItem.Status
    var isMajor = false

    var body: some View {
        HStack(spacing: 4) {
            switch status {
            case .upToDate:
                Circle()
                    .fill(.brandGreen)
                    .frame(width: 7, height: 7)
                Text("Up to date")
                    .foregroundStyle(.secondary)
            case .outdated:
                Text("Update")
                    .foregroundStyle(.updateOrange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.updateOrange.opacity(0.15), in: .capsule)
                if isMajor {
                    MajorBadge()
                }
            case .unknown:
                Circle()
                    .strokeBorder(.secondary, lineWidth: 1)
                    .frame(width: 7, height: 7)
                Text("Unknown")
                    .foregroundStyle(.secondary)
            case .pinned:
                Image(systemName: "pin.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text("Pinned")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: Text {
        switch status {
        case .upToDate: Text("Status: up to date")
        case .outdated: isMajor ? Text("Status: major update available") : Text("Status: update available")
        case .unknown: Text("Status: unknown")
        case .pinned: Text("Status: pinned")
        }
    }
}

struct MajorBadge: View {
    var body: some View {
        Text("Major")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.red)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(.red.opacity(0.6), lineWidth: 1))
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        StatusChip(status: .upToDate)
        StatusChip(status: .outdated)
        StatusChip(status: .outdated, isMajor: true)
        StatusChip(status: .unknown)
        StatusChip(status: .pinned)
    }
    .padding()
}
