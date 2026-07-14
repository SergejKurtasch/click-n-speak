import Foundation

/// Dynamic JSON value that preserves object key order and the int/double
/// distinction, and serializes byte-compatibly with Python's
/// `json.dump(obj, indent=4)` (the format `config.json` is written in by the
/// Python version). This is the storage layer under `Config`: modelling the
/// config as dynamic JSON (rather than a fixed Codable struct) guarantees that
/// unknown keys a user hand-edited into the file survive a read/write round-trip,
/// exactly as the Python dict-based code does.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

/// Insertion-ordered string-keyed JSON object.
public struct JSONObject: Sendable, Equatable {
    public private(set) var keys: [String]
    private var map: [String: JSONValue]

    public init() {
        keys = []
        map = [:]
    }

    public init(_ pairs: [(String, JSONValue)]) {
        keys = []
        map = [:]
        for (k, v) in pairs { self[k] = v }
    }

    public subscript(_ key: String) -> JSONValue? {
        get { map[key] }
        set {
            if let newValue {
                if map[key] == nil { keys.append(key) }
                map[key] = newValue
            } else {
                remove(key)
            }
        }
    }

    public func contains(_ key: String) -> Bool { map[key] != nil }

    @discardableResult
    public mutating func remove(_ key: String) -> JSONValue? {
        guard let existing = map.removeValue(forKey: key) else { return nil }
        keys.removeAll { $0 == key }
        return existing
    }

    /// Set the key only if absent (mirrors Python `dict.setdefault`).
    @discardableResult
    public mutating func setDefault(_ key: String, _ value: @autoclosure () -> JSONValue) -> JSONValue {
        if let existing = map[key] { return existing }
        let v = value()
        self[key] = v
        return v
    }

    public var pairs: [(String, JSONValue)] { keys.map { ($0, map[$0]!) } }
}

// MARK: - Convenience accessors

public extension JSONValue {
    var objectValue: JSONObject? { if case let .object(o) = self { return o }; return nil }
    var arrayValue: [JSONValue]? { if case let .array(a) = self { return a }; return nil }
    var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }

    var intValue: Int64? {
        switch self {
        case let .int(i): return i
        case let .double(d): return Int64(d)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .double(d): return d
        case let .int(i): return Double(i)
        default: return nil
        }
    }

    /// Python truthiness for the values that appear in config logic:
    /// null/false/0/""/[]/{} are falsy.
    var isTruthy: Bool {
        switch self {
        case .null: return false
        case let .bool(b): return b
        case let .int(i): return i != 0
        case let .double(d): return d != 0
        case let .string(s): return !s.isEmpty
        case let .array(a): return !a.isEmpty
        case let .object(o): return !o.keys.isEmpty
        }
    }
}

// MARK: - Semantic equality

public extension JSONValue {
    /// Compare two JSON values ignoring object key order (objects compared as
    /// key→value maps). Used by tests where JSON object ordering is not
    /// semantically significant.
    func semanticallyEqual(to other: JSONValue) -> Bool {
        switch (self, other) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.int(a), .double(b)), let (.double(b), .int(a)): return Double(a) == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.semanticallyEqual(to: $1) }
        case let (.object(a), .object(b)):
            guard Set(a.keys) == Set(b.keys) else { return false }
            for key in a.keys {
                guard let av = a[key], let bv = b[key], av.semanticallyEqual(to: bv) else { return false }
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - Parsing

public extension JSONValue {
    enum ParseError: Error, Sendable {
        case notUTF8
        case invalid(String)
    }

    /// Parse JSON text into an ordered `JSONValue`, preserving object key order
    /// and the int/double distinction of numeric literals.
    static func parse(_ text: String) throws -> JSONValue {
        var parser = JSONParser(text)
        let value = try parser.parseValue()
        parser.skipWhitespace()
        if !parser.isAtEnd {
            throw ParseError.invalid("Trailing content after JSON value")
        }
        return value
    }

    static func parse(data: Data) throws -> JSONValue {
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError.notUTF8 }
        return try parse(text)
    }
}

