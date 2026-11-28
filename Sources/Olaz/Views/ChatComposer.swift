import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Floating glass composer: typing indicator, reply banner, suggestions, then one row of "+" menu, text capsule and send / like button.
struct ChatComposer: View {
    let name: String
    /// Group conversations offer @mentions of the official member list.
    var conversationId: String = ""
    var isGroup: Bool = false
    @Binding var draft: String
    @Binding var mentions: [Mention]
    @Binding var replyTo: ChatMessage?
    let typingName: String?
    let focusTick: Int
    let send: () -> Void
    let sendLike: () -> Void

    @Environment(ZaloEngine.self) private var engine
    @AppStorage(OlazPrefs.accent) private var accentStored = OlazAccent.blue.rawValue
    @Namespace private var glassNamespace
    @State private var textHeight: CGFloat = ComposerTextView.lineHeight
    @State private var handle = ComposerHandle()
    @State private var query: MentionQuery?
    @State private var candidates: [MentionCandidate] = []
    @State private var selected = 0
    @State private var showPollCreate = false
    @State private var showStickers = false
    /// "Ảnh hoặc Video" / "Tệp": the open panel and what its pick is sent as.
    @State private var importing = false
    @State private var importKind = AttachmentKind.files
    @State private var showMyCard = false
    @State private var reminderInfo: ReminderComposeInfo?
    /// ⌘V with an image or Finder files on the pasteboard: shown for confirmation before sending.
    @State private var pendingPaste: PastedAttachments?

    private enum AttachmentKind { case media, files }
    /// Stickers suggested for the draft (official suggestion logic); they show only while the draft still is the text they were found for.
    @State private var typingStickers = TypingStickerState()
    @State private var sendingSuggestion: String?

