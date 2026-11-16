import Foundation

/// Step 3 of docs/plans/learned-words-review.md: optional 1–5 pre-screening of
/// learned words by a ChatGPT model. 5 means "most likely a mistake" (a typo,
/// a wrong word boundary or a phrase that should not have become a word), 1
/// means an ordinary word. Scores only change the review window's order,
/// filters and the scope of "delete everything scored 5"; nothing is deleted
/// automatically.
///
/// Privacy: scoring sends the user's own words to OpenAI. It is off by
/// default, every round is started by hand after the word count is shown, and
/// exclusion rules keep words with digits, Latin letters or long phrases
/// local unless the user changes them.

// MARK: Preferences

final class LearnedWordsScoringPreferences {
    static let shared = LearnedWordsScoringPreferences()
    static let didChange = Notification.Name("RIMES.LearnedWordsScoring.didChange")

    static let defaultModel = "gpt-6-luna"
    static let modelChoices: [(value: String, title: String)] = [
        ("gpt-6-luna", "GPT-6 Luna"),
        ("gpt-5.6-luna", "GPT-5.6 Luna"),
        ("gpt-6-sol", "GPT-6 Sol"),
    ]
    static let batchSizeChoices = [100, 200, 300]
    static let roundLimitChoices = [200, 600, 1_000, 2_000]
    static let defaultBatchSize = 200
    static let defaultRoundLimit = 600
    static let longWordLength = 8

    private enum Key {
        static let enabled = "lexiconReview.scoring.enabled.v1"
        static let model = "lexiconReview.scoring.model.v1"
        static let batchSize = "lexiconReview.scoring.batchSize.v1"
        static let roundLimit = "lexiconReview.scoring.roundLimit.v1"
        static let excludeDigits = "lexiconReview.scoring.excludeDigits.v1"
        static let excludeLatin = "lexiconReview.scoring.excludeLatin.v1"
        static let excludeLong = "lexiconReview.scoring.excludeLong.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Off by default: scoring sends real words to an external service.
    var isEnabled: Bool { defaults.bool(forKey: Key.enabled) }

    var model: String {
        let stored = defaults.string(forKey: Key.model) ?? ""
        return Self.modelChoices.contains { $0.value == stored } ? stored : Self.defaultModel
    }

    var batchSize: Int {
        let stored = defaults.integer(forKey: Key.batchSize)
        return Self.batchSizeChoices.contains(stored) ? stored : Self.defaultBatchSize
    }

    var roundLimit: Int {
        let stored = defaults.integer(forKey: Key.roundLimit)
        return Self.roundLimitChoices.contains(stored) ? stored : Self.defaultRoundLimit
    }

    var excludesDigits: Bool { flag(Key.excludeDigits, default: true) }
    var excludesLatin: Bool { flag(Key.excludeLatin, default: true) }
    var excludesLongWords: Bool { flag(Key.excludeLong, default: true) }

    func setEnabled(_ value: Bool) { set(value, Key.enabled) }
    func setModel(_ value: String) {
        guard Self.modelChoices.contains(where: { $0.value == value }) else { return }
        set(value, Key.model)
    }
    func setBatchSize(_ value: Int) {
        guard Self.batchSizeChoices.contains(value) else { return }
        set(value, Key.batchSize)
    }
    func setRoundLimit(_ value: Int) {
        guard Self.roundLimitChoices.contains(value) else { return }
        set(value, Key.roundLimit)
    }
    func setExcludesDigits(_ value: Bool) { set(value, Key.excludeDigits) }
    func setExcludesLatin(_ value: Bool) { set(value, Key.excludeLatin) }
    func setExcludesLongWords(_ value: Bool) { set(value, Key.excludeLong) }

    /// Words that stay on this Mac whatever the round size.
    func excludes(_ word: String) -> Bool {
        if excludesDigits, word.contains(where: \.isNumber) { return true }
        if excludesLatin, word.unicodeScalars.contains(where: {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0)
        }) { return true }
        if excludesLongWords, word.count > Self.longWordLength { return true }
        return false
    }

