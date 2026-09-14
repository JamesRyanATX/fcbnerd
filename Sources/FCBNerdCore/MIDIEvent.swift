import Foundation

/// A decoded MIDI 1.0 message. Channels are 1-16 (as printed on hardware),
/// every other number is the raw 0-127 wire value.
public enum MIDIEvent: Equatable, Sendable {
    case noteOn(channel: Int, note: Int, velocity: Int)
    case noteOff(channel: Int, note: Int, velocity: Int)
    case polyPressure(channel: Int, note: Int, pressure: Int)
    case controlChange(channel: Int, controller: Int, value: Int)
    case programChange(channel: Int, program: Int)
    case channelPressure(channel: Int, pressure: Int)
    /// 0-16383, center 8192.
    case pitchBend(channel: Int, value: Int)
    /// Payload only -- without the F0 / F7 framing bytes.
    case sysex([UInt8])
}

/// One line of output: something that happened, where, and when.
public struct StreamRecord: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case midi(MIDIEvent)
        case connected
        case disconnected
    }

    public let time: Date
    public let source: String
    public let kind: Kind

    public init(time: Date, source: String, kind: Kind) {
        self.time = time
        self.source = source
        self.kind = kind
    }
}
