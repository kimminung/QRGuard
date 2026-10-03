import SwiftUI
import QRGuardCore

/// 링크·텍스트 붙여넣기 검사 (F-04). `PasteButton`으로 붙여넣기 권한 팝업을 피하고, 수동 입력도 지원한다.
struct PasteEntryView: View {
    let onSubmit: (ScanInput) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("QR 대신 받은 링크나 문자 내용을 그대로 넣어 주세요. 접속하지 않고 분석만 해요.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary)

                TextEditor(text: $text)
                    .font(.body)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.m)
                    .frame(minHeight: 120, maxHeight: 200)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.line))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("https://… 또는 문자 내용")
                                .foregroundStyle(Palette.inkSecondary.opacity(0.7))
                                .padding(Spacing.l)
                                .padding(.top, 4)
                                .allowsHitTesting(false)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first {
                        text = first
                    }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)

                Spacer()

                Button {
                    onSubmit(ScanInput(raw: trimmed, source: .paste))
                } label: {
                    Label("분석하기", systemImage: "magnifyingglass")
                }
                .buttonStyle(.primary(.brand))
                .disabled(trimmed.isEmpty)
            }
            .padding(Spacing.l)
            .background(Palette.surface.ignoresSafeArea())
            .navigationTitle("링크 붙여넣기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }
}

#Preview {
    PasteEntryView { _ in }
}
