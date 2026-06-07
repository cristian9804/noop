package com.noop.ingest

/*
 * Tolerant, header-name-driven CSV reader.
 *
 * Direct Kotlin port of the macOS source of truth:
 *   Packages/StrandImport/Sources/StrandImport/CSVParsing.swift
 *
 * It must behave identically to the Swift `CSVTable` / `HeaderNorm` / `WhoopTime`
 * so the same column aliases, date parsing and unit handling apply:
 *   - UTF-8 BOM is stripped (raw bytes and decoded string).
 *   - Headers are normalized: lowercase, `%`->`pct`, drop parens (keep inner
 *     content), collapse non-alphanumerics to `_`, trim `_`.
 *   - Quoted fields (RFC-4180 `""` escaping) with embedded commas / quotes /
 *     newlines are honoured; CRLF / CR / LF are all treated as row terminators.
 *   - Rows are exposed as normalizedHeader -> rawCellString; missing columns
 *     return null. Columns are matched by name, never position.
 */

// MARK: - UTF-8 BOM handling

internal object Bom {
    /** Strip a leading UTF-8 byte-order-mark (EF BB BF) from raw bytes. */
    fun stripUtf8(data: ByteArray): ByteArray {
        if (data.size >= 3 &&
            data[0] == 0xEF.toByte() &&
            data[1] == 0xBB.toByte() &&
            data[2] == 0xBF.toByte()
        ) {
            return data.copyOfRange(3, data.size)
        }
        return data
    }

    /** Strip a leading BOM (U+FEFF) that survived string decoding. */
    fun stripString(s: String): String =
        if (s.isNotEmpty() && s[0] == '﻿') s.substring(1) else s
}

// MARK: - Header normalization

internal object HeaderNorm {
    /**
     * Normalize a CSV header to a stable lookup key.
     *
     * lowercase, `%`->`pct`, any non-ASCII-alphanumeric run -> single `_`, trim `_`.
     *   "Heart rate variability (ms)" -> "heart_rate_variability_ms"
     *   "Recovery score %"            -> "recovery_score_pct"
     */
    fun normalize(header: String): String {
        var s = header.lowercase().trim()
        s = s.replace("%", "pct")
        val out = StringBuilder(s.length)
        var lastWasUnderscore = false
        for (ch in s) {
            // ASCII letters / digits are kept; everything else collapses to `_`.
            val isAsciiAlnum = (ch in 'a'..'z') || (ch in '0'..'9')
            if (isAsciiAlnum) {
                out.append(ch)
                lastWasUnderscore = false
            } else {
                if (!lastWasUnderscore) {
                    out.append('_')
                    lastWasUnderscore = true
                }
            }
        }
        var result = out.toString()
        while (result.startsWith("_")) result = result.substring(1)
        while (result.endsWith("_")) result = result.substring(0, result.length - 1)
        return result
    }
}

// MARK: - Tolerant CSV reader

/**
 * A parsed CSV table. Rows are normalized-key -> cell-value maps; callers match
 * columns by name. Mirrors Swift `CSVTable`.
 */
