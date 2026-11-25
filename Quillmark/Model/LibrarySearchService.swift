import CoreGraphics
import Foundation
import PDFKit
import UIKit
import Vision

// MARK: - Search Models

enum SearchDocumentFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case pdf
    case web

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "全部文档"
        case .pdf: return "PDF"
        case .web: return "网页"
        }
    }

    func matches(_ meta: DocumentMeta) -> Bool {
        switch self {
        case .all:
            return true
        case .pdf:
            return meta.layout != .live
        case .web:
            return meta.layout == .live
        }
    }
}

/// One extracted searchable unit within a document: a PDF page or a logical HTML section.
struct DocumentTextSegment: Codable, Equatable, Hashable, Sendable {
    /// Zero-based PDF page index, or `nil` for live HTML/web documents.
    var pageIndex: Int?
    /// Optional heading title extracted from `<h1>`–`<h3>` in HTML documents.
    var sectionTitle: String?
    /// Clean plain text extracted from this page or section.
    var text: String
}

/// Per-document disk-cached text index stored in `<uuid>.qmark/search-text.json`.
struct DocumentTextCache: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = DocumentTextCache.currentSchemaVersion
    /// Fingerprint of the underlying PDF or HTML source file (layout + entry + size + mtime).
    var sourceFingerprint: String
    /// Whether Vision OCR has already been performed on image-only pages.
    var usedOCR: Bool = false
    /// True when a non-blank PDF contains pages with virtually no embedded text layer and OCR has not run yet.
    var hasUnrecognizedImagePages: Bool = false
    var segments: [DocumentTextSegment] = []
}

/// Immutable, `Sendable` snapshot of a library document's disk paths and metadata for background indexing.
struct SearchDocumentInput: Sendable {
    let meta: DocumentMeta
    let folderName: String?
    let documentFolderURL: URL
    let pdfURL: URL
    let sourceFolderURL: URL
    let cacheURL: URL

    @MainActor
    static func snapshot(from library: LibraryStore) -> [SearchDocumentInput] {
        let folderNames = Dictionary(library.folders.map { ($0.id, $0.name) },
                                     uniquingKeysWith: { first, _ in first })
        return library.documents.map { meta in
            SearchDocumentInput(
                meta: meta,
                folderName: meta.folderID.flatMap { folderNames[$0] },
                documentFolderURL: library.folder(for: meta.id),
                pdfURL: library.pdfURL(for: meta.id),
                sourceFolderURL: library.sourceFolder(for: meta.id),
                cacheURL: library.searchTextCacheURL(for: meta.id)
            )
        }
    }
}

/// One matched snippet row inside a document's search result card.
struct FullTextSearchMatch: Identifiable, Equatable, Sendable {
    let id: String
    let documentID: UUID
    /// Zero-based PDF page index when tapping should jump directly to that page.
    let pageIndex: Int?
    /// Human-readable location badge (e.g. `"第 3 页"`, HTML section heading, or `"正文"`).
    let locationLabel: String
    /// Number of token hits found within this page/section.
    let hitCount: Int
    /// Context snippet around the match.
    let snippet: String
    /// Ranges within `snippet` to highlight.
    let highlightRanges: [Range<String.Index>]
}

/// Grouped cross-document search result for one document.
struct FullTextDocumentResult: Identifiable, Equatable, Sendable {
    var id: UUID { meta.id }
    let meta: DocumentMeta
    let folderName: String?
    let titleMatched: Bool
    let folderMatched: Bool
    let totalMatchCount: Int
    let matches: [FullTextSearchMatch]
    let score: Int
}

// MARK: - HTML & WebArchive Plain-Text Extractor

enum HTMLTextExtractor {
    private static let rawSkipTags: Set<String> = [
        "script", "style", "noscript", "template", "head",
    ]

    private static let blockBreakTags: Set<String> = [
        "p", "div", "section", "article", "main", "aside", "header", "footer", "nav",
        "li", "ul", "ol", "tr", "table", "thead", "tbody", "tfoot", "blockquote", "pre",
        "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6", "dt", "dd", "figcaption", "figure",
        "form", "fieldset", "button", "label", "option", "summary", "details", "caption",
    ]

    private static let cellSpaceTags: Set<String> = ["td", "th"]

    private static let namedEntities: [String: String] = [
        "nbsp": " ",
        "ensp": " ",
        "emsp": " ",
        "thinsp": " ",
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "times": "×",
        "divide": "÷",
        "deg": "°",
        "plusmn": "±",
        "le": "≤",
        "ge": "≥",
        "ne": "≠",
        "approx": "≈",
        "sim": "∼",
        "cong": "≅",
        "perp": "⊥",
        "parallel": "∥",
        "angle": "∠",
        "pi": "π",
        "alpha": "α",
        "beta": "β",
        "gamma": "γ",
        "theta": "θ",
        "delta": "δ",
        "Delta": "Δ",
        "radic": "√",
        "infin": "∞",
        "prime": "′",
        "Prime": "″",
        "mdash": "—",
        "ndash": "–",
        "hellip": "…",
        "ldquo": "“",
        "rdquo": "”",
        "lsquo": "‘",
        "rsquo": "’",
        "middot": "·",
        "bull": "•",
        "copy": "©",
        "rarr": "→",
        "larr": "←",
        "rArr": "⇒",
        "hArr": "⇔",
    ]

