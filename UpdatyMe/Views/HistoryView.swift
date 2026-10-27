import SwiftUI
import UpdatyMeCore

/// Update-Verlauf mit Vorher-/Nachher-Version, Ergebnis und Ausgabe.
struct HistoryView: View {
    let runs: [UpdateRun]

    var body: some View {
        if runs.isEmpty {
            ContentUnavailableView(
                "No Updates Yet",
                systemImage: InventoryCategory.history.systemImage,
                description: Text("Completed updates appear here with their previous and new version.")
            )
        } else {
            List(runs) { run in
                VStack(alignment: .leading, spacing: 4) {
                    UpdateRunSummary(run: run, showsName: true)
                    if !run.log.isEmpty {
                        DisclosureGroup("Output") {
                            Text(run.log)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// Eine Zeile Verlauf: Ergebnis, Versionen, Zeitpunkt, ggf. Fehlerursache.
struct UpdateRunSummary: View {
    let run: UpdateRun
    var showsName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                outcomeIcon
                if showsName {
                    Text(run.itemName).fontWeight(.medium)
                }
                Text(verbatim: "\(run.fromVersion) → \(run.toVersion ?? "–")")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(outcomeText)
                Text(run.startedAt, format: .dateTime)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let reason = run.failureReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(run.outcome == .failed ? .red : .secondary)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var outcomeIcon: some View {
        switch run.outcome {
        case .succeeded, .succeededRestartRequired:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.brandGreen)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.mini)
        }
    }

    private var outcomeText: LocalizedStringKey {
        switch run.outcome {
        case .succeeded: "Succeeded"
        case .succeededRestartRequired: "Succeeded, restart required"
        case .failed: "Failed"
        case .cancelled: "Skipped"
        case .running: "Running"
        }
    }
}
