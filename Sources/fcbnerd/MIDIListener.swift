import CoreMIDI
import FCBNerdCore
import Foundation

struct SourceInfo {
    let id: MIDIUniqueID
    let endpoint: MIDIEndpointRef
    let name: String
}

enum MIDISources {
    /// Every online MIDI source: hardware interfaces, network sessions, and
    /// other apps' virtual sources (including `fcbnerd simulate`).
    static func all() -> [SourceInfo] {
        (0..<MIDIGetNumberOfSources()).compactMap { index in
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { return nil }

            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
            guard offline == 0 else { return nil }

            var id: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id)

            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
            let displayName = name?.takeRetainedValue() as String? ?? "Unknown source \(id)"

            return SourceInfo(id: id, endpoint: endpoint, name: displayName)
        }
    }
}

/// Per-source state handed to CoreMIDI as the connection's refCon, so the
/// receive block knows which source (and which sysex decoder) a packet
/// belongs to without any lookup or locking.
private final class SourceConnection {
    let info: SourceInfo
    let decoder = UMPDecoder()

    init(info: SourceInfo) {
        self.info = info
    }
}

/// Connects to every matching MIDI source, follows hotplug, and writes each
/// decoded message to `sink`.
final class MIDIListener {
    private let sink: @Sendable (StreamRecord) -> Void
    private let sourceFilter: String?
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    // Only touched on the main thread: start() runs there, and notifications
    // are explicitly hopped there (CoreMIDI calls the notify block on a
    // thread of its choosing).
    private var connections: [MIDIUniqueID: SourceConnection] = [:]
    private var failedEndpoints = Set<MIDIEndpointRef>()
    // Disconnected sources are kept alive rather than freed: a packet that
    // was already in flight on CoreMIDI's thread may still hold a raw
    // pointer to one. Unplug events are rare, so the cost is negligible.
    private var retired: [SourceConnection] = []
    private var warnedNoSources = false

    init(sourceFilter: String?, sink: @escaping @Sendable (StreamRecord) -> Void) {
        self.sink = sink
        self.sourceFilter = sourceFilter
    }

    func start() throws {
        var status = MIDIClientCreateWithBlock("fcbnerd" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.refreshSources() }
            }
        }
        guard status == noErr else { throw ListenerError.coreMIDI("MIDIClientCreate", status) }

        let sink = self.sink
        status = MIDIInputPortCreateWithProtocol(client, "fcbnerd input" as CFString, ._1_0, &port) { eventList, refCon in
            // Runs on CoreMIDI's high-priority receive thread. Keep it short:
            // decode, hand off to the sink (which only enqueues), return.
            guard let refCon else { return }
            let connection = Unmanaged<SourceConnection>.fromOpaque(refCon).takeUnretainedValue()
            let now = Date()
            for packet in eventList.unsafeSequence() {
                for event in connection.decoder.decode(Self.words(in: packet)) {
                    sink(StreamRecord(time: now, source: connection.info.name, kind: .midi(event)))
                }
            }
        }
        guard status == noErr else { throw ListenerError.coreMIDI("MIDIInputPortCreate", status) }

        refreshSources()
    }

    /// Reads a packet's words straight from memory. Deliberately avoids
    /// `packet.pointee`, which would copy the full fixed-size struct (room
    /// for 64 words) even when the real packet is shorter and sits at the
    /// end of CoreMIDI's buffer.
    private static func words(in packet: UnsafePointer<MIDIEventPacket>) -> [UInt32] {
        let raw = UnsafeRawPointer(packet)
        let count = raw.load(fromByteOffset: MemoryLayout<MIDIEventPacket>.offset(of: \.wordCount)!, as: UInt32.self)
        let words = raw.advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!)
            .assumingMemoryBound(to: UInt32.self)
        return Array(UnsafeBufferPointer(start: words, count: Int(min(count, 64))))
    }

    private func refreshSources() {
        let now = Date()
        var present = Set<MIDIUniqueID>()
        var seenEndpoints = Set<MIDIEndpointRef>()

        for info in MIDISources.all() {
            if let filter = sourceFilter, !info.name.localizedCaseInsensitiveContains(filter) { continue }
            seenEndpoints.insert(info.endpoint)
            if let existing = connections[info.id] {
                if existing.info.endpoint == info.endpoint {
                    present.insert(info.id)
                    continue
                }
                // Same unique ID, new endpoint: the source went away and came
                // back (e.g. an app relaunching its virtual source) between
                // two refreshes. The old endpoint is dead; replace it.
                disconnect(existing, at: now)
            }
            // Don't retry, or re-report, an endpoint that already refused.
            guard !failedEndpoints.contains(info.endpoint) else { continue }

            // Announce before connecting: packets can start arriving on the
            // receive thread as soon as MIDIPortConnectSource returns, and
            // their lines must not precede this one.
            sink(StreamRecord(time: now, source: info.name, kind: .connected))
            let connection = SourceConnection(info: info)
            let status = MIDIPortConnectSource(port, info.endpoint, Unmanaged.passUnretained(connection).toOpaque())
            guard status == noErr else {
                sink(StreamRecord(time: now, source: info.name, kind: .disconnected))
                printError("could not connect to \(info.name) (OSStatus \(status))")
                failedEndpoints.insert(info.endpoint)
                continue
            }
            present.insert(info.id)
            connections[info.id] = connection
        }

        failedEndpoints.formIntersection(seenEndpoints)
        for (id, connection) in connections where !present.contains(id) {
            disconnect(connection, at: now)
        }

        if connections.isEmpty, !warnedNoSources {
            let which = sourceFilter.map { " matching \"\($0)\"" } ?? ""
            printError("no MIDI sources\(which) yet; waiting for one to appear (Ctrl+C to quit)")
            warnedNoSources = true
        } else if !connections.isEmpty {
            warnedNoSources = false
        }
    }

    private func disconnect(_ connection: SourceConnection, at time: Date) {
        MIDIPortDisconnectSource(port, connection.info.endpoint)
        connections[connection.info.id] = nil
        retired.append(connection)
        sink(StreamRecord(time: time, source: connection.info.name, kind: .disconnected))
    }
}

enum ListenerError: Error, CustomStringConvertible {
    case coreMIDI(String, OSStatus)

    var description: String {
        switch self {
        case let .coreMIDI(call, status): return "\(call) failed (OSStatus \(status))"
        }
    }
}
