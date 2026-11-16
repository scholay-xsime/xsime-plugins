import AppKit

/// Review of learned words, grouped by the day they were learned, with
/// deletion and undo and optional 1–5 scoring (steps 1–3 of
/// docs/plans/learned-words-review.md).
final class LearnedWordsReviewWindowController: NSObject, NSWindowDelegate,
                                                NSTableViewDataSource, NSTableViewDelegate {
    static let shared = LearnedWordsReviewWindowController(ledger: .shared)

    enum Section: Equatable {
        case day(String)
        case all
        case deletion(String)
    }

    enum Filter: Int, CaseIterable {
        case everything
        case usedOnce
        case longPhrases
        case unscored
        case flagged

        var title: String {
            switch self {
            case .everything: return "全部"
            case .usedOnce: return "只用过一次"
            case .longPhrases: return "5 字以上"
            case .unscored: return "未评分"
            case .flagged: return "评分 4–5"
            }
        }
    }

    struct SectionRow: Equatable {
        let section: Section
        let title: String
        let detail: String
    }

    struct WordRow: Equatable {
        let word: String
        let code: String
        let count: Int
        let change: String
        let isNew: Bool
        var isDeleted = false
        var score: Int?

        var key: LearnedWordKey { LearnedWordKey(word: word, code: code) }
    }

    private let ledger: LearnedWordsLedger
    private let preferences: LearnedWordsReviewPreferences
    private let scoringPreferences: LearnedWordsScoringPreferences
    private let makeScoringBackend: () -> LearnedWordsScoringBackend
    private let scoringNotifier: LearnedWordsScoringNotifier
    private var scores: [String: LearnedWordScore] = [:]
    private(set) var scoringRound: LearnedWordsScoringRound?
    /// Footer text while a scoring round runs.
    private var scoringProgress: String?
    private(set) var window: NSWindow?
    private(set) var kind: UserLexiconKind = .chinese
    private(set) var sections: [SectionRow] = []
    private(set) var rows: [WordRow] = []
    private(set) var filter: Filter = .everything
    private var allRows: [WordRow] = []
    private var days: [LearnedWordsDay] = []
    private var rounds: [LearnedWordsDeletionRound] = []
    private var deletedKeys: Set<LearnedWordKey> = []
    /// Result of the last delete or undo, shown in the footer.
    private(set) var notice: String?
    private var observers: [NSObjectProtocol] = []

    private let dictionaryPopUp = NSPopUpButton()
    private let recordSwitch = NSSwitch()
    private let recordLabel = NSTextField(labelWithString: "每天记录新学的词（只保存在本机）")
    private let captureButton = NSButton(title: "立即记录", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let filterControl = NSSegmentedControl()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let sectionTable = NSTableView()
    private let wordTable = LearnedWordsTableView()
    private let deleteButton = NSButton(title: "删除所选…", target: nil, action: nil)
    private let undoButton = NSButton(title: "撤销这一轮", target: nil, action: nil)
    private let scoreButton = NSButton(title: "评分…", target: nil, action: nil)
    private let deleteFlaggedButton = NSButton(title: "删除评分为 5 的…", target: nil, action: nil)
    private let footerLabel = NSTextField(labelWithString: "")
    private static let defaultFooter = "选中词后按 Delete 键或点“删除所选…”。删除前会自动备份，可以撤销。"

    init(ledger: LearnedWordsLedger,
         preferences: LearnedWordsReviewPreferences = .shared,
         scoringPreferences: LearnedWordsScoringPreferences = .shared,
         scoringBackend: @escaping () -> LearnedWordsScoringBackend = { CodexLearnedWordsScoringBackend() },
         scoringNotifier: LearnedWordsScoringNotifier = MailboxLearnedWordsScoringNotifier()) {
        self.ledger = ledger
        self.preferences = preferences
        self.scoringPreferences = scoringPreferences
        self.makeScoringBackend = scoringBackend
        self.scoringNotifier = scoringNotifier
        super.init()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func show(kind: UserLexiconKind) {
        if window == nil { build() }
        select(kind: kind)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func select(kind: UserLexiconKind) {
        // A running round belongs to one dictionary; keep the window on it.
        if scoringRound != nil, kind != self.kind {
            if let index = UserLexiconKind.allCases.firstIndex(of: self.kind) {
                dictionaryPopUp.selectItem(at: index)
            }
            return
        }
        if kind != self.kind { notice = nil }
        self.kind = kind
        if let index = UserLexiconKind.allCases.firstIndex(of: kind) {
            dictionaryPopUp.selectItem(at: index)
        }
        reload()
    }

    // MARK: Data

    var selectedSection: Section? {
        sections.indices.contains(sectionTable.selectedRow)
            ? sections[sectionTable.selectedRow].section : nil
    }

    func reload() {
        let previous = selectedSection
        days = ledger.days(for: kind)
        rounds = ledger.deletionRounds(for: kind)
        deletedKeys = ledger.currentlyDeleted(for: kind)
        scores = ledger.scores(for: kind)
        let entries = ledger.currentEntries(for: kind)
        var built = days.map { day in
            SectionRow(section: .day(day.day),
                       title: Self.dayTitle(day.day, today: ledger.dayString(for: Date())),
                       detail: "新学 \(day.added.count) · 再用 \(day.reused.count)")
        }
        if !entries.isEmpty {
            built.append(SectionRow(section: .all, title: "全部学习词",
                                    detail: "\(entries.count.formatted()) 个"))
        }
        built += rounds.map { round in
            SectionRow(section: .deletion(round.id),
                       title: "删除 · \(Self.timestampFormatter.string(from: round.deletedAt))",
                       detail: round.isUndone ? "已撤销 · \(round.words.count.formatted()) 个词"
                                              : "\(round.words.count.formatted()) 个词")
        }
        sections = built
        recordSwitch.state = preferences.recordsDaily ? .on : .off
        updateStatus()
        sectionTable.reloadData()
        let index = previous.flatMap { section in sections.firstIndex { $0.section == section } }
            ?? (sections.isEmpty ? nil : 0)
        if let index {
            sectionTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        showSelectedSection()
    }

    func showSection(at index: Int) {
        guard sections.indices.contains(index) else { return }
        sectionTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        showSelectedSection()
    }

    func setFilter(_ filter: Filter) {
        self.filter = filter
        filterControl.selectedSegment = filter.rawValue
        applyFilter()
    }

    private func showSelectedSection() {
        let index = sectionTable.selectedRow
        guard sections.indices.contains(index) else {
            allRows = []
            applyFilter()
            return
        }
        switch sections[index].section {
        case .day(let name):
            guard let day = days.first(where: { $0.day == name }) else { allRows = []; break }
            let added = day.added.map {
                markDeleted(WordRow(word: $0.word, code: $0.code, count: $0.count,
                                    change: "新学", isNew: true))
            }
            let reused = day.reused.map {
                markDeleted(WordRow(word: $0.word, code: $0.code, count: $0.toCount,
                                    change: "\($0.fromCount) → \($0.toCount)", isNew: false))
            }
            allRows = added.sorted(by: Self.byWord) + reused.sorted(by: Self.byWord)
        case .all:
            allRows = ledger.currentEntries(for: kind)
                .map { WordRow(word: $0.word, code: $0.code, count: $0.count, change: "", isNew: false) }
                .sorted { ($0.count, $0.word) < ($1.count, $1.word) }
        case .deletion(let id):
            guard let round = rounds.first(where: { $0.id == id }) else { allRows = []; break }
            allRows = round.words.map { word in
                let deleted = deletedKeys.contains(word.key)
                let change = round.isUndone ? "已撤销" : (deleted ? "已删除" : "已重新学会")
                return WordRow(word: word.word, code: word.code, count: word.count,
                               change: change, isNew: false, isDeleted: deleted)
            }.sorted(by: Self.byWord)
        }
        allRows = allRows.map { row in
            var row = row
            row.score = scores[row.word]?.score
            return row
        }
        applyFilter()
    }

    private func markDeleted(_ row: WordRow) -> WordRow {
        guard deletedKeys.contains(row.key) else { return row }
        return WordRow(word: row.word, code: row.code, count: row.count,
                       change: "已删除", isNew: false, isDeleted: true)
    }

    private func applyFilter() {
        switch filter {
        case .everything: rows = allRows
        case .usedOnce: rows = allRows.filter { $0.count == 1 }
        case .longPhrases: rows = allRows.filter { $0.word.count >= 5 }
        case .unscored: rows = allRows.filter { $0.score == nil }
        case .flagged: rows = allRows.filter { ($0.score ?? 0) >= 4 }
        }
        if let descriptor = wordTable.sortDescriptors.first {
            rows = Self.sorted(rows, by: descriptor)
        } else if rows.contains(where: { $0.score != nil }) {
            // Default order once scores exist: highest score first; unscored
            // rows keep their order after them.
            rows = rows.enumerated().sorted { lhs, rhs in
                let left = lhs.element.score ?? 0, right = rhs.element.score ?? 0
                return left != right ? left > right : lhs.offset < rhs.offset
            }.map(\.element)
        }
        wordTable.reloadData()
        countLabel.stringValue = "\(rows.count.formatted()) 个词"
        emptyLabel.stringValue = emptyMessage()
        emptyLabel.isHidden = !rows.isEmpty
        footerLabel.stringValue = scoringProgress ?? notice ?? Self.defaultFooter
        updateActionButtons()
    }

    private func updateActionButtons() {
        var roundIsOpen: Bool?
        if case .deletion(let id)? = selectedSection {
            roundIsOpen = rounds.first(where: { $0.id == id }).map { !$0.isUndone } ?? false
        }
        deleteButton.isHidden = roundIsOpen != nil
        deleteButton.isEnabled = !deletableSelection().isEmpty && scoringRound == nil
        undoButton.isHidden = roundIsOpen == nil
        undoButton.isEnabled = roundIsOpen == true && scoringRound == nil
        scoreButton.isHidden = !scoringPreferences.isEnabled && scoringRound == nil
        scoreButton.title = scoringRound == nil ? "评分…" : "停止评分"
        deleteFlaggedButton.isHidden = roundIsOpen != nil || !rows.contains { $0.score != nil }
        deleteFlaggedButton.isEnabled = !highestScoredKeys().isEmpty && scoringRound == nil
    }

    /// Visible, not yet deleted rows scored 5.
    private func highestScoredKeys() -> [LearnedWordKey] {
        if case .deletion? = selectedSection { return [] }
        return rows.filter { $0.score == 5 && !$0.isDeleted }.map(\.key)
    }

    private func deletableSelection() -> [LearnedWordKey] {
        if case .deletion? = selectedSection { return [] }
        return wordTable.selectedRowIndexes.compactMap { index in
            rows.indices.contains(index) && !rows[index].isDeleted ? rows[index].key : nil
        }
    }

    // MARK: Selection (also used by the smoke test)

    func selectWords(at indexes: IndexSet) {
        wordTable.selectRowIndexes(indexes, byExtendingSelection: false)
        updateActionButtons()
    }

    var canDeleteSelection: Bool { !deleteButton.isHidden && deleteButton.isEnabled }
    var canDeleteHighestScored: Bool { !deleteFlaggedButton.isHidden && deleteFlaggedButton.isEnabled }
    var canStartScoring: Bool { scoringPreferences.isEnabled && scoringRound == nil }
    var canUndoSelectedRound: Bool { !undoButton.isHidden && undoButton.isEnabled }

    private func emptyMessage() -> String {
        if sections.isEmpty {
            return preferences.recordsDaily
                ? "还没有记录。点“立即记录”建立第一份记录；之后每天会自动比较一次。"
                : "打开上方的开关后，每天会把新学的词记下来。词语只保存在本机，不会发送到任何地方。"
        }
        if allRows.isEmpty { return "这里没有词。" }
        return "没有符合筛选条件的词。"
    }

    private func updateStatus() {
        if let date = ledger.lastCapturedAt(for: kind) {
            statusLabel.stringValue = "上次记录：\(Self.timestampFormatter.string(from: date))"
        } else {
            statusLabel.stringValue = preferences.recordsDaily ? "尚未记录" : "未开启"
        }
        captureButton.isEnabled = preferences.recordsDaily
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日 HH:mm"
        return formatter
    }()

    static func dayTitle(_ day: String, today: String) -> String {
        if day == today { return "今天" }
        let parts = day.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let dayOfMonth = Int(parts[2]) else {
            return day
        }
        return "\(parts[0]) 年 \(month) 月 \(dayOfMonth) 日"
    }

    private static func byWord(_ lhs: WordRow, _ rhs: WordRow) -> Bool {
        lhs.word.localizedStandardCompare(rhs.word) == .orderedAscending
    }

    private static func sorted(_ rows: [WordRow], by descriptor: NSSortDescriptor) -> [WordRow] {
        let ascending = descriptor.ascending
        return rows.sorted { lhs, rhs in
            let result: ComparisonResult
            switch descriptor.key {
            case "code": result = lhs.code.localizedStandardCompare(rhs.code)
            case "count":
                result = lhs.count == rhs.count ? .orderedSame
                    : (lhs.count < rhs.count ? .orderedAscending : .orderedDescending)
            case "change": result = lhs.change.localizedStandardCompare(rhs.change)
            case "score":
                let left = lhs.score ?? 0, right = rhs.score ?? 0
                result = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            default: result = lhs.word.localizedStandardCompare(rhs.word)
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    // MARK: Actions

    @objc private func dictionaryChanged(_ sender: NSPopUpButton) {
        let all = UserLexiconKind.allCases
        guard all.indices.contains(sender.indexOfSelectedItem) else { return }
        select(kind: all[sender.indexOfSelectedItem])
    }

    @objc private func recordSwitchChanged(_ sender: NSSwitch) {
        preferences.setRecordsDaily(sender.state == .on)
        if sender.state == .on { captureNow(nil) } else { reload() }
    }

    @objc func captureNow(_ sender: Any?) {
        do {
            let result = try ledger.capture(kind)
            IMELog.write("lexicon-review: manual capture \(kind.rawValue) \(result)")
        } catch {
            presentError(error)
        }
        reload()
    }

    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        setFilter(Filter(rawValue: sender.selectedSegment) ?? .everything)
    }

    @objc private func deleteButtonPressed(_ sender: Any?) {
        requestDeletion(skipConfirmation: false)
    }

    /// Asks first unless `skipConfirmation` is set (the smoke test does).
    func requestDeletion(skipConfirmation: Bool) {
        confirmDeletion(deletableSelection(), skipConfirmation: skipConfirmation,
                        title: { "删除 \($0.formatted()) 个学习词？" })
    }

    /// One-click removal of every visible word scored 5 (step 3 of the plan).
    func requestDeletionOfHighestScored(skipConfirmation: Bool) {
        confirmDeletion(highestScoredKeys(), skipConfirmation: skipConfirmation,
                        title: { "删除评分为 5 的 \($0.formatted()) 个学习词？" })
    }

    @objc private func deleteFlaggedButtonPressed(_ sender: Any?) {
        requestDeletionOfHighestScored(skipConfirmation: false)
    }

    private func confirmDeletion(_ keys: [LearnedWordKey], skipConfirmation: Bool,
                                 title: (Int) -> String) {
        guard !keys.isEmpty, scoringRound == nil else { return }
        if skipConfirmation {
            performDeletion(keys)
            return
        }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title(keys.count)
        alert.informativeText = "删除前会自动备份当前学习词库，之后可以在左侧的“删除”记录里撤销。\n以后再输入这些词时，Rime 会按原来的次数把它们恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.performDeletion(keys) }
        }
    }

    private func performDeletion(_ keys: [LearnedWordKey]) {
        do {
            let result = try ledger.delete(keys, from: kind)
            var text = "已删除 \(result.round.words.count.formatted()) 个词，可以在左侧“删除”记录里撤销。"
            if result.notFound > 0 { text += "另有 \(result.notFound) 个已不在学习词库里。" }
            if result.notDeleted > 0 { text += "还有 \(result.notDeleted) 个没有删掉，请再试一次。" }
            notice = text
        } catch {
            presentError(error, title: "无法删除学习词")
        }
        reload()
    }

    @objc func undoSelectedRound(_ sender: Any?) {
        guard case .deletion(let id)? = selectedSection else { return }
        do {
            let round = try ledger.undo(roundID: id, for: kind)
            notice = "已恢复 \(round.words.count.formatted()) 个词，次数和删除前一样。"
        } catch {
            presentError(error, title: "无法撤销删除")
        }
        reload()
    }

    // MARK: Scoring

    @objc private func scoreButtonPressed(_ sender: Any?) {
        if scoringRound != nil { stopScoring() } else { startScoring(skipConfirmation: false) }
    }

    /// Shows how many words will be sent, then sends them in batches. The
    /// smoke test passes `skipConfirmation`.
    func startScoring(skipConfirmation: Bool) {
        guard scoringRound == nil, scoringPreferences.isEnabled else { return }
        let words = ledger.scoringCandidates(for: kind, preferences: scoringPreferences,
                                             limit: scoringPreferences.roundLimit)
        guard !words.isEmpty else {
            notice = "没有需要评分的词：都已评分，或被排除规则留在本机。"
            applyFilter()
            return
        }
        let backend = makeScoringBackend()
        if case let .unavailable(message) = backend.availability {
            notice = "无法评分：\(message)"
            applyFilter()
            return
        }
        let model = scoringPreferences.model
        let batchSize = scoringPreferences.batchSize
        let begin = { [weak self] in
            self?.runScoring(words: words, model: model, batchSize: batchSize, backend: backend)
        }
        if skipConfirmation { begin(); return }
        guard let window else { return }
        let batches = (words.count + batchSize - 1) / batchSize
        let alert = NSAlert()
        alert.messageText = "把 \(words.count.formatted()) 个学习词发送给 ChatGPT 评分？"
        alert.informativeText = """
            这些词会经本机的 Codex CLI 发送给 OpenAI（模型 \(model)），分 \(batches) 批，每批都有固定的处理开销。\
            只发送词本身，不发送编码、次数或日期；含数字、英文或过长的词按设置留在本机。
            评分只影响排序和一键删除的范围，不会自动删除任何词。完成后会在 Mailbox 里提示。
            """
        alert.addButton(withTitle: "发送并评分")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { begin() }
        }
    }

    func stopScoring() {
        scoringRound?.cancel()
    }

    private func runScoring(words: [String], model: String, batchSize: Int,
                            backend: LearnedWordsScoringBackend) {
        guard scoringRound == nil else { return }
        let round = LearnedWordsScoringRound(ledger: ledger, kind: kind, words: words,
                                             model: model, batchSize: batchSize, backend: backend)
        scoringRound = round
        notice = nil
        round.start(progress: { [weak self] done, total in
            guard let self, self.scoringRound === round else { return }
            self.scoringProgress = "正在评分 \(words.count.formatted()) 个词：第 \(min(done + 1, total))/\(total) 批…"
            self.reload()
        }, completion: { [weak self] outcome in
            guard let self, self.scoringRound === round else { return }
            self.scoringRound = nil
            self.scoringProgress = nil
            switch outcome {
            case let .finished(scored, unscored):
                self.notice = "本轮已评分 \(scored.formatted()) 个词"
                    + (unscored > 0 ? "，\(unscored.formatted()) 个没有拿到有效评分。" : "。")
                self.scoringNotifier.scoringRoundFinished(kind: round.kind, scored: scored,
                                                          unscored: unscored, model: round.model)
            case let .cancelled(scored):
                self.notice = "已停止评分；已保存 \(scored.formatted()) 个词的评分。"
            case let .failed(scored, message):
                self.notice = "评分中断：\(message)。已保存 \(scored.formatted()) 个词的评分，可以稍后再试。"
            }
            self.reload()
        })
    }

    private func presentError(_ error: Error, title: String = "无法记录学习词") {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sectionTable ? sections.count : rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("section")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        if tableView === sectionTable {
            let item = sections[row]
            cell.textField?.attributedStringValue = Self.sectionText(item)
        } else {
            let item = rows[row]
            switch identifier.rawValue {
            case "code": cell.textField?.stringValue = item.code
            case "count": cell.textField?.stringValue = "\(item.count)"
            case "change": cell.textField?.stringValue = item.change
            case "score": cell.textField?.stringValue = item.score.map(String.init) ?? "—"
            default: cell.textField?.stringValue = item.word
            }
            cell.textField?.textColor = item.isDeleted ? RimeUI.textMuted
                : (identifier.rawValue == "change" && item.isNew ? RimeUI.accentTextColor
                   : (identifier.rawValue == "score" && (item.score ?? 0) >= 4
                      ? RimeUI.warningTextColor : RimeUI.textPrimary))
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        tableView === sectionTable ? 40 : 22
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === sectionTable {
            showSelectedSection()
        } else {
            updateActionButtons()
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === wordTable else { return }
        applyFilter()
    }

    private static func sectionText(_ item: SectionRow) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: item.title + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: RimeUI.textPrimary]
        )
        text.append(NSAttributedString(
            string: item.detail,
            attributes: [.font: NSFont.systemFont(ofSize: 10),
                         .foregroundColor: RimeUI.textMuted]
        ))
        return text
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = identifier.rawValue == "section" ? 2 : 1
        field.font = .systemFont(ofSize: 12)
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Build

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "学习词回顾"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.minSize = NSSize(width: 680, height: 420)
        win.appearance = RimeUI.appKitAppearance
        win.backgroundColor = RimeUI.surface
        win.identifier = NSUserInterfaceItemIdentifier("lexicon-review.window")

        for kind in UserLexiconKind.allCases { dictionaryPopUp.addItem(withTitle: kind.displayName) }
        dictionaryPopUp.target = self
        dictionaryPopUp.action = #selector(dictionaryChanged(_:))
        dictionaryPopUp.controlSize = .small

        recordSwitch.target = self
        recordSwitch.action = #selector(recordSwitchChanged(_:))
        recordSwitch.controlSize = .small
        recordSwitch.identifier = NSUserInterfaceItemIdentifier("lexicon-review.record-switch")
        recordLabel.font = .systemFont(ofSize: 12)
        recordLabel.textColor = RimeUI.textPrimary

        captureButton.target = self
        captureButton.action = #selector(captureNow(_:))
        captureButton.controlSize = .small
        captureButton.bezelStyle = .rounded

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = RimeUI.textMuted

        let header = NSStackView(views: [dictionaryPopUp, recordSwitch, recordLabel,
                                         NSView(), statusLabel, captureButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
        header.views[3].setContentHuggingPriority(.defaultLow, for: .horizontal)

        configure(sectionTable, columns: [("section", "日期", 200)], sortable: false)
        sectionTable.headerView = nil
        sectionTable.identifier = NSUserInterfaceItemIdentifier("lexicon-review.sections")
        configure(wordTable, columns: [("word", "词", 200), ("code", "编码", 190),
                                       ("count", "次数", 60), ("score", "评分", 56),
                                       ("change", "变化", 100)],
                  sortable: true)
        wordTable.identifier = NSUserInterfaceItemIdentifier("lexicon-review.words")

        filterControl.segmentCount = Filter.allCases.count
        for item in Filter.allCases {
            filterControl.setLabel(item.title, forSegment: item.rawValue)
        }
        filterControl.selectedSegment = filter.rawValue
        filterControl.trackingMode = .selectOne
        filterControl.controlSize = .small
        filterControl.target = self
        filterControl.action = #selector(filterChanged(_:))

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = RimeUI.textMuted
        for (button, action, id) in [(deleteButton, #selector(deleteButtonPressed(_:)), "delete"),
                                     (undoButton, #selector(undoSelectedRound(_:)), "undo"),
                                     (scoreButton, #selector(scoreButtonPressed(_:)), "score"),
                                     (deleteFlaggedButton, #selector(deleteFlaggedButtonPressed(_:)),
                                      "delete-flagged")] {
            button.target = self
            button.action = action
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier("lexicon-review.\(id)")
        }
        undoButton.isHidden = true
        wordTable.onDelete = { [weak self] in self?.requestDeletion(skipConfirmation: false) }
        scoreButton.toolTip = "把未评分的学习词发送给 ChatGPT，按 1–5 分标出疑似误学的词"
        let toolbar = NSStackView(views: [filterControl, NSView(), countLabel, scoreButton,
                                          deleteFlaggedButton, deleteButton, undoButton])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.views[1].setContentHuggingPriority(.defaultLow, for: .horizontal)

        let sectionScroll = scrollView(for: sectionTable)
        let wordScroll = scrollView(for: wordTable)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = RimeUI.textMuted
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        wordScroll.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: wordScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: wordScroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: wordScroll.widthAnchor, constant: -60),
        ])

        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = RimeUI.textMuted
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.stringValue = Self.defaultFooter

        let right = NSStackView(views: [toolbar, wordScroll, footerLabel])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8
        let content = NSStackView(views: [sectionScroll, right])
        content.orientation = .horizontal
        content.alignment = .top
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 14, right: 14)

        let root = NSStackView(views: [header, content])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(root)
        win.contentView = container
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            content.widthAnchor.constraint(equalTo: root.widthAnchor),
            sectionScroll.widthAnchor.constraint(equalToConstant: 200),
            sectionScroll.heightAnchor.constraint(equalTo: right.heightAnchor),
            toolbar.widthAnchor.constraint(equalTo: right.widthAnchor),
            wordScroll.widthAnchor.constraint(equalTo: right.widthAnchor),
        ])
        win.center()
        window = win

        observers.append(NotificationCenter.default.addObserver(
            forName: LearnedWordsScoringPreferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.updateActionButtons() })
        observers.append(NotificationCenter.default.addObserver(
            forName: .rimeAppearanceDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.window?.appearance = RimeUI.appKitAppearance
            self?.window?.backgroundColor = RimeUI.surface
            self?.sectionTable.reloadData()
            self?.wordTable.reloadData()
        })
    }

    private func configure(_ table: NSTableView,
                           columns: [(String, String, CGFloat)],
                           sortable: Bool) {
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 50
            if sortable {
                column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            }
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = table !== sectionTable
        table.allowsMultipleSelection = table !== sectionTable
        table.style = .inset
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    }

    private func scrollView(for table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = RimeUI.surface2
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }
}

/// Lets the Delete and Forward Delete keys act on the selected words.
final class LearnedWordsTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, let onDelete {
            onDelete()
            return
        }
        super.keyDown(with: event)
    }
}
