import Foundation

// MARK: - UTF-8 BOM handling

enum BOM {
    /// Strip a leading UTF-8 byte-order-mark (EF BB BF) from raw bytes.
    static func stripUTF8(_ data: Data) -> Data {
        guard data.count >= 3,
              data[data.startIndex] == 0xEF,
              data[data.startIndex + 1] == 0xBB,
              data[data.startIndex + 2] == 0xBF
        else { return data }
        return data.subdata(in: (data.startIndex + 3)..<data.endIndex)
    }

    /// Strip a leading BOM from a decoded string (covers the case where the
    /// bytes were already decoded and the BOM survived as U+FEFF).
    static func stripString(_ s: String) -> String {
        if s.hasPrefix("\u{FEFF}") { return String(s.dropFirst()) }
        return s
    }
}

// MARK: - Header normalization

enum HeaderNorm {
    /// Normalize a CSV header to a stable lookup key.
    ///
    /// lowercase, `%`→`pct`, drop parens (keep inner content), collapse runs of
    /// non-alphanumerics to `_`, trim `_`. Mirrors the reference Python parser so
    /// the same field aliases apply.
    ///   "Heart rate variability (ms)" -> "heart_rate_variability_ms"
    ///   "Recovery score %"            -> "recovery_score_pct"
    static func normalize(_ header: String) -> String {
        var s = header.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "%", with: "pct")
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasUnderscore = false
        for ch in s {
            if ch.isLetter || ch.isNumber, ch.isASCII {
                out.append(ch)
                lastWasUnderscore = false
            } else {
                // Any non-alphanumeric (including parens, spaces, slashes, etc.)
                // becomes a single underscore.
                if !lastWasUnderscore {
                    out.append("_")
                    lastWasUnderscore = true
                }
            }
        }
        // Trim leading/trailing underscores.
        while out.hasPrefix("_") { out.removeFirst() }
        while out.hasSuffix("_") { out.removeLast() }
        return out
    }
}

// MARK: - Tolerant CSV reader

/// A tolerant, header-name-driven CSV parser.
///
/// - Handles UTF-8 BOM, quoted fields with embedded commas/quotes/newlines
///   (RFC-4180 style with `""` escaping), and CRLF or LF line endings.
/// - Exposes rows as `[normalizedHeader: rawCellString]` so callers match
///   columns by name; missing columns simply return `nil`.
struct CSVTable {
    /// Original header strings, in file order.
    let headers: [String]
    /// Normalized header keys, parallel to `headers`.
    let normalizedHeaders: [String]
    /// Rows; each is a normalized-key → cell-value dictionary.
    let rows: [[String: String]]

    /// Parse CSV text (BOM already advisable to strip, but handled here too).
    init(text rawText: String) {
        let text = BOM.stripString(rawText)
        var records = CSVTable.parseRecords(text)
        guard !records.isEmpty else {
            self.headers = []
            self.normalizedHeaders = []
            self.rows = []
            return
        }
        let headerRow = records.removeFirst()
        self.headers = headerRow
        let normHeaders = headerRow.map { HeaderNorm.normalize($0) }
        self.normalizedHeaders = normHeaders

        var parsedRows: [[String: String]] = []
        parsedRows.reserveCapacity(records.count)
        for fields in records {
            // Skip completely blank lines.
            if fields.count == 1, fields[0].trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            var dict: [String: String] = [:]
            for (i, key) in normHeaders.enumerated() where !key.isEmpty {
                let value = i < fields.count ? fields[i] : ""
                // First non-empty header wins if duplicated (rare).
                if dict[key] == nil || dict[key]!.isEmpty {
                    dict[key] = value
                }
            }
            parsedRows.append(dict)
        }
        self.rows = parsedRows
    }

    /// Parse from raw `Data` (strips UTF-8 BOM, decodes UTF-8 with a latin-1
    /// fallback for the rare malformed export).
    init(data: Data) {
        let clean = BOM.stripUTF8(data)
        let text = String(data: clean, encoding: .utf8)
            ?? String(data: clean, encoding: .isoLatin1)
            ?? ""
        self.init(text: text)
    }

    // MARK: RFC-4180-ish record splitter

