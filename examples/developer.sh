#!/usr/bin/env bash
#
# developer.sh: a footboard of macros for software engineers.
#
# Ten switches and an expression pedal, bound to things you'd otherwise
# reach for the keyboard to do mid-thought: run the tests, wait on CI, sync
# the branch, mute the mic for a call, and so on.
#
# Usage:
#   ./developer.sh                      # use every MIDI source
#   ./developer.sh --source "USB MIDI"  # extra arguments go to fcbnerd
#   DRY_RUN=1 ./developer.sh            # print what would run, do nothing
#   PROJECT_DIR=~/src/app ./developer.sh
#
# Try it without a pedal: run `fcbnerd simulate` in another terminal, then
# `DRY_RUN=1 MAPPING=simulator ./developer.sh --source simulator`. Keep
# DRY_RUN on while testing with it, because the simulator presses every
# switch on a loop (lock screen included).
#
# Requirements: fcbnerd. watch_ci and open_pr also need the GitHub CLI
# (`gh`), logged in. macOS asks for permissions the first time some macros
# run: notifications for your terminal, and Screen Recording for screenshot.

set -euo pipefail

# ---------------------------------------------------------------------------
# Mappings
#
# Every pedal is programmed differently. Run `fcbnerd -f text`, press a
# switch, and copy the `bind=` pattern it prints. Edit the lines below, or
# override any of them from the environment, e.g. SWITCH_1=1:20:127.
#
# The fcb1010 mapping is bank 1 of a factory-programmed FCB1010: switches
# 1-10 send CC 20-29 with value 127 on channel 1. Stay in bank 1; other banks
# send different messages.
#
# PEDAL_A is a space-separated list, because on the FCB1010 an expression
# pedal's CC depends on the selected preset: pedal A sends CC 30 in preset 1,
# CC 31 in preset 2, and so on up to CC 39. Pedal B does the same from CC 40,
# and is left unbound here; set PEDAL_A= (empty) to unbind pedal A too. A
# pedal pattern must never match a switch, or pressing that switch would also
# move the volume. main checks this.
# ---------------------------------------------------------------------------

case ${MAPPING:-fcb1010} in
  fcb1010)
    : "${SWITCH_1:=1:20:127}"  # run_tests
    : "${SWITCH_2:=1:21:127}"  # watch_ci
    : "${SWITCH_3:=1:22:127}"  # git_sync
    : "${SWITCH_4:=1:23:127}"  # open_pr
    : "${SWITCH_5:=1:24:127}"  # copy_branch
    : "${SWITCH_6:=1:25:127}"  # mic_toggle
    : "${SWITCH_7:=1:26:127}"  # focus_timer
    : "${SWITCH_8:=1:27:127}"  # rubber_duck
    : "${SWITCH_9:=1:28:127}"  # screenshot
    : "${SWITCH_10:=1:29:127}" # lock_screen
    : "${PEDAL_A=1:30:* 1:31:* 1:32:* 1:33:* 1:34:* 1:35:* 1:36:* 1:37:* 1:38:* 1:39:*}" # output_volume
    ;;
  simulator) # what `fcbnerd simulate` sends
    : "${SWITCH_1:=pc:1:0}"
    : "${SWITCH_2:=pc:1:1}"
    : "${SWITCH_3:=pc:1:2}"
    : "${SWITCH_4:=pc:1:3}"
    : "${SWITCH_5:=pc:1:4}"
    : "${SWITCH_6:=pc:1:5}"
    : "${SWITCH_7:=pc:1:6}"
    : "${SWITCH_8:=pc:1:7}"
    : "${SWITCH_9:=pc:1:8}"
    : "${SWITCH_10:=pc:1:9}"
    : "${PEDAL_A=1:27:*}"
    ;;
  *)
    echo "developer.sh: unknown MAPPING \"$MAPPING\" (expected fcb1010 or simulator)" >&2
    exit 64
    ;;
esac

# The repository the git and test macros work in. Defaults to wherever you
# started the script.
export PROJECT_DIR=${PROJECT_DIR:-$PWD}