private struct JSONParser {
    private let scalars: [Unicode.Scalar]
    private var index: Int = 0

    init(_ text: String) { scalars = Array(text.unicodeScalars) }

    var isAtEnd: Bool { index >= scalars.count }

    mutating func skipWhitespace() {
        while index < scalars.count {
            let c = scalars[index]
            if c == " " || c == "\t" || c == "\n" || c == "\r" { index += 1 } else { break }
        }
    }

    private mutating func peek() -> Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

    mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard let c = peek() else { throw JSONValue.ParseError.invalid("Unexpected end of input") }
        switch c {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t", "f": return try parseBool()
        case "n": return try parseNull()
        default: return try parseNumber()
        }
    }

    private mutating func expect(_ scalar: Unicode.Scalar) throws {
        guard peek() == scalar else {
            throw JSONValue.ParseError.invalid("Expected '\(scalar)'")
        }
        index += 1
    }

    private mutating func parseObject() throws -> JSONValue {
        try expect("{")
        var obj = JSONObject()
        skipWhitespace()
        if peek() == "}" { index += 1; return .object(obj) }
        while true {
            skipWhitespace()
            let key = try parseString()
            skipWhitespace()
            try expect(":")
            let value = try parseValue()
            obj[key] = value
            skipWhitespace()
            guard let c = peek() else { throw JSONValue.ParseError.invalid("Unterminated object") }
            if c == "," { index += 1; continue }
            if c == "}" { index += 1; break }
            throw JSONValue.ParseError.invalid("Expected ',' or '}' in object")
        }
        return .object(obj)
    }

    private mutating func parseArray() throws -> JSONValue {
        try expect("[")
        var arr: [JSONValue] = []
        skipWhitespace()
        if peek() == "]" { index += 1; return .array(arr) }
        while true {
            let value = try parseValue()
            arr.append(value)
            skipWhitespace()
            guard let c = peek() else { throw JSONValue.ParseError.invalid("Unterminated array") }
            if c == "," { index += 1; continue }
            if c == "]" { index += 1; break }
            throw JSONValue.ParseError.invalid("Expected ',' or ']' in array")
        }
        return .array(arr)
    }

    private mutating func parseString() throws -> String {
        try expect("\"")
        var result = String.UnicodeScalarView()
        while let c = peek() {
            index += 1
            if c == "\"" { return String(result) }
            if c == "\\" {
                guard let esc = peek() else { throw JSONValue.ParseError.invalid("Unterminated escape") }
                index += 1
                switch esc {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append(Unicode.Scalar(0x08))
                case "f": result.append(Unicode.Scalar(0x0C))
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u":
                    let cp = try parseHex4()
                    if cp >= 0xD800 && cp <= 0xDBFF {
                        // High surrogate — expect a low surrogate next.
                        guard peek() == "\\" else { throw JSONValue.ParseError.invalid("Expected low surrogate") }
                        index += 1
                        guard peek() == "u" else { throw JSONValue.ParseError.invalid("Expected \\u low surrogate") }
                        index += 1
                        let low = try parseHex4()
                        let combined = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)
                        guard let scalar = Unicode.Scalar(combined) else {
                            throw JSONValue.ParseError.invalid("Invalid surrogate pair")
                        }
                        result.append(scalar)
                    } else {
                        guard let scalar = Unicode.Scalar(cp) else {
                            throw JSONValue.ParseError.invalid("Invalid unicode scalar")
                        }
                        result.append(scalar)
                    }
                default:
                    throw JSONValue.ParseError.invalid("Invalid escape '\\\(esc)'")
                }
            } else {
                result.append(c)
            }
        }
        throw JSONValue.ParseError.invalid("Unterminated string")
    }

    private mutating func parseHex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let c = peek() else { throw JSONValue.ParseError.invalid("Unterminated \\u escape") }
            index += 1
            let d: UInt32
            switch c {
            case "0"..."9": d = c.value - 48
            case "a"..."f": d = c.value - 97 + 10
            case "A"..."F": d = c.value - 65 + 10
            default: throw JSONValue.ParseError.invalid("Invalid hex digit")
            }
            value = value * 16 + d
        }
        return value
    }

    private mutating func parseBool() throws -> JSONValue {
        if match("true") { return .bool(true) }
        if match("false") { return .bool(false) }
        throw JSONValue.ParseError.invalid("Invalid literal")
    }

    private mutating func parseNull() throws -> JSONValue {
        if match("null") { return .null }
        throw JSONValue.ParseError.invalid("Invalid literal")
    }

    private mutating func match(_ literal: String) -> Bool {
        let lit = Array(literal.unicodeScalars)
        guard index + lit.count <= scalars.count else { return false }
        for (offset, s) in lit.enumerated() where scalars[index + offset] != s { return false }
        index += lit.count
        return true
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        var isDouble = false
        if peek() == "-" { index += 1 }
        while let c = peek() {
            switch c {
            case "0"..."9": index += 1
            case ".", "e", "E", "+", "-":
                if c == "." || c == "e" || c == "E" { isDouble = true }
                index += 1
            default:
                return try makeNumber(from: start, isDouble: isDouble)
            }
        }
        return try makeNumber(from: start, isDouble: isDouble)
    }

    private func makeNumber(from start: Int, isDouble: Bool) throws -> JSONValue {
        let literal = String(String.UnicodeScalarView(scalars[start..<index]))
        if !isDouble, let i = Int64(literal) { return .int(i) }
        guard let d = Double(literal) else { throw JSONValue.ParseError.invalid("Invalid number '\(literal)'") }
        return .double(d)
    }
}

