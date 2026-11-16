import AppKit
import Foundation

/// Built-in lexicon-review extension (docs/plans/learned-words-review.md).
/// It owns everything about learned words: status, portable import/export,
/// the opt-in daily record, the review window and deletion with undo. The
/// host 词库 page reaches it only through `LexiconLearningBridge`, so turning
/// the extension off removes every learning surface and stops the daily
/// capture, while the base dictionaries, Rime's user database and the files
/// under ~/Library/RIMES/lexicon-review stay untouched.
///
/// Rime access stays behind `UserLexiconService` and `LearnedWordsLedger`,
/// both of which use librime's official user-dictionary levers.
final class LexiconReviewExtension: LexiconLearningProvider {
    static let shared = LexiconReviewExtension()
    static let settingsID = "lexicon-review"

    private var reviewWindowOpened = false

    var settingsRouteID: SettingsRouteID {
        SettingsRouteID(rawValue: SettingsRouteCatalog.extensionNamespace + Self.settingsID)
    }

    // The shared ledger and service bind the global Rime engine, so they are
    // resolved on first use and never while the plugin registry is built.
    private var service: UserLexiconService { .shared }
    private var ledger: LearnedWordsLedger { .shared }

    func status(for kind: UserLexiconKind) -> UserLexiconStatus {
        service.status(for: kind)
    }

    func engineDidStart() {
        ledger.startDailyCapture()
    }

    /// Bridge withdrawal is the plugin's job; this stops the work it owns.
    func stop() {
        ledger.stopDailyCapture()
        if reviewWindowOpened {
            LearnedWordsReviewWindowController.shared.stopScoring()
            LearnedWordsReviewWindowController.shared.window?.close()
        }
    }

    func showReview(kind: UserLexiconKind) {
        reviewWindowOpened = true
        LearnedWordsReviewWindowController.shared.show(kind: kind)
    }

    func importLearningData(_ kind: UserLexiconKind,
                            from url: URL) throws -> UserLexiconTransferResult {
        try service.importLearningData(kind, from: url)
    }

    func exportLearningData(_ kind: UserLexiconKind,
                            to url: URL) throws -> UserLexiconTransferResult {
        try service.exportLearningData(kind, to: url)
    }
}

final class LexiconReviewInternalPlugin: InternalPlugin {
    let descriptor = PluginDescriptor(
        key: PluginKey(domain: .builtIn, rawID: BuiltInPluginID.lexiconReview),
        wireID: nil,
        name: "词库学习",
        symbolName: "book.closed",
        version: "1.1.0",
        summary: "管理各词库的本机学习数据：回顾每天学到的词、可选地用 ChatGPT 评分初筛、删除误学词并可撤销，导入与导出学习记录。",
        source: .builtIn,
        capabilities: [.settingsPage, .lexiconLearning, .localStorage],
        settings: PluginSettingsContribution(
            id: LexiconReviewExtension.settingsID,
            title: "词库学习",
            symbolName: "book.closed",
            subpages: [
                PluginSettingsSubpage(id: "lexicons", title: "学习词库"),
            ]
        ),
        canUninstall: true
    )

    private let learning: LexiconReviewExtension

    init(learning: LexiconReviewExtension = .shared) {
        self.learning = learning
    }

    func start() {
        LexiconLearningBridge.shared.register(learning)
    }

    func stop() {
        LexiconLearningBridge.shared.unregister(learning)
        learning.stop()
    }

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        BuiltInPluginPageFactory.makeLexiconReview(subpageID: subpageID)
    }
}

final class LexiconReviewActionButton: RimePointingHandButton {
    var lexiconKind: UserLexiconKind = .chinese
}

/// Per-lexicon learning cards: 回顾 opens the review window; import/export
/// moved out of the host 词库 page with unchanged behavior (imports merge
/// through Rime and never replace the live database; exports contain learned
/// entries only).
final class LexiconReviewSettingsViewController: NSViewController {
    static let lexicons: [(kind: UserLexiconKind, title: String, detail: String)] = [
        (.chinese, "雾凇拼音", "中文主词库 · 全拼、自然码双拼、小鹤双拼与飞耀方案共享"),
        (.wubi86, "五笔86", "五笔86 码表与独立用户词频"),
        (.english, "Easy English", "英文候选、补全、生词兜底与独立学习"),
    ]

    private let learning: LexiconReviewExtension
    private let scoring: LearnedWordsScoringPreferences
    private let column = NSStackView()

