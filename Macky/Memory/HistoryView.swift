import AppKit
import MackyCore
import SwiftUI

/// Every request, searchable, grouped by day.
struct HistoryView: View {
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var settings: AppSettings
    @State private var searchText = ""
    @State private var isConfirmingDeletion = false

    private var dayGroups: [(day: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        let filteredEntries = HistorySearch.filter(historyStore.entries, query: searchText)
        let grouped = Dictionary(grouping: filteredEntries) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Caută în istoric…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Toggle("Păstrează istoricul", isOn: $settings.historyEnabled)
                Button("Șterge tot…", role: .destructive) { isConfirmingDeletion = true }
                    .disabled(historyStore.entries.isEmpty)
            }
            if historyStore.entries.isEmpty {
                Spacer()
                Text("Nimic încă. Aici apar toate cererile tale și ce a făcut Macky.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(dayGroups, id: \.day) { group in
                        Section(dayTitle(group.day)) {
                            ForEach(group.entries) { entry in
                                row(for: entry)
                            }
                        }
                    }
                }
            }
            Text(totalsLine)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(minWidth: 480, minHeight: 400)
        .confirmationDialog("Ștergi tot istoricul?", isPresented: $isConfirmingDeletion) {
            Button("Șterge", role: .destructive) { historyStore.deleteAll() }
        }
    }

    private func row(for entry: HistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: routeSymbol(entry.route))
                .foregroundColor(entry.route == .procedure ? MackyDesign.accent : .secondary)
                .frame(width: 18)
                .help(routeName(entry.route))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.question).fontWeight(.semibold).textSelection(.enabled)
                if !entry.answer.isEmpty {
                    Text(entry.answer).font(.callout).textSelection(.enabled)
                }
                if !entry.actions.isEmpty {
                    Text(entry.actions.joined(separator: " → "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(detailLine(for: entry))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.answer, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copiază răspunsul")
            Button { historyStore.delete(entry.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Șterge")
        }
        .padding(.vertical, 3)
    }

    private func detailLine(for entry: HistoryEntry) -> String {
        var parts = [entry.date.formatted(date: .omitted, time: .shortened), routeName(entry.route)]
        if let modelIdentifier = entry.modelIdentifier { parts.append(modelIdentifier) }
        if let cost = entry.costInDollars { parts.append(SessionCostTracker.formatCredits(cost)) }
        if let duration = entry.durationInSeconds { parts.append(String(format: "%.1fs", duration).replacingOccurrences(of: ".", with: ",")) }
        return parts.joined(separator: " · ")
    }

    private var totalsLine: String {
        let entries = historyStore.entries
        let totalCost = entries.compactMap(\.costInDollars).reduce(0, +)
        let withoutModel = entries.filter { $0.route != .model && $0.route != .backgroundAgent }.count
        return "\(entries.count) cereri · \(withoutModel) rezolvate fără model · cost total \(SessionCostTracker.formatCredits(totalCost))"
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Azi" }
        if calendar.isDateInYesterday(day) { return "Ieri" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "ro_RO")))
    }

    private func routeSymbol(_ route: HistoryEntry.Route) -> String {
        switch route {
        case .model: return "sparkles"
        case .quickCommand: return "hare"
        case .procedure: return "bolt.fill"
        case .backgroundAgent: return "person.crop.circle.badge.clock"
        case .routine: return "calendar.badge.clock"
        case .meeting: return "video"
        }
    }

    private func routeName(_ route: HistoryEntry.Route) -> String {
        switch route {
        case .model: return "model AI"
        case .quickCommand: return "comandă rapidă"
        case .procedure: return "procedură învățată"
        case .backgroundAgent: return "agent în fundal"
        case .routine: return "rutină"
        case .meeting: return "meeting Zoom"
        }
    }
}