// MARK: - Serialization (Python json.dump compatible)

public extension JSONValue {
    /// Serialize matching Python's `json.dump(obj, indent=4)` defaults:
    /// 4-space indent, `", "` / `": "` separators collapsed to `,\n`/`": "`,
    /// and `ensure_ascii=True` (non-ASCII escaped as `\uXXXX`). Object key order
    /// is preserved.
    func serializedPythonCompatible(indent: Int = 4) -> String {
        var out = ""
        write(into: &out, indent: indent, level: 0)
        return out
    }

    private func write(into out: inout String, indent: Int, level: Int) {
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .int(i): out += String(i)
        case let .double(d): out += JSONValue.formatDouble(d)
        case let .string(s): out += JSONValue.encodeString(s)
        case let .array(a):
            if a.isEmpty { out += "[]"; return }
            let pad = String(repeating: " ", count: indent * (level + 1))
            let closePad = String(repeating: " ", count: indent * level)
            out += "[\n"
            for (idx, item) in a.enumerated() {
                out += pad
                item.write(into: &out, indent: indent, level: level + 1)
                out += idx == a.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "]"
        case let .object(o):
            if o.keys.isEmpty { out += "{}"; return }
            let pad = String(repeating: " ", count: indent * (level + 1))
            let closePad = String(repeating: " ", count: indent * level)
            out += "{\n"
            let items = o.pairs
            for (idx, pair) in items.enumerated() {
                out += pad + JSONValue.encodeString(pair.0) + ": "
                pair.1.write(into: &out, indent: indent, level: level + 1)
                out += idx == items.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "}"
        }
    }

    /// Match Python's repr for floats written by json: integral doubles keep a
    /// trailing `.0`, others use the shortest round-trippable form.
    static func formatDouble(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e16 {
            return String(format: "%.1f", d)
        }
        return String(d)
    }

    static func encodeString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case Unicode.Scalar(0x08): out += "\\b"
            case Unicode.Scalar(0x0C): out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else if scalar.value < 0x80 {
                    out.unicodeScalars.append(scalar)
                } else if scalar.value > 0xFFFF {
                    // Encode as UTF-16 surrogate pair, matching Python ensure_ascii.
                    let v = scalar.value - 0x10000
                    let high = 0xD800 + (v >> 10)
                    let low = 0xDC00 + (v & 0x3FF)
                    out += String(format: "\\u%04x\\u%04x", high, low)
                } else {
                    out += String(format: "\\u%04x", scalar.value)
                }
            }
        }
        out += "\""
        return out
    }
}