internal class CsvTable private constructor(
    val headers: List<String>,
    val normalizedHeaders: List<String>,
    val rows: List<Map<String, String>>,
) {
    companion object {
        /** Parse from raw bytes: strip UTF-8 BOM, decode UTF-8 then Latin-1 fallback. */
        fun fromData(data: ByteArray): CsvTable {
            val clean = Bom.stripUtf8(data)
            val text = decode(clean)
            return fromText(text)
        }

        private fun decode(bytes: ByteArray): String {
            // Try strict UTF-8; on malformed input fall back to Latin-1 (every byte maps).
            return try {
                val decoder = Charsets.UTF_8.newDecoder()
                    .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                    .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
                decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString()
            } catch (_: Exception) {
                String(bytes, Charsets.ISO_8859_1)
            }
        }

        /** Parse CSV text. */
        fun fromText(rawText: String): CsvTable {
            val text = Bom.stripString(rawText)
            val records = parseRecords(text).toMutableList()
            if (records.isEmpty()) {
                return CsvTable(emptyList(), emptyList(), emptyList())
            }
            val headerRow = records.removeAt(0)
            val normHeaders = headerRow.map { HeaderNorm.normalize(it) }

            val parsedRows = ArrayList<Map<String, String>>(records.size)
            for (fields in records) {
                // Skip completely blank lines (single empty/whitespace field).
                if (fields.size == 1 && fields[0].trim().isEmpty()) continue
                val dict = HashMap<String, String>(normHeaders.size)
                for (i in normHeaders.indices) {
                    val key = normHeaders[i]
                    if (key.isEmpty()) continue
                    val value = if (i < fields.size) fields[i] else ""
                    // First non-empty header wins if duplicated (rare).
                    val existing = dict[key]
                    if (existing == null || existing.isEmpty()) {
                        dict[key] = value
                    }
                }
                parsedRows.add(dict)
            }
            return CsvTable(headerRow, normHeaders, parsedRows)
        }

        // MARK: RFC-4180-ish record splitter

        /**
         * Split CSV text into records of fields, honouring quotes and `""` escapes,
         * and treating CRLF / CR / LF uniformly as row terminators.
         * Faithful port of `CSVTable.parseRecords` (operates on Unicode code points).
         */
        fun parseRecords(text: String): List<List<String>> {
            val records = ArrayList<List<String>>()
            val field = StringBuilder()
            var record = ArrayList<String>()
            var inQuotes = false
            var sawAnyField = false

            // Iterate over Unicode code points (parity with Swift's unicodeScalars).
            val codePoints = ArrayList<Int>(text.length)
            var idx = 0
            while (idx < text.length) {
                val cp = text.codePointAt(idx)
                codePoints.add(cp)
                idx += Character.charCount(cp)
            }

            var pos = 0
            var pending: Int? = null

            fun nextScalar(): Int? {
                pending?.let { pending = null; return it }
                return if (pos < codePoints.size) codePoints[pos++] else null
            }
            fun peekConsume(): Int? = if (pos < codePoints.size) codePoints[pos++] else null

            val quote = '"'.code
            val comma = ','.code
            val cr = '\r'.code
            val lf = '\n'.code

            while (true) {
                val scalar = nextScalar() ?: break
                if (inQuotes) {
                    if (scalar == quote) {
                        // Look ahead for an escaped quote ("").
                        val look = peekConsume()
                        if (look != null) {
                            if (look == quote) {
                                field.appendCodePoint(quote)
                            } else {
                                inQuotes = false
                                pending = look
                            }
                        } else {
                            inQuotes = false
                        }
                    } else {
                        field.appendCodePoint(scalar)
                    }
                } else {
                    when (scalar) {
                        quote -> {
                            inQuotes = true
                            sawAnyField = true
                        }
                        comma -> {
                            record.add(field.toString())
                            field.setLength(0)
                            sawAnyField = true
                        }
                        cr -> {
                            // Consume an optional following \n (CRLF).
                            val look = peekConsume()
                            if (look != null && look != lf) {
                                pending = look
                            }
                            record.add(field.toString())
                            records.add(record)
                            field.setLength(0)
                            record = ArrayList()
                            sawAnyField = false
                        }
                        lf -> {
                            record.add(field.toString())
                            records.add(record)
                            field.setLength(0)
                            record = ArrayList()
                            sawAnyField = false
                        }
                        else -> {
                            field.appendCodePoint(scalar)
                            sawAnyField = true
                        }
                    }
                }
            }
            // Flush the final field/record if the file didn't end with a newline.
            if (sawAnyField || field.isNotEmpty() || record.isNotEmpty()) {
                record.add(field.toString())
                records.add(record)
            }
            return records
        }
    }
}

// MARK: - Cell accessors (mirror the Swift Dictionary extension)

/** First non-empty cell among the given normalized keys, trimmed; null if absent/blank. */
internal fun Map<String, String>.cell(vararg keys: String): String? {
    for (k in keys) {
        val v = this[k] ?: continue
        val t = v.trim()
        if (t.isNotEmpty()) return t
    }
    return null
}

/**
 * Parse a cell as a Double across the given keys, tolerating thousands separators
 * and stray units accidentally left in the cell (e.g. "1,234" or "62 ms").
 */
internal fun Map<String, String>.double(vararg keys: String): Double? {
    for (k in keys) {
        val v = this[k] ?: continue
        val t = v.trim()
        if (t.isEmpty()) continue
        t.toDoubleOrNull()?.let { return it }
        // Tolerate values like "1,234" or "62 ms": strip commas, keep only numeric chars.
        val allowed = "0123456789.+-eE"
        val cleaned = buildString {
            for (ch in t.replace(",", "")) {
                if (ch in allowed) append(ch)
            }
        }
        cleaned.toDoubleOrNull()?.let { return it }
    }
    return null
}

/** Parse a cell as a boolean (`true`/`yes`/`1`/`y` vs `false`/`no`/`0`/`n`); null otherwise. */
internal fun Map<String, String>.bool(vararg keys: String): Boolean? {
    for (k in keys) {
        val v = this[k] ?: continue
        val t = v.trim().lowercase()
        if (t.isEmpty()) continue
        if (t == "true" || t == "yes" || t == "1" || t == "y") return true
        if (t == "false" || t == "no" || t == "0" || t == "n") return false
    }
    return null
}