    private var suggestionsOpen: Bool { isGroup && query != nil && !candidates.isEmpty }
    private var stickerStripOpen: Bool {
        typingStickers.isVisible(draft: draft, mentionListOpen: suggestionsOpen, settingEnabled: StickerSuggestState.shared.setting?.enabled)
    }

    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 8) {
            if let typingName {
                HStack(spacing: 6) {
                    Image(systemName: "ellipsis.bubble").symbolEffect(.pulse)
                    Text("\(typingName) đang soạn tin…")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11).padding(.vertical, 4)
                .glassEffect(.regular, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
            if let replyTo {
                HStack(spacing: 8) {
                    Rectangle().fill(.tint).frame(width: 2.5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Trả lời \(replyTo.isMine ? "chính mình" : replyTo.senderName)")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(replyTo.text.isEmpty ? "Tin nhắn" : replyTo.text)
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Hủy trả lời", systemImage: "xmark") { self.replyTo = nil }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if suggestionsOpen {
                MentionSuggestions(candidates: candidates, selected: $selected, pick: pick)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if stickerStripOpen {
                TypingStickerStrip(stickers: typingStickers.stickers, sending: sendingSuggestion, pick: sendSuggestion,
                                   dismiss: { typingStickers.dismissed = true })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // Container spacing below the stack spacing: the discs and the field stay separate shapes instead of melting together.
            GlassEffectContainer(spacing: 4) {
                HStack(alignment: .bottom, spacing: 8) {
                    // Extra room: with Dictation on, macOS shows its glass mic chip just left of the insertion point,
                    // which reaches past the field's leading edge.
                    plusMenu
                        .padding(.trailing, 8)
                    field
                    sendControl
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .animation(.snappy(duration: 0.18), value: suggestionsOpen)
        .animation(.snappy(duration: 0.18), value: stickerStripOpen)
        .animation(.snappy(duration: 0.18), value: replyTo?.id)
        .animation(.snappy(duration: 0.18), value: typingName)
        .onAppear { ComposerTextView.accent = NSColor(ChatPalette.accent(accentStored)) }
        .onChange(of: accentStored) { _, now in ComposerTextView.accent = NSColor(ChatPalette.accent(now)) }
        .task(id: query) { await loadCandidates() }
        .task(id: draft) { await loadStickerSuggestions() }
        .onChange(of: draft) { _, _ in typingStickers.dismissed = false }
        .sheet(isPresented: $showPollCreate) { PollCreateSheet(conversationId: conversationId) }
        .sheet(isPresented: $showMyCard) { MyCardSheet(conversationId: conversationId, conversationName: name) }
        .sheet(isPresented: Binding(get: { reminderInfo != nil }, set: { if !$0 { reminderInfo = nil } })) {
            if let reminderInfo { ReminderComposeSheet(conversationId: conversationId, info: reminderInfo) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: importKind == .media ? [.image, .movie] : [.data],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            sendAttachments(urls, as: importKind)
        }
        .sheet(item: $pendingPaste) { pasted in
            PastePreviewSheet(items: pasted, name: name,
                              send: { sendPasted(pasted); pendingPaste = nil },
                              cancel: { pendingPaste = nil })
        }
    }

    // MARK: Parts

    /// The official toolbar's attachments (photo / video, file, screenshot, my contact card) and its "…" menu (reminder, poll),
    /// then sticker and the system emoji palette.
    private var plusMenu: some View {
        Menu {
            if !conversationId.isEmpty {
                Button("Ảnh hoặc Video", systemImage: "photo.on.rectangle") { importKind = .media; importing = true }
                Button("Tệp", systemImage: "paperclip") { importKind = .files; importing = true }
                Menu("Chụp màn hình", systemImage: "camera.viewfinder") {
                    Button("Chụp kèm cửa sổ \(AppBrand.name)") { engine.startScreenCapture(in: conversationId, withOlaz: true) }
                    Button("Chụp không kèm cửa sổ \(AppBrand.name)") { engine.startScreenCapture(in: conversationId, withOlaz: false) }
                }
                Button("Danh thiếp của tôi", systemImage: "person.crop.rectangle") { showMyCard = true }
                Divider()
                Button("Nhắc hẹn", systemImage: "alarm") { openReminder() }
            }
            if isGroup && !conversationId.isEmpty {
                Button("Bình chọn", systemImage: "chart.bar.doc.horizontal") { showPollCreate = true }
            }
            if !conversationId.isEmpty {
                Button("Sticker", systemImage: "face.dashed") { showStickers = true }
            }
            Button("Emoji", systemImage: "face.smiling") { NSApp.orderFrontCharacterPalette(nil) }
        } label: {
            // Drawn like the send disc: a glass-styled Menu renders an extra pull-down segment beside the button.
            Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Thêm")
        .accessibilityLabel("Thêm")
        .tourAnchor(.composer, arrowEdge: .top)
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ComposerTextView(
                text: $draft, mentions: $mentions, height: $textHeight, focusTick: focusTick,
                handle: handle, mentionsEnabled: isGroup,
                onMentionQuery: { query = $0 },
                onSuggestionKey: suggestionKey,
                onPasteAttachments: conversationId.isEmpty ? nil : { pendingPaste = $0 },
                onSend: send)
                .frame(height: textHeight)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Tin nhắn tới \(name)")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.vertical, 10)
            if !conversationId.isEmpty {
                Button {
                    showStickers.toggle()
                } label: {
                    Image(systemName: "face.smiling").font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
                .help("Gửi Sticker")
                .accessibilityLabel("Gửi Sticker")
                .popover(isPresented: $showStickers, arrowEdge: .top) {
                    StickerPicker(conversationId: conversationId) { showStickers = false }
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    /// 👍 while the box is empty, the arrow once there is something to send; the two glass discs morph into each other.
    private var sendControl: some View {
        Group {
            if isEmpty {
                Button(action: sendLike) {
                    Text("👍").font(.system(size: 18)).frame(width: 36, height: 36).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .glassEffectID("send", in: glassNamespace)
                .help("Gửi biểu tượng thích")
                .accessibilityLabel("Gửi biểu tượng thích")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(ChatPalette.accent(accentStored)).interactive(), in: Circle())
                .glassEffectID("send", in: glassNamespace)
                .help("Gửi")
                .accessibilityLabel("Gửi tin nhắn")
            }
        }
        .animation(.bouncy(duration: 0.3), value: isEmpty)
    }

    // MARK: Attachments, reminder

    /// The picked files go to the conversation they were picked in, even if another one is open by the time they are sent.
    private func sendAttachments(_ urls: [URL], as kind: AttachmentKind) {
        let target = conversationId
        guard !target.isEmpty else { return }
        Task {
            let outcome = kind == .media ? await engine.sendMedia(urls, to: target) : await engine.sendFiles(urls, to: target)
            engine.report(outcome, in: target)
        }
    }

    /// Pasted photos / videos go the "Ảnh hoặc Video" way, other pasted files the "Tệp" way.
    private func sendPasted(_ pasted: PastedAttachments) {
        let target = conversationId
        guard !target.isEmpty else { return }
        // A clipboard bitmap goes the screenshot "Gửi" way; Finder files take the attach buttons' paths, whose adapter
        // sends the official photo types as photos and anything else (HEIC, SVG, video…) as files.
        if let image = pasted.clipboardImage {
            Task { engine.report(await engine.sendPastedImage(image, to: target), in: target) }
        }
        if !pasted.media.isEmpty { sendAttachments(pasted.media, as: .media) }
        if !pasted.files.isEmpty { sendAttachments(pasted.files, as: .files) }
    }

    /// The chat-bar gate decides on click, as the official menu item does (its warning when I may not create one here).
    private func openReminder() {
        let target = conversationId
        Task {
            guard let info = await engine.reminderComposeInfo(for: target) else {
                CardActionCenter.shared.show("Chưa đọc được thông tin nhắc hẹn từ Zalo. Hãy thử lại sau giây lát.", in: target)
                return
            }
            guard info.allowed else {
                CardActionCenter.shared.show(info.text.isEmpty ? "Không thể tạo nhắc hẹn trong cuộc trò chuyện này." : info.text, in: target)
                return
            }
            if engine.openConversationId == target { reminderInfo = info }
        }
    }

    // MARK: @mention suggestions

    /// Debounced lookup against the official member list; stale answers are discarded.
    private func loadCandidates() async {
        guard isGroup, let query else { candidates = []; return }
        try? await Task.sleep(for: .milliseconds(40))
        guard !Task.isCancelled else { return }
        let found = await engine.mentionCandidates(in: conversationId, query: query.text,
                                                   excluding: mentions.map(\.uid))
        guard !Task.isCancelled else { return }
        candidates = found
        selected = 0
    }

    private func pick(_ candidate: MentionCandidate) {
        guard let range = query?.range else { return }
        handle.insertMention(candidate, replacing: range)
        query = nil
        candidates = []
    }

    // MARK: Sticker suggestions

    /// Official `_handleSuggestTextChange` → `_checkStickerSuggestion` (debounced): the text is matched by the official suggestion logic. Swift only
    /// skips what can never match (blank, over the 200 UTF-16 units JS accepts); length, "#…" and line rules stay in the adapter. While the setting is
    /// off, or while an IME composition is open, nothing is asked.
    private func loadStickerSuggestions() async {
        let text = draft
        let state = StickerSuggestState.shared
        guard !conversationId.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= 200, !suggestionsOpen else {
            typingStickers.clear()
            return
        }
        await state.loadIfNeeded(from: engine)
        guard state.setting?.enabled == true else { typingStickers.clear(); return }
        try? await Task.sleep(for: .milliseconds(state.delay))
        // Marked text is a half-typed syllable: wait for the composition to end (a bounded wait), never ask about it.
        var waits = 0
        while handle.textView?.hasMarkedText() == true, waits < 20, !Task.isCancelled {
            waits += 1
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard !Task.isCancelled else { return }
        guard handle.textView?.hasMarkedText() != true, draft == text, !typingStickers.isHeld(text) else { typingStickers.clear(); return }
        let found = await engine.typingStickerSuggestions(in: conversationId, text: text)
        guard !Task.isCancelled else { return }
        typingStickers.offer(found, for: text)
    }

    /// Official `_sendSuggestionSticker`: the box is cleared first (the typed text is not sent), then the sticker goes out with the suggestion
    /// source. A send that fails gives the text back, after whatever was typed meanwhile.
    private func sendSuggestion(_ sticker: StickerEntry, index: Int) {
        // A click on a strip that no longer matches the text, or during an IME composition (the draft would not be what the user sees), is ignored.
        guard sendingSuggestion == nil, stickerStripOpen, handle.textView?.hasMarkedText() != true else { return }
        let target = conversationId
        guard engine.openConversationId == target else {
            CardActionCenter.shared.show(StickerNotice.notReady, in: target)
            return
        }
        let taken = typingStickers.take(ComposerDraft(text: draft, mentions: mentions))
        sendingSuggestion = sticker.id
        draft = ""
        mentions = []
        Task {
            let outcome = await engine.sendSticker(sticker, in: target, source: .suggestion, typed: taken.typed, index: index)
            sendingSuggestion = nil
            switch outcome {
            case .done: break
            case .pending(let text):
                // No answer: the sticker may be on its way. The text is not given back (nothing invites a second send), the strip stays away
                // for that text, and the notice says to check the conversation.
                typingStickers.hold(taken.typed)
                CardActionCenter.shared.show(text, in: target)
            case .locked(let text), .failed(let text), .unsupported(let text):
                // The composer for this conversation takes the text back (ChatView `restoreFailedDraft`, also when the view is gone). Silently:
                // this toast is the one message about this failure.
                engine.failedDrafts.stash(taken.draft, for: target, silent: true)
                CardActionCenter.shared.show(text, in: target)
            default: break
            }
        }
    }

    /// Keys the text view forwards while the popover is open; returns whether it consumed the key.
    private func suggestionKey(_ key: MentionKey) -> Bool {
        // Esc hides the sticker suggestions (they take no other keys: Return keeps sending the text).
        if !suggestionsOpen, stickerStripOpen, key == .cancel { typingStickers.dismissed = true; return true }
        guard suggestionsOpen else { return false }
        switch key {
        case .down: selected = (selected + 1) % candidates.count
        case .up: selected = (selected - 1 + candidates.count) % candidates.count
        case .confirm: pick(candidates[min(selected, candidates.count - 1)])
        case .cancel: query = nil; candidates = []
        }
        return true
    }
}

// MARK: - @mention popover

/// The "@…" being typed: `range` covers the "@" and everything typed after it.
struct MentionQuery: Equatable {
    var range: NSRange
    var text: String
}

enum MentionKey { case up, down, confirm, cancel }

private struct MentionSuggestions: View {
    let candidates: [MentionCandidate]
    @Binding var selected: Int
    let pick: (MentionCandidate) -> Void

    private let rowHeight: CGFloat = 38

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        row(candidate, isSelected: index == selected)
                            .id(candidate.id)
                            .onHover { inside in if inside { selected = index } }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selected) { _, now in
                guard candidates.indices.contains(now) else { return }
                withAnimation(.snappy(duration: 0.12)) { proxy.scrollTo(candidates[now].id) }
            }
        }
        .frame(height: min(CGFloat(candidates.count) * (rowHeight + 2) + 12, 6.5 * (rowHeight + 2)))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Gợi ý nhắc thành viên")
    }

    private func row(_ candidate: MentionCandidate, isSelected: Bool) -> some View {
        Button { pick(candidate) } label: {
            HStack(spacing: 10) {
                if candidate.isAll {
                    Image(systemName: "at")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.tint))
                } else {
                    RemoteAvatar(url: candidate.avatar, name: candidate.name, size: 26)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(candidate.isAll ? "Tất cả" : candidate.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    if candidate.isAll {
                        Text("Nhắc tất cả thành viên")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(TintShapeStyle().opacity(0.16)) : AnyShapeStyle(Color.clear)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.isAll ? "Nhắc tất cả thành viên" : "Nhắc \(candidate.name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Lets SwiftUI insert a chosen mention into the NSTextView.
@MainActor
final class ComposerHandle {
    weak var textView: NSTextView?

    func insertMention(_ candidate: MentionCandidate, replacing range: NSRange) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        var range = range
        if tv.hasMarkedText() {
            // A half-typed Telex syllable: commit it first, or replacing under the input method garbles the text. The committed
            // syllable belongs to the "@query", so the replaced range runs up to the caret.
            // Commit in the field as shown, then reset the input method so it does not keep composing on the old syllable.
            tv.unmarkText()
            tv.inputContext?.discardMarkedText()
            let caret = tv.selectedRange()
            if caret.length == 0, caret.location > NSMaxRange(range), caret.location <= storage.length,
               range.location < storage.length,
               (storage.string as NSString).substring(with: NSRange(location: range.location, length: caret.location - range.location))
                   .rangeOfCharacter(from: .newlines) == nil {
                range.length = caret.location - range.location
            }
        }
        guard NSMaxRange(range) <= storage.length, range.location < storage.length,
              (storage.string as NSString).character(at: range.location) == 0x40 else { return }
        let label = "@" + candidate.name.replacingOccurrences(of: "\n", with: " ")
        let token = MentionToken(uid: candidate.isAll ? "-1" : candidate.id, label: label, isAll: candidate.isAll)
        let inserted = NSMutableAttributedString(string: label, attributes: ComposerTextView.tokenAttributes(token))
        inserted.append(NSAttributedString(string: " ", attributes: ComposerTextView.baseAttributes))
        guard tv.shouldChangeText(in: range, replacementString: inserted.string) else { return }
        storage.replaceCharacters(in: range, with: inserted)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + inserted.length, length: 0))
        tv.window?.makeFirstResponder(tv)
    }
}

/// Attribute payload of an atomic mention inside the composer text.
final class MentionToken: NSObject {
    let uid: String
    let label: String
    let isAll: Bool
    init(uid: String, label: String, isAll: Bool) { self.uid = uid; self.label = label; self.isAll = isAll }
}

extension NSAttributedString.Key {
    static let zaloMention = NSAttributedString.Key("app.olaz.mention")
}

// MARK: - NSTextView-backed field

/// Multi-line field that respects the caret and IME composition (Vietnamese Telex):
/// Return sends only when there is no marked text; Shift/Option+Return inserts a newline
/// at the caret.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var mentions: [Mention]
    @Binding var height: CGFloat
    var focusTick: Int
    var handle: ComposerHandle? = nil
    var mentionsEnabled = false
    var onMentionQuery: (MentionQuery?) -> Void = { _ in }
    /// While the popover is open: ↑ ↓ Return/Tab Esc. Returns true when consumed.
    var onSuggestionKey: (MentionKey) -> Bool = { _ in false }
    /// ⌘V with an image or files on the pasteboard; nil keeps the plain-text paste only.
    var onPasteAttachments: ((PastedAttachments) -> Void)? = nil
    var onSend: () -> Void

    /// What ⌘V should send instead of inserting text: Finder files (photos / videos as media, the rest as files), or a bitmap
    /// (screenshot, "Copy Image") written to a temporary PNG. Text on the pasteboard always wins over a bitmap, so text copied
    /// from apps that also publish a picture of the selection (Office, Pages…) still pastes as text.
    /// Cheap check for menu validation (no file is written).
    static func canPasteAttachments(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        return pasteboard.availableType(from: [.string]) == nil && pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    static func pastedAttachments(_ pasteboard: NSPasteboard) -> PastedAttachments? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            var media: [URL] = [], files: [URL] = []
            for url in urls where !url.hasDirectoryPath {
                let type = UTType(filenameExtension: url.pathExtension)
                if let type, type.conforms(to: .image) || type.conforms(to: .movie) { media.append(url) } else { files.append(url) }
            }
            if !media.isEmpty || !files.isEmpty { return PastedAttachments(media: media, files: files) }
        }
        guard pasteboard.availableType(from: [.string]) == nil,
              pasteboard.availableType(from: [.png, .tiff]) != nil,
              let png = ScreenCapture.clipboardPNG(pasteboard),
              let url = ScreenCapture.writeShot(png) else { return nil }
        return PastedAttachments(clipboardImage: url)
    }

    static let font = NSFont.systemFont(ofSize: 14)
    static let baseAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
    /// Color of mention tokens: the accent picked in Settings (set by `ChatComposer`; an `NSColor` cannot read `.tint`).
    static var accent = NSColor(ZaloTheme.blue)
    static func tokenAttributes(_ token: MentionToken) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
         .foregroundColor: accent,
         .backgroundColor: accent.withAlphaComponent(0.12),
         .zaloMention: token]
    }
    /// Sets text set from outside (restored draft) together with its mentions, rebuilding their token styling
    /// so `syncMentions` publishes them back instead of wiping them. Offsets that no longer read "@…" are skipped.
    static func setContent(_ tv: NSTextView, text: String, mentions: [Mention]) {
        tv.string = text
        tv.typingAttributes = baseAttributes
        guard let storage = tv.textStorage, !mentions.isEmpty else { return }
        let ns = text as NSString
        for m in mentions where m.pos >= 0 && m.len > 1 && m.pos + m.len <= ns.length && ns.character(at: m.pos) == 0x40 {
            let range = NSRange(location: m.pos, length: m.len)
            storage.setAttributes(tokenAttributes(MentionToken(uid: m.uid, label: ns.substring(with: range), isAll: m.isAll)), range: range)
        }
    }
    static var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }
    private static let maxLines: CGFloat = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = FieldTextView()
        tv.delegate = context.coordinator
        tv.font = Self.font
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.setAccessibilityLabel("Nhập tin nhắn")
        context.coordinator.applyingExternal = true
        Self.setContent(tv, text: text, mentions: mentions)
        context.coordinator.applyingExternal = false
        context.coordinator.parent.handle?.textView = tv
        tv.pasteHandler = { [weak coordinator = context.coordinator] in coordinator?.parent.onPasteAttachments }
        tv.onWidthChange = { [weak coordinator = context.coordinator, weak tv] in
            guard let tv else { return }
            coordinator?.remeasure(tv)
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.documentView = tv
        context.coordinator.lastFocusTick = focusTick
        DispatchQueue.main.async { [weak tv] in tv?.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        handle?.textView = tv
        if tv.string != text, tv.hasMarkedText() {
            // IME composition in progress: keep the external text until it is committed (`textDidChange`).
            context.coordinator.deferExternal(base: tv.string, text: text, mentions: mentions)
        } else if tv.string != text {
            context.coordinator.pending = nil
            // During a view update: the selection change `setContent` causes must not publish state (the async refresh below does).
            context.coordinator.applyingExternal = true
            Self.setContent(tv, text: text, mentions: mentions)
            context.coordinator.applyingExternal = false
            // The field's own undo manager (`undoManager(for:)`): other fields of the window keep their undo history.
            context.coordinator.undo.removeAllActions()
            DispatchQueue.main.async { [weak coordinator = context.coordinator, weak tv] in
                guard let tv else { return }
                coordinator?.syncMentions(tv)
                coordinator?.refreshQuery(tv)
            }
        }
        if context.coordinator.lastFocusTick != focusTick {
            context.coordinator.lastFocusTick = focusTick
            DispatchQueue.main.async { [weak tv] in tv?.window?.makeFirstResponder(tv) }
        }
        context.coordinator.remeasure(tv)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var lastFocusTick = 0
        /// Set while `textView(_:shouldChangeTextIn:)` widens an edit to a whole mention token (re-entrancy guard).
        private var expandingMention = false
        /// Set while text from outside is put into the field (`setContent`): its selection change publishes nothing.
        var applyingExternal = false
        /// The field's own undo stack, so clearing it after an external content change leaves other fields' undo alone.
        let undo = UndoManager()
        init(_ parent: ComposerTextView) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        /// Text set from outside (restored draft) while composing: `base` is what the field held then.
        var pending: (base: String, text: String, mentions: [Mention])?

        func deferExternal(base: String, text: String, mentions: [Mention]) {
            pending = (pending?.base ?? base, text, mentions)
        }

        /// After the composition ended: the external text wins, but whatever was typed since goes first
        /// (external text is then `base` + restored tail, so only the tail is appended).
        private func applyPending(_ tv: NSTextView) {
            guard let p = pending else { return }
            pending = nil
            let current = tv.string
            let baseLen = (p.base as NSString).length, currentLen = (current as NSString).length
            var text = p.text, mentions = p.mentions
            // UTF-16 prefix test, consistent with the NSString offsets below (`String.hasPrefix` compares grapheme clusters).
            if current != p.base, (p.text as NSString).hasPrefix(p.base) {
                text = current + (p.text as NSString).substring(from: baseLen)
                mentions = currentMentions(tv) + p.mentions.filter { $0.pos >= baseLen }.map {
                    Mention(uid: $0.uid, pos: $0.pos + currentLen - baseLen, len: $0.len, isAll: $0.isAll)
                }
            }
            applyingExternal = true
            ComposerTextView.setContent(tv, text: text, mentions: mentions)
            applyingExternal = false
            // The undo stack recorded edits of the replaced text: ⌘Z would apply them to ranges that no longer exist.
            undo.removeAllActions()
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if pending != nil {
                if tv.hasMarkedText() { remeasure(tv); return }
                applyPending(tv)
            }
            sanitizeTokens(tv)
            if parent.text != tv.string { parent.text = tv.string }
            syncMentions(tv)
            refreshQuery(tv)
            remeasure(tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Typing next to a mention must never extend it.
            tv.typingAttributes = ComposerTextView.baseAttributes
            // Content set from outside (possibly inside a view update): the caller refreshes the query afterwards.
            if applyingExternal { return }
            refreshQuery(tv)
        }

        /// A mention is atomic: any edit touching it replaces/deletes the whole token.
        func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // `tv.shouldChangeText(in:)` below asks this delegate again for the expanded range, which still overlaps the
            // token: without this guard it expands and asks again forever (stack overflow on ⌫ next to a mention).
            if expandingMention { return true }
            guard let storage = tv.textStorage, storage.length > 0, !tv.hasMarkedText() else { return true }
            var expanded = range
            var touched = false
            storage.enumerateAttribute(.zaloMention, in: NSRange(location: 0, length: storage.length)) { value, tokenRange, _ in
                guard value != nil else { return }
                let hits = range.length == 0
                    ? range.location > tokenRange.location && range.location < NSMaxRange(tokenRange)
                    : NSIntersectionRange(range, tokenRange).length > 0
                if hits { expanded = NSUnionRange(expanded, tokenRange); touched = true }
            }
            guard touched, expanded.location != NSNotFound else { return true }
            let replacement = NSAttributedString(string: replacementString ?? "", attributes: ComposerTextView.baseAttributes)
            expandingMention = true
            defer { expandingMention = false }
            guard tv.shouldChangeText(in: expanded, replacementString: replacement.string) else { return false }
            storage.replaceCharacters(in: expanded, with: replacement)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: expanded.location + replacement.length, length: 0))
            return false
        }

        /// Drops mention styling from runs that no longer read exactly "@Name".
        private func sanitizeTokens(_ tv: NSTextView) {
            guard let storage = tv.textStorage, storage.length > 0 else { return }
            var broken: [NSRange] = []
            storage.enumerateAttribute(.zaloMention, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let token = value as? MentionToken else { return }
                if (storage.string as NSString).substring(with: range) != token.label { broken.append(range) }
            }
            guard !broken.isEmpty else { return }
            storage.beginEditing()
            for range in broken {
                storage.removeAttribute(.zaloMention, range: range)
                storage.setAttributes(ComposerTextView.baseAttributes, range: range)
            }
            storage.endEditing()
        }

        /// Publishes the current tokens as official-style mentions (UTF-16 offsets).
        func syncMentions(_ tv: NSTextView) {
            let found = currentMentions(tv)
            if parent.mentions != found { parent.mentions = found }
        }

        private func currentMentions(_ tv: NSTextView) -> [Mention] {
            guard let storage = tv.textStorage, storage.length > 0 else { return [] }
            var found: [Mention] = []
            storage.enumerateAttribute(.zaloMention, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let token = value as? MentionToken {
                    found.append(Mention(uid: token.uid, pos: range.location, len: range.length, isAll: token.isAll))
                }
            }
            return found
        }

        /// "@query" ending at the caret: "@" at the start or after whitespace, not inside a token.
        func refreshQuery(_ tv: NSTextView) {
            guard parent.mentionsEnabled else { return }
            var result: MentionQuery?
            let selection = tv.selectedRange()
            if selection.length == 0, let storage = tv.textStorage, selection.location <= storage.length {
                let ns = storage.string as NSString
                var index = selection.location
                let floor = max(0, selection.location - 40)
                while index > floor {
                    let unit = ns.character(at: index - 1)
                    if unit == 0x0A { break }
                    if unit == 0x40 {
                        let at = index - 1
                        let startsWord = at == 0 || CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(ns.character(at: at - 1)) ?? "x")
                        let insideToken = storage.attribute(.zaloMention, at: at, effectiveRange: nil) != nil
                        if startsWord, !insideToken {
                            let range = NSRange(location: at, length: selection.location - at)
                            let typed = ns.substring(with: range).dropFirst()
                            if !typed.hasPrefix(" ") { result = MentionQuery(range: range, text: String(typed)) }
                        }
                        break
                    }
                    index -= 1
                }
            }
            if lastQuery != result {
                lastQuery = result
                parent.onMentionQuery(result)
            }
        }
        private var lastQuery: MentionQuery?

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): if parent.onSuggestionKey(.up) { return true }
            case #selector(NSResponder.moveDown(_:)): if parent.onSuggestionKey(.down) { return true }
            case #selector(NSResponder.insertTab(_:)):
                // Like Return: never confirm a mention under an open IME composition.
                if !textView.hasMarkedText(), parent.onSuggestionKey(.confirm) { return true }
            case #selector(NSResponder.cancelOperation(_:)): if parent.onSuggestionKey(.cancel) { return true }
            case #selector(NSResponder.insertNewline(_:)):
                let mods = NSApp.currentEvent?.modifierFlags ?? []
                if !mods.contains(.shift), !mods.contains(.option), !textView.hasMarkedText(),
                   parent.onSuggestionKey(.confirm) { return true }
            default: break
            }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            if mods.contains(.shift) || mods.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            // Return confirming IME composition never reaches here, but be defensive.
            if textView.hasMarkedText() { return false }
            parent.onSend()
            return true
        }

        func remeasure(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let container = tv.textContainer else { return }
            lm.ensureLayout(for: container)
            let line = ComposerTextView.lineHeight
            let used = lm.usedRect(for: container).height
            let h = min(max(line, ceil(used)), line * ComposerTextView.maxLines)
            if abs(parent.height - h) > 0.5 {
                DispatchQueue.main.async { [weak self] in self?.parent.height = h }
            }
        }
    }

    final class FieldTextView: NSTextView {
        var onWidthChange: (() -> Void)?
        /// Reads the current `onPasteAttachments` (the representable is rebuilt on every update).
        var pasteHandler: (() -> ((PastedAttachments) -> Void)?)?

        /// A plain-text NSTextView disables Paste (so ⌘V never reaches `paste(_:)`) when the pasteboard holds no text type —
        /// exactly the case of a screenshot. Keep it enabled when there is something to attach.
        override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(paste(_:)), (pasteHandler?() ?? nil) != nil,
               ComposerTextView.canPasteAttachments(.general) {
                return true
            }
            return super.validateUserInterfaceItem(item)
        }

        override func paste(_ sender: Any?) {
            if let handler = pasteHandler?() ?? nil, let pasted = ComposerTextView.pastedAttachments(.general) {
                handler(pasted)
                return
            }
            super.paste(sender)
        }

        override func setFrameSize(_ newSize: NSSize) {
            let changed = abs(newSize.width - frame.width) > 0.5
            super.setFrameSize(newSize)
            if changed { DispatchQueue.main.async { [weak self] in self?.onWidthChange?() } }
        }
    }
}

/// Attachments taken from the pasteboard by ⌘V in the composer.
struct PastedAttachments: Identifiable {
    let id = UUID()
    /// Finder photos / videos.
    var media: [URL] = []
    /// Other Finder files.
    var files: [URL] = []
    /// A bitmap from the clipboard (screenshot, "Copy Image"), written to a temporary PNG.
    var clipboardImage: URL? = nil
}

/// Confirmation before pasted attachments are sent, like the official paste preview.
struct PastePreviewSheet: View {
    let items: PastedAttachments
    let name: String
    let send: () -> Void
    let cancel: () -> Void
    /// The first picture, decoded once (downsampled) instead of on every `body` evaluation.
    @State private var preview: NSImage?

    private var summary: String {
        var parts: [String] = []
        let mediaCount = items.media.count + (items.clipboardImage == nil ? 0 : 1)
        if mediaCount > 0 { parts.append("\(mediaCount) ảnh/video") }
        if !items.files.isEmpty { parts.append("\(items.files.count) tệp") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Gửi tới \(name)").font(.headline)
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Text(summary).font(.callout).foregroundStyle(.secondary)
            if !items.files.isEmpty {
                Text(items.files.map(\.lastPathComponent).joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(4).multilineTextAlignment(.center)
            }
            HStack {
                Button("Hủy", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Gửi", action: send).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .task(id: items.id) {
            preview = nil
            if let first = items.clipboardImage ?? items.media.first { preview = await PreviewImage.load(first, maxPixel: 840) }
        }
    }
}
