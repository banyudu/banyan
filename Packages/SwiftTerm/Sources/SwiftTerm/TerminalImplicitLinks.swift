import Foundation

extension Terminal {
    /// Implicit references shared by terminal cells and native text renderers.
    /// Ranges use the original string so callers can retain their own styling.
    public static func implicitLinkRanges(in text: String) -> [Range<String.Index>] {
        guard let regex = ghosttyImplicitLinkRegex else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.range.length > 0, let range = Range(match.range, in: text) else { return nil }
            // ICU cannot express Ghostty's variable-length dollar lookbehind.
            if range.lowerBound > text.startIndex, text[text.index(before: range.lowerBound)] == "$" {
                return nil
            }
            return range
        }
    }

    // Ghostty-style URL/path pattern adapted for ICU regex.
    // Oniguruma uses a variable-length lookbehind in one branch; we keep
    // compatibility by applying an equivalent post-match suppression rule.
    private static let ghosttyImplicitLinkRegex: NSRegularExpression? = {
        let urlSchemes = #"https?://|mailto:|ftp://|file:|ssh:|git://|ssh://|tel:|magnet:|ipfs://|ipns://|gemini://|gopher://|news:"#
        let ipv6URLPattern = #"(?:\[[:0-9a-fA-F]+(?:[:0-9a-fA-F]*)+\](?::[0-9]+)?)"#
        let schemeURLChars = #"[\w\-.~:/?#@!$&*+,;=%]"#
        let pathChars = #"[\w\-.~:\/?#@!$&*+;=%]"#
        let optionalBracketedWordSuffix = #"(?:[\(\[]\w*[\)\]])?"#
        let noTrailingPunctuation = #"(?<![,.])"#
        let noTrailingColon = #"(?<!:)"#
        let trailingSpacesAtEOL = #"(?: +(?= *$))?"#
        let dottedPathLookahead = #"(?=[\w\-.~:\/?#@!$&*+;=%]*\.)"#
        let nonDottedPathLookahead = #"(?![\w\-.~:\/?#@!$&*+;=%]*\.)"#
        let dottedPathSpaceSegments = #"(?:(?<!:) (?!\w+:\/\/)[\w\-.~:\/?#@!$&*+;=%]*[\/.])*"#
        let anyPathSpaceSegments = #"(?:(?<!:) (?!\w+:\/\/)[\w\-.~:\/?#@!$&*+;=%]+)*"#

        let schemeURLBranch =
            "(?:" + urlSchemes + ")" +
            "(?:" + ipv6URLPattern + "|" + schemeURLChars + "+" + optionalBracketedWordSuffix + ")+" +
            noTrailingPunctuation

        let rootedOrRelativePathPrefix = #"(?:\.\.\/|\.\/|(?<!\w)~\/|(?:[\w][\w\-.]*\/)*(?<!\w)\$[A-Za-z_]\w*\/|\.[\w][\w\-.]*\/|(?<![\w~\/])\/(?!\/))"#
        let rootedOrRelativePathBranch =
            rootedOrRelativePathPrefix +
            "(?:" +
            dottedPathLookahead +
            pathChars + "+" +
            dottedPathSpaceSegments +
            noTrailingColon +
            trailingSpacesAtEOL +
            "|" +
            nonDottedPathLookahead +
            pathChars + "+" +
            anyPathSpaceSegments +
            noTrailingColon +
            trailingSpacesAtEOL +
            ")"

        // Ghostty uses (?<!\$\d*) here, which is unsupported by ICU.
        // We enforce the same intent by skipping any match preceded by '$'.
        let bareRelativePathPrefix = #"(?<!\w)[\w][\w\-.]*\/"#
        let bareRelativePathBranch =
            dottedPathLookahead +
            bareRelativePathPrefix +
            pathChars + "+" +
            dottedPathSpaceSegments +
            noTrailingColon +
            trailingSpacesAtEOL

        // Bare `#123` references, the form agents print for pull requests and
        // issues (`PR #9326`). The `#` must not follow a word character or a
        // path/URL/identifier character, and the digits must not run into a
        // word character or hyphen, so hex colors, URL fragments, and embedded
        // identifiers (`#ff0000`, `owner/repo#123`, `page#123`, `#123abc`) are
        // left alone.
        let referenceNumberBranch = #"(?<![\w$&/#.@=:%-])#\d+(?![\w/-])"#

        // Bare Linear issue IDs are implicit links too. Keep the boundaries
        // aligned with `LinearIssueReference.issueID(in:)` so an ID embedded in a
        // larger alphanumeric token is left alone.
        let linearIssueBranch = #"(?<![A-Za-z0-9])[A-Za-z]{2,5}-[0-9]+(?![A-Za-z0-9])"#

        let regex = schemeURLBranch + "|" + rootedOrRelativePathBranch + "|" + bareRelativePathBranch + "|" + referenceNumberBranch + "|" + linearIssueBranch
        return try? NSRegularExpression(pattern: regex, options: [])
    }()

}
