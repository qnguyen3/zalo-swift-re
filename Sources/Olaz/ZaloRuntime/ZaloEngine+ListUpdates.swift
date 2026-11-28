import Foundation

// Coalescing of the conversation list.
//
// The adapters push the conversation list (state-adapter.js) and its extras (conversations-adapter.js) every time a
// preview, an unread count or a label changes anywhere in the account, often as a pair ~300 ms apart. Each publish
// re-diffs the whole SwiftUI `List` of the sidebar (~75 ms on a large account), which showed as hitches while a chat was
// scrolled and as a 0.6–1.8 s hang when a chat opened (markRead → unread change → list rebuild during the chat's build).
//
// Pushes are therefore staged and published together: at most once per `listUpdateInterval`, not while a chat is being
// scrolled (up to `listUpdateMaxHold`), and not during the short hold after a chat opens. Engine code reads
// `latestConversations` / `latestConversationExtras`; views keep reading the published values.

extension ZaloEngine {
    static let listUpdateInterval: Duration = .milliseconds(400)
    /// A chat scrolled for longer than this still gets the staged list (the sidebar must not go stale indefinitely).
    static let listUpdateMaxHold: Duration = .seconds(3)

    var latestConversations: [ConversationSummary] { pendingConversations ?? conversations }
    var latestConversationExtras: ConversationExtras { pendingExtras ?? conversationExtras }

    func stageConversations(_ list: [ConversationSummary]) {
        guard list != latestConversations else { return }
        // The first list (empty sidebar) is shown at once.
        if conversations.isEmpty, pendingConversations == nil {
            conversations = list
            lastListFlush = .now
            return
        }
        pendingConversations = list
        if pendingListSince == nil { pendingListSince = .now }
        scheduleListFlush()
    }

    func stageConversationExtras(_ next: ConversationExtras) {
        guard next != latestConversationExtras else { return }
        pendingExtras = next
        if pendingListSince == nil { pendingListSince = .now }
        scheduleListFlush()
    }

    /// The open chat is scrolling (`true`) or came to rest (`false`).
    func setListUpdatesHeldByScroll(_ held: Bool) {
        guard listHeldByScroll != held else { return }
        listHeldByScroll = held
        scheduleListFlush()
    }

    /// Keeps staged list updates back for `duration` (a chat is being built).
    func holdListUpdates(for duration: Duration) {
        let until = ContinuousClock.now + duration
        if listHoldUntil.map({ $0 < until }) ?? true { listHoldUntil = until }
        scheduleListFlush()
    }

    /// Publishes whatever is staged now.
    func flushListUpdates() {
        listFlushTask?.cancel()
        listFlushTask = nil
        guard pendingConversations != nil || pendingExtras != nil else { return }
        lastListFlush = .now
        pendingListSince = nil
        if let list = pendingConversations {
            pendingConversations = nil
            if list != conversations { conversations = list }
        }
        if let extras = pendingExtras {
            pendingExtras = nil
            if extras != conversationExtras { conversationExtras = extras }
        }
    }

    func discardPendingListUpdates() {
        listFlushTask?.cancel()
        listFlushTask = nil
        pendingConversations = nil
        pendingExtras = nil
        pendingListSince = nil
        listHoldUntil = nil
        listHeldByScroll = false
    }

    private func scheduleListFlush() {
        guard pendingConversations != nil || pendingExtras != nil else { return }
        let now = ContinuousClock.now
        var due = lastListFlush.map { $0 + Self.listUpdateInterval } ?? now
        if let hold = listHoldUntil, hold > due { due = hold }
        if listHeldByScroll { due = max(due, (pendingListSince ?? now) + Self.listUpdateMaxHold) }
        if due <= now {
            flushListUpdates()
            return
        }
        listFlushTask?.cancel()
        listFlushTask = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.listFlushTask = nil
            self.scheduleListFlush() // a hold or a scroll may have moved the time on
        }
    }
}
