import SwiftUI
import SwiftData
import QRGuardCore

/// 기록 (TASKS T-5.2): 필터 · 검색 · 스와이프 삭제 · 전체 삭제 · 미니 RiskMeter · "열었음".
struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \ScanRecord.scannedAt, order: .reverse) private var records: [ScanRecord]

    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var confirmDeleteAll = false

    enum Filter: Hashable, CaseIterable {
        case all, safe, caution, danger
        var title: String {
            switch self {
            case .all: String(localized: "전체")
            case .safe: RiskTier.safe.label
            case .caution: RiskTier.caution.label
            case .danger: RiskTier.danger.label
            }
        }
        var tier: RiskTier? {
            switch self {
            case .all: nil
            case .safe: .safe
            case .caution: .caution
            case .danger: .danger
            }
        }
    }

    private var filtered: [ScanRecord] {
        records.filter { record in
            if let tier = filter.tier, record.riskTier != tier { return false }
            guard !search.isEmpty else { return true }
            let q = search.lowercased()
            return record.rawPayload.lowercased().contains(q)
                || (record.registrableDomain?.contains(q) ?? false)
                || (record.finalURL?.lowercased().contains(q) ?? false)
        }
    }

    private var grouped: [(String, [ScanRecord])] {
        let calendar = Calendar.current
        var sections: [(String, [ScanRecord])] = []
        for record in filtered {
            let title: String
            if calendar.isDateInToday(record.scannedAt) { title = String(localized: "오늘") }
            else if calendar.isDateInYesterday(record.scannedAt) { title = String(localized: "어제") }
            else { title = record.scannedAt.formatted(date: .abbreviated, time: .omitted) }
            if let last = sections.indices.last, sections[last].0 == title {
                sections[last].1.append(record)
            } else {
                sections.append((title, [record]))
            }
        }
        return sections
    }

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView {
                    Label("아직 기록이 없어요", systemImage: "clock")
                } description: {
                    Text(app.settings.retention == .none
                         ? "설정에서 기록 저장이 꺼져 있어요."
                         : "QR을 검사하면 여기에 쌓여요. 기록은 기기 안에만 저장돼요.")
                }
            } else {
                list
            }
        }
        .background(Palette.surface.ignoresSafeArea())
        .navigationTitle("기록")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "주소 검색")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(role: .destructive) { confirmDeleteAll = true } label: {
                        Label("전체 삭제", systemImage: "trash")
                    }
                } label: {
                    Text("편집")
                }
                .disabled(records.isEmpty)
            }
        }
        .confirmationDialog("기록을 모두 삭제할까요?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("모두 삭제", role: .destructive) { app.history.deleteAll() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("삭제한 기록은 복구할 수 없어요.")
        }
    }

    private var list: some View {
        List {
            Section {
                filterChips
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
            }
            if filtered.isEmpty {
                Section {
                    Text("조건에 맞는 기록이 없어요")
                        .font(.subheadline)
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(grouped, id: \.0) { section in
                Section(section.0) {
                    ForEach(section.1) { record in
                        Button { app.openRecord(record) } label: {
                            RecordRow(record: record, showsSource: true)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Palette.card)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { app.history.delete(record) } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                        // 스와이프를 할 수 없는 보조 기술 사용자를 위한 로터 동작
                        .accessibilityAction(named: Text("삭제")) { app.history.delete(record) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                ForEach(Filter.allCases, id: \.self) { item in
                    let selected = filter == item
                    Button { filter = item } label: {
                        HStack(spacing: Spacing.xs) {
                            if let tier = item.tier {
                                Circle().fill(tier.color).frame(width: 7, height: 7)
                            }
                            Text(item.title)
                            Text("\(count(for: item))")
                                .foregroundStyle(selected ? Palette.onInk.opacity(0.8) : Palette.inkSecondary)
                        }
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        // Dark에서 ink는 밝은색이라 흰 글자(1.1:1)는 보이지 않는다 → onInk
                        .foregroundStyle(selected ? Palette.onInk : Palette.ink)
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.s)
                        .background(selected ? Palette.ink : Palette.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(selected ? .clear : Palette.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.title) \(count(for: item))건")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private func count(for item: Filter) -> Int {
        guard let tier = item.tier else { return records.count }
        return records.filter { $0.riskTier == tier }.count
    }
}

#Preview {
    NavigationStack { HistoryView() }
        .environment(PreviewSupport.appModel())
        .modelContainer(PreviewSupport.container)
}
