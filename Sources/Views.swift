import AppKit
import AVFoundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var speaker: Speaker
    @EnvironmentObject private var model: AppModel
    @AppStorage("pinned") private var pinned = true
    @State private var showSettings = false
    @State private var selected: String?

    var body: some View {
        VStack(spacing: 0) {
            Reader(selected: $selected)
            Divider()
            SessionList(selected: $selected)
        }
        .frame(minWidth: 400, minHeight: 480)
        .background(WindowAccessor(pinned: pinned))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { pinned.toggle() } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                }
                .help(pinned ? "Floating on top. Click to unpin." : "Keep this window on top of others")

                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .help("Voices, speed, summary language, auto-read")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsView() }
            }
        }
        // Follow playback into the next reply only if the user was watching the playing one.
        .onChange(of: speaker.currentSid) { old, new in
            if let new, selected == nil || selected == old { selected = new }
        }
        .onAppear { if selected == nil { selected = store.visible.first?.id } }
        .alert(model.ask?.title ?? "", isPresented: Binding(
            get: { model.ask != nil }, set: { if !$0 { model.ask = nil } }), presenting: model.ask) { a in
            if a.canRun { Button("Summarize") { model.confirm(a) } }
            Button(a.canRun ? "Cancel" : "OK", role: .cancel) { model.cancel(a) }
        } message: { a in
            Text(a.message)
        }
    }
}

// MARK: - Reader (selected session) + transport

struct Reader: View {
    @Binding var selected: String?
    @EnvironmentObject private var speaker: Speaker
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var summarizer: Summarizer
    @State private var mode: ReadMode = .full
    @State private var showProgress = false

    private var session: Session? { store.sessions.first { $0.id == selected } }

    /// The speaker's playlist item for the selected session, if loaded in the shown mode.
    private var loadedItem: Int? {
        guard let s = session, let i = speaker.displayItem,
              speaker.items[i].sid == s.id, speaker.items[i].mode == mode else { return nil }
        return i
    }

    /// Mode of the selected session's playback, when it is the one in the player.
    private var playingMode: ReadMode? {
        guard let s = session, let i = speaker.displayItem, speaker.items[i].sid == s.id else { return nil }
        return speaker.items[i].mode
    }

