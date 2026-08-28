import Foundation

/// Behaviour-free parsing chores shared by the provider mappers and auth
/// stores. Lives in one place so Claude and Codex can never drift on how a
/// number, a timestamp, or a credential blob is read.
enum ProviderParse {
    /// Top-level JSON object from raw response data. Returns `nil` for an empty
    /// body, a malformed body, or a valid-but-non-object payload. Nothing about
    /// the body is logged (research doc §9.2 п.9).
    static func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Permissive numeric read: JSON numbers and numeric strings, rejecting
    /// booleans (which `JSONSerialization` bridges through `NSNumber`) and
    /// non-finite values.
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue.isFinite ? number.doubleValue : nil
        }
        if let string = value as? String {
            guard let parsed = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)),
                  parsed.isFinite
            else {
                return nil
            }
            return parsed
        }
        return nil
    }

    /// Decode `T` from JSON text, falling back to a hex-encoded JSON blob —
    /// some CLI tools store their credentials file/Keychain item as hex
    /// (optionally `0x`-prefixed) rather than plain JSON.
    static func decodeJSONWithHexFallback<T: Decodable>(_ text: String, as type: T.Type) -> T? {
        if let decoded = decodeJSON(text, as: type) { return decoded }

        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex = String(hex.dropFirst(2))
        }
        guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit),
              let bytes = Data(hexEncoded: hex),
              let decoded = String(data: bytes, encoding: .utf8)
        else {
            return nil
        }
        return decodeJSON(decoded, as: type)
    }

    private static func decodeJSON<T: Decodable>(_ text: String, as type: T.Type) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// A JWT's payload (the middle dot-separated segment) as a JSON object.
    /// Used only to read the `exp` claim of an access token we already hold —
    /// never to log or transmit any part of it.
    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !payload.count.isMultiple(of: 4) {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A reset timestamp that may arrive as an ISO-8601 string **or** as a
    /// number. Claude sends both shapes for `resets_at`; the numeric form is
    /// seconds when small and milliseconds when large (research doc §9.3).
    /// `nil` (or an unparseable value) means "the window has not started" —
    /// callers must not substitute a date or a 0% reading.
    static func timestamp(_ value: Any?) -> Date? {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return ISO8601.date(from: text)
        }
        guard let number = number(value), number.isFinite else { return nil }
        let milliseconds = abs(number) < 1e10 ? number * 1000 : number
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// Title-case a plan name: split on `isSeparator`, upper-case each word's
    /// first character, re-join with single spaces.
    static func titleCased(
        _ value: String,
        separator isSeparator: (Character) -> Bool,
        lowercasingTail: Bool = false
    ) -> String {
        value
            .split(whereSeparator: isSeparator)
            .map { word in
                let head = word.prefix(1).uppercased()
                let tail = lowercasingTail ? word.dropFirst().lowercased() : String(word.dropFirst())
                return head + tail
            }
            .joined(separator: " ")
    }
}

/// Merging an update into a credential document without losing the keys Mana
/// does not model.
///
/// The CLI tools own these files: `~/.codex/auth.json` carries `auth_mode`,
/// and either tool may add fields in a future release. Re-encoding only the
/// fields Mana decodes would silently delete the rest, so a rotation is merged
/// onto the document actually on disk (ТЗ §4.2).
enum JSONMerge {
    /// Deep merge: nested objects merge recursively, every other value in
    /// `updates` replaces its counterpart in `base`. Keys absent from `updates`
    /// are left untouched.
    static func merge(_ base: [String: Any], _ updates: [String: Any]) -> [String: Any] {
        var merged = base
        for (key, value) in updates {
            if let nested = value as? [String: Any],
               let existing = merged[key] as? [String: Any] {
                merged[key] = merge(existing, nested)
            } else {
                merged[key] = value
            }
        }
        return merged
    }

    /// Encodes `value`, merges it onto `baseText`'s JSON object, and returns the
    /// serialized result. `nil` when the base is not a JSON object (e.g. a
    /// hex-encoded credential blob) — in which case the caller must skip the
    /// write rather than replace a format it does not understand.
    static func merged<T: Encodable>(
        into baseText: String,
        updating value: T,
        prettyPrinted: Bool
    ) -> String? {
        guard let base = ProviderParse.jsonObject(Data(baseText.utf8)),
              let encoded = try? JSONEncoder().encode(value),
              let updates = ProviderParse.jsonObject(encoded)
        else {
            return nil
        }
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if prettyPrinted { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(
            withJSONObject: merge(base, updates),
            options: options
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// ISO-8601 parsing that tolerates the shapes these APIs actually return
/// (with and without fractional seconds, space-separated, trailing " UTC").
enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(from date: Date) -> String {
        fractional.string(from: date)
    }

    static func date(from value: String) -> Date? {
        let normalized = normalize(value)
        return fractional.date(from: normalized) ?? plain.date(from: normalized)
    }

    private static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        if let range = text.range(
            of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#,
            options: .regularExpression
        ) {
            text.replaceSubrange(range, with: text[range].replacingOccurrences(of: " ", with: "T"))
        }
        if text.hasSuffix(" UTC") {
            text = String(text.dropLast(4)) + "Z"
        }
        // A bare date-time with no zone designator is UTC in these payloads.
        if text.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?$"#,
            options: .regularExpression
        ) != nil {
            text += "Z"
        }
        return text
    }
}

extension Data {
    init?(hexEncoded hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

extension String {
    /// Percent-encode one `application/x-www-form-urlencoded` value: only the
    /// RFC 3986 unreserved characters pass through, spaces become `%20`.
    var urlFormEncoded: String {
        var encoded = ""
        encoded.reserveCapacity(utf8.count)
        for byte in utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                encoded.append(Character(UnicodeScalar(byte)))
            default:
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded
    }

    var trimmingTrailingSlashes: String {
        var copy = self
        while copy.hasSuffix("/") { copy.removeLast() }
        return copy
    }

    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
