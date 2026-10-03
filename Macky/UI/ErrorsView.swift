import MackyCore
import SwiftUI

/// Home → Erori: everything that went wrong, newest first, with the technical detail one click away.
struct ErrorsSectionView: View {
    @ObservedObject var errorLog: ErrorLogStore
    @State private var expandedIdentifiers: Set<UUID> = []
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Erori").font(MackyDesign.rounded(24, .bold)).foregroundColor(MackyDesign.textPrimary)
                    Text("Tot ce nu a mers: comenzi, agenți, email, Google și închideri neașteptate.")
                        .font(MackyDesign.rounded(13)).foregroundColor(MackyDesign.textSecondary)
                }
                Spacer()
                Button(copied ? "Copiat" : "Copiază tot") {
                    errorLog.copyAll()
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                }
                .buttonStyle(MackySecondaryPillStyle())
                .disabled(errorLog.entries.isEmpty)
                Button("Șterge tot") { errorLog.clear() }
                    .buttonStyle(MackySecondaryPillStyle())
                    .disabled(errorLog.entries.isEmpty)
            }

            if errorLog.entries.isEmpty {
                VStack(spacing: 10) {
                    MackyMascotView(mood: .happy, size: 56)
                    Text("Nicio eroare. Totul merge.").font(MackyDesign.rounded(15, .semibold)).foregroundColor(MackyDesign.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(errorLog.entries) { entry in
                            row(entry)
                        }
                    }
                }
            }
        }
        .padding(24)
        .onAppear { errorLog.importCrashReports() }
    }

    private func row(_ entry: ErrorLogEntry) -> some View {
        let isExpanded = expandedIdentifiers.contains(entry.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: entry.source == "Închidere neașteptată" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(entry.source == "Închidere neașteptată" ? .red : .orange)
                Text(entry.source).font(MackyDesign.rounded(13, .bold)).foregroundColor(MackyDesign.textPrimary)
                Spacer()
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(MackyDesign.rounded(12)).foregroundColor(MackyDesign.textSecondary)
            }
            Text(entry.message)
                .font(MackyDesign.rounded(13)).foregroundColor(MackyDesign.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !entry.details.isEmpty {
                Button(isExpanded ? "Ascunde detaliile" : "Detalii") {
                    if isExpanded { expandedIdentifiers.remove(entry.id) } else { expandedIdentifiers.insert(entry.id) }
                }
                .buttonStyle(.link)
                .font(MackyDesign.rounded(12))
                if isExpanded {
                    Text(entry.details)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(MackyDesign.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MackyDesign.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(MackyDesign.hairline, lineWidth: 1))
    }
}
