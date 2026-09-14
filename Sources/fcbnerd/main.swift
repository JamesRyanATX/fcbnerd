import FCBNerdCore
import Foundation

let version = "0.2.1"

let usage = """
    fcbnerd \(version) -- stream MIDI foot controller events, or bind them to commands

    USAGE
      fcbnerd [listen] [--source NAME] [--format json|text]
                       [--bind BINDING]... [--quiet] [--shell PATH]
      fcbnerd list [--format json|text]
      fcbnerd simulate

    COMMANDS
      listen      (default) Connect to MIDI sources and print one line per
                  event until interrupted. Follows hotplug.
      list        Print the currently available MIDI sources and exit.
      simulate    Publish a virtual source that plays synthetic pedal
                  presses and sweeps, for testing without hardware.

    OPTIONS
      -s, --source NAME   Only use sources whose name contains NAME
                          (case-insensitive). Default: all sources.
      -f, --format FMT    json (default): one JSON object per line.
                          text: human-readable columns; not a stable format.
                          Shows a ready-to-use bind= pattern for each event.
      -b, --bind BINDING  Run a shell command when a message matches. Repeatable.
                            CHANNEL:CONTROLLER:VALUE=COMMAND   control change
                            pc:CHANNEL:PROGRAM=COMMAND         program change
                          Any number may be * (match anything). Commands run
                          in the background via SHELL -c, with MIDI_TYPE,
                          MIDI_CHANNEL, MIDI_CONTROLLER, MIDI_VALUE,
                          MIDI_PROGRAM and MIDI_SOURCE in the environment.
                          Their stdout goes to stderr unless --quiet.
      -q, --quiet         With --bind: don't print events, only run commands.
      --shell PATH        Shell for --bind commands. Default: /bin/sh.
      -h, --help          Show this help.
      --version           Show the version.

    EXAMPLES
      fcbnerd -f text                                  find out what your pedal sends
      fcbnerd -q --bind '1:20:127=open ~/Downloads'    stomp to open a folder
      fcbnerd -q --bind 'pc:1:0=say hello' \\
                 --bind '1:27:*=osascript -e "set volume output volume $((MIDI_VALUE * 100 / 127))"'

    """

enum Command: String {
    case listen, list, simulate
}

struct Options {
    var command = Command.listen
    var source: String?
    var format = OutputFormat.json
    var bindings: [Binding] = []
    var quiet = false
    var shell: String?
}

func usageError(_ message: String) -> Never {
    printError(message)
    fputs("Run `fcbnerd --help` for usage.\n", stderr)
    exit(64) // EX_USAGE
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var sawCommand = false
    var remaining = arguments[...]

    func value(for flag: String) -> String {
        guard let next = remaining.popFirst() else { usageError("\(flag) needs a value") }
        return next
    }

    while let argument = remaining.popFirst() {
        switch argument {
        case "-h", "--help", "help":
            print(usage, terminator: "")
            exit(0)
        case "--version":
            print(version)
            exit(0)
        case "-s", "--source":
            options.source = value(for: argument)
        case "-f", "--format":
            let raw = value(for: argument)
            guard let format = OutputFormat(rawValue: raw) else {
                usageError("unknown format \"\(raw)\" (expected json or text)")
            }
            options.format = format
        case "-b", "--bind":
            do {
                options.bindings.append(try Binding(parsing: value(for: argument)))
            } catch {
                usageError("bad --bind \(error)")
            }
        case "-q", "--quiet":
            options.quiet = true
        case "--shell":
            let shell = value(for: argument)
            guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else {
                usageError("--shell needs the absolute path of an executable, got \"\(shell)\"")
            }
            options.shell = shell
        default:
            guard !sawCommand, !argument.hasPrefix("-"), let command = Command(rawValue: argument) else {
                usageError("unexpected argument \"\(argument)\"")
            }
            options.command = command
            sawCommand = true
        }
    }

    if options.command != .listen, !options.bindings.isEmpty || options.quiet || options.shell != nil {
        usageError("--bind, --quiet and --shell only apply to listen")
    }
    if options.bindings.isEmpty, options.quiet || options.shell != nil {
        usageError("--quiet and --shell need at least one --bind")
    }
    return options
}

/// Stops bound commands, then dies from the signal that ended fcbnerd so the
/// exit status is what a shell expects (e.g. 130 for Ctrl+C).
func exit(stoppingCommandsOf runner: CommandRunner?, dueTo signalNumber: Int32) -> Never {
    runner?.terminateAll()
    signal(signalNumber, SIG_DFL)
    kill(getpid(), signalNumber)
    exit(128 + signalNumber)
}

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
var signalSources: [DispatchSourceSignal] = []

switch options.command {
case .list:
    let sources = MIDISources.all()
    for source in sources {
        switch options.format {
        case .json:
            print("{\"type\":\"source\",\"name\":\"\(RecordFormatter.escapeJSONString(source.name))\",\"id\":\(source.id)}")
        case .text:
            print(source.name)
        }
    }
    if sources.isEmpty { printError("no MIDI sources found") }
    exit(0)

case .listen:
    let runner = options.bindings.isEmpty ? nil : CommandRunner(
        bindings: options.bindings,
        shell: options.shell ?? "/bin/sh",
        stdoutToStderr: !options.quiet
    )

    if let runner {
        let count = options.bindings.count
        printError("\(count) binding\(count == 1 ? "" : "s"); commands run with \(runner.shell) -c")

        // Bound commands run in their own process groups, so Ctrl+C at the
        // terminal (or SIGTERM from a supervisor, or the terminal closing)
        // reaches only fcbnerd. Catch those signals and stop the commands
        // before exiting.
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { exit(stoppingCommandsOf: runner, dueTo: signalNumber) }
            source.resume()
            signalSources.append(source)
        }
        // Same for a closed stdout (`fcbnerd --bind ... | head`): ignore
        // SIGPIPE so the failed write returns and we can clean up first.
        signal(SIGPIPE, SIG_IGN)
    }

    let output = options.quiet ? nil : OutputWriter(format: options.format) {
        exit(stoppingCommandsOf: runner, dueTo: SIGPIPE)
    }

    let listener = MIDIListener(sourceFilter: options.source) { record in
        output?.write(record)
        runner?.handle(record)
    }
    do {
        try listener.start()
    } catch {
        printError("\(error)")
        exit(1)
    }
    withExtendedLifetime(listener) { RunLoop.main.run() }

case .simulate:
    let simulator = Simulator()
    do {
        try simulator.start()
    } catch {
        printError("\(error)")
        exit(1)
    }
    withExtendedLifetime(simulator) { RunLoop.main.run() }
}
