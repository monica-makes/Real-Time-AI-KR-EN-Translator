import SwiftUI

/// How chat text appears as it streams in. Word fade is the default; the others are debug
/// options (Debug Controls > CHAT TEXT, or launch with `-debugChatTextReveal chunkFade`).
enum ChatTextReveal: String, CaseIterable {
    /// Each word fades in over 60ms, one after another from left to right
    case wordFade
    /// Each newly arrived word or phrase fades in over 30ms, all at once
    case chunkFade
    /// No fade
    case instant

    static let storageKey = "debugChatTextReveal"
    static let defaultStyle: ChatTextReveal = .wordFade

    /// The stored debug choice; release builds always use the default
    static func resolved(_ rawValue: String) -> ChatTextReveal {
        return defaultStyle
    }

    var label: String {
        switch self {
        case .wordFade: return "Word 60ms"
        case .chunkFade: return "Fade 30ms"
        case .instant: return "Instant"
        }
    }

    /// How long one word takes to fade in
    var fadeDuration: TimeInterval {
        switch self {
        case .wordFade: return 0.06
        case .chunkFade: return 0.03
        case .instant: return 0
        }
    }

    /// Delay between one new word starting to fade in and the next
    var stagger: TimeInterval {
        self == .wordFade ? fadeDuration : 0
    }

    /// Word fade wipes each word in from its left edge; chunk fade fades the whole chunk evenly
    var sweepsLeftToRight: Bool { self == .wordFade }
}

/// Text that fades in its new words as it grows, for live captions and translations.
///
/// Words already shown stay put when the text changes; words that are new (or were revised)
/// fade in per `reveal`, starting `startDelay` after they arrive. Layout never moves: invisible
/// words still take their space, so a line wraps (and a chat bubble grows) the moment its word
/// arrives, and the word fills in after. Only animates while a word is fading.
struct RevealingText: View {
    let text: String
    let font: Font
    let color: Color
    let lineSpacing: CGFloat
    let reveal: ChatTextReveal
    /// How long new words wait before they start fading in
    let startDelay: TimeInterval

    /// The text split into words, each with its trailing whitespace
    @State private var words: [String]
    /// Leading words that are fully shown
    @State private var settled: Int
    /// When each word after `settled` starts fading in
    @State private var starts: [Date]

    init(text: String, font: Font, color: Color, lineSpacing: CGFloat = 0, reveal: ChatTextReveal,
         startDelay: TimeInterval = 0) {
        self.text = text
        self.font = font
        self.color = color
        self.lineSpacing = lineSpacing
        self.reveal = reveal
        self.startDelay = startDelay
        // The first words fade in too: a new bubble or translation row is new text
        let words = Self.words(in: text)
        let starts = Self.schedule(words.count, after: nil, delay: startDelay, style: reveal)
        _words = State(initialValue: words)
        _settled = State(initialValue: reveal == .instant ? words.count : 0)
        _starts = State(initialValue: reveal == .instant ? [] : starts)
    }