    private func flag(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    private func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

// MARK: Prompt and parsing

enum LearnedWordsScoringPrompt {
    static func prompt(for words: [String]) -> String {
        """
        你在帮一位中文输入法用户整理输入法从他的日常打字里自动学到的词。下面每行是一个学到的词或短语。

        给每个词打 1 到 5 分，只看词本身：
        5 = 最值得警惕：疑似错字、错误的组词边界、不该成为一个词的随意短语或半句话；
        4 = 很可能有问题；3 = 拿不准；2 = 大概正常；
        1 = 正常、常见或明显有用的词、名称或固定说法。

        只返回一个 block。block 的 text 里每行一个结果，格式严格为：词<TAB>分数
        逐字照抄输入中的词，不要增删、合并、改写或解释，也不要输出其他内容；title 设为 null。

        待评分的词（共 \(words.count) 个）：
        \(words.joined(separator: "\n"))
        """
    }

    /// Accepts `word<TAB>score` and, leniently, `word score`. Only words that
    /// were actually sent and scores 1–5 are kept; a word given two different
    /// scores stays unscored rather than guessed.
    static func parse(_ text: String, expected: Set<String>) -> [String: Int] {
        var result: [String: Int] = [:]
        var conflicting: Set<String> = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let separator = line.lastIndex(where: { $0 == "\t" || $0 == " " }) else { continue }
            let word = line[..<separator].trimmingCharacters(in: .whitespaces)
            let scoreText = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard expected.contains(word), let score = Int(scoreText), (1...5).contains(score) else {
                continue
            }
            if let existing = result[word], existing != score { conflicting.insert(word) }
            result[word] = score
        }
        conflicting.forEach { result[$0] = nil }
        return result
    }
}

// MARK: Storage

struct LearnedWordScore: Codable, Equatable, Sendable {
    let score: Int
    let roundID: String
    let scoredAt: Date
}

private struct LearnedWordScoresFile: Codable {
    static let currentVersion = 1
    var version = LearnedWordScoresFile.currentVersion
    var scores: [String: LearnedWordScore]
}

extension LearnedWordsLedger {
    private static let scoresFileName = "scores.json"
    private static let maxScoresBytes = 16 * 1_024 * 1_024

    private func scoresURL(for kind: UserLexiconKind) -> URL {
        dictionaryDirectory(for: kind).appendingPathComponent(Self.scoresFileName)
    }

    /// Keyed by word: the model only ever sees the word, so every code of the
    /// same word shares its score.
    func scores(for kind: UserLexiconKind) -> [String: LearnedWordScore] {
        let url = scoresURL(for: kind)
        guard fileManager.fileExists(atPath: url.path),
              let text = try? readText(url, limit: Self.maxScoresBytes),
              let file = try? JSONDecoder.learnedWordScores.decode(
                LearnedWordScoresFile.self, from: Data(text.utf8)
              ),
              file.version == LearnedWordScoresFile.currentVersion else { return [:] }
        return file.scores
    }

    func recordScores(_ scores: [String: Int], roundID: String,
                      for kind: UserLexiconKind, now: Date = Date()) throws {
        guard !scores.isEmpty else { return }
        var merged = self.scores(for: kind)
        for (word, score) in scores {
            merged[word] = LearnedWordScore(score: score, roundID: roundID, scoredAt: now)
        }
        let data = try JSONEncoder.learnedWordScores.encode(LearnedWordScoresFile(scores: merged))
        try writeAtomically(data, to: scoresURL(for: kind))
    }

    /// Unscored learned words that may leave this Mac, newest learned first,
    /// then rarely used ones, at most `limit`.
    func scoringCandidates(for kind: UserLexiconKind,
                           preferences: LearnedWordsScoringPreferences,
                           limit: Int) -> [String] {
        let scored = scores(for: kind)
        var newestDay: [String: Int] = [:]
        for (index, day) in days(for: kind).enumerated() {
            for record in day.added where newestDay[record.word] == nil {
                newestDay[record.word] = index
            }
        }
        var lowestCount: [String: Int] = [:]
        for entry in currentEntries(for: kind) {
            lowestCount[entry.word] = min(lowestCount[entry.word] ?? .max, entry.count)
        }
        let words = lowestCount.keys.filter { scored[$0] == nil && !preferences.excludes($0) }
        return words.sorted { lhs, rhs in
            let left = (newestDay[lhs] ?? .max, lowestCount[lhs] ?? .max)
            let right = (newestDay[rhs] ?? .max, lowestCount[rhs] ?? .max)
            if left != right { return left < right }
            return lhs < rhs
        }.prefix(max(limit, 0)).map { $0 }
    }
}

private extension JSONEncoder {
    static var learnedWordScores: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var learnedWordScores: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: Backend

/// One scoring request. The completion carries the model's raw text, which is
/// parsed by `LearnedWordsScoringPrompt.parse`.
protocol LearnedWordsScoringBackend: AnyObject {
    var availability: AITextProviderAvailability { get }
    @discardableResult
    func score(prompt: String, model: String,
               completion: @escaping (Result<String, AITextProviderError>) -> Void)
        -> any AITextCancellable
}

/// Uses the user's own Codex CLI connector (their ChatGPT sign-in) with a
/// per-request model and low reasoning effort, so the ordinary connector
/// defaults are not changed.
final class CodexLearnedWordsScoringBackend: LearnedWordsScoringBackend {
    private var provider: (any AITextProvider)? {
        AITextConnectorRegistry.shared.provider(for: .codexCLI)
    }

    var availability: AITextProviderAvailability {
        provider?.availability ?? .unavailable("Codex CLI 连接器不可用")
    }

