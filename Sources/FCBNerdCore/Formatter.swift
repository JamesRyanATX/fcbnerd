import Foundation

public enum OutputFormat: String, CaseIterable, Sendable {
    /// One JSON object per line (NDJSON). The stable, machine-readable format.
    case json
    /// Aligned columns for eyeballing. Not a stable interface.
    case text
}

public enum RecordFormatter {
    public static func format(_ record: StreamRecord, as format: OutputFormat) -> String {
        switch format {
        case .json: return json(record)
        case .text: return text(record)
        }
    }

    // MARK: - JSON

    private enum Value {
        case string(String)
        case int(Int)
    }

    public static func json(_ record: StreamRecord) -> String {
        let (type, fields) = typeAndFields(record.kind)
        // Hand-built rather than JSONEncoder so key order is stable and
        // readable: type first, payload, then source and time.
        var pairs: [(String, Value)] = [("type", .string(type))]
        pairs += fields
        pairs.append(("source", .string(record.source)))
        pairs.append(("time", .string(isoTime(record.time))))

        let body = pairs.map { key, value in
            switch value {
            case let .string(string): return "\"\(key)\":\"\(escapeJSONString(string))\""
            case let .int(int): return "\"\(key)\":\(int)"
            }
        }
        return "{" + body.joined(separator: ",") + "}"
    }

    private static func typeAndFields(_ kind: StreamRecord.Kind) -> (String, [(String, Value)]) {
        switch kind {
        case .connected: return ("connected", [])
        case .disconnected: return ("disconnected", [])
        case let .midi(event):
            switch event {
            case let .noteOn(channel, note, velocity):
                return ("note_on", [("channel", .int(channel)), ("note", .int(note)), ("velocity", .int(velocity))])
            case let .noteOff(channel, note, velocity):
                return ("note_off", [("channel", .int(channel)), ("note", .int(note)), ("velocity", .int(velocity))])
            case let .polyPressure(channel, note, pressure):
                return ("poly_pressure", [("channel", .int(channel)), ("note", .int(note)), ("pressure", .int(pressure))])
            case let .controlChange(channel, controller, value):
                return ("cc", [("channel", .int(channel)), ("controller", .int(controller)), ("value", .int(value))])
            case let .programChange(channel, program):
                return ("pc", [("channel", .int(channel)), ("program", .int(program))])
            case let .channelPressure(channel, pressure):
                return ("channel_pressure", [("channel", .int(channel)), ("pressure", .int(pressure))])
            case let .pitchBend(channel, value):
                return ("pitch_bend", [("channel", .int(channel)), ("value", .int(value))])
            case let .sysex(payload):
                let hex = ([0xF0] + payload + [0xF7]).map { String(format: "%02x", $0) }.joined()
                return ("sysex", [("length", .int(payload.count + 2)), ("data", .string(hex))])
            }
        }
    }

    public static func escapeJSONString(_ string: String) -> String {
        var out = ""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // Date formatters are expensive to create; both are used only from the
    // single serial output queue.
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func isoTime(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    // MARK: - Text

    public static func text(_ record: StreamRecord) -> String {
        let (type, fields) = typeAndFields(record.kind)
        var payload = fields.map { key, value -> String in
            switch value {
            case let .string(string): return "\(key)=\(string)"
            case let .int(int): return "\(key)=\(int)"
            }
        }.joined(separator: " ")
        // Ready to paste into --bind.
        if case let .midi(event) = record.kind, let pattern = Binding.pattern(for: event) {
            payload += "  bind=\(pattern)"
        }
        let paddedType = type.padding(toLength: 16, withPad: " ", startingAt: 0)
        let columns = [clockFormatter.string(from: record.time), paddedType, payload, "[\(record.source)]"]
        return columns.filter { !$0.isEmpty }.joined(separator: "  ")
    }
}