    private var finishTime: Date? {
        starts.last.map { $0.addingTimeInterval(reveal.fadeDuration) }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: starts.isEmpty)) { timeline in
            styledText
                .textRenderer(WordRevealRenderer(
                    starts: starts.map(\.timeIntervalSinceReferenceDate),
                    now: timeline.date.timeIntervalSinceReferenceDate,
                    duration: reveal.fadeDuration,
                    sweep: reveal.sweepsLeftToRight
                ))
        }
        .lineSpacing(lineSpacing)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: text) { _, newText in
            update(to: newText)
        }
        .task(id: finishTime) {
            // Once the last word is in, draw everything as plain text and stop the timeline
            guard let finishTime else { return }
            let remaining = finishTime.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            settled = words.count
            starts = []
        }
    }

    /// Shown words as one plain run, then each fading word as its own run the renderer can find
    private var styledText: Text {
        var result = Text(verbatim: words[..<settled].joined())
        for (index, word) in words[settled...].enumerated() {
            result = Text("\(result)\(Text(verbatim: word).customAttribute(FadingWord(index: index)))")
        }
        return result
            .font(font)
            .foregroundStyle(color)
    }

    private func update(to newText: String) {
        let newWords = Self.words(in: newText)

        // Words up to the first change keep their state; the rest fade in as new. A last word that
        // only grew ("날씨" -> "날씨가" in a live caption) keeps its state too, so it doesn't flicker.
        var unchanged = 0
        while unchanged < min(words.count, newWords.count), Self.sameWord(words[unchanged], newWords[unchanged]) {
            unchanged += 1
        }
        if unchanged == words.count - 1, unchanged < newWords.count,
           Self.letters(newWords[unchanged]).hasPrefix(Self.letters(words[unchanged])),
           !Self.letters(words[unchanged]).isEmpty {
            unchanged += 1
        }
        let keptStarts = unchanged > settled ? Array(starts.prefix(unchanged - settled)) : []
        settled = min(settled, unchanged)
        words = newWords

        guard reveal != .instant else {
            settled = newWords.count
            starts = []
            return
        }
        starts = keptStarts + Self.schedule(newWords.count - unchanged, after: keptStarts.last, delay: startDelay, style: reveal)
    }

    /// Start times for `count` new words: from `delay` after now, each `stagger` after the one before
    private static func schedule(_ count: Int, after previous: Date?, delay: TimeInterval, style: ChatTextReveal) -> [Date] {
        guard count > 0 else { return [] }
        let first = Date().addingTimeInterval(delay)
        var next = max(first, previous.map { $0.addingTimeInterval(style.stagger) } ?? first)
        var result: [Date] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(next)
            next = next.addingTimeInterval(style.stagger)
        }
        return result
    }

    static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var afterSpace = false
        for character in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if character.isWhitespace {
                afterSpace = true
            } else if afterSpace {
                words.append(current)
                current = ""
                afterSpace = false
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// Same word, ignoring punctuation and capitals (a final adds "." and "," to its interim)
    private static func sameWord(_ a: String, _ b: String) -> Bool {
        let (x, y) = (letters(a), letters(b))
        return x.isEmpty && y.isEmpty
            ? a.trimmingCharacters(in: .whitespaces) == b.trimmingCharacters(in: .whitespaces)
            : x == y
    }

    private static func letters(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// Marks a word that is still fading in: its position among the fading words
private struct FadingWord: TextAttribute {
    let index: Int
}

/// Draws shown words as-is and fading words at their current opacity. With `sweep`, a word
/// wipes in from its left edge with a soft gradient rather than fading evenly.
private struct WordRevealRenderer: TextRenderer {
    /// Fade start per fading word (seconds since the reference date)
    let starts: [TimeInterval]
    let now: TimeInterval
    let duration: TimeInterval
    let sweep: Bool

    /// Width of the wipe's soft edge, as a fraction of the word
    private static let softness = 0.8

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let word = run[FadingWord.self], word.index < starts.count else {
                    context.draw(run)
                    continue
                }
                let progress = duration > 0 ? min(max((now - starts[word.index]) / duration, 0), 1) : 1
                if progress >= 1 {
                    context.draw(run)
                } else if progress > 0 {
                    draw(run, progress: progress, in: context)
                }
            }
        }
    }

    private func draw(_ run: Text.Layout.Run, progress: Double, in context: GraphicsContext) {
        guard sweep else {
            var faded = context
            faded.opacity = progress
            faded.draw(run)
            return
        }
        let bounds = run.typographicBounds.rect
        let softness = Self.softness
        for slice in run {
            let position = (slice.typographicBounds.rect.midX - bounds.minX) / max(bounds.width, 1)
            var faded = context
            faded.opacity = min(max((progress * (1 + softness) - position) / softness, 0), 1)
            faded.draw(slice)
        }
    }
}
