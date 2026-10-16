import XCTest

final class JSONSchemaValidatorTests: XCTestCase {
    private func issues(_ value: Any, _ schema: [String: Any], strict: Bool = false, components: [String: Any] = [:]) -> [String] {
        JSONSchemaValidator(document: ["components": ["schemas": components]], reportUndeclaredProperties: strict).validate(value, against: schema)
    }

    func testScalarsAndFormats() {
        XCTAssertEqual(issues("2026-10-16", ["type": "string", "format": "date"]), [])
        XCTAssertEqual(issues("2026-02-30", ["type": "string", "format": "date"]).count, 1)
        XCTAssertEqual(issues("2026-10-16T08:00:00Z", ["type": "string", "format": "date-time"]), [])
        XCTAssertEqual(issues("2026-10-16T08:00:00.123Z", ["type": "string", "format": "date-time"]), [])
        XCTAssertEqual(issues("2026-10-16", ["type": "string", "format": "date-time"]).count, 1)
        XCTAssertEqual(issues(UUID().uuidString, ["type": "string", "format": "uuid"]), [])
        XCTAssertEqual(issues("nope", ["type": "string", "format": "uuid"]).count, 1)
        XCTAssertEqual(issues(3, ["type": "integer"]), [])
        XCTAssertEqual(issues(3.5, ["type": "integer"]).count, 1)
        XCTAssertEqual(issues(3.5, ["type": "number"]), [])
        XCTAssertEqual(issues(true, ["type": "integer"]).count, 1)
        XCTAssertEqual(issues(1, ["type": "boolean"]).count, 1)
        XCTAssertEqual(issues("b", ["type": "string", "enum": ["a"]]).count, 1)
        XCTAssertEqual(issues("ok", ["const": "ok"]), [])
    }

    func testNullability() {
        XCTAssertEqual(issues(NSNull(), ["type": ["string", "null"]]), [])
        XCTAssertEqual(issues(NSNull(), ["type": "string"]).count, 1)
        XCTAssertEqual(issues(NSNull(), ["type": "string", "nullable": true]), [])
        XCTAssertEqual(issues(NSNull(), ["oneOf": [["type": "string"], ["type": "null"]]]), [])
    }

    func testObjectsRefsAndComposition() {
        let components: [String: Any] = [
            "Base": ["type": "object", "required": ["id"], "properties": ["id": ["type": "string", "format": "uuid"]]],
            "Item": ["allOf": [["$ref": "#/components/schemas/Base"], ["type": "object", "properties": ["n": ["type": "integer"]]]]],
        ]
        let list: [String: Any] = ["type": "array", "items": ["$ref": "#/components/schemas/Item"]]
        XCTAssertEqual(issues([["id": UUID().uuidString, "n": 1]], list, strict: true, components: components), [])
        XCTAssertEqual(issues([["n": 1]], list, components: components).count, 1)
        XCTAssertEqual(issues([["id": UUID().uuidString, "n": "x"]], list, components: components).count, 1)
        XCTAssertEqual(issues([["id": UUID().uuidString, "extra": 1]], list, components: components), [])
        XCTAssertEqual(issues([["id": UUID().uuidString, "extra": 1]], list, strict: true, components: components).count, 1)
        XCTAssertEqual(issues(["a": 1, "b": 2], ["type": "object", "properties": ["a": ["type": "integer"]], "additionalProperties": false]).count, 1)
        XCTAssertEqual(issues(["a": 1, "b": "x"], ["type": "object", "additionalProperties": ["type": "integer"]]).count, 1)
        XCTAssertEqual(issues(5, ["oneOf": [["type": "integer"], ["type": "number"]]]).count, 1)  // matches both branches
        XCTAssertEqual(issues(["x": 1], ["$ref": "#/components/schemas/Missing"]).count, 1)
    }

    func testJSONSerializationRoundTripBooleans() throws {
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":1}"#.utf8)) as? [String: Any])
        XCTAssertEqual(issues(parsed, ["type": "object", "properties": ["a": ["type": "boolean"], "b": ["type": "integer"]]]), [])
        XCTAssertEqual(issues(parsed, ["type": "object", "properties": ["a": ["type": "integer"], "b": ["type": "boolean"]]]).count, 2)
    }
}
