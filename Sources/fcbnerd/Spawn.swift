import Darwin

struct SpawnError: Error, CustomStringConvertible {
    let code: Int32

    var description: String {
        String(cString: strerror(code))
    }
}

/// Starts `shell -c command` without waiting for it, returning its pid.
///
/// Uses posix_spawn directly rather than Foundation's Process for control
/// over exactly what the child gets:
///
/// - Its own process group (pgid = its pid), so `killpg` reaches pipelines
///   and grandchildren the shell starts, not just the shell.
/// - Default dispositions for the termination signals. fcbnerd ignores
///   them while it cleans up, and ignored dispositions survive exec, so
///   without this the children would ignore our SIGTERM too.
/// - stdin from /dev/null, and no inherited file descriptors besides
///   stdout and stderr.
/// - A spawn failure reported as an errno value, never an exception.
func spawnShell(_ shell: String, command: String, environment: [String: String], stdoutToStderr: Bool) throws -> pid_t {
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    if stdoutToStderr {
        posix_spawn_file_actions_adddup2(&fileActions, STDERR_FILENO, STDOUT_FILENO)
    } else {
        posix_spawn_file_actions_addinherit_np(&fileActions, STDOUT_FILENO)
    }
    posix_spawn_file_actions_addinherit_np(&fileActions, STDERR_FILENO)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }

    var defaultSignals = sigset_t()
    sigemptyset(&defaultSignals)
    for signal in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE] {
        sigaddset(&defaultSignals, signal)
    }
    posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
    var emptyMask = sigset_t()
    sigemptyset(&emptyMask)
    posix_spawnattr_setsigmask(&attributes, &emptyMask)
    posix_spawnattr_setpgroup(&attributes, 0)
    let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
    posix_spawnattr_setflags(&attributes, Int16(flags))

    let arguments = [shell, "-c", command]
    let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
    var pid: pid_t = 0
    let result = withCStringArray(arguments) { argv in
        withCStringArray(environmentStrings) { envp in
            posix_spawn(&pid, shell, &fileActions, &attributes, argv, envp)
        }
    }
    guard result == 0 else { throw SpawnError(code: result) }
    return pid
}

/// Calls `body` with a NULL-terminated C array of the strings.
private func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
