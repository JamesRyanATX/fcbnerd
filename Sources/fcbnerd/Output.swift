import FCBNerdCore
import Foundation

/// Serializes all writes to stdout through one queue, so lines from the
/// CoreMIDI thread and the main thread never interleave.
///
/// Flushes after every line. Without that, stdout into a pipe is
/// block-buffered and a consumer would see footswitch presses kilobytes
/// late. Broken pipes (`fcbnerd | head -1`) are left to the default
/// SIGPIPE behavior: the process exits quietly.
final class OutputWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fcbnerd.output")
    private let format: OutputFormat
    private let onWriteFailure: (() -> Void)?

    /// - Parameter onWriteFailure: called if stdout can't be written. Only
    ///   reachable when SIGPIPE is ignored (see main.swift); otherwise a
    ///   broken pipe kills the process before the write returns.
    init(format: OutputFormat, onWriteFailure: (() -> Void)? = nil) {
        self.format = format
        self.onWriteFailure = onWriteFailure
    }

    func write(_ record: StreamRecord) {
        queue.async { [format, onWriteFailure] in
            let line = RecordFormatter.format(record, as: format)
            if fputs(line + "\n", stdout) == EOF || fflush(stdout) != 0 {
                onWriteFailure?()
            }
        }
    }
}

func printError(_ message: String) {
    fputs("fcbnerd: \(message)\n", stderr)
}