# Timer state, the mic's saved volume and test logs live here.
export STATE_DIR=${STATE_DIR:-${TMPDIR:-/tmp}/fcbnerd-developer}

export DRY_RUN=${DRY_RUN:-}

# ---------------------------------------------------------------------------
# How this works
#
# fcbnerd runs each binding's command in a fresh shell, which knows nothing
# about this script. Two things carry it across:
#
#   1. `export -f` (at the bottom) puts these functions in the environment,
#      where any child bash can see them.
#   2. `--shell "$BASH"` makes fcbnerd use the bash running this script, not
#      /bin/sh. Same interpreter, so the exported functions load exactly as
#      written.
#
# Commands run in the background. A slow macro, like waiting on CI, doesn't
# block the pedal, and pressing a switch twice starts it twice. Macros that
# shouldn't overlap take a lock (see with_lock).
#
# Each command also gets the triggering message in its environment:
# MIDI_TYPE, MIDI_CHANNEL, MIDI_CONTROLLER, MIDI_VALUE, MIDI_PROGRAM and
# MIDI_SOURCE. output_volume uses MIDI_VALUE.
# ---------------------------------------------------------------------------

# Every binding goes through here: log the press, honor DRY_RUN, run it.
macro() {
  local name=$1
  if [ -n "$DRY_RUN" ]; then
    echo "$(date +%T) [dry run] $name (${MIDI_TYPE:-?} ${MIDI_CONTROLLER:+controller=$MIDI_CONTROLLER }${MIDI_VALUE:+value=$MIDI_VALUE}${MIDI_PROGRAM:+program=$MIDI_PROGRAM})"
    return
  fi
  echo "$(date +%T) $name"
  "$name"
}

# A macOS notification. Arguments go to AppleScript as data, not spliced into
# the script, so branch names with quotes in them can't break it.
notify() {
  osascript - "$1" "${2:-}" > /dev/null <<'APPLESCRIPT'
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
}

# One of the stock system sounds: Glass, Basso, Pop, Submarine, ...
sound() {
  afplay "/System/Library/Sounds/$1.aiff" &
}

# Runs a command unless another copy of the same macro is still going.
# mkdir is atomic, so two presses can't both take the lock. The lock records
# its owner's pid, so a lock left behind by a killed run gets cleared.
with_lock() {
  local name=$1 lock="$STATE_DIR/$1.lock"
  shift
  mkdir -p "$STATE_DIR"
  if ! mkdir "$lock" 2> /dev/null; then
    if kill -0 "$(cat "$lock/pid" 2> /dev/null)" 2> /dev/null; then
      notify "$name" "Already running"
      return 0
    fi
    rm -rf "$lock"
    mkdir "$lock" 2> /dev/null || return 0 # another press just took it
  fi
  echo $$ > "$lock/pid"
  "$@"
  local status=$?
  rm -rf "$lock"
  return $status
}

# ---------------------------------------------------------------------------
# Switch 1: run the project's tests
#
# Works out the test command from the files in PROJECT_DIR, runs it, and
# tells you the result with a notification and a sound. Output goes to a log
# file, which the failure notification names.
# ---------------------------------------------------------------------------

test_command() {
  if [ -f Package.swift ]; then echo "swift test"
  elif [ -f Cargo.toml ]; then echo "cargo test"
  elif [ -f go.mod ]; then echo "go test ./..."
  elif [ -f package.json ]; then echo "npm test"
  elif [ -f pyproject.toml ] || [ -f pytest.ini ]; then echo "python3 -m pytest"
  elif [ -f Makefile ]; then echo "make test"
  else return 1
  fi
}

run_tests() {
  with_lock run_tests _run_tests
}

_run_tests() {
  cd "$PROJECT_DIR" || return 1
  local command log project
  project=$(basename "$PROJECT_DIR")
  if ! command=$(test_command); then
    notify "Tests" "Don't know how to test $project"
    return 1
  fi

  log="$STATE_DIR/tests-$project.log"
  notify "Tests" "Running $command in $project"
  local started=$SECONDS
  if $command > "$log" 2>&1; then
    notify "Tests passed" "$project in $((SECONDS - started))s"
    sound Glass
  else
    notify "Tests failed" "$project, see $log"
    sound Basso
  fi
}