    func score(prompt: String, model: String,
               completion: @escaping (Result<String, AITextProviderError>) -> Void)
        -> any AITextCancellable {
        guard let provider else {
            completion(.failure(.unavailable("Codex CLI 连接器不可用")))
            return AITextNoopCancellation()
        }
        let request = AITextProviderRequest(
            requestID: UUID(),
            sourceText: "学习词评分",
            preparedPrompt: prompt,
            modelID: model,
            reasoningEffort: "low",
            outputContract: .semanticBlocks
        )
        return provider.generate(request, onEvent: { _ in }, completion: { result in
            completion(result.map { blocks in blocks.map(\.text).joined(separator: "\n") })
        })
    }
}

// MARK: Notice

protocol LearnedWordsScoringNotifier: AnyObject {
    func scoringRoundFinished(kind: UserLexiconKind, scored: Int, unscored: Int, model: String)
}

/// Posts a one-way Mailbox notice with counts only, never the words.
final class MailboxLearnedWordsScoringNotifier: LearnedWordsScoringNotifier {
    private let store: () -> MailboxStore

    init(store: @escaping () -> MailboxStore = { MailboxStore.shared }) {
        self.store = store
    }

    static let source = MailboxSource(kind: .plugin,
                                      displayName: "词库学习",
                                      identifier: "builtin.lexicon-review",
                                      replyCapability: .localNotesOnly)

    static func body(kind: UserLexiconKind, scored: Int, unscored: Int, model: String) -> String {
        var text = "\(kind.displayName)：本轮已评分 \(scored) 个词（\(model)）。"
        if unscored > 0 { text += "另有 \(unscored) 个词这次没有拿到有效评分，仍为未评分。" }
        text += "\n\n在“词库学习 › 回顾…”里按评分查看和处理。评分只影响排序和一键删除的范围，不会自动删除任何词。"
        return text
    }

    func scoringRoundFinished(kind: UserLexiconKind, scored: Int, unscored: Int, model: String) {
        do {
            _ = try store().createInboundThread(
                source: Self.source,
                title: "学习词评分完成",
                body: Self.body(kind: kind, scored: scored, unscored: unscored, model: model)
            )
        } catch {
            IMELog.write("lexicon-review: scoring notice failed: \(error.localizedDescription)")
        }
    }
}

// MARK: Round

/// Sends one round of words in sequential batches. Each batch's scores are
/// saved as soon as they arrive, so stopping or a later failure keeps them.
final class LearnedWordsScoringRound {
    enum Outcome: Equatable {
        case finished(scored: Int, unscored: Int)
        case cancelled(scored: Int)
        case failed(scored: Int, message: String)
    }

    let id: String
    let kind: UserLexiconKind
    let words: [String]
    let model: String
    private let batches: [[String]]
    private let ledger: LearnedWordsLedger
    private let backend: LearnedWordsScoringBackend
    private let now: () -> Date
    private var current: (any AITextCancellable)?
    private var nextBatch = 0
    private var scored = 0
    private var finished = false
    private var completion: ((Outcome) -> Void)?
    private var progress: ((Int, Int) -> Void)?

    init(ledger: LearnedWordsLedger, kind: UserLexiconKind, words: [String],
         model: String, batchSize: Int, backend: LearnedWordsScoringBackend,
         now: @escaping () -> Date = Date.init) {
        self.ledger = ledger
        self.kind = kind
        self.words = words
        self.model = model
        self.backend = backend
        self.now = now
        let size = max(batchSize, 1)
        batches = stride(from: 0, to: words.count, by: size).map {
            Array(words[$0..<min($0 + size, words.count)])
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        id = formatter.string(from: now())
    }

    var batchCount: Int { batches.count }

    /// `progress(done, total)` and `completion` run on the main queue.
    func start(progress: @escaping (Int, Int) -> Void,
               completion: @escaping (Outcome) -> Void) {
        self.progress = progress
        self.completion = completion
        runNext()
    }

    func cancel() {
        guard !finished else { return }
        current?.cancel()
        finish(.cancelled(scored: scored))
    }

    private func runNext() {
        guard !finished else { return }
        guard nextBatch < batches.count else {
            finish(.finished(scored: scored, unscored: words.count - scored))
            return
        }
        progress?(nextBatch, batches.count)
        let batch = batches[nextBatch]
        let prompt = LearnedWordsScoringPrompt.prompt(for: batch)
        current = backend.score(prompt: prompt, model: model) { [weak self] result in
            let deliver: () -> Void = { self?.batchFinished(batch, result) }
            if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
        }
    }

    private func batchFinished(_ batch: [String], _ result: Result<String, AITextProviderError>) {
        guard !finished else { return }
        switch result {
        case .success(let text):
            let parsed = LearnedWordsScoringPrompt.parse(text, expected: Set(batch))
            do {
                try ledger.recordScores(parsed, roundID: id, for: kind, now: now())
                scored += parsed.count
            } catch {
                finish(.failed(scored: scored, message: error.localizedDescription))
                return
            }
            nextBatch += 1
            runNext()
        case .failure(.cancelled):
            finish(.cancelled(scored: scored))
        case .failure(let error):
            finish(.failed(scored: scored, message: error.userFacingMessage))
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        current = nil
        progress?(min(nextBatch, batches.count), batches.count)
        let completion = self.completion
        self.completion = nil
        self.progress = nil
        completion?(outcome)
    }
}
