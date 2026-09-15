#!/usr/bin/env bash
#
# developer.sh: a footboard of macros for software engineers.
#
# Ten switches and an expression pedal, bound to things you'd otherwise
# reach for the keyboard to do mid-thought: open your home folder, Mail,
# iTerm, Chrome or Claude, mute the mic for a call, and so on.
#
# Usage:
#   ./developer.sh                      # use every MIDI source
#   ./developer.sh --source "USB MIDI"  # extra arguments go to fcbnerd
#   DRY_RUN=1 ./developer.sh            # print what would run, do nothing
#
# Try it without a pedal: run `fcbnerd simulate` in another terminal, then
# `DRY_RUN=1 MAPPING=simulator ./developer.sh --source simulator`. Keep
# DRY_RUN on while testing with it, because the simulator presses every
# switch on a loop (lock screen included).
#
# Requirements: fcbnerd, plus iTerm, Google Chrome and Claude for switches
# 3-5. macOS asks for permissions the first time some macros run:
# notifications for your terminal, and Screen Recording for screenshot.
# close_window needs Accessibility, which you grant by hand in System
# Settings.

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
# PEDAL_A and PEDAL_B are space-separated lists, because on the FCB1010 an
# expression pedal's CC depends on the selected preset: pedal A sends CC 30
# in preset 1, CC 31 in preset 2, and so on up to CC 39. Pedal B does the same
# from CC 40. Set either to empty (PEDAL_B=) to unbind it. A pedal pattern
# must never match a switch, or pressing that switch would also move the
# volume. main checks this.
# ---------------------------------------------------------------------------

case ${MAPPING:-fcb1010} in
  fcb1010)
    : "${SWITCH_1:=1:20:127}"  # open_home
    : "${SWITCH_2:=1:21:127}"  # open_mail
    : "${SWITCH_3:=1:22:127}"  # open_iterm
    : "${SWITCH_4:=1:23:127}"  # chrome_window
    : "${SWITCH_5:=1:24:127}"  # open_claude
    : "${SWITCH_6:=1:25:127}"  # mic_toggle
    : "${SWITCH_7:=1:26:127}"  # close_window
    : "${SWITCH_8:=1:27:127}"  # rubber_duck
    : "${SWITCH_9:=1:28:127}"  # screenshot
    : "${SWITCH_10:=1:29:127}" # lock_screen
    : "${PEDAL_A=1:30:* 1:31:* 1:32:* 1:33:* 1:34:* 1:35:* 1:36:* 1:37:* 1:38:* 1:39:*}" # output_volume
    : "${PEDAL_B=1:40:* 1:41:* 1:42:* 1:43:* 1:44:* 1:45:* 1:46:* 1:47:* 1:48:* 1:49:*}" # music_volume
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
    : "${PEDAL_B=}" # the simulator sweeps one pedal; try PEDAL_A= PEDAL_B=1:27:*
    ;;
  *)
    echo "developer.sh: unknown MAPPING \"$MAPPING\" (expected fcb1010 or simulator)" >&2
    exit 64
    ;;
esac

# The mic's saved volume lives here.
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
# Commands run in the background. A slow macro, like the rubber duck talking,
# doesn't block the pedal, and pressing a switch twice starts it twice.
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

# ---------------------------------------------------------------------------
# Switch 1: open your home folder
#
# A Finder window on ~, for when the file you need isn't in any project.
# ---------------------------------------------------------------------------

open_home() {
  open "$HOME"
}

# ---------------------------------------------------------------------------
# Switch 2: open Mail
#
# Brings Mail to the front, launching it if it isn't running.
# ---------------------------------------------------------------------------

open_mail() {
  open -a Mail
}

# ---------------------------------------------------------------------------
# Switch 3: open iTerm
#
# Brings iTerm to the front, launching it if it isn't running.
# ---------------------------------------------------------------------------

open_iterm() {
  open -a iTerm
}

# ---------------------------------------------------------------------------
# Switch 4: new Chrome window
#
# Opens Chrome's profile picker, so you choose work or personal before the
# window appears. -n hands the arguments to Chrome even when it's already
# running; without it, open just focuses the existing windows.
# ---------------------------------------------------------------------------

