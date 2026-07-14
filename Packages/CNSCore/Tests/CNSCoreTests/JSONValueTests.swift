import Testing
import Foundation
@testable import CNSCore

@Suite("JSONValue")
struct JSONValueTests {
    @Test("Parse preserves object key order")
    func objectOrder() throws {
        let value = try JSONValue.parse(#"{"b": 1, "a": 2, "c": 3}"#)
        let obj = try #require(value.objectValue)
        #expect(obj.keys == ["b", "a", "c"])
    }

    @Test("Int and double literals stay distinct")
    func numberTypes() throws {
        let value = try JSONValue.parse(#"{"i": 20, "d": 1.5, "neg": -3, "e": 1.0}"#)
        let obj = try #require(value.objectValue)
        #expect(obj["i"] == .int(20))
        #expect(obj["d"] == .double(1.5))
        #expect(obj["neg"] == .int(-3))
        #expect(obj["e"] == .double(1.0))
    }

    @Test("Serialization matches Python json.dump(indent=4) with ensure_ascii")
    func pythonCompatibleFormat() throws {
        var obj = JSONObject()
        obj["autostart"] = .bool(true)
        obj["name"] = .string("Русский")
        obj["count"] = .int(20)
        let expected = """
        {
            "autostart": true,
            "name": "\\u0420\\u0443\\u0441\\u0441\\u043a\\u0438\\u0439",
            "count": 20
        }
        """
        #expect(JSONValue.object(obj).serializedPythonCompatible() == expected)
    }

    @Test("Integral doubles keep trailing .0")
    func doubleFormatting() {
        #expect(JSONValue.formatDouble(3.0) == "3.0")
        #expect(JSONValue.formatDouble(1.5) == "1.5")
    }

    @Test("Empty containers serialize compactly")
    func emptyContainers() {
        #expect(JSONValue.array([]).serializedPythonCompatible() == "[]")
        #expect(JSONValue.object(JSONObject()).serializedPythonCompatible() == "{}")
    }

    @Test("Non-BMP characters escape as surrogate pairs (ensure_ascii)")
    func surrogatePairs() {
        let s = JSONValue.string("😀")
        // U+1F600 → "😀", matching Python json.dumps default.
        #expect(s.serializedPythonCompatible() == "\"\\ud83d\\ude00\"")
    }

    @Test("Round-trip parse → serialize → parse is stable")
    func roundTrip() throws {
        let original = #"{"a": [1, 2.5, "x", null, true], "b": {"nested": "值"}}"#
        let parsed = try JSONValue.parse(original)
        let serialized = parsed.serializedPythonCompatible()
        let reparsed = try JSONValue.parse(serialized)
        #expect(parsed.semanticallyEqual(to: reparsed))
    }

    @Test("Real config.json round-trips without key loss")
    func realConfigNoKeyLoss() throws {
        let data = Fixtures.data("migration_inputs/real_v6.json")
        let parsed = try JSONValue.parse(data: data)
        let serialized = parsed.serializedPythonCompatible()
        let reparsed = try JSONValue.parse(serialized)
        #expect(parsed.semanticallyEqual(to: reparsed))
    }
}
