import CoreMIDI
import FCBNerdCore
import Foundation

/// `fcbnerd simulate`: publishes a virtual MIDI source that plays a
/// synthetic footboard session on a loop, so consumers can be built and
/// tested with no pedal attached.
///
/// The messages are illustrative, not a capture of the factory FCB1010
/// config (which assigns different CCs per preset -- see README).
final class Simulator {
    static let sourceName = "fcbnerd simulator"

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()

    func start() throws {
        var status = MIDIClientCreateWithBlock("fcbnerd simulator" as CFString, &client, nil)
        guard status == noErr else { throw ListenerError.coreMIDI("MIDIClientCreate", status) }
        status = MIDISourceCreateWithProtocol(client, Self.sourceName as CFString, ._1_0, &source)
        guard status == noErr else { throw ListenerError.coreMIDI("MIDISourceCreate", status) }

        printError("publishing virtual source \"\(Self.sourceName)\"; run `fcbnerd` in another terminal (Ctrl+C to quit)")

        let source = self.source
        Thread.detachNewThread {
            // Give listeners a moment to notice the new source.
            Thread.sleep(forTimeInterval: 1)
            while true {
                for footswitch in 1...10 {
                    Self.send(.programChange(channel: 1, program: footswitch - 1), to: source)
                    Self.send(.controlChange(channel: 1, controller: 101 + footswitch, value: 127), to: source)
                    Thread.sleep(forTimeInterval: 0.4)
                }
                for value in stride(from: 0, through: 127, by: 8) + [127] {
                    Self.send(.controlChange(channel: 1, controller: 27, value: value), to: source)
                    Thread.sleep(forTimeInterval: 0.03)
                }
                // Short sysex, spanning several UMP packets. 0x7D is the
                // manufacturer ID reserved for non-commercial use.
                Self.send(.sysex([0x7D] + Array(0x01...0x10)), to: source)
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    private static func send(_ event: MIDIEvent, to source: MIDIEndpointRef) {
        for message in UMPEncoder.messages(for: event) {
            var list = MIDIEventList()
            // One pointer for all three calls: `&list` passed separately to
            // each would make `packet` (a pointer into the list) dangle
            // between calls.
            withUnsafeMutablePointer(to: &list) { listPointer in
                let packet = MIDIEventListInit(listPointer, ._1_0)
                message.withUnsafeBufferPointer { words in
                    _ = MIDIEventListAdd(listPointer, MemoryLayout<MIDIEventList>.size, packet, 0, words.count, words.baseAddress!)
                }
                MIDIReceivedEventList(source, listPointer)
            }
        }
    }
}