chrome_window() {
  open -na "Google Chrome" --args --new-window chrome://profile-picker/
}

# ---------------------------------------------------------------------------
# Switch 5: open Claude
#
# Brings the Claude desktop app to the front, launching it if it isn't
# running.
# ---------------------------------------------------------------------------

open_claude() {
  open -a Claude
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
# Switch 7: close the active window
#
# Clicks the close button on the front window of whatever app you're in, so
# it closes the whole window, not a tab the way ⌘W does in Chrome or iTerm.
# Apps with unsaved changes still ask first. Needs Accessibility permission
# for your terminal (System Settings → Privacy & Security → Accessibility).
# ---------------------------------------------------------------------------

close_window() {
  osascript > /dev/null <<'APPLESCRIPT'
tell application "System Events" to tell (first process whose frontmost is true)
  click (first button of front window whose subrole is "AXCloseButton")
end tell
APPLESCRIPT
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
# Expression pedal A: output volume
#
# The pedal sends 0-127; macOS volume is 0-100. fcbnerd only runs one of
# these at a time and skips to the latest position, so a fast sweep doesn't
# spawn a pile of osascript processes.
# ---------------------------------------------------------------------------

output_volume() {
  osascript -e "set volume output volume $((MIDI_VALUE * 100 / 127))"
}

# ---------------------------------------------------------------------------
# Expression pedal B: music volume
#
# Spotify's or Music's own volume, separate from the system's, so you can
# duck the music under a call without turning the call down. Only apps that
# are already running are touched; telling a closed app its volume would
# launch it.
# ---------------------------------------------------------------------------

music_volume() {
  local level=$((MIDI_VALUE * 100 / 127)) app
  for app in Spotify Music; do
    if pgrep -xq "$app"; then
      osascript -e "tell application \"$app\" to set sound volume to $level"
    fi
  done
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

main() {
  if ! command -v fcbnerd > /dev/null; then
    echo "developer.sh: fcbnerd isn't installed; see https://github.com/JamesRyanATX/fcbnerd" >&2
    exit 1
  fi

  export -f macro notify sound \
    open_home open_mail open_iterm chrome_window open_claude \
    mic_toggle close_window rubber_duck screenshot lock_screen \
    output_volume music_volume

  local switches=(
    "$SWITCH_1" "$SWITCH_2" "$SWITCH_3" "$SWITCH_4" "$SWITCH_5"
    "$SWITCH_6" "$SWITCH_7" "$SWITCH_8" "$SWITCH_9" "$SWITCH_10"
  )
  local binds=(
    --bind "$SWITCH_1=macro open_home"
    --bind "$SWITCH_2=macro open_mail"
    --bind "$SWITCH_3=macro open_iterm"
    --bind "$SWITCH_4=macro chrome_window"
    --bind "$SWITCH_5=macro open_claude"
    --bind "$SWITCH_6=macro mic_toggle"
    --bind "$SWITCH_7=macro close_window"
    --bind "$SWITCH_8=macro rubber_duck"
    --bind "$SWITCH_9=macro screenshot"
    --bind "$SWITCH_10=macro lock_screen"
  )

  # `read -a` splits on spaces without expanding the * in each pattern as a
  # filename glob.
  local pedal macro pedal_patterns pattern switch
  for pedal in "PEDAL_A output_volume" "PEDAL_B music_volume"; do
    read -r pedal macro <<< "$pedal"
    read -r -a pedal_patterns <<< "${!pedal:-}"
    for pattern in ${pedal_patterns[@]+"${pedal_patterns[@]}"}; do
      for switch in "${switches[@]}"; do
        case $switch in
          "${pattern%:\*}":*)
            echo "developer.sh: $pedal pattern $pattern also matches switch $switch" >&2
            exit 64
            ;;
        esac
      done
      binds+=(--bind "$pattern=macro $macro")
    done
  done

  echo "developer.sh: mapping ${MAPPING:-fcb1010}${DRY_RUN:+ (dry run)}"

  # exec hands the process over to fcbnerd, so Ctrl+C goes straight to it and
  # it stops any macros still running.
  exec fcbnerd --quiet --shell "$BASH" "${binds[@]}" "$@"
}

# Run only when executed, so the functions can be sourced for testing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
