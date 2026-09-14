import Foundation

/// A `--bind` rule: which MIDI message runs which shell command.
///
///     CHANNEL:CONTROLLER:VALUE=command     control change (the default)
///     cc:CHANNEL:CONTROLLER:VALUE=command  the same, explicitly
///     pc:CHANNEL:PROGRAM=command           program change
///
/// Any number may be `*` to match anything. The command is everything after
/// the first `=`, so it may itself contain `=` and `:`.
public struct Binding: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case cc, pc
    }

    public let kind: Kind
    /// 1-16, or nil for any.
    public let channel: Int?
    /// Controller (cc) or program (pc), 0-127, or nil for any.
    public let number: Int?
    /// cc value 0-127, or nil for any. Always nil for pc.
    public let value: Int?
    public let command: String
    /// The pattern as the user wrote it (left of the `=`), for messages.
    public let pattern: String

    /// A cc binding with a wildcard value tracks a continuous control such
    /// as an expression pedal, which sends dozens of messages a second.
    public var isContinuous: Bool {
        kind == .cc && value == nil
    }

    public init(parsing argument: String) throws {
        guard let equals = argument.firstIndex(of: "=") else {
            throw BindingError("\"\(argument)\": expected PATTERN=COMMAND, e.g. 1:20:127=ls")
        }
        pattern = String(argument[..<equals])
        command = String(argument[argument.index(after: equals)...])
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BindingError("\"\(argument)\": the command after = is empty")
        }

        var fields = pattern.split(separator: ":", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if let explicit = fields.first.flatMap({ Kind(rawValue: $0.lowercased()) }) {
            kind = explicit
            fields.removeFirst()
        } else {
            kind = .cc
        }

        let pattern = self.pattern
        func field(_ text: String, _ name: String, _ range: ClosedRange<Int>) throws -> Int? {
            if text == "*" { return nil }
            // Plain ASCII digits only: Int() would also take "+20" and "-0".
            guard text.allSatisfy({ ("0"..."9").contains($0) }), let number = Int(text), range.contains(number) else {
                throw BindingError("\"\(pattern)\": \(name) must be \(range.lowerBound)-\(range.upperBound) or *, got \"\(text)\"")
            }
            return number
        }

        switch kind {
        case .cc:
            guard fields.count == 3 else {
                throw BindingError("\"\(pattern)\": expected CHANNEL:CONTROLLER:VALUE, e.g. 1:20:127")
            }
            channel = try field(fields[0], "channel", 1...16)
            number = try field(fields[1], "controller", 0...127)
            value = try field(fields[2], "value", 0...127)
        case .pc:
            guard fields.count == 2 else {
                throw BindingError("\"\(pattern)\": expected pc:CHANNEL:PROGRAM, e.g. pc:1:5")
            }
            channel = try field(fields[0], "channel", 1...16)
            number = try field(fields[1], "program", 0...127)
            value = nil
        }
    }

    public func matches(_ event: MIDIEvent) -> Bool {
        func match(_ expected: Int?, _ actual: Int) -> Bool {
            expected == nil || expected == actual
        }

        switch (kind, event) {
        case let (.cc, .controlChange(channel, controller, value)):
            return match(self.channel, channel) && match(number, controller) && match(self.value, value)
        case let (.pc, .programChange(channel, program)):
            return match(self.channel, channel) && match(number, program)
        default:
            return false
        }
    }

    /// The pattern that would match exactly this event, or nil if the event
    /// type can't be bound. Shown in `--format text` output for copying.
    public static func pattern(for event: MIDIEvent) -> String? {
        switch event {
        case let .controlChange(channel, controller, value): return "\(channel):\(controller):\(value)"
        case let .programChange(channel, program): return "pc:\(channel):\(program)"
        default: return nil
        }
    }

    /// Environment variables describing the event, for the command to read.
    public static func environment(for event: MIDIEvent, source: String) -> [String: String] {
        var environment = ["MIDI_SOURCE": source]
        switch event {
        case let .controlChange(channel, controller, value):
            environment["MIDI_TYPE"] = "cc"
            environment["MIDI_CHANNEL"] = String(channel)
            environment["MIDI_CONTROLLER"] = String(controller)
            environment["MIDI_VALUE"] = String(value)
        case let .programChange(channel, program):
            environment["MIDI_TYPE"] = "pc"
            environment["MIDI_CHANNEL"] = String(channel)
            environment["MIDI_PROGRAM"] = String(program)
        default:
            break
        }
        return environment
    }
}

public struct BindingError: Error, CustomStringConvertible {
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}