    init(subpageID: String, learning: LexiconReviewExtension = .shared,
         scoring: LearnedWordsScoringPreferences = .shared) {
        self.learning = learning
        self.scoring = scoring
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 22, right: 24)
        view = column
        rebuild()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuild()
    }

    private func rebuild() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let intro = NSTextField(wrappingLabelWithString:
            "学习记录保存在本机 ~/Library/\(RimesPaths.directoryName)，各词库独立。"
            + "回顾按天列出新学的词，可删除误学词并按轮次撤销；每日记录默认关闭，在回顾窗口中开启。"
            + "导入会合并词频，不会替换现有学习数据；导出只包含学习记录，不含基础词库或输入正文。")
        intro.font = .systemFont(ofSize: 10)
        intro.textColor = RimeUI.textMuted
        intro.preferredMaxLayoutWidth = 650
        column.addArrangedSubview(intro)
        for lexicon in Self.lexicons {
            column.addArrangedSubview(card(kind: lexicon.kind,
                                           title: lexicon.title,
                                           detail: lexicon.detail))
        }
        scoringSection().forEach(column.addArrangedSubview)
    }

    // MARK: Scoring (step 3 of docs/plans/learned-words-review.md)

    private func scoringSection() -> [NSView] {
        let title = NSTextField(labelWithString: "评分初筛（可选）")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = RimeUI.textPrimary

        let enable = NSButton(checkboxWithTitle: "允许把学习词发送给 ChatGPT 评分",
                              target: self, action: #selector(scoringEnabledChanged(_:)))
        enable.state = scoring.isEnabled ? .on : .off
        enable.identifier = NSUserInterfaceItemIdentifier("lexicon-review.scoring.enabled")

        let privacy = NSTextField(wrappingLabelWithString:
            "默认关闭。开启后，回顾窗口会出现“评分…”：每一轮都由你手动发起，发起前显示将发送的词数；"
            + "词语经本机 Codex CLI 和你的 ChatGPT 登录发送给 OpenAI，只发送词本身。"
            + "模型按 1–5 分标出疑似误学的词（5 最可疑），只影响排序和“删除评分为 5 的…”的范围，不会自动删除。完成后在 Mailbox 提示。")
        privacy.font = .systemFont(ofSize: 10)
        privacy.textColor = RimeUI.textMuted
        privacy.preferredMaxLayoutWidth = 650

        let model = popUp(LearnedWordsScoringPreferences.modelChoices.map(\.title),
                          selected: LearnedWordsScoringPreferences.modelChoices
                            .firstIndex { $0.value == scoring.model } ?? 0,
                          action: #selector(modelChanged(_:)))
        let batch = popUp(LearnedWordsScoringPreferences.batchSizeChoices.map { "每批 \($0) 个" },
                          selected: LearnedWordsScoringPreferences.batchSizeChoices
                            .firstIndex(of: scoring.batchSize) ?? 0,
                          action: #selector(batchSizeChanged(_:)))
        let limit = popUp(LearnedWordsScoringPreferences.roundLimitChoices.map { "每轮最多 \($0) 个" },
                          selected: LearnedWordsScoringPreferences.roundLimitChoices
                            .firstIndex(of: scoring.roundLimit) ?? 0,
                          action: #selector(roundLimitChanged(_:)))
        let options = NSStackView(views: [label("模型"), model, batch, limit])
        options.orientation = .horizontal
        options.alignment = .centerY
        options.spacing = 8

        let digits = NSButton(checkboxWithTitle: "含数字的词留在本机", target: self,
                              action: #selector(excludeDigitsChanged(_:)))
        digits.state = scoring.excludesDigits ? .on : .off
        let latin = NSButton(checkboxWithTitle: "含英文字母的词留在本机", target: self,
                             action: #selector(excludeLatinChanged(_:)))
        latin.state = scoring.excludesLatin ? .on : .off
        let long = NSButton(checkboxWithTitle:
                                "超过 \(LearnedWordsScoringPreferences.longWordLength) 个字的词留在本机",
                            target: self, action: #selector(excludeLongChanged(_:)))
        long.state = scoring.excludesLongWords ? .on : .off
        let exclusions = NSStackView(views: [digits, latin, long])
        exclusions.orientation = .horizontal
        exclusions.alignment = .centerY
        exclusions.spacing = 14

        for control in [model, batch, limit, digits, latin, long] as [NSControl] {
            control.isEnabled = scoring.isEnabled
            control.controlSize = .small
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
        return [spacer, title, enable, privacy, options, exclusions]
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = RimeUI.textSecondary
        return field
    }

    private func popUp(_ titles: [String], selected: Int, action: Selector) -> NSPopUpButton {
        let button = NSPopUpButton()
        button.addItems(withTitles: titles)
        button.selectItem(at: selected)
        button.target = self
        button.action = action
        return button
    }

    @objc private func scoringEnabledChanged(_ sender: NSButton) {
        scoring.setEnabled(sender.state == .on)
        rebuild()
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        let choices = LearnedWordsScoringPreferences.modelChoices
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        scoring.setModel(choices[sender.indexOfSelectedItem].value)
    }

    @objc private func batchSizeChanged(_ sender: NSPopUpButton) {
        let choices = LearnedWordsScoringPreferences.batchSizeChoices
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        scoring.setBatchSize(choices[sender.indexOfSelectedItem])
    }

    @objc private func roundLimitChanged(_ sender: NSPopUpButton) {
        let choices = LearnedWordsScoringPreferences.roundLimitChoices
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        scoring.setRoundLimit(choices[sender.indexOfSelectedItem])
    }

    @objc private func excludeDigitsChanged(_ sender: NSButton) {
        scoring.setExcludesDigits(sender.state == .on)
    }

    @objc private func excludeLatinChanged(_ sender: NSButton) {
        scoring.setExcludesLatin(sender.state == .on)
    }

    @objc private func excludeLongChanged(_ sender: NSButton) {
        scoring.setExcludesLongWords(sender.state == .on)
    }

    private func actionButton(_ title: String, kind: UserLexiconKind,
                              action: Selector) -> LexiconReviewActionButton {
        let button = LexiconReviewActionButton(title: title, target: self, action: action)
        button.lexiconKind = kind
        button.controlSize = .small
        return button
    }

    private func card(kind: UserLexiconKind, title: String, detail: String) -> NSView {
        let status = learning.status(for: kind)
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 11, weight: .semibold)
        name.textColor = RimeUI.textPrimary
        name.toolTip = detail

        let statusLabel = NSTextField(labelWithString:
            status.hasLearningDatabase ? "学习库已建立" : "尚未建立学习库")
        statusLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        statusLabel.textColor = status.hasLearningDatabase
            ? RimeUI.accentTextColor : RimeUI.textMuted

        let reviewButton = actionButton("回顾…", kind: kind, action: #selector(review(_:)))
        reviewButton.toolTip = "按天查看新学的词，可删除误学词并撤销"
        let importButton = actionButton("导入学习…", kind: kind,
                                        action: #selector(importLearning(_:)))
        let exportButton = actionButton("导出学习…", kind: kind,
                                        action: #selector(exportLearning(_:)))
        exportButton.isEnabled = status.hasLearningDatabase

        let header = NSStackView(views: [name, statusLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 6
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actions = NSStackView(views: [reviewButton, importButton, exportButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 6

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let card = NSStackView(views: [header, spacer, actions])
        card.orientation = .horizontal
        card.alignment = .centerY
        card.spacing = 10
        card.edgeInsets = NSEdgeInsets(top: 8, left: 11, bottom: 8, right: 10)
        card.wantsLayer = true
        card.layer?.backgroundColor = RimeUI.surface2.cgColor
        card.layer?.borderColor = RimeUI.border.cgColor
        card.layer?.borderWidth = 1 / max(view.window?.backingScaleFactor ?? 2, 1)
        card.layer?.cornerRadius = 8
        card.layer?.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 650).isActive = true
        card.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        return card
    }

    @objc private func review(_ sender: LexiconReviewActionButton) {
        learning.showReview(kind: sender.lexiconKind)
    }

    @objc private func importLearning(_ sender: LexiconReviewActionButton) {
        let kind = sender.lexiconKind
        let panel = NSOpenPanel()
        panel.title = "导入\(kind.displayName)"
        panel.message = "选择由 \(ProductIdentity.displayName) 或 Rime 用户词典管理器导出的 TSV；记录会合并，不会替换现有学习数据。"
        panel.prompt = "选择并导入"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.tabSeparatedText, .plainText]
        panel.appearance = RimeUI.appKitAppearance
        guard panel.runModal() == .OK,
              RimeInputSourceAuthority.currentSourceIsOwn(),
              let sourceURL = panel.url else { return }

        let confirmation = NSAlert()
        confirmation.alertStyle = .informational
        confirmation.messageText = "合并到\(kind.displayName)？"
        confirmation.informativeText = "Rime 会短暂收束当前组字并重新建立输入会话；已有词频不会被清空。"
        confirmation.addButton(withTitle: "导入并合并")
        confirmation.addButton(withTitle: "取消")
        confirmation.window.appearance = RimeUI.appKitAppearance
        guard StandaloneWindowFocusCoordinator.shared
            .runModalAlertIfRIMESActive(confirmation)
                == .alertFirstButtonReturn else { return }

        do {
            let result = try learning.importLearningData(kind, from: sourceURL)
            inform("已向\(kind.displayName)合并 \(result.entryCount) 条学习记录。")
            rebuild()
        } catch {
            showError(error, operation: "导入")
        }
    }

    @objc private func exportLearning(_ sender: LexiconReviewActionButton) {
        let kind = sender.lexiconKind
        let panel = NSSavePanel()
        panel.title = "导出\(kind.displayName)"
        panel.message = "导出为可再次导入的 UTF-8 TSV，不包含基础词库、输入正文或其他统计。"
        panel.prompt = "导出"
        panel.nameFieldStringValue = kind.suggestedFileName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.tabSeparatedText]
        panel.appearance = RimeUI.appKitAppearance
        guard panel.runModal() == .OK,
              RimeInputSourceAuthority.currentSourceIsOwn(),
              let destinationURL = panel.url else { return }

        do {
            let result = try learning.exportLearningData(kind, to: destinationURL)
            inform("已导出 \(result.entryCount) 条\(kind.displayName)记录。")
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } catch {
            showError(error, operation: "导出")
        }
    }

    private func inform(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.window.appearance = RimeUI.appKitAppearance
        _ = StandaloneWindowFocusCoordinator.shared.runModalAlertIfRIMESActive(alert)
    }

    private func showError(_ error: Error, operation: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "学习词库\(operation)失败"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.window.appearance = RimeUI.appKitAppearance
        _ = StandaloneWindowFocusCoordinator.shared.runModalAlertIfRIMESActive(alert)
    }
}
