import SwiftUI
import QRGuardCore

/// 링크·텍스트 붙여넣기 검사 (F-04). `PasteButton`으로 붙여넣기 권한 팝업을 피하고, 수동 입력도 지원한다.
struct PasteEntryView: View {
    let onSubmit: (ScanInput) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var decodingTextArt = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 문자(█▀▄)로 그린 QR이면 먼저 비트맵으로 디코딩한다 (V03). 아니면 입력 그대로 분석한다.
    private func submit() {
        let input = trimmed
        guard TextArtQR.looksLikeTextArt(input) else {
            onSubmit(ScanInput(raw: input, source: .paste))
            return
        }
        decodingTextArt = true
        Task {
            defer { decodingTextArt = false }
            if let decoded = await QRImageDecoder.decodeTextArt(input) {
                onSubmit(ScanInput(raw: decoded, source: .paste, vision: VisionSignals(decodedFromTextArt: true)))
            } else {
                onSubmit(ScanInput(raw: input, source: .paste))
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("QR 대신 받은 링크나 문자 내용을 그대로 넣어 주세요. 접속하지 않고 분석만 해요.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary)

                TextEditor(text: $text)
                    .font(.body)
                    .accessibilityLabel("링크 또는 문자 내용")
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.m)
                    .frame(minHeight: 120, maxHeight: 200)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.line))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            // 70% 불투명은 Light 카드 위 3.1:1 → 불투명 inkSecondary(5.9:1). 입력란 라벨이 같은 내용을 읽으므로 VoiceOver에서는 숨긴다.
                            Text("https://… 또는 문자 내용")
                                .foregroundStyle(Palette.inkSecondary)
                                .padding(Spacing.l)
                                .padding(.top, 4)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
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
                    submit()
                } label: {
                    Label("분석하기", systemImage: "magnifyingglass")
                }
                .buttonStyle(.primary(.brand))
                .disabled(trimmed.isEmpty || decodingTextArt)
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
