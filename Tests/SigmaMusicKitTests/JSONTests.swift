import Foundation
import Testing
@testable import SigmaMusicKit

struct JSONTests {
    @Test func parsesNestedValuesWithTheirTypes() throws {
        let json = try JSON.parse(#"{"a":1,"b":1.5,"c":true,"d":null,"e":"x","f":[1,2],"g":{"h":false}}"#)
        #expect(json["a"] == .int(1))
        #expect(json["b"] == .double(1.5))
        #expect(json["c"] == .bool(true))
        #expect(json["d"]?.isNull == true)
        #expect(json["e"]?.string == "x")
        #expect(json["f"]?[1]?.int == 2)
        #expect(json["g"]?["h"]?.bool == false)
        #expect(json["missing"] == nil)
        #expect(json["f"]?[5] == nil)
    }

    @Test func keepsLargeIntegersExact() throws {
        let json = try JSON.parse(#"{"id":9007199254740993}"#)
        #expect(json["id"]?.int64 == 9_007_199_254_740_993)
    }

    @Test func accessorsAreLenientLikeGson() throws {
        let json = try JSON.parse(#"{"n":"123","w":5.0,"t":"true","f":1.5}"#)
        #expect(json["n"]?.int64 == 123)
        #expect(json["w"]?.int == 5)
        #expect(json["t"]?.bool == true)
        #expect(json["f"]?.int64 == nil)
        #expect(json["n"]?.string == "123")
        #expect(JSON.int(1).string == nil)
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: (any Error).self) { try JSON.parse("{not json") }
        #expect(throws: (any Error).self) { try JSON.parse("") }
    }

    @Test func serializesCompactlyWithSortedKeys() {
        let json: JSON = ["b": 2, "a": ["x", true, .null], "c": 1.5]
        #expect(json.serialized() == #"{"a":["x",true,null],"b":2,"c":1.5}"#)
    }

    @Test func escapesStrings() {
        let json: JSON = .string("q\"b\\n\nt\tc\u{01}日本😀")
        #expect(json.serialized() == "\"q\\\"b\\\\n\\nt\\tc\\u0001日本😀\"")
    }

    @Test func roundTrips() throws {
        let json: JSON = ["s": "海阔天空 \"x\"", "n": [1, 2, 3], "o": ["k": false]]
        #expect(try JSON.parse(json.serialized()) == json)
    }
}