    /// Split CSV text into records of fields, honouring quotes and escaped
    /// quotes, and treating CRLF / CR / LF uniformly as row terminators.
    static func parseRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var sawAnyField = false

        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func nextScalar() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let scalar = nextScalar() {
            if inQuotes {
                if scalar == "\"" {
                    // Look ahead for an escaped quote ("").
                    if let look = iterator.next() {
                        if look == "\"" {
                            field.unicodeScalars.append("\"")
                        } else {
                            inQuotes = false
                            pending = look
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
            } else {
                switch scalar {
                case "\"":
                    inQuotes = true
                    sawAnyField = true
                case ",":
                    record.append(field)
                    field = ""
                    sawAnyField = true
                case "\r":
                    // Consume an optional following \n (CRLF).
                    if let look = iterator.next(), look != "\n" {
                        pending = look
                    }
                    record.append(field)
                    records.append(record)
                    field = ""
                    record = []
                    sawAnyField = false
                case "\n":
                    record.append(field)
                    records.append(record)
                    field = ""
                    record = []
                    sawAnyField = false
                default:
                    field.unicodeScalars.append(scalar)
                    sawAnyField = true
                }
            }
        }
        // Flush the final field/record if the file didn't end with a newline.
        if sawAnyField || !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }
}

// MARK: - Cell accessors

extension Dictionary where Key == String, Value == String {
    /// First non-empty cell among the given normalized keys, trimmed; `nil` if
    /// absent or blank.
    func cell(_ keys: String...) -> String? {
        for k in keys {
            if let v = self[k] {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    /// Parse a cell as a `Double`, tolerating thousands separators and stray
    /// units accidentally left in the cell.
    func double(_ keys: String...) -> Double? {
        for k in keys {
            if let v = self[k] {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                if let d = Double(t) { return d }
                // Tolerate values like "1,234" or "62 ms".
                let cleaned = t
                    .replacingOccurrences(of: ",", with: "")
                    .components(separatedBy: CharacterSet(charactersIn: "0123456789.+-eE").inverted)
                    .joined()
                if let d = Double(cleaned) { return d }
            }
        }
        return nil
    }

    /// Parse a cell as a boolean (`true`/`yes`/`1`).
    func bool(_ keys: String...) -> Bool? {
        for k in keys {
            if let v = self[k] {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if t.isEmpty { continue }
                if ["true", "yes", "1", "y"].contains(t) { return true }
                if ["false", "no", "0", "n"].contains(t) { return false }
            }
        }
        return nil
    }
}

// MARK: - Whoop timestamp parsing

enum WhoopTime {
    /// Parse a `Cycle timezone` string like `UTC+01:00`, `UTC-05:00`, `+01:00`,
    /// or `Z` into an offset in **minutes**.
    static func tzOffsetMinutes(_ raw: String?) -> Int {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return 0 }
        let upper = s.uppercased()
        if upper == "UTC" || upper == "Z" || upper == "GMT" { return 0 }
        if upper.hasPrefix("UTC") { s = String(s.dropFirst(3)) }
        else if upper.hasPrefix("GMT") { s = String(s.dropFirst(3)) }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "Z" { return 0 }

        var sign = 1
        if s.hasPrefix("+") { s.removeFirst() }
        else if s.hasPrefix("-") { sign = -1; s.removeFirst() }

        // Accept HH:MM or HHMM.
        let comps = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var hours = 0, minutes = 0
        if comps.count == 2 {
            hours = Int(comps[0]) ?? 0
            minutes = Int(comps[1]) ?? 0
        } else {
            let digits = String(s.prefix(while: { $0.isNumber }))
            if digits.count >= 3 {
                hours = Int(digits.prefix(digits.count - 2)) ?? 0
                minutes = Int(digits.suffix(2)) ?? 0
            } else {
                hours = Int(digits) ?? 0
            }
        }
        return sign * (hours * 60 + minutes)
    }

    /// Parse a Whoop CSV timestamp `YYYY-MM-DD HH:MM:SS` interpreted in the
    /// timezone given by `offsetMinutes`, returning a UTC `Date`.
    ///
    /// Some exports already include an offset inside the timestamp itself
    /// (e.g. `2024-01-02 03:04:05+0000`); when present that wins.
    static func parse(_ raw: String?, offsetMinutes: Int) -> Date? {
        guard let s0 = raw?.trimmingCharacters(in: .whitespaces), !s0.isEmpty else { return nil }

        // 1) ISO-8601 with embedded offset (e.g. "...T...Z", "...+01:00").
        if let d = isoFormatter.date(from: s0) { return d }
        if let d = isoFormatterFractional.date(from: s0) { return d }

        // 2) Plain "YYYY-MM-DD HH:MM:SS" or with a 'T'.
        let normalized = s0.replacingOccurrences(of: "T", with: " ")
        // Reuse one formatter (allocating a DateFormatter per CSV row was a measurable cost on
        // imports with tens of thousands of rows). Imports run on a single thread, so the shared
        // mutable formatter is safe; only timeZone/dateFormat are set per parse.
        let fmt = plainFormatter
        fmt.timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60) ?? TimeZone(identifier: "UTC")!
        for pattern in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            fmt.dateFormat = pattern
            if let d = fmt.date(from: normalized) { return d }
        }
        return nil
    }

    private static let plainFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