    /// Position of the spoken line within the loaded item (skipping a "From <project>" header).
    private var localIndex: Int? {
        guard let item = loadedItem, speaker.state != .idle,
              let start = speaker.lines.firstIndex(where: { $0.item == item }) else { return nil }
        let i = speaker.index - start - speaker.items[item].headerLines
        return i >= 0 ? i : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = session {
                header(s)
                content(s)
                progressSection(s)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Select a session below").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 170)
            }
            status
            transport
        }
        .padding(12)
        .onChange(of: selected) { _, _ in mode = playingMode ?? .full }
        .onChange(of: playingMode) { _, m in if let m { mode = m } }
    }

    // MARK: header + tabs

    private func header(_ s: Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(s.displayProject).font(.headline)
                if !s.title.isEmpty {
                    Text(s.title).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(ago(s.modified, ctx.date)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if s.words >= AppModel.summaryMinWords {
                Picker("", selection: Binding(get: { mode }, set: { setMode($0, s) })) {
                    Text("Full · \(s.words)w").tag(ReadMode.full)
                    Text("Summary (low cost)").tag(ReadMode.quick)
                    Text("Summary (from Claude Code)").tag(ReadMode.session)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .help("Low cost: Haiku summarizes after you confirm. From Claude Code: run /summarize-for-voice in that session")
            }
        }
    }

    private func setMode(_ new: ReadMode, _ s: Session) {
        let playingThis = speaker.currentSid == s.id
        guard new != .full else {
            mode = .full
            if playingThis { AppModel.shared.play(s) }
            return
        }
        AppModel.shared.ensureSummary(s, new, onConfirm: { mode = new }) { ok in
            if ok {
                mode = new
                if playingThis { AppModel.shared.play(s, mode: new) }
            } else if mode == new, summarizer.cached(s, new) == nil {
                mode = .full
            }
        }
    }

    // MARK: content

    @ViewBuilder private func content(_ s: Session) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if mode == .full {
                        fullText(s)
                    } else if let text = summarizer.cached(s, mode) {
                        summaryText(s, text)
                    } else if summarizer.isWorking(s.id, mode) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Summarizing…").foregroundStyle(.secondary)
                        }
                        .padding(8)
                    } else if mode == .session {
                        Text("Run /summarize-for-voice in this Claude Code session. The summary shows up here and plays on its own.")
                            .foregroundStyle(.secondary).padding(8)
                    } else {
                        Button("Create summary…") { setMode(mode, s) }.padding(8)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 160, idealHeight: 230, maxHeight: 320)
            .onChange(of: speaker.index) { _, _ in
                guard let i = localIndex else { return }
                let target: Int = mode == .full ? (ReplyDoc.of(s).spoken[safe: i]?.block ?? 0) : i
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    /// The reply rendered from markdown, like Claude Code shows it.
    @ViewBuilder private func fullText(_ s: Session) -> some View {
        let doc = ReplyDoc.of(s)
        let current = localIndex.flatMap { doc.spoken[safe: $0] }
        ForEach(doc.blocks) { b in
            BlockView(block: b, current: current?.block == b.id ? current : nil)
                .id(b.id)
                .onTapGesture { play(s, doc, fromBlock: b.id) }
                .help("Read from here")
        }
    }

    private func play(_ s: Session, _ doc: ReplyDoc, fromBlock b: Int) {
        guard let li = doc.spoken.firstIndex(where: { $0.block >= b }) else { return }
        if let item = loadedItem, let start = speaker.lines.firstIndex(where: { $0.item == item }) {
            speaker.speak(at: start + speaker.items[item].headerLines + li)
        } else {
            AppModel.shared.play(s, from: li)
        }
    }

    @ViewBuilder private func summaryText(_ s: Session, _ text: String) -> some View {
        let lines = Sentences.split(text)
        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
            let current = localIndex == i
            Text(current ? highlighted(line, speaker.word) : AttributedString(line))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(current ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture {
                    if let item = loadedItem, let start = speaker.lines.firstIndex(where: { $0.item == item }) {
                        speaker.speak(at: start + speaker.items[item].headerLines + i)
                    } else {
                        AppModel.shared.play(s, mode: mode, from: i)
                    }
                }
                .help("Read from here")
                .id(i)
        }
        Text(summaryCaption(s))
            .font(.caption2).foregroundStyle(.tertiary)
            .padding(.horizontal, 6).padding(.top, 4)
    }

    private func summaryCaption(_ s: Session) -> String {
        if mode == .quick { return "Summary by Claude Haiku 5.5 · \(Languages.selected.name) · cached" }
        return "Summary written by the Claude Code session itself · cached"
    }

    /// Claude's short messages between tool calls (recorded while "Read progress" is on).
    @ViewBuilder private func progressSection(_ s: Session) -> some View {
        let notes = store.progress[s.id] ?? []
        if !notes.isEmpty {
            DisclosureGroup(isExpanded: $showProgress) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(notes) { n in
                            Text(n.text)
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 90)
            } label: {
                Label("Progress · \(notes.count)", systemImage: "list.bullet")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func highlighted(_ s: String, _ r: NSRange?) -> AttributedString {
        var a = AttributedString(s)
        if let r, let sr = Range(r, in: s), let ar = Range(sr, in: a) {
            a[ar].backgroundColor = Color.accentColor.opacity(0.35)
        }
        return a
    }

    // MARK: status + transport

    @ViewBuilder private var status: some View {
        if !summarizer.working.isEmpty {
            let names = summarizer.working.compactMap { key in
                store.sessions.first { $0.id == key.split(separator: "|").first.map(String.init) }?.displayProject
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Summarizing \(names.isEmpty ? "reply" : names.joined(separator: ", "))…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let err = speaker.engineError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(err).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button { speaker.engineError = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).font(.caption)
            }
        } else if let err = summarizer.lastError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Summary failed: \(err)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button { summarizer.clearError() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }

    private var transport: some View {
        let nothing = speaker.lines.isEmpty
        return HStack(spacing: 14) {
            Button { speaker.back() } label: { Image(systemName: "backward.fill") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous sentence (←)")
                .disabled(nothing)
            Button { playPause() } label: {
                Image(systemName: speaker.state == .playing ? "pause.fill" : "play.fill")
                    .font(.title2).frame(width: 26)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause (space)")
            .disabled(nothing && session == nil)
            Button { speaker.next() } label: { Image(systemName: "forward.fill") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next sentence (→)")
                .disabled(nothing)
            Button { speaker.restart() } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Read the playing reply from the beginning")
                .disabled(nothing)
            Button { speaker.skip() } label: { Image(systemName: "forward.end.fill") }
                .help("Skip to the next reply")
                .disabled(speaker.items.count < 2)
            Button { speaker.stop() } label: { Image(systemName: "stop.fill") }
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop (⌘.)")
                .disabled(speaker.state == .idle)
            Spacer()
            if let sid = speaker.currentSid, sid != selected {
                Button {
                    selected = sid
                } label: {
                    Label("Now: \(store.sessions.first { $0.id == sid }?.displayProject ?? "reply")",
                          systemImage: "waveform")
                        .font(.caption).lineLimit(1)
                }
                .help("Show the reply that is playing")
            }
            if !nothing {
                Text("\(min(speaker.index + 1, speaker.lines.count))/\(speaker.lines.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
    }

    /// Pause/resume what is playing; otherwise play what the user is looking at.
    private func playPause() {
        if speaker.state != .idle { speaker.togglePause(); return }
        guard let s = session else { speaker.togglePause(); return }
        if loadedItem != nil, speaker.lines.indices.contains(speaker.index) {
            speaker.togglePause()                 // resume after stop
        } else if mode == .full || summarizer.cached(s, mode) != nil {
            AppModel.shared.play(s, mode: mode)
        }
    }
}

/// One markdown block, styled like Claude Code's output, with the spoken sentence highlighted.
struct BlockView: View {
    let block: ReplyDoc.Block
    let current: ReplyDoc.Spoken?

    var body: some View {
        body(for: block.kind)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2).padding(.horizontal, 6)
            .background(current != nil ? Color.accentColor.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
    }

    @ViewBuilder private func body(for kind: ReplyDoc.Kind) -> some View {
        switch kind {
        case .heading(let level):
            Text(inline(block.markdown, range: current?.range))
                .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
        case .paragraph:
            Text(inline(block.markdown, range: current?.range))
        case .bullet(let marker, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                Text(inline(block.markdown, range: current?.range))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote:
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.5)).frame(width: 3)
                Text(inline(block.markdown, range: current?.range)).foregroundStyle(.secondary)
            }
        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.markdown)
                    .font(.system(.callout, design: .monospaced))
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        case .table:
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(Array(block.rows.enumerated()), id: \.offset) { r, cells in
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell, range: nil))
                                .font(r == 0 ? .callout.bold() : .callout)
                        }
                    }
                    .background(current?.row == r ? Color.accentColor.opacity(0.18) : .clear)
                    if r == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func inline(_ md: String, range: NSRange?) -> AttributedString {
        var a = (try? AttributedString(
            markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(md)
        if let range {
            let plain = String(a.characters)
            if let sr = Range(range, in: plain), let ar = Range(sr, in: a) {
                a[ar].backgroundColor = Color.accentColor.opacity(0.3)
            }
        }
        return a
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Sessions

struct SessionList: View {
    @Binding var selected: String?
    @EnvironmentObject private var store: Store
    @AppStorage("autoAll") private var autoAll = false
    @AppStorage("autoSids") private var autoSids = ""
    @State private var showHidden = false

    var body: some View {
        let shown = showHidden ? store.sessions : store.visible
        let newCount = store.visible.filter(\.isNew).count
        let hiddenCount = store.hiddenCount
        VStack(spacing: 0) {
            HStack {
                Text("Sessions").font(.headline)
                if hiddenCount > 0 {
                    Button { showHidden.toggle() } label: {
                        Label("\(hiddenCount) hidden", systemImage: showHidden ? "eye" : "eye.slash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(showHidden ? Color.accentColor : Color.secondary)
                    .help(showHidden ? "Stop showing hidden sessions" : "Show hidden sessions")
                }
                Spacer()
                Button("Play new (\(newCount))") {
                    selected = store.visible.first(where: \.isNew)?.id
                    AppModel.shared.playAllNew()
                }
                .disabled(newCount == 0)
                .help("Play every unheard reply, top to bottom")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            if shown.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    if store.sessions.isEmpty {
                        Text("No replies yet").foregroundStyle(.secondary)
                        Text("They appear here when any Claude Code session finishes a turn.")
                            .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    } else {
                        Text("All sessions are hidden").foregroundStyle(.secondary)
                        Text("They come back when they reply again, or click \"\(hiddenCount) hidden\".")
                            .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    }
                    Spacer()
                }
                .padding()
            } else {
                List(shown, selection: $selected) { s in
                    SessionRow(session: s) {
                        selected = s.id
                        AppModel.shared.play(s)
                    }
                    .opacity(s.hidden ? 0.55 : 1)
                    .swipeActions {
                        if s.hidden {
                            Button("Unhide") { store.unhide(s.id) }.tint(.accentColor)
                        } else {
                            Button("Hide") { hide(s, always: false) }.tint(.gray)
                        }
                    }
                }
                .listStyle(.inset)
                .onDeleteCommand {   // ⌫ hides the selected session until it replies again
                    if let s = store.sessions.first(where: { $0.id == selected }), !s.hidden { hide(s, always: false) }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let s = store.sessions.first(where: { $0.id == id }) {
                        menu(s)
                    }
                } primaryAction: { ids in   // double-click / Return
                    if let id = ids.first, let s = store.sessions.first(where: { $0.id == id }) {
                        selected = id
                        AppModel.shared.play(s)
                    }
                }
            }
        }
        .onChange(of: hiddenCount) { _, n in if n == 0 { showHidden = false } }
    }

    /// Hide a session; if it was selected, select its neighbour in the list.
    private func hide(_ s: Session, always: Bool) {
        if selected == s.id, !showHidden {
            let vis = store.visible
            if let i = vis.firstIndex(where: { $0.id == s.id }) {
                selected = (vis[safe: i + 1] ?? vis[safe: i - 1])?.id
            }
        }
        store.hide(s, always: always)
    }

    @ViewBuilder private func menu(_ s: Session) -> some View {
        let auto = autoAll || AutoRead.contains(autoSids, s.id)
        Button("Play") { selected = s.id; AppModel.shared.play(s) }
        if s.words >= AppModel.summaryMinWords {
            Button("Play Summary (low cost)…") { playSummary(s, .quick) }
            Button("Play Summary from Claude Code") { playSummary(s, .session) }
        }
        Button("Add to Queue") { AppModel.shared.queue(s) }
        Divider()
        Button(auto ? "Stop Auto-Reading" : "Auto-Read New Replies") {
            autoSids = AutoRead.toggled(autoSids, s.id)
        }
        .disabled(autoAll)
        Button("Mark as Heard") { store.markHeard(s.id) }
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Summarizer.source(for: s), forType: .string)
        }
        Divider()
        if s.hidden {
            Button("Unhide") { store.unhide(s.id) }
            if (store.hiddenAt[s.id] ?? -1) >= 0 {
                Button("Always Hide") { hide(s, always: true) }
            }
        } else {
            Button("Hide Until Next Reply") { hide(s, always: false) }
            Button("Always Hide") { hide(s, always: true) }
        }
    }

    private func playSummary(_ s: Session, _ mode: ReadMode) {
        AppModel.shared.ensureSummary(s, mode, onConfirm: { selected = s.id }) { ok in
            if ok { AppModel.shared.play(s, mode: mode) }
        }
    }
}

struct SessionRow: View {
    let session: Session
    let play: () -> Void
    @EnvironmentObject private var speaker: Speaker
    @EnvironmentObject private var summarizer: Summarizer
    @EnvironmentObject private var store: Store
    @AppStorage("autoAll") private var autoAll = false
    @AppStorage("autoSids") private var autoSids = ""

    private var auto: Bool { autoAll || AutoRead.contains(autoSids, session.id) }
    private var playing: Bool { speaker.currentSid == session.id }
    private var summarizing: Bool { summarizer.working.contains { $0.hasPrefix(session.id + "|") } }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isNew ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)
                .help(session.isNew ? "Not heard yet" : "")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.displayProject).fontWeight(.semibold).lineLimit(1)
                    if session.hidden {
                        Image(systemName: "eye.slash").font(.caption).foregroundStyle(.secondary)
                            .help((store.hiddenAt[session.id] ?? -1) < 0
                                  ? "Always hidden" : "Hidden until it replies again")
                    }
                    if playing {
                        Image(systemName: "waveform")
                            .foregroundStyle(.tint)
                            .symbolEffect(.variableColor.iterative, isActive: speaker.state == .playing)
                    }
                    if summarizing { ProgressView().controlSize(.mini) }
                }
                Text(session.displayTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text("\(ago(session.modified, ctx.date)) · \(session.words)w"
                     + (session.context.map { " · \(tokenCount($0)) ctx" } ?? ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help(session.context.map { "Context when this reply was written: \($0.formatted()) tokens" } ?? "")
            }
            Button { autoSids = AutoRead.toggled(autoSids, session.id) } label: {
                Image(systemName: auto ? "speaker.wave.2.fill" : "speaker.slash")
                    .foregroundStyle(auto ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .disabled(autoAll)
            .help(autoAll ? "Auto-read is on for every session (Settings)"
                  : auto ? "Auto-reading new replies (full text). Click to stop."
                  : "Auto-read new replies from this session (full text)")
            Button(action: play) {
                Image(systemName: "play.circle.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Play this reply (full text)")
        }
        .padding(.vertical, 3)
    }
}

func ago(_ d: Date, _ now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(d)))
    switch s {
    case ..<60: return "now"
    case ..<3600: return "\(s / 60)m"
    case ..<86400: return "\(s / 3600)h"
    default: return "\(s / 86400)d"
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("voiceID") private var voiceID = ""
    @AppStorage("rate") private var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage("autoAll") private var autoAll = false
    @AppStorage("readProgress") private var readProgress = false
    @AppStorage("allLanguages") private var allLanguages = false
    @AppStorage("matchLanguage") private var matchLanguage = true
    @AppStorage("summaryLang") private var summaryLang = "ro-RO"
    @ObservedObject private var catalog = VoiceCatalog.shared

    private var voices: [VoiceOption] {
        let list = Voices.options(language: allLanguages ? nil : "en")
        if !voiceID.isEmpty, !list.contains(where: { $0.id == voiceID }) {
            return [Voices.option(id: voiceID)] + list
        }
        return list
    }

    var body: some View {
        Form {
            Section("Playback") {
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $rate, in: 0.3...0.7)
                        Text(String(format: "%.1f×", rate / Double(AVSpeechUtteranceDefaultSpeechRate)))
                            .monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                }
                Toggle("Auto-read new replies from every session (full text)", isOn: $autoAll)
                Toggle("Also read progress updates", isOn: $readProgress)
                    .onChange(of: readProgress) { _, _ in AppModel.shared.syncProgressFlag() }
                Text("The short messages Claude writes between tasks are read as they appear, for the sessions that are auto-read, and recorded under each reply. Needs the PostToolUse hook (scripts/install-integration.sh). Updates not yet spoken when the final reply arrives are skipped.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Test Voice") { AppModel.shared.speaker.test() }
            }
            Section("Full text") {
                Picker("Voice", selection: $voiceID) {
                    ForEach(voices) { v in Text("\(v.label)  \(v.language)").tag(v.id) }
                }
                Toggle("Show all languages", isOn: $allLanguages)
                Toggle("Read each reply in its own language", isOn: $matchLanguage)
                    .help("A reply written in another language is read by that language's voice")
            }
            Section("Summaries") {
                Picker("Language", selection: $summaryLang) {
                    ForEach(Languages.all, id: \.code) { l in Text(l.native).tag(l.code) }
                }
                LanguageVoicePicker(lang: summaryLang).id(summaryLang)
                Text("Low cost: Claude Haiku 5.5 reads only the reply, made only when you ask and confirm. From Claude Code: run /summarize-for-voice in the session; it writes the summary itself (about one short message of usage) and this app reads it. Auto-read never calls Claude.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("More voices") {
                LabeledContent("Piper (offline)") {
                    Text(catalog.python[.piper] == nil ? "not installed"
                         : catalog.piper.isEmpty ? "no voices downloaded"
                         : "\(catalog.piper.count) voice\(catalog.piper.count == 1 ? "" : "s")")
                }
                LabeledContent("Microsoft neural (online)") {
                    Text(catalog.python[.edge] == nil ? "not installed"
                         : catalog.edge.isEmpty ? "loading voices…" : "\(catalog.edge.count) voices")
                }
                Text("Install both with scripts/install-voices.sh from the Claude Voice folder. Piper runs on this Mac. Microsoft voices send each sentence to Microsoft's online speech service, so they are never chosen automatically.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Piper Folder") {
                        try? FileManager.default.createDirectory(at: VoiceCatalog.piperDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(VoiceCatalog.piperDir)
                    }
                    Spacer()
                    if catalog.scanning { ProgressView().controlSize(.small) }
                    Button("Rescan") {
                        ExternalTTS.shared.clearFailures()
                        catalog.refresh()
                    }
                    .disabled(catalog.scanning)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 680)
        .onAppear {
            if voiceID.isEmpty { voiceID = Voices.mainID }
        }
    }
}

/// The voice for one language: used for summaries and for replies written in it.
struct LanguageVoicePicker: View {
    let lang: String
    @AppStorage private var choice: String
    @AppStorage("matchLanguage") private var matchLanguage = true
    @ObservedObject private var catalog = VoiceCatalog.shared

    init(lang: String) {
        self.lang = lang
        _choice = AppStorage(wrappedValue: "", "voice.\(lang.prefix(2))")
    }

    var body: some View {
        let prefix = String(lang.prefix(2))
        let options = Voices.options(language: prefix)
        let auto = Voices.automatic(prefix)
        HStack {
            Picker("Voice", selection: $choice) {
                Text("Automatic (\(auto.map { $0.label.components(separatedBy: " · ")[0] } ?? "none"))").tag("")
                ForEach(options) { v in Text(v.label).tag(v.id) }
                if !choice.isEmpty, !options.contains(where: { $0.id == choice }) {
                    Text(Voices.option(id: choice).label).tag(choice)
                }
            }
            Button("Test") {
                AppModel.shared.speaker.test(voiceID: Voices.id(forLanguage: lang), text: Languages.lang(lang).sample)
            }
            .disabled(options.isEmpty)
        }
        Text(options.isEmpty
             ? "No voice installed for this language: add one in System Settings → Accessibility → Spoken Content → Manage Voices, or a Piper voice (below)."
             : matchLanguage ? "Also reads replies written in \(Languages.lang(lang).native)." : "")
            .font(.caption2).foregroundStyle(options.isEmpty ? .orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Menu bar

struct MenuContent: View {
    @EnvironmentObject private var speaker: Speaker
    @EnvironmentObject private var store: Store
    @Environment(\.openWindow) private var openWindow
    @AppStorage("pinned") private var pinned = true

    var body: some View {
        let newCount = store.visible.filter(\.isNew).count
        Button("Show Window") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button(speaker.state == .playing ? "Pause" : "Play") { speaker.togglePause() }
            .disabled(speaker.lines.isEmpty)
        Button("Stop") { speaker.stop() }
            .disabled(speaker.state == .idle)
        Button("Play New Replies (\(newCount))") { AppModel.shared.playAllNew() }
            .disabled(newCount == 0)
        Divider()
        Toggle("Keep Window on Top", isOn: $pinned)
        Divider()
        Button("Quit Claude Voice") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - Window level

/// Applies "always on top" to the hosting NSWindow, including over full-screen apps.
struct WindowAccessor: NSViewRepresentable {
    var pinned: Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { apply(v.window) }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { apply(v.window) }
    }

    private func apply(_ w: NSWindow?) {
        guard let w else { return }
        w.level = pinned ? .floating : .normal
        let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if pinned { w.collectionBehavior.formUnion(behavior) } else { w.collectionBehavior.subtract(behavior) }
    }
}
