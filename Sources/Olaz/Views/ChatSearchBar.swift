import SwiftUI

/// Search inside the open conversation (⇧⌘F, or the magnifier in the toolbar). It looks through the messages that are
/// loaded; "Tìm tin cũ hơn" pulls the next older batch so the search reaches further back.
struct ChatSearchState: Equatable {
    var active = false
    var query = ""
    /// Ids of the matching messages, newest first.
    var hits: [String] = []
    /// Position in `hits` (0 = newest match).
    var index = 0
    var focusTick = 0

    var current: String? { hits.indices.contains(index) ? hits[index] : nil }

    /// Messages whose text contains `query` (case, diacritics and đ folded), newest first.
    static func hits(_ query: String, in messages: [ChatMessage]) -> [String] {
        let needle = ZaloEngine.contactFold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return messages.reversed()
            .filter { $0.kind != .recalled && !$0.text.isEmpty && ZaloEngine.contactFold($0.text).contains(needle) }
            .map(\.id)
    }
}

struct ChatSearchBar: View {
    @Binding var state: ChatSearchState
    /// Older history can still be pulled.
    let canLoadOlder: Bool
    var older: () -> Void
    var newer: () -> Void
    var loadOlder: () -> Void
    var close: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Tìm tin nhắn trong hội thoại", text: $state.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(older)
                .onExitCommand(perform: close)
            if !state.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(state.hits.isEmpty ? "Không có kết quả" : "\(state.index + 1)/\(state.hits.count)")
                    .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize()
            }
            Button(action: older) { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(state.index + 1 >= state.hits.count)
                .help("Kết quả cũ hơn (↩)")
            Button(action: newer) { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(state.index == 0 || state.hits.isEmpty)
                .help("Kết quả mới hơn")
            if canLoadOlder && !state.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Tìm tin cũ hơn", action: loadOlder)
                    .buttonStyle(.borderless).font(.system(size: 12))
                    .help("Tải thêm tin nhắn cũ để tìm tiếp")
            }
            Button("Xong", action: close)
                .buttonStyle(.borderless).font(.system(size: 12, weight: .medium))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
        .onAppear { focused = true }
        .onChange(of: state.focusTick) { _, _ in focused = true }
    }
}
