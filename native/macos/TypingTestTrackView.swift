import AppKit

/// Double-track practice surface. The real input text view lays typed text out
/// in fixed-width cells, one row per `columns` characters; above every typed
/// row the matching row of the source text is drawn in the same cells. Both
/// tracks therefore stay column-for-column aligned, and the input method, marked
/// text and candidate window all work on ordinary NSTextView text.
///
/// Chinese text keeps its paragraphs: each starts on a new row, indented two
/// cells. The typed row mirrors that with real paragraph breaks that the view
/// inserts itself once a paragraph is complete; line breaks are never scored.
final class TypingTestTrackTextView: TypingTestTextView, NSTextStorageDelegate {
    static let fontSize: CGFloat = 22
    static let cellWidth: CGFloat = 28
    static let paragraphIndentCells = 2
    private let trackFont = NSFont.systemFont(ofSize: TypingTestTrackTextView.fontSize)
    private let sourceSlot: CGFloat = 32        // source cell, directly above its typed cell
    private let rowGap: CGFloat = 14            // air between one source/typed pair and the next
    private let topPadding: CGFloat = 10
    private let bottomPadding: CGFloat = 24
    private let glyphShift = (TypingTestTrackTextView.cellWidth - TypingTestTrackTextView.fontSize) / 2
    private var lineHeight: CGFloat = 28
    private var advanceCache: [String: CGFloat] = [:]
    private var correctingKerning = false       // our own kern edits must not re-enter the storage delegate
    private var kernDirtyFrom: Int?             // first UTF-16 offset whose neighbours changed
    private(set) var columns = 20

    private(set) var sourceCharacters: [Character] = []
    private var paragraphEnds: [Int] = []       // exclusive end of every paragraph, in source offsets
    private var indentCells = 0
    private var sourceStates: [TypingTestCharacterState] = []
    private var typedCorrectness: [Bool] = []

    private struct Row { var start: Int; var end: Int; var firstColumn: Int }
    private var rowCache: (key: [Int], rows: [Row])?