    /// Decodes raw HTML bytes into a Swift `String`, handling UTF-8, GB18030/GBK, and UTF-16.
    static func decodeHTMLData(_ data: Data, declaredEncoding: String? = nil) -> String {
        guard !data.isEmpty else { return "" }
        // Guard against unexpectedly huge single files on 4GB iPads.
        let bounded = data.count > 12 * 1024 * 1024 ? data.prefix(12 * 1024 * 1024) : data[...]
        let bytes = Data(bounded)

        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF,
           let str = String(data: bytes.dropFirst(3), encoding: .utf8) {
            return str
        }
        if bytes.count >= 2, (bytes[0] == 0xFE && bytes[1] == 0xFF) || (bytes[0] == 0xFF && bytes[1] == 0xFE),
           let str = String(data: bytes, encoding: .utf16) {
            return str
        }

        let encodingHint = declaredEncoding?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? sniffMetaCharset(in: bytes)
        if let hint = encodingHint, let enc = stringEncoding(forName: hint),
           let str = String(data: bytes, encoding: enc) {
            return str
        }

        if let utf8 = String(data: bytes, encoding: .utf8) {
            return utf8
        }
        if let gb = gb18030Encoding(), let str = String(data: bytes, encoding: gb) {
            return str
        }
        if let utf16 = String(data: bytes, encoding: .utf16) {
            return utf16
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Extracts plain-text segments from a WKWebView `.webarchive` binary property list without WebKit.
    static func extractSegments(fromWebArchiveData data: Data) -> [DocumentTextSegment] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return []
        }
        var segments: [DocumentTextSegment] = []
        collectWebArchiveDictionary(plist, depth: 0, into: &segments)
        return segments
    }

    private static func collectWebArchiveDictionary(_ dict: [String: Any],
                                                    depth: Int,
                                                    into out: inout [DocumentTextSegment]) {
        guard depth <= 4 else { return }
        if let main = dict["WebMainResource"] as? [String: Any],
           let rawData = main["WebResourceData"] as? Data, !rawData.isEmpty {
            let mime = (main["WebResourceMIMEType"] as? String)?.lowercased() ?? "text/html"
            let encodingName = main["WebResourceTextEncodingName"] as? String
            if mime.contains("html") || mime.contains("xml") {
                let html = decodeHTMLData(rawData, declaredEncoding: encodingName)
                out.append(contentsOf: extractSegments(fromHTML: html))
            } else if mime.hasPrefix("text/") {
                let text = normalizeWhitespace(decodeHTMLData(rawData, declaredEncoding: encodingName))
                if !text.isEmpty {
                    out.append(DocumentTextSegment(pageIndex: nil, sectionTitle: nil, text: text))
                }
            }
        }
        if let subframes = dict["WebSubframeArchives"] as? [[String: Any]] {
            for sub in subframes {
                collectWebArchiveDictionary(sub, depth: depth + 1, into: &out)
            }
        }
    }

    /// Parses an HTML document into clean plain-text segments grouped by `<h1>`–`<h3>` headings.
    /// Completely skips `<script>`, `<style>`, `<noscript>`, `<template>`, `<head>`, and comments,
    /// while preserving Chinese/math wording across inline tags like `<strong>` and `<span>`.
    static func extractSegments(fromHTML html: String) -> [DocumentTextSegment] {
        let scalars = html.unicodeScalars
        var i = scalars.startIndex
        let end = scalars.endIndex

        var segments: [DocumentTextSegment] = []
        var currentHeading: String? = nil
        var currentBuffer = ""
        currentBuffer.reserveCapacity(min(html.count / 4, 8192))

        var capturingHeadingLevel: Int? = nil
        var headingBuffer = ""

        func flushCurrentSection() {
            let cleaned = normalizeWhitespace(currentBuffer)
            if !cleaned.isEmpty {
                segments.append(DocumentTextSegment(pageIndex: nil, sectionTitle: currentHeading, text: cleaned))
            }
            currentBuffer.removeAll(keepingCapacity: true)
        }

        func appendText(_ piece: String) {
            if capturingHeadingLevel != nil {
                headingBuffer.append(piece)
                if headingBuffer.unicodeScalars.count > 240 {
                    currentBuffer.append(headingBuffer)
                    headingBuffer.removeAll(keepingCapacity: false)
                    capturingHeadingLevel = nil
                }
            } else {
                currentBuffer.append(piece)
            }
        }

        func appendScalar(_ scalar: UnicodeScalar) {
            if capturingHeadingLevel != nil {
                headingBuffer.unicodeScalars.append(scalar)
                if headingBuffer.unicodeScalars.count > 240 {
                    currentBuffer.append(headingBuffer)
                    headingBuffer.removeAll(keepingCapacity: false)
                    capturingHeadingLevel = nil
                }
            } else {
                currentBuffer.unicodeScalars.append(scalar)
            }
        }

        func appendSeparator(_ sep: Character) {
            if capturingHeadingLevel != nil {
                if let last = headingBuffer.last, !last.isWhitespace {
                    headingBuffer.append(" ")
                }
            } else {
                if let last = currentBuffer.last, last != sep && !(sep == " " && last == "\n") {
                    currentBuffer.append(sep)
                }
            }
        }

        while i < end {
            let s = scalars[i]

            if s == "<" {
                // 1. HTML comment: <!-- ... -->
                if matchesASCIIPrefix("<!--", in: scalars, at: i) {
                    i = advancePastSubstring("-->", in: scalars, from: scalars.index(i, offsetBy: 4, limitedBy: end) ?? end)
                    continue
                }

                // 2. Parse tag name and closing '>'
                var cursor = scalars.index(after: i)
                var isClosing = false
                if cursor < end && scalars[cursor] == "/" {
                    isClosing = true
                    cursor = scalars.index(after: cursor)
                }

                // Skip declarations like <!DOCTYPE ...> or <?xml ...?>
                if !isClosing && cursor < end && (scalars[cursor] == "!" || scalars[cursor] == "?") {
                    i = advancePastTagEnd(in: scalars, from: cursor)
                    continue
                }

                let nameStart = cursor
                while cursor < end && isTagNameScalar(scalars[cursor]) {
                    cursor = scalars.index(after: cursor)
                }
                let rawTagName = makeString(from: scalars[nameStart..<cursor]).lowercased()

                let tagEndInfo = scanToTagEnd(in: scalars, from: cursor)
                i = tagEndInfo.nextIndex

                guard !rawTagName.isEmpty else { continue }

                // 3. Skip non-visible container bodies (<script>, <style>, <noscript>, <template>, <head>)
                if !isClosing && !tagEndInfo.selfClosing && rawSkipTags.contains(rawTagName) {
                    i = advancePastClosingTag(rawTagName, in: scalars, from: i)
                    continue
                }

                // 4. Section headings (<h1>, <h2>, <h3>)
                if let level = headingLevel(for: rawTagName) {
                    if !isClosing && !tagEndInfo.selfClosing {
                        if capturingHeadingLevel != nil {
                            let partial = normalizeSingleLine(headingBuffer)
                            if !partial.isEmpty { currentBuffer.append(partial); currentBuffer.append("\n") }
                            headingBuffer.removeAll(keepingCapacity: false)
                            capturingHeadingLevel = nil
                        }
                        flushCurrentSection()
                        capturingHeadingLevel = level
                        headingBuffer.removeAll(keepingCapacity: true)
                    } else if isClosing && capturingHeadingLevel == level {
                        let title = normalizeSingleLine(headingBuffer)
                        headingBuffer.removeAll(keepingCapacity: false)
                        capturingHeadingLevel = nil
                        if !title.isEmpty {
                            currentHeading = truncateHeading(title)
                            currentBuffer.append(title)
                            currentBuffer.append("\n")
                        }
                    }
                    continue
                }

                // 5. Block / table-cell spacing
                if blockBreakTags.contains(rawTagName) {
                    appendSeparator("\n")
                } else if cellSpaceTags.contains(rawTagName) {
                    appendSeparator(" ")
                }
                continue
            }

            if s == "&" {
                let decoded = decodeEntity(in: scalars, from: i)
                appendText(decoded.text)
                i = decoded.nextIndex
                continue
            }

            appendScalar(s)
            i = scalars.index(after: i)
        }

        if capturingHeadingLevel != nil {
            let leftover = normalizeSingleLine(headingBuffer)
            if !leftover.isEmpty {
                currentBuffer.append(leftover)
            }
        }
        flushCurrentSection()
        return segments
    }