# ---------------------------------------------------------------------------
# Switch 2: wait on CI
#
# Finds the latest GitHub Actions run for the current branch and pings you
# when it finishes. Push, stomp, go do something else.
# ---------------------------------------------------------------------------

watch_ci() {
  with_lock watch_ci _watch_ci
}

_watch_ci() {
  cd "$PROJECT_DIR" || return 1
  local branch run
  branch=$(git branch --show-current)
  run=$(gh run list --branch "$branch" --limit 1 --json databaseId --jq '.[0].databaseId')
  if [ -z "$run" ]; then
    notify "CI" "No runs for $branch"
    return
  fi

  notify "CI" "Watching the latest run on $branch"
  if gh run watch "$run" --exit-status > /dev/null 2>&1; then
    notify "CI passed" "$branch"
    sound Glass
  else
    notify "CI failed" "$branch: gh run view $run --log-failed"
    sound Basso
  fi
}

# ---------------------------------------------------------------------------
# Switch 3: sync the branch
#
# Pull with rebase, stashing and restoring local changes around it, and
# report how many commits came in.
# ---------------------------------------------------------------------------

git_sync() {
  with_lock git_sync _git_sync
}

_git_sync() {
  cd "$PROJECT_DIR" || return 1
  local branch before
  branch=$(git branch --show-current)
  before=$(git rev-parse HEAD)
  if git pull --rebase --autostash --quiet > /dev/null 2>&1; then
    notify "Synced $branch" "$(git rev-list --count "$before..HEAD") new commit(s)"
    sound Pop
  else
    notify "Sync failed" "$branch needs attention in $PROJECT_DIR"
    sound Basso
  fi
}

# ---------------------------------------------------------------------------
# Switch 4: open the pull request
#
# Opens the current branch's PR in the browser, or the repository page if
# there isn't one yet.
# ---------------------------------------------------------------------------

open_pr() {
  cd "$PROJECT_DIR" || return 1
  gh pr view --web > /dev/null 2>&1 || gh repo view --web > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Switch 5: copy the branch name
#
# For commit messages, tickets and "which branch is that on?" in chat.
# ---------------------------------------------------------------------------

copy_branch() {
  cd "$PROJECT_DIR" || return 1
  local branch
  branch=$(git branch --show-current)
  printf '%s' "$branch" | pbcopy
  notify "Copied" "$branch"
}

# ---------------------------------------------------------------------------
# Switch 6: mute the microphone
#
# A toggle, which is what the FCB1010 is good at: it has no release event, so
# hold-to-talk isn't possible. The volume before muting is saved and restored
# on the next press.
# ---------------------------------------------------------------------------

mic_toggle() {
  mkdir -p "$STATE_DIR"
  local saved="$STATE_DIR/mic-volume" current
  current=$(osascript -e 'input volume of (get volume settings)')
  case $current in
    '' | *[!0-9]*)
      notify "Microphone" "This input device has no adjustable volume"
      return 1
      ;;
  esac

  if [ "$current" -gt 0 ]; then
    echo "$current" > "$saved"
    osascript -e 'set volume input volume 0'
    notify "Microphone" "Muted"
    sound Submarine
  else
    osascript -e "set volume input volume $(cat "$saved" 2> /dev/null || echo 75)"
    notify "Microphone" "Live"
    sound Pop
  fi
}

# ---------------------------------------------------------------------------
# Switch 7: focus timer
#
# First press starts the clock, second press stops it and appends a line to
# focus.log: when you started, which project, and how many minutes.
# ---------------------------------------------------------------------------

focus_timer() {
  mkdir -p "$STATE_DIR"
  local started_file="$STATE_DIR/focus-started"
  if [ -f "$started_file" ]; then
    local started minutes
    started=$(cat "$started_file")
    minutes=$((($(date +%s) - started) / 60))
    rm -f "$started_file"
    printf '%s\t%s\t%d min\n' "$(date -r "$started" '+%Y-%m-%d %H:%M')" \
      "$(basename "$PROJECT_DIR")" "$minutes" >> "$STATE_DIR/focus.log"
    notify "Focus" "Stopped after $minutes min"
  else
    date +%s > "$started_file"
    notify "Focus" "Started"
  fi
}

