import Foundation

/// Block-level markdown splitter for incremental rendering. Inline styling is delegated to
/// `AttributedString(markdown:)`; an unterminated code fence is still rendered as code so the
/// block stabilizes as soon as the closing fence streams in.
public enum MarkdownBlock: Hashable, Identifiable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, text: String, closed: Bool)
    case bullets([String])
    case numbered([String])
    case quote(String)
    case rule

    public var id: Int { hashValue }
}

public enum MarkdownParser {
    public static func blocks(from text: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var quote: [String] = []
        var code: [String]? = nil
        var codeLang: String? = nil
        var fence = ""

        func flushParagraph() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushLists() {
            if !bullets.isEmpty { out.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { out.append(.numbered(numbered)); numbered = [] }
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        func flushAll() { flushParagraph(); flushLists() }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var codeLines = code {
                if trimmed.hasPrefix(fence) {
                    out.append(.code(language: codeLang, text: codeLines.joined(separator: "\n"), closed: true))
                    code = nil; codeLang = nil
                } else {
                    codeLines.append(line); code = codeLines
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                codeLang = lang.isEmpty ? nil : lang
                code = []
                continue
            }
            if trimmed.isEmpty { flushAll(); continue }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flushAll(); out.append(.rule); continue }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                if level <= 6, trimmed.dropFirst(level).hasPrefix(" ") {
                    flushAll(); out.append(.heading(level: level, text: trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces))); continue
                }
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                if !numbered.isEmpty { out.append(.numbered(numbered)); numbered = [] }
                bullets.append(String(trimmed.dropFirst(2))); continue
            }
            if let dot = trimmed.firstIndex(of: "."), trimmed[trimmed.startIndex..<dot].allSatisfy(\.isNumber), !trimmed[trimmed.startIndex..<dot].isEmpty,
               trimmed[dot...].dropFirst().hasPrefix(" ") {
                flushParagraph()
                if !bullets.isEmpty { out.append(.bullets(bullets)); bullets = [] }
                numbered.append(trimmed[dot...].dropFirst(2).description); continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)); continue
            }
            if !bullets.isEmpty, line.hasPrefix("  ") { bullets[bullets.count - 1] += " " + trimmed; continue }
            if !numbered.isEmpty, line.hasPrefix("  ") { numbered[numbered.count - 1] += " " + trimmed; continue }
            flushLists()
            paragraph.append(line)
        }
        if let codeLines = code { out.append(.code(language: codeLang, text: codeLines.joined(separator: "\n"), closed: false)) }
        flushAll()
        return out
    }

    /// Inline markdown → AttributedString, falling back to plain text.
    public static func inline(_ text: String) -> AttributedString {
        if let a = try? AttributedString(markdown: text, options: .init(allowsExtendedAttributes: true, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)) {
            return a
        }
        return AttributedString(text)
    }
}