    static func normalizeWhitespace(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        var pendingNewline = false
        var pendingSpace = false

        for scalar in raw.unicodeScalars {
            // Skip soft hyphens & zero-width formatting characters that break substring matching in PDFs/HTML.
            if scalar.value == 0x00AD || scalar.value == 0x200B || scalar.value == 0x200C ||
                scalar.value == 0x200D || scalar.value == 0xFEFF {
                continue
            }
            if scalar == "\n" || scalar == "\r" || scalar.value == 0x000B || scalar.value == 0x000C {
                if !result.isEmpty {
                    pendingNewline = true
                    pendingSpace = false
                }
            } else if scalar == " " || scalar == "\t" || scalar.value == 0x00A0 || scalar.value == 0x3000 {
                if !result.isEmpty && !pendingNewline {
                    pendingSpace = true
                }
            } else {
                if pendingNewline {
                    result.append("\n")
                    pendingNewline = false
                    pendingSpace = false
                } else if pendingSpace {
                    result.append(" ")
                    pendingSpace = false
                }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func normalizeSingleLine(_ raw: String) -> String {
        normalizeWhitespace(raw)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncateHeading(_ heading: String, maxChars: Int = 48) -> String {
        guard heading.count > maxChars else { return heading }
        let idx = heading.index(heading.startIndex, offsetBy: maxChars)
        return String(heading[..<idx]) + "…"
    }

    private static func headingLevel(for tag: String) -> Int? {
        switch tag {
        case "h1": return 1
        case "h2": return 2
        case "h3": return 3
        default: return nil
        }
    }

    private static func isTagNameScalar(_ s: UnicodeScalar) -> Bool {
        let v = s.value
        return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) ||
            (v >= 0x30 && v <= 0x39) || v == 0x2D || v == 0x3A
    }

    private static func matchesASCIIPrefix(_ prefix: String,
                                           in scalars: String.UnicodeScalarView,
                                           at index: String.UnicodeScalarView.Index) -> Bool {
        var i = index
        for p in prefix.unicodeScalars {
            guard i < scalars.endIndex, scalars[i] == p else { return false }
            i = scalars.index(after: i)
        }
        return true
    }

    private static func advancePastSubstring(_ needle: String,
                                             in scalars: String.UnicodeScalarView,
                                             from start: String.UnicodeScalarView.Index) -> String.UnicodeScalarView.Index {
        var i = start
        let end = scalars.endIndex
        let needleScalars = Array(needle.unicodeScalars)
        guard let first = needleScalars.first else { return start }

        while i < end {
            if scalars[i] == first {
                var j = i
                var matched = true
                for target in needleScalars {
                    guard j < end, scalars[j] == target else {
                        matched = false
                        break
                    }
                    j = scalars.index(after: j)
                }
                if matched { return j }
            }
            i = scalars.index(after: i)
        }
        return end
    }

    private static func advancePastTagEnd(in scalars: String.UnicodeScalarView,
                                          from start: String.UnicodeScalarView.Index) -> String.UnicodeScalarView.Index {
        scanToTagEnd(in: scalars, from: start).nextIndex
    }

    private static func scanToTagEnd(in scalars: String.UnicodeScalarView,
                                     from start: String.UnicodeScalarView.Index) -> (nextIndex: String.UnicodeScalarView.Index, selfClosing: Bool) {
        var i = start
        let end = scalars.endIndex
        var quote: UnicodeScalar? = nil
        var prevNonSpace: UnicodeScalar = " "

        while i < end {
            let s = scalars[i]
            if let q = quote {
                if s == q { quote = nil }
            } else {
                if s == "\"" || s == "'" {
                    quote = s
                } else if s == ">" {
                    return (scalars.index(after: i), prevNonSpace == "/")
                } else if s != " " && s != "\t" && s != "\n" && s != "\r" {
                    prevNonSpace = s
                }
            }
            i = scalars.index(after: i)
        }
        return (end, false)
    }

    private static func advancePastClosingTag(_ tagName: String,
                                              in scalars: String.UnicodeScalarView,
                                              from start: String.UnicodeScalarView.Index) -> String.UnicodeScalarView.Index {
        let targetScalars = Array(tagName.unicodeScalars)
        var i = start
        let end = scalars.endIndex

        while i < end {
            if scalars[i] == "<" {
                let next = scalars.index(after: i)
                if next < end && scalars[next] == "/" {
                    var j = scalars.index(after: next)
                    var matched = true
                    for target in targetScalars {
                        guard j < end, asciiLowercase(scalars[j]) == target else {
                            matched = false
                            break
                        }
                        j = scalars.index(after: j)
                    }
                    if matched && (j == end || !isTagNameScalar(scalars[j])) {
                        return advancePastTagEnd(in: scalars, from: j)
                    }
                }
            }
            i = scalars.index(after: i)
        }
        return end
    }

    private static func asciiLowercase(_ s: UnicodeScalar) -> UnicodeScalar {
        if s.value >= 0x41 && s.value <= 0x5A, let lowered = UnicodeScalar(s.value + 32) {
            return lowered
        }
        return s
    }

    private static func decodeEntity(in scalars: String.UnicodeScalarView,
                                     from start: String.UnicodeScalarView.Index) -> (text: String, nextIndex: String.UnicodeScalarView.Index) {
        let end = scalars.endIndex
        let afterAmp = scalars.index(after: start)
        var cursor = afterAmp
        var steps = 0

        while cursor < end && steps < 12 {
            let s = scalars[cursor]
            if s == ";" {
                let token = makeString(from: scalars[afterAmp..<cursor])
                let afterSemi = scalars.index(after: cursor)
                if let resolved = resolveEntityToken(token) {
                    return (resolved, afterSemi)
                }
                return ("&", afterAmp)
            }
            if s == " " || s == "\n" || s == "<" || s == "&" {
                break
            }
            cursor = scalars.index(after: cursor)
            steps += 1
        }
        return ("&", afterAmp)
    }

    private static func makeString(from slice: String.UnicodeScalarView.SubSequence) -> String {
        var out = ""
        out.unicodeScalars.append(contentsOf: slice)
        return out
    }

    private static func resolveEntityToken(_ token: String) -> String? {
        guard !token.isEmpty else { return nil }
        if token.hasPrefix("#x") || token.hasPrefix("#X") {
            let hex = token.dropFirst(2)
            if let code = UInt32(hex, radix: 16), let scalar = UnicodeScalar(code) {
                return String(scalar)
            }
            return nil
        }
        if token.hasPrefix("#") {
            let dec = token.dropFirst(1)
            if let code = UInt32(dec, radix: 10), let scalar = UnicodeScalar(code) {
                return String(scalar)
            }
            return nil
        }
        return namedEntities[token] ?? namedEntities[token.lowercased()]
    }

    private static func sniffMetaCharset(in data: Data) -> String? {
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        guard let range = head.range(of: "charset=") else { return nil }
        var cursor = range.upperBound
        while cursor < head.endIndex && (head[cursor] == "\"" || head[cursor] == "'" || head[cursor] == " ") {
            cursor = head.index(after: cursor)
        }
        let start = cursor
        while cursor < head.endIndex {
            let ch = head[cursor]
            if ch == "\"" || ch == "'" || ch == ";" || ch == " " || ch == ">" || ch == "/" {
                break
            }
            cursor = head.index(after: cursor)
        }
        let charset = String(head[start..<cursor])
        return charset.isEmpty ? nil : charset
    }

    private static func stringEncoding(forName name: String) -> String.Encoding? {
        switch name {
        case "utf-8", "utf8":
            return .utf8
        case "gbk", "gb2312", "gb18030", "gb_2312-80":
            return gb18030Encoding()
        case "utf-16", "utf16":
            return .utf16
        case "iso-8859-1", "latin1":
            return .isoLatin1
        default:
            return nil
        }
    }

    private static func gb18030Encoding() -> String.Encoding? {
        let cfEnc = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
        guard nsEnc != UInt(kCFStringEncodingInvalidId) else { return nil }
        return String.Encoding(rawValue: nsEnc)
    }
}

// MARK: - Per-Document Text Extractor (PDF + HTML + Optional Vision OCR)

enum DocumentTextExtractor {
    /// Computes a lightweight fingerprint from the underlying document file's size and modification time.
    static func sourceFingerprint(for input: SearchDocumentInput) -> String {
        let fm = FileManager.default
        if input.meta.layout == .live {
            guard let entryURL = resolvedLiveEntryURL(for: input),
                  let attrs = try? fm.attributesOfItem(atPath: entryURL.path) else {
                return "live:\(input.meta.sourceEntry ?? "none"):missing"
            }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtimeMS = Int64((((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000.0).rounded())
            return "live:\(entryURL.lastPathComponent):\(size):\(mtimeMS)"
        } else {
            guard let attrs = try? fm.attributesOfItem(atPath: input.pdfURL.path) else {
                return "pdf:\(input.meta.layout.rawValue):missing"
            }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtimeMS = Int64((((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000.0).rounded())
            return "pdf:\(input.meta.layout.rawValue):\(size):\(mtimeMS)"
        }
    }

    static func resolvedLiveEntryURL(for input: SearchDocumentInput) -> URL? {
        let fm = FileManager.default
        if let entry = input.meta.sourceEntry {
            let direct = input.sourceFolderURL.appendingPathComponent(entry)
            if fm.fileExists(atPath: direct.path) {
                return direct
            }
        }
        guard let items = try? fm.contentsOfDirectory(at: input.sourceFolderURL, includingPropertiesForKeys: nil) else {
            return nil
        }
        let sorted = items.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let archive = sorted.first(where: { $0.pathExtension.lowercased() == "webarchive" }) {
            return archive
        }
        let htmlCandidates = sorted.filter { ["html", "htm", "xhtml"].contains($0.pathExtension.lowercased()) }
        return htmlCandidates.first(where: { $0.lastPathComponent.lowercased().hasPrefix("index.") }) ?? htmlCandidates.first
    }

    /// Extracts all searchable text segments for a document (1 document in memory at a time).
    static func extract(input: SearchDocumentInput, performOCR: Bool = false) -> DocumentTextCache {
        let fingerprint = sourceFingerprint(for: input)
        if input.meta.layout == .live {
            let segments: [DocumentTextSegment] = autoreleasepool {
                guard let entryURL = resolvedLiveEntryURL(for: input),
                      let data = try? Data(contentsOf: entryURL, options: .mappedIfSafe) else {
                    return []
                }
                if entryURL.pathExtension.lowercased() == "webarchive" {
                    return HTMLTextExtractor.extractSegments(fromWebArchiveData: data)
                } else {
                    let html = HTMLTextExtractor.decodeHTMLData(data)
                    return HTMLTextExtractor.extractSegments(fromHTML: html)
                }
            }
            return DocumentTextCache(
                schemaVersion: DocumentTextCache.currentSchemaVersion,
                sourceFingerprint: fingerprint,
                usedOCR: false,
                hasUnrecognizedImagePages: false,
                segments: segments
            )
        } else {
            return extractPDF(input: input, fingerprint: fingerprint, performOCR: performOCR)
        }
    }

    private static func extractPDF(input: SearchDocumentInput,
                                   fingerprint: String,
                                   performOCR: Bool) -> DocumentTextCache {
        let isBlankNotebook = (input.meta.sourceKind == .blankNotebook)
        var segments: [DocumentTextSegment] = []
        var hasImageOnlyPages = false
        var didRunOCR = false

        autoreleasepool {
            guard let doc = PDFDocument(url: input.pdfURL) else { return }
            let count = doc.pageCount
            for pageIndex in 0..<count {
                autoreleasepool {
                    guard let page = doc.page(at: pageIndex) else { return }
                    let raw = page.string ?? ""
                    var cleaned = HTMLTextExtractor.normalizeWhitespace(raw)

                    if cleaned.count < 6 && !isBlankNotebook {
                        if performOCR {
                            didRunOCR = true
                            let ocrText = recognizeText(on: page)
                            if !ocrText.isEmpty {
                                cleaned = ocrText
                            }
                        } else {
                            hasImageOnlyPages = true
                        }
                    }

                    if !cleaned.isEmpty {
                        segments.append(DocumentTextSegment(pageIndex: pageIndex, sectionTitle: nil, text: cleaned))
                    }
                }
            }
        }

        return DocumentTextCache(
            schemaVersion: DocumentTextCache.currentSchemaVersion,
            sourceFingerprint: fingerprint,
            usedOCR: performOCR || didRunOCR,
            hasUnrecognizedImagePages: performOCR ? false : hasImageOnlyPages,
            segments: segments
        )
    }

    private static func recognizeText(on page: PDFPage) -> String {
        let box = page.bounds(for: .cropBox)
        let rot = ((page.rotation % 360) + 360) % 360
        let oriented = (rot == 90 || rot == 270) ? CGSize(width: box.height, height: box.width) : box.size
        guard oriented.width > 1, oriented.height > 1 else { return "" }

        // Cap rendered size to <= 1400pt on the longest edge so 4GB iPads stay far below memory limits.
        let maxSide: CGFloat = 1400
        let scale = min(2.0, maxSide / max(oriented.width, oriented.height))
        let targetSize = CGSize(
            width: max(64, (oriented.width * scale).rounded()),
            height: max(64, (oriented.height * scale).rounded())
        )
        let image = page.thumbnail(of: targetSize, for: .cropBox)
        guard let cgImage = image.cgImage else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return HTMLTextExtractor.normalizeWhitespace(lines.joined(separator: "\n"))
    }
}

// MARK: - Query Tokenization, Ranking & Snippet Matching

enum LibrarySearchMatcher {
    /// Case-insensitive AND full-width/half-width insensitive (`(1)` matches `（1）`, `AB` matches `ab`).
    static let compareOptions: String.CompareOptions = [.caseInsensitive, .widthInsensitive]

    static func tokenize(_ rawQuery: String) -> [String] {
        var seen: [String] = []
        let parts = rawQuery.components(separatedBy: .whitespacesAndNewlines)
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !seen.contains(where: { $0.compare(trimmed, options: compareOptions) == .orderedSame }) {
                seen.append(trimmed)
            }
        }
        return seen
    }

    /// Finds all non-overlapping highlight ranges for `tokens` inside `text`, sorted left-to-right.
    static func findHighlightRanges(in text: String, tokens: [String]) -> [Range<String.Index>] {
        guard !text.isEmpty, !tokens.isEmpty else { return [] }
        var rawRanges: [Range<String.Index>] = []
        for token in tokens where !token.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: token, options: compareOptions, range: searchStart..<text.endIndex) {
                rawRanges.append(found)
                searchStart = found.upperBound > searchStart ? found.upperBound : text.index(after: searchStart)
            }
        }
        guard !rawRanges.isEmpty else { return [] }
        rawRanges.sort { lhs, rhs in
            if lhs.lowerBound != rhs.lowerBound { return lhs.lowerBound < rhs.lowerBound }
            return lhs.upperBound > rhs.upperBound
        }
        var merged: [Range<String.Index>] = []
        for range in rawRanges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                if range.upperBound > last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<range.upperBound
                }
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Evaluates one document against `tokens` (multi-token AND across title + folder + body segments).
    static func matchDocument(_ input: SearchDocumentInput,
                              cache: DocumentTextCache,
                              tokens: [String],
                              maxMatchesPerDocument: Int = 40) -> FullTextDocumentResult? {
        guard !tokens.isEmpty else { return nil }

        let title = input.meta.title
        let folderName = input.folderName ?? ""

        var matchedTokenIndices = Set<Int>()
        var titleMatchedCount = 0
        var folderMatchedCount = 0

        for (idx, token) in tokens.enumerated() {
            if title.range(of: token, options: compareOptions) != nil {
                matchedTokenIndices.insert(idx)
                titleMatchedCount += 1
            }
            if !folderName.isEmpty, folderName.range(of: token, options: compareOptions) != nil {
                matchedTokenIndices.insert(idx)
                folderMatchedCount += 1
            }
        }

        struct SegmentHit {
            let segmentIndex: Int
            let segment: DocumentTextSegment
            let distinctTokenCount: Int
            let totalOccurrences: Int
            let bestAnchorRange: Range<String.Index>
        }

        var segmentHits: [SegmentHit] = []
        var totalBodyOccurrences = 0

        for (segIdx, segment) in cache.segments.enumerated() {
            let text = segment.text
            guard !text.isEmpty else { continue }

            var distinctInSegment = 0
            var occurrencesInSegment = 0
            var firstHitRange: Range<String.Index>? = nil
            var tokenFirstRanges: [Range<String.Index>] = []

            for (tokIdx, token) in tokens.enumerated() {
                var searchStart = text.startIndex
                var tokenCountHere = 0
                while searchStart < text.endIndex,
                      let found = text.range(of: token, options: compareOptions, range: searchStart..<text.endIndex) {
                    if tokenCountHere == 0 {
                        tokenFirstRanges.append(found)
                        if firstHitRange == nil || found.lowerBound < firstHitRange!.lowerBound {
                            firstHitRange = found
                        }
                    }
                    tokenCountHere += 1
                    occurrencesInSegment += 1
                    // Cap scanning huge repetitive segments while keeping hit counts informative.
                    if tokenCountHere >= 50 { break }
                    searchStart = found.upperBound > searchStart ? found.upperBound : text.index(after: searchStart)
                }
                if tokenCountHere > 0 {
                    distinctInSegment += 1
                    matchedTokenIndices.insert(tokIdx)
                }
            }

            if distinctInSegment > 0, let anchor = chooseBestAnchor(in: text, tokenFirstRanges: tokenFirstRanges, fallback: firstHitRange!) {
                totalBodyOccurrences += occurrencesInSegment
                segmentHits.append(SegmentHit(
                    segmentIndex: segIdx,
                    segment: segment,
                    distinctTokenCount: distinctInSegment,
                    totalOccurrences: occurrencesInSegment,
                    bestAnchorRange: anchor
                ))
            }
        }

        // Strict AND: every query token must appear somewhere in the document's metadata or body.
        guard matchedTokenIndices.count == tokens.count else { return nil }

        // Build snippet matches (ordered by co-occurrence richness first when multi-token, then document order).
        let orderedHits: [SegmentHit]
        if tokens.count > 1 {
            orderedHits = segmentHits.sorted { lhs, rhs in
                if lhs.distinctTokenCount != rhs.distinctTokenCount {
                    return lhs.distinctTokenCount > rhs.distinctTokenCount
                }
                return lhs.segmentIndex < rhs.segmentIndex
            }
        } else {
            orderedHits = segmentHits
        }

        var matches: [FullTextSearchMatch] = []
        for hit in orderedHits.prefix(maxMatchesPerDocument) {
            let snippet = buildSnippet(in: hit.segment.text, around: hit.bestAnchorRange)
            let highlights = findHighlightRanges(in: snippet, tokens: tokens)
            let locationLabel: String
            if let page = hit.segment.pageIndex {
                locationLabel = "第 \(page + 1) 页"
            } else if let heading = hit.segment.sectionTitle, !heading.isEmpty {
                locationLabel = heading
            } else {
                locationLabel = "正文"
            }
            matches.append(FullTextSearchMatch(
                id: "\(input.meta.id.uuidString)-\(hit.segmentIndex)",
                documentID: input.meta.id,
                pageIndex: hit.segment.pageIndex,
                locationLabel: locationLabel,
                hitCount: hit.totalOccurrences,
                snippet: snippet,
                highlightRanges: highlights
            ))
        }

        // Compute relevance score:
        // - Full title match / exact phrase gets highest priority
        // - Same-page/section co-occurrence of all tokens strongly boosted
        // - More matching pages/occurrences boosts rank smoothly
        var score = 0
        if titleMatchedCount == tokens.count {
            score += 400
            if tokens.count == 1, title.compare(tokens[0], options: compareOptions) == .orderedSame {
                score += 200
            }
        } else if titleMatchedCount > 0 {
            score += titleMatchedCount * 90
        }
        if folderMatchedCount > 0 {
            score += folderMatchedCount * 35
        }
        let fullCooccurrenceSegments = segmentHits.filter { $0.distinctTokenCount == tokens.count }.count
        score += fullCooccurrenceSegments * 140
        score += min(segmentHits.count, 15) * 20
        score += min(totalBodyOccurrences, 40) * 4

        let totalMatchCount = totalBodyOccurrences + (titleMatchedCount > 0 ? 1 : 0) + (folderMatchedCount > 0 ? 1 : 0)

        return FullTextDocumentResult(
            meta: input.meta,
            folderName: input.folderName,
            titleMatched: titleMatchedCount > 0,
            folderMatched: folderMatchedCount > 0,
            totalMatchCount: max(1, totalMatchCount),
            matches: matches,
            score: score
        )
    }

    private static func chooseBestAnchor(in text: String,
                                         tokenFirstRanges: [Range<String.Index>],
                                         fallback: Range<String.Index>) -> Range<String.Index>? {
        guard tokenFirstRanges.count > 1 else { return fallback }
        // Pick the token occurrence that has another token nearest to it so snippets show multiple terms together.
        let sorted = tokenFirstRanges.sorted { $0.lowerBound < $1.lowerBound }
        var bestRange = sorted[0]
        var bestDistance = Int.max
        for i in 0..<(sorted.count - 1) {
            let d = text.distance(from: sorted[i].upperBound, to: sorted[i + 1].lowerBound)
            if d < bestDistance {
                bestDistance = d
                bestRange = sorted[i]
            }
        }
        return bestRange
    }

    static func buildSnippet(in text: String,
                             around anchor: Range<String.Index>,
                             leadingContext: Int = 24,
                             trailingContext: Int = 60) -> String {
        let start = text.index(anchor.lowerBound, offsetBy: -leadingContext, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(anchor.upperBound, offsetBy: trailingContext, limitedBy: text.endIndex) ?? text.endIndex

        let rawSlice = String(text[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        let prefix = start > text.startIndex ? "…" : ""
        let suffix = end < text.endIndex ? "…" : ""
        return prefix + rawSlice + suffix
    }
}

// MARK: - Background Per-Document Cache Actor

actor LibrarySearchIndexStore {
    private var memoryCache: [UUID: DocumentTextCache] = [:]

    func cachedText(for input: SearchDocumentInput, performOCR: Bool = false) -> DocumentTextCache {
        let fingerprint = DocumentTextExtractor.sourceFingerprint(for: input)

        if let existing = memoryCache[input.meta.id],
           existing.schemaVersion == DocumentTextCache.currentSchemaVersion,
           existing.sourceFingerprint == fingerprint,
           (!performOCR || existing.usedOCR || !existing.hasUnrecognizedImagePages) {
            return existing
        }

        if let diskData = try? Data(contentsOf: input.cacheURL),
           let diskCache = try? LibraryStore.makeDecoder().decode(DocumentTextCache.self, from: diskData),
           diskCache.schemaVersion == DocumentTextCache.currentSchemaVersion,
           diskCache.sourceFingerprint == fingerprint,
           (!performOCR || diskCache.usedOCR || !diskCache.hasUnrecognizedImagePages) {
            memoryCache[input.meta.id] = diskCache
            return diskCache
        }

        let extracted = DocumentTextExtractor.extract(input: input, performOCR: performOCR)
        memoryCache[input.meta.id] = extracted
        writeCacheToDisk(extracted, for: input)
        return extracted
    }

    func clearMemoryCache() {
        memoryCache.removeAll(keepingCapacity: false)
    }

    func removeCachedEntry(for id: UUID) {
        memoryCache.removeValue(forKey: id)
    }

    private func writeCacheToDisk(_ cache: DocumentTextCache, for input: SearchDocumentInput) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: input.documentFolderURL.path) else { return }
        if let encoded = try? LibraryStore.makeEncoder().encode(cache) {
            try? encoded.write(to: input.cacheURL, options: .atomic)
        }
    }
}

// MARK: - MainActor ViewModel / Search Engine

@MainActor
final class LibrarySearchEngine: ObservableObject {
    private static let recentQueriesKey = "quillmark.fullTextSearch.recentQueries"
    private static let maxRecentQueries = 8

    @Published var query: String = ""
    @Published var documentFilter: SearchDocumentFilter = .all
    @Published var folderFilterID: UUID? = nil

    @Published private(set) var results: [FullTextDocumentResult] = []
    @Published private(set) var isIndexing: Bool = false
    @Published private(set) var isSearching: Bool = false
    @Published private(set) var indexedCount: Int = 0
    @Published private(set) var totalDocumentCount: Int = 0
    @Published private(set) var unindexedImagePDFCount: Int = 0
    @Published private(set) var isRunningOCR: Bool = false
    @Published private(set) var ocrProgressText: String? = nil
    @Published private(set) var recentQueries: [String] = []

    private let indexStore = LibrarySearchIndexStore()
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?
    private var memoryWarningObserver: NSObjectProtocol?

    init() {
        recentQueries = (UserDefaults.standard.stringArray(forKey: Self.recentQueriesKey) ?? [])
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let store = self.indexStore
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await store.clearMemoryCache() }
        }
    }

    deinit {
        indexTask?.cancel()
        searchTask?.cancel()
        ocrTask?.cancel()
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    var totalMatchCount: Int {
        results.reduce(0) { $0 + $1.totalMatchCount }
    }

    /// Incrementally builds or verifies disk text caches for every document in the library.
    func prepareIndex(for library: LibraryStore) {
        indexTask?.cancel()
        let inputs = SearchDocumentInput.snapshot(from: library)
        totalDocumentCount = inputs.count
        indexedCount = 0
        unindexedImagePDFCount = 0

        guard !inputs.isEmpty else {
            isIndexing = false
            return
        }

        isIndexing = true
        let store = indexStore
        indexTask = Task { [weak self] in
            var processed = 0
            var imagePDFs = 0
            for input in inputs {
                if Task.isCancelled { return }
                let cache = await Task.detached(priority: .utility) {
                    await store.cachedText(for: input, performOCR: false)
                }.value
                if Task.isCancelled { return }
                processed += 1
                if cache.hasUnrecognizedImagePages {
                    imagePDFs += 1
                }
                await MainActor.run {
                    guard let self else { return }
                    self.indexedCount = processed
                    self.unindexedImagePDFCount = imagePDFs
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.isIndexing = false
                if !self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.scheduleSearch(in: library, debounceNanoseconds: 0)
                }
            }
        }
    }

    /// Schedules a debounced, cancellable cross-document full-text search.
    func scheduleSearch(in library: LibraryStore, debounceNanoseconds: UInt64 = 160_000_000) {
        searchTask?.cancel()
        let currentQuery = query
        let tokens = LibrarySearchMatcher.tokenize(currentQuery)
        guard !tokens.isEmpty else {
            results = []
            isSearching = false
            return
        }

        let docFilter = documentFilter
        let folderID = folderFilterID
        let allInputs = SearchDocumentInput.snapshot(from: library)
        let filteredInputs = allInputs.filter { input in
            guard docFilter.matches(input.meta) else { return false }
            if let folderID {
                return input.meta.folderID == folderID
            }
            return true
        }

        isSearching = true
        let store = indexStore
        searchTask = Task { [weak self] in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            if Task.isCancelled { return }

            let computed = await Self.executeSearch(
                tokens: tokens,
                inputs: filteredInputs,
                store: store
            )
            if Task.isCancelled { return }

            await MainActor.run {
                guard let self else { return }
                self.results = computed
                self.isSearching = false
            }
        }
    }

    /// Direct async search entry point (also used by unit tests for deterministic assertions).
    func searchNow(query: String,
                   in library: LibraryStore,
                   documentFilter: SearchDocumentFilter = .all,
                   folderFilterID: UUID? = nil) async -> [FullTextDocumentResult] {
        let tokens = LibrarySearchMatcher.tokenize(query)
        guard !tokens.isEmpty else { return [] }
        let inputs = SearchDocumentInput.snapshot(from: library).filter { input in
            guard documentFilter.matches(input.meta) else { return false }
            if let folderFilterID {
                return input.meta.folderID == folderFilterID
            }
            return true
        }
        return await Self.executeSearch(tokens: tokens, inputs: inputs, store: indexStore)
    }

    /// Runs sequential on-device Vision OCR for scanned/photo PDFs lacking an embedded text layer.
    func runOCRForImagePDFs(in library: LibraryStore) {
        guard !isRunningOCR else { return }
        ocrTask?.cancel()
        let inputs = SearchDocumentInput.snapshot(from: library)
        let store = indexStore
        isRunningOCR = true
        ocrProgressText = "正在检测扫描件/图片 PDF…"

        ocrTask = Task { [weak self] in
            var targets: [SearchDocumentInput] = []
            for input in inputs where input.meta.layout != .live && input.meta.sourceKind != .blankNotebook {
                if Task.isCancelled { break }
                let existing = await Task.detached(priority: .utility) {
                    await store.cachedText(for: input, performOCR: false)
                }.value
                if existing.hasUnrecognizedImagePages {
                    targets.append(input)
                }
            }

            let total = targets.count
            for (idx, input) in targets.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run {
                    self?.ocrProgressText = "正在识别第 \(idx + 1)/\(total) 份：《\(input.meta.title)》…"
                }
                _ = await Task.detached(priority: .utility) {
                    await store.cachedText(for: input, performOCR: true)
                }.value
            }

            let remaining = await Self.countUnindexedImagePDFs(inputs: inputs, store: store)
            await MainActor.run {
                guard let self else { return }
                self.isRunningOCR = false
                self.ocrProgressText = nil
                self.unindexedImagePDFCount = remaining
                if !self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.scheduleSearch(in: library, debounceNanoseconds: 0)
                }
            }
        }
    }

    func cancelOCR() {
        ocrTask?.cancel()
        ocrTask = nil
        isRunningOCR = false
        ocrProgressText = nil
    }

    func cancelActiveTasks() {
        indexTask?.cancel()
        searchTask?.cancel()
        isIndexing = false
        isSearching = false
    }

    func recordRecentQuery(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = recentQueries.filter {
            $0.compare(trimmed, options: LibrarySearchMatcher.compareOptions) != .orderedSame
        }
        updated.insert(trimmed, at: 0)
        if updated.count > Self.maxRecentQueries {
            updated = Array(updated.prefix(Self.maxRecentQueries))
        }
        recentQueries = updated
        UserDefaults.standard.set(updated, forKey: Self.recentQueriesKey)
    }

    func clearRecentQueries() {
        recentQueries = []
        UserDefaults.standard.removeObject(forKey: Self.recentQueriesKey)
    }

    nonisolated private static func executeSearch(tokens: [String],
                                                  inputs: [SearchDocumentInput],
                                                  store: LibrarySearchIndexStore) async -> [FullTextDocumentResult] {
        await Task.detached(priority: .userInitiated) {
            var matched: [FullTextDocumentResult] = []
            for input in inputs {
                if Task.isCancelled { return [] }
                let cache = await store.cachedText(for: input, performOCR: false)
                if Task.isCancelled { return [] }
                if let result = LibrarySearchMatcher.matchDocument(input, cache: cache, tokens: tokens) {
                    matched.append(result)
                }
            }
            matched.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.meta.modifiedAt > rhs.meta.modifiedAt
            }
            return matched
        }.value
    }

    nonisolated private static func countUnindexedImagePDFs(inputs: [SearchDocumentInput],
                                                            store: LibrarySearchIndexStore) async -> Int {
        var count = 0
        for input in inputs where input.meta.layout != .live && input.meta.sourceKind != .blankNotebook {
            let cache = await store.cachedText(for: input, performOCR: false)
            if cache.hasUnrecognizedImagePages {
                count += 1
            }
        }
        return count
    }
}
