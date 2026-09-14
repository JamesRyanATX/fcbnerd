import Darwin
import FCBNerdCore
import Foundation

/// Runs `--bind` commands for matching events.
///
/// Commands run in the background through `shell -c`, so the MIDI stream
/// never waits on them.
///
/// Exact bindings (`1:20:127`) run once per matching message, even if an
/// earlier run is still going: two stomps are two runs. Bindings with a
/// wildcard value (`1:27:*`, an expression pedal) run at most one instance
/// at a time *per physical control* (channel + controller); while one is
/// running, only the newest value for that control is kept and it runs
/// next. A sweep therefore can't spawn a hundred shells, the pedal's final
/// position is always applied, and a `1:*:*` binding never lets one
/// control's messages overwrite another's.
final class CommandRunner: @unchecked Sendable {
    /// One physical control as seen by one binding.
    private struct StreamKey: Hashable {
        let binding: Int
        let channel: Int
        let controller: Int
    }

    private struct Run {
        let binding: Int
        let key: StreamKey?
        let started: Date
    }

    /// How long a coalesced command may run before we say it looks stuck.
    private static let slowRunWarning: TimeInterval = 5

    let shell: String
    private let bindings: [Binding]
    private let stdoutToStderr: Bool
    private let baseEnvironment: [String: String]

    // All state below is only touched on `queue`. The SIGCHLD source also
    // delivers there, so a child can't be reaped before it's recorded.
    private let queue = DispatchQueue(label: "fcbnerd.commands")
    private var runs: [pid_t: Run] = [:]
    private var busy: [StreamKey: pid_t] = [:]
    private var pending: [StreamKey: StreamRecord] = [:]
    private var warnedSlow = Set<StreamKey>()
    private var failingBindings = Set<Int>()
    private var shuttingDown = false
    private var childExitSource: DispatchSourceSignal?

    /// - Parameter stdoutToStderr: send commands' stdout to stderr, so it
    ///   can't interleave with events fcbnerd is printing on stdout.
    init(bindings: [Binding], shell: String, stdoutToStderr: Bool) {
        self.bindings = bindings
        self.shell = shell
        self.stdoutToStderr = stdoutToStderr
        // A stale MIDI_VALUE exported in the user's shell must not leak into
        // a pc command, which doesn't overwrite it.
        baseEnvironment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("MIDI_") }

        let source = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: queue)
        source.setEventHandler { [weak self] in self?.reapChildren() }
        source.resume()
        childExitSource = source
    }

    func handle(_ record: StreamRecord) {
        guard case let .midi(event) = record.kind else { return }
        queue.async { [self] in
            guard !shuttingDown else { return }
            for (index, binding) in bindings.enumerated() where binding.matches(event) {
                guard binding.isContinuous, case let .controlChange(channel, controller, _) = event else {
                    launch(index, record, key: nil)
                    continue
                }
                let key = StreamKey(binding: index, channel: channel, controller: controller)
                guard let pid = busy[key] else {
                    launch(index, record, key: key)
                    continue
                }
                pending[key] = record
                if let run = runs[pid], Date().timeIntervalSince(run.started) > Self.slowRunWarning,
                   warnedSlow.insert(key).inserted {
                    printError("bind \(binding.pattern): command still running after \(Int(Self.slowRunWarning))s; holding newer values until it exits")
                }
            }
        }
    }

    /// Sends SIGTERM to every running command's process group and stops
    /// starting new ones. Call before fcbnerd exits: the terminal's Ctrl+C
    /// only reaches fcbnerd's own process group, not the commands'.
    func terminateAll() {
        queue.sync {
            shuttingDown = true
            for pid in runs.keys {
                killpg(pid, SIGTERM)
            }
        }
    }

    private func launch(_ index: Int, _ record: StreamRecord, key: StreamKey?) {
        guard case let .midi(event) = record.kind else { return }
        let binding = bindings[index]
        let environment = baseEnvironment.merging(Binding.environment(for: event, source: record.source)) { _, new in new }

        do {
            let pid = try spawnShell(shell, command: binding.command, environment: environment, stdoutToStderr: stdoutToStderr)
            runs[pid] = Run(binding: index, key: key, started: Date())
            if let key { busy[key] = pid }
            failingBindings.remove(index)
        } catch {
            // Report once until it works again, not once per pedal step.
            if failingBindings.insert(index).inserted {
                printError("bind \(binding.pattern): could not start \(shell): \(error)")
            }
        }
    }

    private func reapChildren() {
        var status: Int32 = 0
        while case let pid = waitpid(-1, &status, WNOHANG), pid > 0 {
            guard let run = runs.removeValue(forKey: pid) else { continue }

            // WIFEXITED / WEXITSTATUS are C macros Swift doesn't import.
            let exitedNormally = status & 0x7F == 0
            let exitStatus = (status >> 8) & 0xFF
            if exitedNormally, exitStatus != 0, !shuttingDown {
                printError("bind \(bindings[run.binding].pattern): command exited with status \(exitStatus)")
            }

            guard let key = run.key else { continue }
            busy[key] = nil
            warnedSlow.remove(key)
            if let next = pending.removeValue(forKey: key), !shuttingDown {
                launch(key.binding, next, key: key)
            }
        }
    }
}