// MARK: - Whoop timestamp parsing (mirror Swift WhoopTime)

internal object WhoopTime {

    /**
     * Parse a `Cycle timezone` string like `UTC+01:00`, `UTC-05:00`, `+01:00`, or
     * `Z` into an offset in **minutes**. Returns 0 for UTC / GMT / Z / blank.
     */
    fun tzOffsetMinutes(raw: String?): Int {
        var s = raw?.trim() ?: return 0
        if (s.isEmpty()) return 0
        val upper = s.uppercase()
        if (upper == "UTC" || upper == "Z" || upper == "GMT") return 0
        if (upper.startsWith("UTC")) s = s.substring(3)
        else if (upper.startsWith("GMT")) s = s.substring(3)
        s = s.trim()
        if (s.isEmpty() || s == "Z") return 0

        var sign = 1
        if (s.startsWith("+")) s = s.substring(1)
        else if (s.startsWith("-")) { sign = -1; s = s.substring(1) }

        // Accept HH:MM or HHMM.
        var hours = 0
        var minutes = 0
        val colonIdx = s.indexOf(':')
        if (colonIdx >= 0) {
            hours = s.substring(0, colonIdx).toIntOrNull() ?: 0
            minutes = s.substring(colonIdx + 1).toIntOrNull() ?: 0
        } else {
            val digits = s.takeWhile { it.isDigit() }
            if (digits.length >= 3) {
                hours = digits.substring(0, digits.length - 2).toIntOrNull() ?: 0
                minutes = digits.substring(digits.length - 2).toIntOrNull() ?: 0
            } else {
                hours = digits.toIntOrNull() ?: 0
            }
        }
        return sign * (hours * 60 + minutes)
    }

    /**
     * Parse a Whoop CSV timestamp interpreted in the timezone given by
     * [offsetMinutes], returning **UTC unix epoch SECONDS** (Long), or null.
     *
     * Mirrors Swift `WhoopTime.parse`:
     *   1. ISO-8601 with embedded offset (e.g. "...T...Z", "...+01:00", fractional secs) wins.
     *   2. Otherwise plain "YYYY-MM-DD HH:MM:SS" / " HH:MM" / "YYYY-MM-DD",
     *      interpreted at the supplied offset.
     */
    fun parseEpochSeconds(raw: String?, offsetMinutes: Int): Long? {
        val s0 = raw?.trim() ?: return null
        if (s0.isEmpty()) return null

        // 1) ISO-8601 with an embedded offset / Z (own offset wins).
        parseIso(s0)?.let { return it }

        // 2) Plain timestamp at the supplied offset. Normalize 'T' to space.
        val normalized = s0.replace("T", " ")
        val zoneOffset = try {
            java.time.ZoneOffset.ofTotalSeconds(offsetMinutes * 60)
        } catch (_: Exception) {
            java.time.ZoneOffset.UTC
        }
        // "yyyy-MM-dd HH:mm:ss"
        runCatching {
            val ldt = java.time.LocalDateTime.parse(
                normalized, FULL_DATETIME
            )
            return ldt.toEpochSecond(zoneOffset)
        }
        // "yyyy-MM-dd HH:mm"
        runCatching {
            val ldt = java.time.LocalDateTime.parse(
                normalized, MINUTE_DATETIME
            )
            return ldt.toEpochSecond(zoneOffset)
        }
        // "yyyy-MM-dd"
        runCatching {
            val ld = java.time.LocalDate.parse(normalized, DATE_ONLY)
            return ld.atStartOfDay(zoneOffset).toEpochSecond()
        }
        return null
    }

    /** Parse an ISO-8601 string carrying its own offset/zone into epoch seconds. */
    private fun parseIso(s: String): Long? {
        // OffsetDateTime handles "Z" and "+01:00" plus optional fractional seconds.
        runCatching {
            return java.time.OffsetDateTime.parse(s).toEpochSecond()
        }
        // Some exports use "+0000" (no colon). Try Instant for a trailing 'Z'.
        runCatching {
            return java.time.Instant.parse(s).epochSecond
        }
        return null
    }

    private val FULL_DATETIME: java.time.format.DateTimeFormatter =
        java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")
    private val MINUTE_DATETIME: java.time.format.DateTimeFormatter =
        java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
    private val DATE_ONLY: java.time.format.DateTimeFormatter =
        java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd")
}
