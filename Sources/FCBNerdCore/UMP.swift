import Foundation

// CoreMIDI's modern receive API (MIDIInputPortCreateWithProtocol) delivers
// Universal MIDI Packets (UMP): 32-bit words, where the top 4 bits of the
// first word say what kind of message it is and therefore how many words
// it spans. With the port opened as MIDI 1.0 protocol, a plain DIN device
// like the FCB1010 shows up as:
//
//   type 0x2  channel voice    1 word:  [0x2|group][status][data1][data2]
//   type 0x3  sysex (7-bit)    2 words: [0x3|group][form|count][d0][d1]  [d2][d3][d4][d5]
//   type 0x1  real-time/common 1 word   (clock etc. -- ignored here)
//
// A nice side effect: CoreMIDI has already expanded MIDI running status
// (which the FCB1010 can be configured to use) into full messages before
// we ever see them, so there is no running-status handling in this file.

/// Size in words of a UMP message, from its message type nibble.
func umpWordCount(messageType: UInt32) -> Int {
    switch messageType {
    case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
    case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
    case 0xB, 0xC: return 3
    default: return 4 // 0x5, 0xD, 0xE, 0xF
    }
}

/// Stateful decoder for one source. Sysex can span many UMP messages, so
/// each connected source needs its own instance. Not thread-safe; CoreMIDI
/// calls the receive block serially, which is the only caller.
public final class UMPDecoder {
    /// A stock FCB1010 dump is 2352 bytes. Anything wildly larger is a
    /// stream we lost the end of, not a real message.
    static let maxSysexLength = 1 << 20

    /// Partial sysex per UMP group (the spec keeps one sysex stream per
    /// group). A key being present means a message is in progress.
    private var sysexInProgress: [UInt32: [UInt8]] = [:]

    public init() {}

    /// Decode every complete message in a run of UMP words. A truncated
    /// trailing message is dropped.
    public func decode(_ words: [UInt32]) -> [MIDIEvent] {
        var events: [MIDIEvent] = []
        var index = 0
        while index < words.count {
            let messageType = words[index] >> 28
            let size = umpWordCount(messageType: messageType)
            guard index + size <= words.count else { break }

            switch messageType {
            case 0x2:
                if let event = Self.channelVoice(words[index]) { events.append(event) }
            case 0x3:
                if let event = sysex7(words[index], words[index + 1]) { events.append(event) }
            default:
                break
            }
            index += size
        }
        return events
    }

    static func channelVoice(_ word: UInt32) -> MIDIEvent? {
        let status = Int((word >> 16) & 0xFF)
        let channel = (status & 0x0F) + 1
        let data1 = Int((word >> 8) & 0x7F)
        let data2 = Int(word & 0x7F)

        switch status & 0xF0 {
        case 0x80: return .noteOff(channel: channel, note: data1, velocity: data2)
        // Note-on with velocity 0 means note-off by MIDI convention.
        case 0x90: return data2 == 0
            ? .noteOff(channel: channel, note: data1, velocity: 0)
            : .noteOn(channel: channel, note: data1, velocity: data2)
        case 0xA0: return .polyPressure(channel: channel, note: data1, pressure: data2)
        case 0xB0: return .controlChange(channel: channel, controller: data1, value: data2)
        case 0xC0: return .programChange(channel: channel, program: data1)
        case 0xD0: return .channelPressure(channel: channel, pressure: data1)
        case 0xE0: return .pitchBend(channel: channel, value: data1 | (data2 << 7))
        default: return nil
        }
    }

    private func sysex7(_ word0: UInt32, _ word1: UInt32) -> MIDIEvent? {
        let form = (word0 >> 20) & 0xF
        let count = min(Int((word0 >> 16) & 0xF), 6)
        let bytes: [UInt8] = [
            UInt8((word0 >> 8) & 0x7F), UInt8(word0 & 0x7F),
            UInt8((word1 >> 24) & 0x7F), UInt8((word1 >> 16) & 0x7F),
            UInt8((word1 >> 8) & 0x7F), UInt8(word1 & 0x7F),
        ]
        let payload = bytes.prefix(count)
        let group = (word0 >> 24) & 0xF

        switch form {
        case 0x0: // complete in one message
            sysexInProgress[group] = nil
            return .sysex(Array(payload))
        case 0x1: // start
            sysexInProgress[group] = Array(payload)
            return nil
        case 0x2, 0x3: // continue, end
            guard var buffer = sysexInProgress[group] else { return nil } // never saw the start; drop
            buffer.append(contentsOf: payload)
            if form == 0x3 {
                sysexInProgress[group] = nil
                return .sysex(buffer)
            }
            sysexInProgress[group] = buffer.count > Self.maxSysexLength ? nil : buffer
            return nil
        default:
            return nil
        }
    }
}

/// The inverse of `UMPDecoder`, used by `fcbnerd simulate` and the tests.
public enum UMPEncoder {
    /// Each inner array is one complete UMP message.
    public static func messages(for event: MIDIEvent, group: UInt32 = 0) -> [[UInt32]] {
        func voice(_ status: Int, _ channel: Int, _ data1: Int, _ data2: Int) -> [[UInt32]] {
            let statusByte = UInt8(status | ((channel - 1) & 0x0F))
            return [[word(0x20 | UInt8(group & 0xF), statusByte, UInt8(data1 & 0x7F), UInt8(data2 & 0x7F))]]
        }

        switch event {
        case let .noteOn(channel, note, velocity): return voice(0x90, channel, note, velocity)
        case let .noteOff(channel, note, velocity): return voice(0x80, channel, note, velocity)
        case let .polyPressure(channel, note, pressure): return voice(0xA0, channel, note, pressure)
        case let .controlChange(channel, controller, value): return voice(0xB0, channel, controller, value)
        case let .programChange(channel, program): return voice(0xC0, channel, program, 0)
        case let .channelPressure(channel, pressure): return voice(0xD0, channel, pressure, 0)
        case let .pitchBend(channel, value): return voice(0xE0, channel, value & 0x7F, (value >> 7) & 0x7F)
        case let .sysex(payload): return sysex7(payload, group: group)
        }
    }

    private static func sysex7(_ payload: [UInt8], group: UInt32) -> [[UInt32]] {
        let chunks = stride(from: 0, to: max(payload.count, 1), by: 6).map {
            Array(payload[min($0, payload.count)..<min($0 + 6, payload.count)])
        }
        return chunks.enumerated().map { index, chunk in
            let form: UInt32
            if chunks.count == 1 { form = 0x0 }
            else if index == 0 { form = 0x1 }
            else if index == chunks.count - 1 { form = 0x3 }
            else { form = 0x2 }

            var bytes = [UInt8](repeating: 0, count: 6)
            bytes.replaceSubrange(0..<chunk.count, with: chunk)
            let word0 = word(0x30 | UInt8(group & 0xF), UInt8(form << 4) | UInt8(chunk.count), bytes[0], bytes[1])
            let word1 = word(bytes[2], bytes[3], bytes[4], bytes[5])
            return [word0, word1]
        }
    }

    /// Packs four bytes into a big-endian UMP word. (Written as separate
    /// statements: one long chain of `<<` and `|` over mixed integer types
    /// makes the Swift type checker time out.)
    static func word(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> UInt32 {
        var result = UInt32(b0) << 24
        result |= UInt32(b1) << 16
        result |= UInt32(b2) << 8
        result |= UInt32(b3)
        return result
    }
}
