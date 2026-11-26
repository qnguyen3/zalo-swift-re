import SwiftUI

// Rows of the conversation list column: the two-line row, the pinned avatar strip and the swipe actions.

/// Conversation avatar: remote photo, tinted cloud for "Cloud của tôi", and a small people badge on groups.
struct ConversationListAvatar: View {
    let conversation: ZaloEngine.ConversationSummary
    let size: CGFloat
    var isSelf = false

    var body: some View {
        Group {
            if isSelf {
                Image(systemName: "cloud.fill")
                    .font(.system(size: size * 0.43, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(.tint))
            } else {
                RemoteAvatar(url: conversation.avatar, name: conversation.displayName, size: size)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if conversation.isGroup && !isSelf {
                let badge = max(15, size * 0.34)
                Image(systemName: "person.2.fill")
                    .font(.system(size: badge * 0.46, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: badge, height: badge)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
                    .offset(x: 2, y: 2)
            }
        }
    }
}

/// One line of the conversation list: name and time over a two-line preview with the unread capsule.
struct ConversationListRow: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.backgroundProminence) private var prominence
    let conversation: ZaloEngine.ConversationSummary
    var label: ConversationExtras.Label?
    /// The pin glyph; off in the inbox, where pins have the strip above.
    var showsPin = false
    /// Manual "chưa đọc" mark (official unread mark): a dot without a count.
    var unreadMark = false
    var isStranger = false
    var isSelf = false
    /// Pinned rows under the strip: smaller avatar and a one-line preview.
    var compact = false

    private var unread: Bool { conversation.unread > 0 }

    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: 10) {
            ConversationListAvatar(conversation: conversation, size: compact ? 36 : 44, isSelf: isSelf)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if showsPin {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                            .accessibilityLabel("Đã ghim")
                    }
                    Text(isSelf ? "Cloud của tôi" : conversation.displayName)
                        .font(.system(size: 13.5, weight: unread ? .semibold : .medium))
                        .lineLimit(1)
                    if let label { LabelTag(label: label) }
                    if isStranger && !isSelf { StrangerBadge() }
                    MutedBell(conversationId: conversation.id, size: 9.5)
                    Spacer(minLength: 4)
                    if let date = conversation.preview?.date {
                        Text(ConversationListTime.string(for: date))
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    previewLine
                        .font(.system(size: 12.5))
                        .lineLimit(compact ? 1 : 2, reservesSpace: !compact)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    if unread {
                        ConversationUnreadBadge(count: conversation.unread, muted: engine.isConversationMuted(conversation.id))
                    } else if unreadMark {
                        ConversationUnreadDot().padding(.top, 4)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var previewLine: some View {
        if let who = engine.typing[conversation.id] {
            Text("\(who) đang soạn tin…")
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
        } else {
            Text(subtitle).foregroundStyle(unread ? .primary : .secondary)
        }
    }

    private var subtitle: String {
        if let p = conversation.preview, !p.text.isEmpty { return (p.fromMe ? "Bạn: " : "") + p.text }
        if conversation.isGroup, conversation.members > 0 { return "\(conversation.members) thành viên" }
        if isSelf { return "Lưu trữ và truy cập nhanh những nội dung quan trọng" }
        return conversation.isGroup ? "Nhóm" : (isStranger ? "Chưa là bạn" : "Bạn bè")
    }
}

// MARK: - Pinned strip

/// Every pinned chat as a small avatar, in pin order (⌘1…⌘9 follow it), and the button that lists them all as rows.
/// Pins with unread messages also show as rows under the strip (`ConversationListColumn`).
struct ConversationListPinStrip: View {
    let pins: [ZaloEngine.ConversationSummary]
    @Binding var expanded: Bool
    @Binding var showLabelManager: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pin.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(pins.enumerated()), id: \.element.id) { index, conversation in
                        ConversationListPinChip(conversation: conversation, index: index, showLabelManager: $showLabelManager)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.never)
            Button { withAnimation(.smooth(duration: 0.2)) { expanded.toggle() } } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(expanded ? "Thu gọn về dải avatar" : "Hiện mọi hội thoại ghim thành dòng")
            .accessibilityLabel(expanded ? "Thu gọn hội thoại ghim" : "Hiện mọi hội thoại ghim")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Đã ghim, \(pins.count) cuộc trò chuyện")
    }
}

/// One pinned chat on the strip: avatar with its unread count; the tooltip names it and shows its last message.
struct ConversationListPinChip: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell
    let conversation: ZaloEngine.ConversationSummary
    let index: Int
    @Binding var showLabelManager: Bool

    private var isSelf: Bool { conversation.id == engine.selfConversationId }
    private var selected: Bool { shell.selection == conversation.id }
    private var name: String { isSelf ? "Cloud của tôi" : conversation.displayName }

    var body: some View {
        Button { shell.selection = conversation.id } label: {
            ConversationListAvatar(conversation: conversation, size: 32, isSelf: isSelf)
                .overlay { if selected { Circle().strokeBorder(.tint, lineWidth: 2).padding(-3) } }
                .overlay(alignment: .topTrailing) {
                    if conversation.unread > 0 {
                        ConversationUnreadBadge(count: conversation.unread, muted: engine.isConversationMuted(conversation.id))
                            .scaleEffect(0.85)
                            .offset(x: 8, y: -5)
                    } else if engine.conversationActions.hasUnreadMark(conversation.id) {
                        ConversationUnreadDot().offset(x: 2, y: -1)
                    }
                }
                .padding(.trailing, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(conversation.unread > 0 ? "\(name), \(conversation.unread) tin chưa đọc" : name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu { ConversationActionsMenu(conversationId: conversation.id, preset: .thread, showLabelManager: $showLabelManager) }
    }

    private var tooltip: String {
        var lines = [index < 9 ? "\(name) (⌘\(index + 1))" : name]
        if let p = conversation.preview, !p.text.isEmpty {
            let text = (p.fromMe ? "Bạn: " : "") + p.text
            lines.append(text.count > 80 ? String(text.prefix(80)) + "…" : text)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Swipe actions

/// Leading "Ghim" / "Bỏ ghim" and trailing "Đã đọc" / "Chưa đọc", offered exactly when the context menu offers them.
struct ConversationListSwipeActions: ViewModifier {
    @Environment(ZaloEngine.self) private var engine
    /// Swipe buttons take a plain color, not the root `.tint` style.
    @AppStorage(OlazPrefs.accent) private var accent = OlazAccent.blue
    let conversation: ZaloEngine.ConversationSummary

    func body(content: Content) -> some View {
        let state = engine.conversationActions
        let plan = ConversationMenuPlan.make(id: conversation.id, preset: .thread, state: state, unread: conversation.unread,
                                             muted: engine.isConversationMuted(conversation.id))
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if state.loaded {
                    switch plan.pin {
                    case .pin: Button("Ghim", systemImage: "pin.fill") { engine.pinConversation(conversation.id) }.tint(.orange)
                    case .unpin: Button("Bỏ ghim", systemImage: "pin.slash.fill") { engine.unpinConversation(conversation.id) }.tint(.orange)
                    case nil: EmptyView()
                    }
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if state.loaded {
                    switch plan.read {
                    case .markRead: Button("Đã đọc", systemImage: "envelope.open.fill") { engine.markConversationRead(conversation.id) }.tint(accent.color)
                    case .markUnread: Button("Chưa đọc", systemImage: "envelope.badge.fill") { engine.markConversationUnread(conversation.id) }.tint(accent.color)
                    case nil: EmptyView()
                    }
                }
            }
    }
}