# ---------------------------------------------------------------------------
# Switch 8: rubber duck
#
# Asks you a debugging question out loud. Explaining the bug to it is the
# point.
# ---------------------------------------------------------------------------

rubber_duck() {
  local questions=(
    "What did you expect to happen, and what happened instead?"
    "When did it last work, and what changed since?"
    "Have you read the error message all the way to the end?"
    "Is the code you're reading the code that's running?"
    "What would have to be true for this to happen?"
    "Can you make it fail with less code?"
    "Which of your assumptions haven't you checked?"
  )
  say "${questions[RANDOM % ${#questions[@]}]}"
}

# ---------------------------------------------------------------------------
# Switch 9: screenshot to the clipboard
#
# Drag to select an area, or press space to pick a window. The image lands on
# the clipboard, ready to paste into a bug report.
# ---------------------------------------------------------------------------

screenshot() {
  screencapture -ic
}

# ---------------------------------------------------------------------------
# Switch 10: lock the screen
#
# Stomp on your way to the coffee machine. This sleeps the display, which
# locks if "Require password after screen saver begins or display is turned
# off" is set to Immediately (System Settings → Lock Screen).
# ---------------------------------------------------------------------------

lock_screen() {
  pmset displaysleepnow
}

# ---------------------------------------------------------------------------
# Expression pedal: output volume
#
# The pedal sends 0-127; macOS volume is 0-100. fcbnerd only runs one of
# these at a time and skips to the latest position, so a fast sweep doesn't
# spawn a pile of osascript processes.
# ---------------------------------------------------------------------------

output_volume() {
  osascript -e "set volume output volume $((MIDI_VALUE * 100 / 127))"
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

main() {
  if ! command -v fcbnerd > /dev/null; then
    echo "developer.sh: fcbnerd isn't installed; see https://github.com/JamesRyanATX/fcbnerd" >&2
    exit 1
  fi

  export -f macro notify sound with_lock \
    test_command run_tests _run_tests watch_ci _watch_ci git_sync _git_sync \
    open_pr copy_branch mic_toggle focus_timer rubber_duck screenshot \
    lock_screen output_volume

  local switches=(
    "$SWITCH_1" "$SWITCH_2" "$SWITCH_3" "$SWITCH_4" "$SWITCH_5"
    "$SWITCH_6" "$SWITCH_7" "$SWITCH_8" "$SWITCH_9" "$SWITCH_10"
  )
  local binds=(
    --bind "$SWITCH_1=macro run_tests"
    --bind "$SWITCH_2=macro watch_ci"
    --bind "$SWITCH_3=macro git_sync"
    --bind "$SWITCH_4=macro open_pr"
    --bind "$SWITCH_5=macro copy_branch"
    --bind "$SWITCH_6=macro mic_toggle"
    --bind "$SWITCH_7=macro focus_timer"
    --bind "$SWITCH_8=macro rubber_duck"
    --bind "$SWITCH_9=macro screenshot"
    --bind "$SWITCH_10=macro lock_screen"
  )

  # `read -a` splits on spaces without expanding the * in each pattern as a
  # filename glob.
  local pedal_patterns pattern switch
  read -r -a pedal_patterns <<< "${PEDAL_A:-}"
  for pattern in ${pedal_patterns[@]+"${pedal_patterns[@]}"}; do
    for switch in "${switches[@]}"; do
      case $switch in
        "${pattern%:\*}":*)
          echo "developer.sh: pedal pattern $pattern also matches switch $switch" >&2
          exit 64
          ;;
      esac
    done
    binds+=(--bind "$pattern=macro output_volume")
  done

  echo "developer.sh: project $PROJECT_DIR, mapping ${MAPPING:-fcb1010}${DRY_RUN:+ (dry run)}"

  # exec hands the process over to fcbnerd, so Ctrl+C goes straight to it and
  # it stops any macros still running.
  exec fcbnerd --quiet --shell "$BASH" "${binds[@]}" "$@"
}

# Run only when executed, so the functions can be sourced for testing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