    /// Draws the character grid in both tracks.
    var showsCells = true { didSet { if oldValue != showsCells { needsDisplay = true } } }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configureTrack()
    }
    required init?(coder: NSCoder) { nil }

    private func configureTrack() {
        font = trackFont
        lineHeight = ceil(layoutManager?.defaultLineHeight(for: trackFont) ?? 28)
        backgroundColor = .clear      // the card behind supplies the surface
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textStorage?.delegate = self
        applyContainerGeometry(width: frame.width)
        typingAttributes = trackAttributes()
        setAccessibilityLabel("文章跟打输入区，上行为原文，下行为输入")
        setAccessibilityHelp("每个格子对应原文的一个字。组字中的编码不判错；不支持粘贴或拖入文字。")
    }

    // MARK: Source

    func setSource(_ text: String, states: [TypingTestCharacterState], typedCorrectness: [Bool]) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
        var characters: [Character] = []
        var ends: [Int] = []
        for line in lines {
            characters.append(contentsOf: line)
            ends.append(characters.count)
        }
        let changed = characters != sourceCharacters || ends != paragraphEnds
        sourceCharacters = characters
        paragraphEnds = ends
        sourceStates = states
        self.typedCorrectness = typedCorrectness
        if changed {
            let indent = TypingTestPassageSplitter.language(of: String(characters)) == .chinese
                ? Self.paragraphIndentCells : 0
            if indent != indentCells {
                indentCells = indent
                typingAttributes = trackAttributes()
                if let storage = textStorage, storage.length > 0 {
                    storage.addAttribute(.paragraphStyle, value: trackAttributes()[.paragraphStyle]!,
                                         range: NSRange(location: 0, length: storage.length))
                }
            }
            rowCache = nil
            updateGeometry()
        }
        syncParagraphBreaks()
        needsDisplay = true
        scrollCaretIntoView()
    }

    // MARK: Layout of the source rows

    /// Rows of the source (first row of a paragraph starts `indentCells` in). `total`
    /// may exceed the source when more was typed than the text holds; the surplus
    /// continues the last paragraph, exactly as the typed row lays it out.
    private func layoutRows(total: Int) -> [Row] {
        let key = [columns, indentCells, total, sourceCharacters.count, paragraphEnds.count]
        if let cache = rowCache, cache.key == key { return cache.rows }
        var ends = paragraphEnds
        if ends.isEmpty { ends = [max(total, 0)] } else if total > (ends.last ?? 0) { ends[ends.count - 1] = total }
        var rows: [Row] = []
        var start = 0
        for end in ends where end > start {
            var index = start
            var first = true
            while index < end {
                let indent = first ? indentCells : 0
                let take = min(max(1, columns - indent), end - index)
                rows.append(Row(start: index, end: index + take, firstColumn: indent))
                index += take
                first = false
            }
            start = end
        }
        if rows.isEmpty { rows = [Row(start: 0, end: 0, firstColumn: indentCells)] }
        rowCache = (key, rows)
        return rows
    }

    private func rowIndex(of index: Int, in rows: [Row]) -> Int? {
        var low = 0, high = rows.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if index < rows[mid].start { high = mid - 1 }
            else if index >= rows[mid].end { low = mid + 1 }
            else { return mid }
        }
        return nil
    }

    /// Committed characters only: composition (marked text) never moves the cursor cell or the rows.
    private var typedCount: Int {
        let native = string as NSString
        guard native.length > 0 else { return 0 }
        var text = native as String
        let marked = markedRange()
        if hasMarkedText(), marked.location != NSNotFound, NSMaxRange(marked) <= native.length {
            text = native.replacingCharacters(in: marked, with: "")
        }
        return TypingTestSession.normalized(text).count
    }

    // MARK: Geometry

    private var rowPitch: CGFloat { lineHeight + sourceSlot + rowGap }
    private func typedRowTop(_ row: Int) -> CGFloat { topPadding + sourceSlot + CGFloat(row) * rowPitch }

    override var intrinsicContentSize: NSSize {
        let rows = layoutRows(total: max(sourceCharacters.count, typedCount)).count
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: topPadding + sourceSlot + CGFloat(rows) * rowPitch + bottomPadding)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyContainerGeometry(width: newSize.width)
    }

    private func applyContainerGeometry(width: CGFloat) {
        guard width > 0 else { return }
        let cell = Self.cellWidth
        let fitted = max(6, Int(floor((width - 24) / cell)))
        let wrapped = fitted != columns
        columns = fitted
        let inner = CGFloat(fitted) * cell
        textContainer?.size = NSSize(width: inner + 0.5, height: .greatestFiniteMagnitude)
        textContainerInset = NSSize(width: max(0, floor((width - inner) / 2)) + glyphShift, height: topPadding + sourceSlot)
        if wrapped { rowCache = nil; updateGeometry() }
    }

    private func updateGeometry() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Cell metrics applied to typed text

    private func trackAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineSpacing = sourceSlot + rowGap
        style.firstLineHeadIndent = CGFloat(indentCells) * Self.cellWidth
        return [.font: trackFont, .paragraphStyle: style, .foregroundColor: RimeUI.textPrimary]
    }

    /// Distance from the start of `piece` to the start of whatever follows it, as
    /// the text system sets it. Measured against the next character because the
    /// system adds Chinese-Latin spacing, squeezes adjacent CJK punctuation and
    /// kerns pairs; a lone measurement misses all three and the rows drift.
    private func advance(of piece: String, before next: String?) -> CGFloat {
        let key = piece + "\u{0}" + (next ?? "")
        if let cached = advanceCache[key] { return cached }
        func width(_ text: String) -> CGFloat { NSAttributedString(string: text, attributes: [.font: trackFont]).size().width }
        let value = max(1, next.map { width(piece + $0) - width($0) } ?? width(piece))
        advanceCache[key] = value
        return value
    }

    /// Pads every character (typed text and marked text alike) to one cell. The
    /// neighbours of an edit are re-padded too, since their advance depends on it.
    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard !correctingKerning, editedMask.contains(.editedCharacters) || editedMask.contains(.editedAttributes),
              textStorage.length > 0 else { return }
        let whole = NSRange(location: 0, length: textStorage.length)
        let base = trackAttributes()
        textStorage.addAttribute(.paragraphStyle, value: base[.paragraphStyle]!, range: whole)
        guard NSMaxRange(editedRange) <= textStorage.length else { return }
        let native = textStorage.string as NSString
        if editedRange.length > 0 { textStorage.addAttribute(.font, value: trackFont, range: editedRange) }
        let lower = editedRange.location > 0 ? native.rangeOfComposedCharacterSequence(at: editedRange.location - 1).location : 0
        let upper = min(native.length, NSMaxRange(editedRange) + 1)
        let span = NSRange(location: lower, length: NSMaxRange(native.rangeOfComposedCharacterSequence(at: upper - 1)) - lower)
        kernDirtyFrom = min(kernDirtyFrom ?? lower, lower)
        native.enumerateSubstrings(in: span, options: [.byComposedCharacterSequences, .substringNotRequired]) { _, range, _, _ in
            let piece = native.substring(with: range)
            if piece == "\n" { textStorage.removeAttribute(.kern, range: range); return }
            var next: String?
            if NSMaxRange(range) < native.length {
                let following = native.substring(with: native.rangeOfComposedCharacterSequence(at: NSMaxRange(range)))
                if following != "\n" { next = following }
            }
            textStorage.addAttribute(.kern, value: max(0, Self.cellWidth - self.advance(of: piece, before: next)), range: range)
        }
    }

    /// Closed-loop correction: lay the typed text out, read where every character
    /// really starts, and adjust its pad until the next one starts exactly one
    /// cell later. Estimates from measuring strings cannot capture every
    /// context-dependent adjustment, the layout itself can.
    private func correctKerning() {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer,
              let dirty = kernDirtyFrom else { return }
        kernDirtyFrom = nil
        let native = storage.string as NSString
        guard native.length > 1 else { return }
        correctingKerning = true
        defer { correctingKerning = false }
        let start = native.rangeOfComposedCharacterSequence(at: min(dirty, native.length - 1)).location
        for _ in 0..<4 {
            layout.ensureLayout(for: container)
            var previous: (range: NSRange, x: CGFloat, y: CGFloat)?
            var fixes: [(NSRange, CGFloat)] = []
            native.enumerateSubstrings(in: NSRange(location: start, length: native.length - start),
                                       options: [.byComposedCharacterSequences, .substringNotRequired]) { _, range, _, _ in
                let glyph = layout.glyphIndexForCharacter(at: range.location)
                guard layout.isValidGlyphIndex(glyph) else { previous = nil; return }
                let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let current = (range: range, x: line.minX + layout.location(forGlyphAt: glyph).x, y: line.minY)
                defer { previous = current }
                guard let before = previous, abs(before.y - current.y) < 1 else { return }
                if native.substring(with: before.range) == "\n" { return }
                let error = Self.cellWidth - (current.x - before.x)
                guard abs(error) > 0.2 else { return }
                let kern = (storage.attribute(.kern, at: before.range.location, effectiveRange: nil) as? CGFloat) ?? 0
                fixes.append((before.range, max(0, kern + error)))
            }
            guard !fixes.isEmpty else { break }
            storage.beginEditing()
            for (range, kern) in fixes { storage.addAttribute(.kern, value: kern, range: range) }
            storage.endEditing()
        }
    }

    // MARK: Paragraph breaks in the typed row

    /// Keeps exactly one break at the end of the typed text when a paragraph of
    /// the source has just been completed, and none otherwise. Done on the text
    /// storage so it never reaches the scorer, and never during composition.
    private func syncParagraphBreaks() {
        guard !hasMarkedText(), let storage = textStorage else { return }
        let native = storage.string as NSString
        let typed = TypingTestSession.normalized(storage.string).count
        let wantsBreak = typed > 0 && typed < sourceCharacters.count && paragraphEnds.contains(typed)
        let hasBreak = native.length > 0 && native.character(at: native.length - 1) == 10
        guard wantsBreak != hasBreak else { return }
        let caretAtEnd = selectedRange().location >= native.length
        if wantsBreak {
            storage.replaceCharacters(in: NSRange(location: native.length, length: 0), with: "\n")
        } else {
            storage.replaceCharacters(in: NSRange(location: native.length - 1, length: 1), with: "")
        }
        if caretAtEnd { setSelectedRange(NSRange(location: storage.length, length: 0)) }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Backspace right after an automatic paragraph break takes the break and the
    /// character before it together; the break comes back when that point is reached again.
    override func deleteBackward(_ sender: Any?) {
        let native = string as NSString
        if !hasMarkedText(), selectedRange().length == 0, selectedRange().location == native.length,
           native.length >= 2, native.character(at: native.length - 1) == 10 {
            setSelectedRange(NSRange(location: native.length - 2, length: 2))
        }
        super.deleteBackward(sender)
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawTracks(in: rect)
    }

    private func drawTracks(in rect: NSRect) {
        guard !sourceCharacters.isEmpty || !string.isEmpty else { return }
        let cell = Self.cellWidth
        let left = textContainerInset.width - glyphShift
        let typed = typedCount
        let total = max(sourceCharacters.count, typed)
        let layout = layoutRows(total: total)
        let first = max(0, Int(floor((rect.minY - typedRowTop(0)) / rowPitch)) - 1)
        guard first < layout.count else { return }
        let last = min(layout.count - 1, Int(ceil((rect.maxY - typedRowTop(0)) / rowPitch)) + 1)
        guard first <= last else { return }
        let gridLine = RimeUI.border.withAlphaComponent(0.9)
        let accent = RimeUI.accentGreen
        let danger = RimeUI.dangerFillColor
        let cursorRow = typed < sourceCharacters.count ? rowIndex(of: typed, in: layout) : nil
        for rowNumber in first...last {
            let row = layout[rowNumber]
            let typedTop = typedRowTop(rowNumber)
            let sourceTop = typedTop - sourceSlot
            let typedHeight = lineHeight + 2
            let cells = row.firstColumn + (row.end - row.start)
            let block = NSRect(x: left, y: sourceTop, width: CGFloat(cells) * cell, height: sourceSlot + typedHeight)

            if showsCells && row.firstColumn > 0 {
                // The paragraph indent: empty cells, faintly shaded so the gap reads as deliberate.
                gridLine.withAlphaComponent(0.18).setFill()
                NSRect(x: left, y: sourceTop, width: CGFloat(row.firstColumn) * cell, height: block.height).fill()
            }
            for index in row.start..<row.end {
                let column = row.firstColumn + (index - row.start)
                let x = left + CGFloat(column) * cell
                let sourceCell = NSRect(x: x, y: sourceTop, width: cell, height: sourceSlot)
                let typedCell = NSRect(x: x, y: typedTop, width: cell, height: typedHeight)
                let state: TypingTestCharacterState = index < sourceStates.count ? sourceStates[index] : .pending
                if index < sourceCharacters.count {
                    switch state {
                    case .correct: accent.withAlphaComponent(0.13).setFill(); sourceCell.fill()
                    case .incorrect, .omitted: danger.withAlphaComponent(0.18).setFill(); sourceCell.fill()
                    case .pending: break
                    }
                }
                if index < typedCorrectness.count && !typedCorrectness[index] {
                    danger.withAlphaComponent(0.18).setFill()
                    typedCell.fill()
                }
            }
            if showsCells {
                // One continuous grid per row: the source cells sit directly on the typed cells.
                gridLine.setStroke()
                let path = NSBezierPath()
                path.lineWidth = 1
                for column in 0...cells {
                    let x = (left + CGFloat(column) * cell).rounded() + 0.5
                    path.move(to: NSPoint(x: x, y: block.minY))
                    path.line(to: NSPoint(x: x, y: block.maxY))
                }
                for y in [block.minY, typedTop, block.maxY] {
                    let line = y.rounded() + 0.5
                    path.move(to: NSPoint(x: block.minX, y: line))
                    path.line(to: NSPoint(x: block.maxX, y: line))
                }
                path.stroke()
            }
            if cursorRow == rowNumber {
                let column = row.firstColumn + (typed - row.start)
                let box = NSRect(x: left + CGFloat(column) * cell, y: typedTop, width: cell, height: typedHeight)
                accent.setStroke()
                let outline = NSBezierPath(rect: box.insetBy(dx: 1, dy: 1))
                outline.lineWidth = 1.5
                outline.stroke()
            }
            for index in row.start..<min(row.end, sourceCharacters.count) {
                let column = row.firstColumn + (index - row.start)
                let state: TypingTestCharacterState = index < sourceStates.count ? sourceStates[index] : .pending
                let color: NSColor
                switch state {
                case .correct: color = RimeUI.accentTextColor
                case .incorrect, .omitted: color = RimeUI.dangerTextColor
                case .pending: color = RimeUI.textMuted
                }
                let glyph = NSAttributedString(string: String(sourceCharacters[index]),
                                               attributes: [.font: trackFont, .foregroundColor: color])
                glyph.draw(at: NSPoint(x: left + CGFloat(column) * cell + glyphShift,
                                       y: sourceTop + (sourceSlot - lineHeight) / 2))
            }
        }
    }

    // MARK: Composition

    /// Marked text changes do not always pass through didChangeText; keep the
    /// composition placeholder padded to its cell as well.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        correctKerning()
    }

    /// The input method anchors its candidate panel here. While composing, that is
    /// the grid cell the next character will land in, taken from the same row model
    /// the tracks are drawn from. The text system would report the end of the
    /// previous row (zero width) whenever a full row makes the composition wrap,
    /// so the panel jumped right and back at every row end.
    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard hasMarkedText(), let window, let cell = cursorCell() else {
            return super.firstRect(forCharacterRange: range, actualRange: actualRange)
        }
        actualRange?.pointee = markedRange()
        return window.convertToScreen(convert(cell, to: nil))
    }

    /// The cell the next committed character goes into, in view coordinates; nil past the source.
    private func cursorCell() -> NSRect? {
        let layout = layoutRows(total: max(sourceCharacters.count, typedCount))
        let typed = typedCount
        guard let row = rowIndex(of: typed, in: layout) else { return nil }
        let column = layout[row].firstColumn + (typed - layout[row].start)
        return NSRect(x: textContainerInset.width - glyphShift + CGFloat(column) * Self.cellWidth, y: typedRowTop(row),
                      width: Self.cellWidth, height: lineHeight)
    }

    // MARK: Behaviour

    /// A typed line break would desynchronise the rows from the source.
    override func insertNewline(_ sender: Any?) { NSSound.beep() }
    override func insertLineBreak(_ sender: Any?) { NSSound.beep() }

    override func didChangeText() {
        super.didChangeText()
        syncParagraphBreaks()
        correctKerning()
        invalidateIntrinsicContentSize()
        needsDisplay = true
        scrollCaretIntoView()
    }

    /// Keeps the row being typed (and the source row above it) in view.
    func scrollCaretIntoView() {
        let layout = layoutRows(total: max(sourceCharacters.count, typedCount))
        let index = min(typedCount, max(0, layout.last?.end ?? 1) - 1)
        let row = rowIndex(of: max(0, index), in: layout) ?? max(0, layout.count - 1)
        let top = typedRowTop(row) - sourceSlot
        scrollToVisible(NSRect(x: 0, y: top - 8, width: 1, height: rowPitch + 16))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        textColor = RimeUI.textPrimary
        needsDisplay = true
    }

    // MARK: Smoke hooks

    /// Top of every laid-out typed line, in view coordinates.
    var smokeTypedLineTops: [CGFloat] {
        guard let layout = layoutManager, let container = textContainer else { return [] }
        layout.ensureLayout(for: container)
        var tops: [CGFloat] = []
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, _, _, _, _ in
            tops.append(rect.minY + self.textContainerInset.height)
        }
        return tops
    }
    /// (start, end, first column) of every source row.
    var smokeRows: [(Int, Int, Int)] {
        layoutRows(total: max(sourceCharacters.count, typedCount)).map { ($0.start, $0.end, $0.firstColumn) }
    }
    var smokeIndentCells: Int { indentCells }
    /// The cell the next character goes into, in view coordinates.
    var smokeCursorCell: NSRect? { cursorCell() }
    /// Worst distance, in cells, between where a typed character sits and the cell it belongs to.
    var smokeWorstCellDrift: CGFloat {
        guard let layout = layoutManager, let container = textContainer else { return 0 }
        layout.ensureLayout(for: container)
        let native = string as NSString
        var worst: CGFloat = 0, column = 0, lineY: CGFloat?, base: CGFloat = 0
        native.enumerateSubstrings(in: NSRange(location: 0, length: native.length), options: .byComposedCharacterSequences) { piece, range, _, _ in
            guard piece != "\n" else { lineY = nil; return }
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let x = line.minX + layout.location(forGlyphAt: glyph).x
            if lineY != line.minY { lineY = line.minY; base = x; column = 0 }
            worst = max(worst, abs((x - base) / Self.cellWidth - CGFloat(column)))
            column += 1
        }
        return worst
    }
    /// Top of the source row the next character belongs to, in view coordinates.
    var smokeCaretRowTop: CGFloat {
        let layout = layoutRows(total: max(sourceCharacters.count, typedCount))
        let row = rowIndex(of: min(typedCount, max(0, (layout.last?.end ?? 1) - 1)), in: layout) ?? max(0, layout.count - 1)
        return typedRowTop(row) - sourceSlot
    }
    var smokeTypedRowTops: [CGFloat] {
        (0..<layoutRows(total: max(sourceCharacters.count, typedCount)).count).map(typedRowTop)
    }
}
