@testable import FCBNerdCore
import XCTest

final class FormatterTests: XCTestCase {
    // 2026-09-14T20:01:02.345Z
    let time = Date(timeIntervalSince1970: 1_789_416_062.345)

    func testControlChangeJSON() {
        let record = StreamRecord(time: time, source: "UM-ONE", kind: .midi(.controlChange(channel: 1, controller: 20, value: 127)))
        XCTAssertEqual(
            RecordFormatter.json(record),
            #"{"type":"cc","channel":1,"controller":20,"value":127,"source":"UM-ONE","time":"2026-09-14T20:01:02.345Z"}"#
        )
    }

    func testEveryRecordIsValidJSONWithExpectedType() throws {
        let cases: [(StreamRecord.Kind, String)] = [
            (.connected, "connected"),
            (.disconnected, "disconnected"),
            (.midi(.noteOn(channel: 1, note: 60, velocity: 1)), "note_on"),
            (.midi(.noteOff(channel: 1, note: 60, velocity: 0)), "note_off"),
            (.midi(.polyPressure(channel: 1, note: 60, pressure: 1)), "poly_pressure"),
            (.midi(.programChange(channel: 1, program: 0)), "pc"),
            (.midi(.channelPressure(channel: 1, pressure: 1)), "channel_pressure"),
            (.midi(.pitchBend(channel: 1, value: 8192)), "pitch_bend"),
            (.midi(.sysex([0x7D, 0x01])), "sysex"),
        ]
        for (kind, type) in cases {
            let line = RecordFormatter.json(StreamRecord(time: time, source: "x", kind: kind))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line)
            XCTAssertEqual(object["type"] as? String, type)
            XCTAssertFalse(line.contains("\n"))
        }
    }

    func testSysexIncludesFraming() throws {
        let line = RecordFormatter.json(StreamRecord(time: time, source: "x", kind: .midi(.sysex([0x7D, 0x01]))))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["data"] as? String, "f07d01f7")
        XCTAssertEqual(object["length"] as? Int, 4)
    }

    func testSourceNameEscaping() throws {
        let name = "Pedal \"A\"\\B\n\u{01}ü"
        let line = RecordFormatter.json(StreamRecord(time: time, source: name, kind: .connected))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line)
        XCTAssertEqual(object["source"] as? String, name)
    }

    func testTextFormat() {
        let record = StreamRecord(time: time, source: "UM-ONE", kind: .midi(.programChange(channel: 2, program: 5)))
        let line = RecordFormatter.text(record)
        XCTAssertTrue(line.hasSuffix("pc                channel=2 program=5  bind=pc:2:5  [UM-ONE]"), line)
    }
}
