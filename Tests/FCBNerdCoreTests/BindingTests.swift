@testable import FCBNerdCore
import XCTest

final class BindingTests: XCTestCase {
    func testParsesControlChange() throws {
        let binding = try Binding(parsing: "1:20:127=open ~/Downloads")
        XCTAssertEqual(binding.kind, .cc)
        XCTAssertEqual(binding.channel, 1)
        XCTAssertEqual(binding.number, 20)
        XCTAssertEqual(binding.value, 127)
        XCTAssertEqual(binding.command, "open ~/Downloads")
        XCTAssertEqual(binding.pattern, "1:20:127")
        XCTAssertFalse(binding.isContinuous)
    }

    func testCommandMayContainEqualsAndColons() throws {
        let binding = try Binding(parsing: "cc:16:0:0=FOO=bar echo a:b")
        XCTAssertEqual(binding.channel, 16)
        XCTAssertEqual(binding.command, "FOO=bar echo a:b")
    }

    func testParsesProgramChangeAndWildcards() throws {
        let pc = try Binding(parsing: "pc:1:*=say preset")
        XCTAssertEqual(pc.kind, .pc)
        XCTAssertNil(pc.number)
        XCTAssertFalse(pc.isContinuous)

        let pedal = try Binding(parsing: "*:27:*=echo $MIDI_VALUE")
        XCTAssertNil(pedal.channel)
        XCTAssertNil(pedal.value)
        XCTAssertTrue(pedal.isContinuous)
    }

    func testRejectsMalformed() {
        let bad = [
            "1:20:127",          // no command
            "1:20:127=",         // empty command
            "1:20:127=   ",      // blank command
            "1:20=ls",           // too few fields
            "1:20:127:5=ls",     // too many fields
            "pc:1:5:6=ls",       // too many for pc
            "0:20:127=ls",       // channel out of range
            "17:20:127=ls",
            "1:128:127=ls",      // controller out of range
            "1:20:-1=ls",
            "x:20:127=ls",       // not a number
            "1:+20:127=ls",      // sign
            "1:20:-0=ls",
            "1:20:٣=ls",         // non-ASCII digit
            "1::127=ls",         // empty field
            "nt:1:60=ls",        // unknown type prefix is treated as a (bad) channel
        ]
        for argument in bad {
            XCTAssertThrowsError(try Binding(parsing: argument), argument)
        }
    }

    func testMatching() throws {
        let exact = try Binding(parsing: "1:20:127=x")
        XCTAssertTrue(exact.matches(.controlChange(channel: 1, controller: 20, value: 127)))
        XCTAssertFalse(exact.matches(.controlChange(channel: 2, controller: 20, value: 127)))
        XCTAssertFalse(exact.matches(.controlChange(channel: 1, controller: 21, value: 127)))
        XCTAssertFalse(exact.matches(.controlChange(channel: 1, controller: 20, value: 0)))
        XCTAssertFalse(exact.matches(.programChange(channel: 1, program: 20)))

        let pc = try Binding(parsing: "pc:*:5=x")
        XCTAssertTrue(pc.matches(.programChange(channel: 9, program: 5)))
        XCTAssertFalse(pc.matches(.programChange(channel: 9, program: 6)))
        XCTAssertFalse(pc.matches(.controlChange(channel: 9, controller: 5, value: 0)))

        let any = try Binding(parsing: "*:*:*=x")
        XCTAssertTrue(any.matches(.controlChange(channel: 16, controller: 0, value: 64)))
        XCTAssertFalse(any.matches(.noteOn(channel: 1, note: 60, velocity: 100)))
    }

    func testPatternForEventRoundTrips() throws {
        let events: [MIDIEvent] = [
            .controlChange(channel: 3, controller: 27, value: 84),
            .programChange(channel: 16, program: 0),
        ]
        for event in events {
            let pattern = try XCTUnwrap(Binding.pattern(for: event))
            XCTAssertTrue(try Binding(parsing: "\(pattern)=x").matches(event), pattern)
        }
        XCTAssertNil(Binding.pattern(for: .noteOn(channel: 1, note: 60, velocity: 1)))
    }

    func testEnvironment() {
        XCTAssertEqual(
            Binding.environment(for: .controlChange(channel: 1, controller: 27, value: 84), source: "UM-ONE"),
            ["MIDI_TYPE": "cc", "MIDI_CHANNEL": "1", "MIDI_CONTROLLER": "27", "MIDI_VALUE": "84", "MIDI_SOURCE": "UM-ONE"]
        )
        XCTAssertEqual(
            Binding.environment(for: .programChange(channel: 2, program: 5), source: "x"),
            ["MIDI_TYPE": "pc", "MIDI_CHANNEL": "2", "MIDI_PROGRAM": "5", "MIDI_SOURCE": "x"]
        )
    }
}
