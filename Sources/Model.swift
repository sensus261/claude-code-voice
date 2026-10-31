import Foundation

/// A summary waiting for the user's OK (shown as an alert).
struct SummaryAsk: Identifiable {
    let id = UUID()
    let session: Session
    let mode: ReadMode
    let title: String
    let message: String
    let canRun: Bool
    let onConfirm: () -> Void
    let onDone: (Bool) -> Void
}

/// Wires the reply store, summarizer and speaker: heard markers, auto-read, headers,
/// and the confirmation before any Claude call. Claude is only called on explicit request.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store = Store()
    let speaker = Speaker()
    let summarizer = Summarizer()

    @Published var ask: SummaryAsk?

    /// Replies shorter than this have no summary option: it would gain nothing.
    static let summaryMinWords = 70

    private var lastSid: String?
    private var request = 0   // the newest explicit play request wins

    private init() {
        Voices.migrate()
        VoiceCatalog.shared.refresh()
        speaker.onItemStart = { [weak self] sid in
            self?.store.markHeard(sid)
            self?.lastSid = sid
        }
        store.onNewReply = { [weak self] s in self?.autoRead(s) }
    }

    // MARK: playing

    /// Play a reply. Summary modes must already be cached (see ensureSummary).
    func play(_ s: Session, mode: ReadMode = .full, from start: Int = 0) {
        request += 1
        let r = request
        guard mode != .full else {
            speaker.play([fullItem(s)], from: start)
            return
        }
        Task {
            guard let text = await summarizer.summary(for: s, mode), r == request else { return }
            speaker.play([summaryItem(s, text, mode)], from: start)
        }
    }

    func queue(_ s: Session) { speaker.enqueue(withHeader(fullItem(s), s)) }

    /// Every unheard reply, full text, top to bottom.
    func playAllNew() {
        let new = store.visible.filter(\.isNew)
        guard !new.isEmpty else { return }
        request += 1
        speaker.play(new.map { withHeader(fullItem($0), $0) })
    }

    /// Auto-read always uses the full reply: no Claude calls without a click.
    private func autoRead(_ s: Session) {
        let d = UserDefaults.standard
        guard !s.hidden, d.bool(forKey: "autoAll") || AutoRead.contains(d.string(forKey: "autoSids") ?? "", s.id) else { return }
        var it = fullItem(s)
        if speaker.state != .idle || lastSid != s.id { it = withHeader(it, s) }
        speaker.enqueue(it)
    }

    // MARK: summaries (always confirmed first)

    /// Run `then` once the summary exists. If it is not cached, ask the user first.
    func ensureSummary(_ s: Session, _ mode: ReadMode, onConfirm: @escaping () -> Void = {},
                       then: @escaping (Bool) -> Void) {
        guard mode != .full else { then(true); return }
        if summarizer.cached(s, mode) != nil { onConfirm(); then(true); return }
        let lang = Languages.selected
        switch mode {
        case .quick:
            ask = SummaryAsk(
                session: s, mode: mode, title: "Create a low-cost summary?",
                message: "Claude Haiku 5.5 turns this \(s.words)-word reply into a short summary in \(lang.name). "
                    + "It uses your Claude subscription, takes about 5 seconds and very little usage. "
                    + "It sees only this reply, not the rest of the conversation.",
                canRun: true, onConfirm: onConfirm, onDone: then)
        case .session:
            guard let info = SessionInfo.of(s) else {
                ask = SummaryAsk(session: s, mode: mode, title: "Session summary unavailable",
                                 message: "This session's log could not be found.", canRun: false,
                                 onConfirm: {}, onDone: then)
                return
            }
            let k = max(1, info.contextTokens / 1000)
            let model = info.model.map(Self.modelName) ?? "its model"
            let idle = ago(info.lastActivity, Date())
            var msg = "The \(s.displayProject) session itself (\(model)) writes the summary in \(lang.name), "
                + "with the whole conversation as context. It uses your Claude subscription and takes "
                + "about 20 seconds. "
            if info.cacheLikelyWarm {
                msg += "It re-reads about \(k)k tokens of conversation from cache, roughly like sending "
                    + "one short message in that session (last activity: \(idle == "now" ? "just now" : idle + " ago"))."
            } else {
                msg += "Its cache has probably expired (last activity \(idle) ago), so all \(k)k tokens are "
                    + "processed again: several times the usage of a normal message."
            }
            if info.lastActivity.timeIntervalSince(s.modified) > 10 {
                msg += "\n\nThe session seems to be working right now; the summary may describe its newest progress."
            }
            ask = SummaryAsk(session: s, mode: mode, title: "Create a session summary?", message: msg,
                             canRun: true, onConfirm: onConfirm, onDone: then)
        case .full:
            break
        }
    }

    /// Called by the alert's Summarize button.
    func confirm(_ a: SummaryAsk) {
        ask = nil
        a.onConfirm()
        Task {
            let ok = await summarizer.summary(for: a.session, a.mode) != nil
            a.onDone(ok)
        }
    }

    func cancel(_ a: SummaryAsk) {
        ask = nil
        a.onDone(false)
    }

    // MARK: items

    /// The full reply, read by the voice for its language when that differs from the main voice.
    func fullItem(_ s: Session) -> PlayItem {
        PlayItem(sid: s.id, lines: ReplyDoc.of(s).lines, voiceID: Voices.replyVoiceID(for: s.text))
    }

    private func summaryItem(_ s: Session, _ text: String, _ mode: ReadMode) -> PlayItem {
        PlayItem(sid: s.id, lines: Sentences.split(text), mode: mode, voiceID: Voices.summaryVoiceID())
    }

    private func withHeader(_ it: PlayItem, _ s: Session) -> PlayItem {
        let project = s.displayProject.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let line = "From \(project)." + (s.title.isEmpty ? "" : " \(s.title).")
        return PlayItem(sid: it.sid, lines: [line] + it.lines, mode: it.mode, voiceID: it.voiceID,
                        headerLines: it.headerLines + 1)
    }

    static func modelName(_ id: String) -> String {
        // "claude-opus-5-5" -> "Opus 5.5"
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " \(version)")
    }
}

/// Per-session auto-read flags, stored as a comma-separated @AppStorage string.
enum AutoRead {
    static func contains(_ list: String, _ sid: String) -> Bool {
        list.split(separator: ",").contains { $0 == sid }
    }

    static func toggled(_ list: String, _ sid: String) -> String {
        var ids = list.split(separator: ",").map(String.init)
        if let i = ids.firstIndex(of: sid) { ids.remove(at: i) } else { ids.append(sid) }
        return ids.joined(separator: ",")
    }
}
