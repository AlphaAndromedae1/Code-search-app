import Foundation
import SwiftUI

struct SearchQuery: Equatable {
    /// FTS MATCH expression.
    let expression: String
    /// Plain strings to highlight on the PDF page.
    let highlightTerms: [String]
    /// For clause / rule numbers: the same query with the number's last part as a prefix, so
    /// "4.7.4" also finds text where the PDF runs it into the next word ("4.7.4Appliances").
    var lenientExpression: String? = nil
    /// Clause / rule numbers typed (e.g. "4.7.4"), as typed.
    var sectionNumbers: [String] = []
}

/// Turns what the user typed into a safe full-text query.
///
/// - `9.10.14.5` becomes the exact token sequence "9 10 14 5" and `26-700` becomes "26 700",
///   so article and rule numbers match precisely.
/// - `smoke alarm` becomes `smoke* alarm*` (both words, word-starts allowed).
/// - `"means of egress"` stays an exact phrase.
enum QueryBuilder {
    static func build(_ input: String, matchAll: Bool = true) -> SearchQuery? {
        var terms: [(text: String, quoted: Bool)] = []
        var current = ""
        var inQuotes = false

        func flush(quoted: Bool) {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { terms.append((text: trimmed, quoted: quoted)) }
            current = ""
        }

        for character in input {
            if character == "\"" || character == "\u{201C}" || character == "\u{201D}" {
                flush(quoted: inQuotes)
                inQuotes.toggle()
            } else if character.isWhitespace && !inQuotes {
                flush(quoted: false)
            } else {
                current.append(character)
            }
        }
        flush(quoted: inQuotes)

        var expression = ""
        var lenient = ""
        var sections: [String] = []
        var highlights: [String] = []
        var pendingOr = false
        for term in terms {
            // A bare uppercase OR between words means "either".
            if !term.quoted && term.text == "OR" {
                pendingOr = !expression.isEmpty
                continue
            }
            let tokens = tokenize(term.text)
            guard !tokens.isEmpty else { continue }
            let part: String
            var lenientPart: String
            if tokens.count == 1 && !term.quoted {
                let token = tokens[0]
                let isNumber = token.allSatisfy { $0.isNumber }
                part = (isNumber || token.count < 3) ? "\"\(token)\"" : "\(token)*"
                lenientPart = part
            } else {
                part = "\"" + tokens.joined(separator: " ") + "\""
                lenientPart = part
                // A clause or rule number like 4.7.4 or 26-700.
                if !term.quoted && tokens.count >= 2 && tokens.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                    lenientPart = part + " *"
                    sections.append(term.text.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)))
                }
            }
            if !expression.isEmpty {
                let joiner = (pendingOr || !matchAll) ? " OR " : " "
                expression += joiner
                lenient += joiner
            }
            expression += part
            lenient += lenientPart
            pendingOr = false

            let display = term.text.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            if !display.isEmpty { highlights.append(display) }
        }
        guard !expression.isEmpty else { return nil }
        return SearchQuery(
            expression: expression,
            highlightTerms: highlights,
            lenientExpression: sections.isEmpty ? nil : lenient,
            sectionNumbers: sections
        )
    }

    /// Splits on anything that isn't a letter or digit, matching SQLite's unicode61 tokenizer.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

enum SnippetFormatter {
    /// Converts an FTS snippet with private-use markers into styled text.
    static func attributed(_ raw: String) -> AttributedString {
        let cleaned = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        var output = AttributedString()
        var rest = Substring(cleaned)
        while let open = rest.range(of: SearchIndex.markStart) {
            output.append(AttributedString(String(rest[..<open.lowerBound])))
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: SearchIndex.markEnd) else {
                rest = afterOpen
                break
            }
            var match = AttributedString(String(afterOpen[..<close.lowerBound]))
            match.inlinePresentationIntent = .stronglyEmphasized
            match.backgroundColor = Color.yellow.opacity(0.35)
            output.append(match)
            rest = afterOpen[close.upperBound...]
        }
        output.append(AttributedString(rest.replacingOccurrences(of: SearchIndex.markEnd, with: "")))
        return output
    }
}
