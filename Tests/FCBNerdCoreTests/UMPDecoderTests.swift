@testable import FCBNerdCore
import XCTest

final class UMPDecoderTests: XCTestCase {
    func testChannelVoiceMessages() {
        let decoder = UMPDecoder()
        // Hand-written words, not via UMPEncoder, so the encoder can't
        // hide a bug shared with the decoder.
        XCTAssertEqual(decoder.decode([0x20B0_147F]), [.controlChange(channel: 1, controller: 20, value: 127)])
        XCTAssertEqual(decoder.decode([0x20CF_0500]), [.programChange(channel: 16, program: 5)])
        XCTAssertEqual(decoder.decode([0x2093_3C64]), [.noteOn(channel: 4, note: 60, velocity: 100)])
        XCTAssertEqual(decoder.decode([0x2083_3C40]), [.noteOff(channel: 4, note: 60, velocity: 64)])
        XCTAssertEqual(decoder.decode([0x20A0_3C10]), [.polyPressure(channel: 1, note: 60, pressure: 16)])
        XCTAssertEqual(decoder.decode([0x20D1_2A00]), [.channelPressure(channel: 2, pressure: 42)])
        XCTAssertEqual(decoder.decode([0x20E0_0040]), [.pitchBend(channel: 1, value: 8192)])
    }

    func testNoteOnWithZeroVelocityIsNoteOff() {
        XCTAssertEqual(UMPDecoder().decode([0x2090_3C00]), [.noteOff(channel: 1, note: 60, velocity: 0)])
    }

    func testSeveralMessagesInOnePacketAndIgnoredTypes() {
        let words: [UInt32] = [
            0x10F8_0000, // timing clock (system real-time): ignored
            0x20B0_1B00, // cc 27 = 0
            0x0000_0000, // utility NOOP: ignored
            0x20B0_1B7F, // cc 27 = 127
        ]
        XCTAssertEqual(UMPDecoder().decode(words), [
            .controlChange(channel: 1, controller: 27, value: 0),
            .controlChange(channel: 1, controller: 27, value: 127),
        ])
    }

    func testTruncatedTrailingMessageIsDropped() {
        // First word of a 2-word sysex message with its second word missing.
        XCTAssertEqual(UMPDecoder().decode([0x20B0_147F, 0x3006_7D01]), [
            .controlChange(channel: 1, controller: 20, value: 127),
        ])
    }

    func testSysexCompleteInOneMessage() {
        // form 0 (complete), 3 bytes: 7D 01 02
        XCTAssertEqual(UMPDecoder().decode([0x3003_7D01, 0x0200_0000]), [.sysex([0x7D, 0x01, 0x02])])
    }

    func testSysexAcrossMessagesAndPackets() {
        let decoder = UMPDecoder()
        // start (6 bytes) in one packet...
        XCTAssertEqual(decoder.decode([0x3016_0001, 0x0203_0405]), [])
        // ...continue (6) and end (2) in the next.
        XCTAssertEqual(decoder.decode([0x3026_0607, 0x0809_0A0B, 0x3032_0C0D, 0x0000_0000]), [
            .sysex(Array(0x00...0x0D)),
        ])
    }

    func testSysexOnDifferentGroupsIsNotSpliced() {
        let decoder = UMPDecoder()
        let events = decoder.decode([
            0x3012_0102, 0x0000_0000, // group 0 start: 01 02
            0x3112_0A0B, 0x0000_0000, // group 1 start: 0A 0B
            0x3031_0300, 0x0000_0000, // group 0 end:   03
            0x3131_0C00, 0x0000_0000, // group 1 end:   0C
        ])
        XCTAssertEqual(events, [.sysex([0x01, 0x02, 0x03]), .sysex([0x0A, 0x0B, 0x0C])])
    }

    func testSysexContinuationWithoutStartIsDropped() {
        let decoder = UMPDecoder()
        XCTAssertEqual(decoder.decode([0x3032_0C0D, 0x0000_0000]), [])
        // And the decoder recovers for the next real message.
        XCTAssertEqual(decoder.decode([0x3001_7D00, 0x0000_0000]), [.sysex([0x7D])])
    }

    func testEncoderRoundTrip() {
        let events: [MIDIEvent] = [
            .noteOn(channel: 10, note: 36, velocity: 127),
            .noteOff(channel: 10, note: 36, velocity: 3),
            .polyPressure(channel: 3, note: 1, pressure: 2),
            .controlChange(channel: 16, controller: 7, value: 64),
            .programChange(channel: 1, program: 99),
            .channelPressure(channel: 5, pressure: 77),
            .pitchBend(channel: 2, value: 16383),
            .sysex([]),
            .sysex([0x7D]),
            .sysex(Array(0...5)),
            .sysex(Array(0...6)),
            // Full stock FCB1010 dump size.
            .sysex((0..<2350).map { UInt8($0 % 128) }),
        ]
        let decoder = UMPDecoder()
        for event in events {
            let words = UMPEncoder.messages(for: event).flatMap { $0 }
            XCTAssertEqual(decoder.decode(words), [event], "\(event)")
        }
    }
}
