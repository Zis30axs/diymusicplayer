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

/// Gson, which the original reads every reply with, is lenient; so is this once the strict decoder refuses.
struct LenientJSONTests {
    @Test func readsControlCharactersInsideStrings() throws {
        let json = try JSON.parse("{\"songname\":\"a\tb\nc\",\"id\":5}")
        #expect(json["songname"]?.string == "a\tb\nc")
        #expect(json["id"]?.int == 5)
    }

    @Test func readsUnknownEscapesAndLoneSurrogates() throws {
        let json = try JSON.parse(#"{"a":"it\'s \x","b":"\ud83d","c":"😀 中"}"#)
        #expect(json["a"]?.string == "it's x")
        #expect(json["b"]?.string == "\u{FFFD}")
        #expect(json["c"]?.string == "😀 中")
    }

    @Test func readsSingleQuotesUnquotedNamesAndComments() throws {
        let json = try JSON.parse("""
        // lead
        {name: 'x', "n": 1, /* c */ ok: true, list: [1, 2,], nothing: null, 'k' = 'v'; z: bare}
        """)
        #expect(json["name"]?.string == "x")
        #expect(json["n"]?.int == 1)
        #expect(json["ok"]?.bool == true)
        #expect(json["list"]?.array?.count == 2)
        #expect(json["nothing"]?.isNull == true)
        #expect(json["k"]?.string == "v")
        #expect(json["z"]?.string == "bare")
    }

    @Test func emptySlotsInArraysAreNull() throws {
        #expect(try JSON.parse("[1,,2]").array == [.int(1), .null, .int(2)])
        #expect(try JSON.parse("[,1]").array == [.null, .int(1)])
    }

    @Test func skipsByteOrderMarkXSSIPrefixAndJSONPWrapper() throws {
        #expect(try JSON.parse("\u{FEFF}{\"a\":1}")["a"]?.int == 1)
        #expect(try JSON.parse(")]}'\n{\"a\":2}")["a"]?.int == 2)
        #expect(try JSON.parse("callback({\"a\":3});")["a"]?.int == 3)
        #expect(try JSON.parse("jsonp.cb ( [1] )").array == [.int(1)])
    }

    @Test func aSearchReplyWithAControlCharacterStillGivesItsSongs() throws {
        let reply = "{\"data\":{\"song\":{\"list\":[{\"songid\":7,\"songmid\":\"m\",\"songname\":\"Tab\there\","
            + "\"singer\":[{\"name\":\"甲\"}],\"albumname\":\"x\",\"interval\":100}]}}}"
        let tracks = QQMusicApi.tracks(from: try JSON.parse(reply))
        #expect(tracks.count == 1)
        #expect(tracks.first?.name == "Tab\there")
    }

    @Test func stillRefusesWhatIsNotAnObjectOrArray() {
        for text in ["", "{not json", "Forbidden", "<html><body>no</body></html>", "{\"a\":1}x", "{\"a\":"] {
            #expect(throws: (any Error).self, "\(text)") { try JSON.parse(text) }
        }
    }
}
