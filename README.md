# mac-stay-awake

Keeps a Mac awake while work is actually running, **including with the lid closed**, and lets it
sleep again as soon as the work is finished.

Closing the lid normally sleeps a Mac no matter what, which kills long-running work: a build, a
render, a download, an AI coding session. `caffeinate` does not help, because macOS ignores its
assertion once the lid is shut.

## What it does

    stayawake                  is it staying awake right now, and why
    stayawake keep 2h          keep it awake myself
    stayawake keep until 08:00 keep it awake until a set time, for an overnight run
    stayawake let-sleep        let it sleep now, even though work is running
    stayawake auto             back to automatic

There is also a menu bar app with the same controls and the settings:

    ┌──────────────────────────────────────────┐
    │ Stay Awake                  [ ON  ●───]  │
    │                                          │
    │ Staying awake                            │
    │ 2 things working (claude, claude)        │
    │ Awake 14m so far, no time limit          │
    │ Battery 76%, on power                    │
    │                                          │
    │ [ Keep awake ▾ ] [ Let it sleep ]        │
    │ or until [ 08:00 ] [ Hold ]              │
    │                                          │
    │ Sleep when quiet for  ──●─────  1h       │
    │ Remind me every       ────●───  6h       │
    │ Battery limit         ─●──────  15%      │
    │ [✓] Wake the Mac daily at [ 07:30 ]      │
    │ [✓] Tell me when it changes              │
    └──────────────────────────────────────────┘

## How it decides

The only switch that survives a lid close is `pmset disablesleep`, which needs root and persists
across reboots, so setting it by hand is easy to forget and awkward to undo.

Instead of guessing, this watches the signal the system already keeps: **`caffeinate` processes**.
Anything doing long work takes that assertion, so it is a reliable "work is happening" flag that
needs no wrappers and no cooperation from the tools involved.

    while at least one caffeinate process exists -> pmset -a disablesleep 1
    once the last one goes, plus a grace period  -> pmset -a disablesleep 0

Because the OS is already counting, parallel jobs and jobs that spawn other jobs reference-count
themselves for free. Nothing has to be started through a wrapper.

Claude Code is a good example: each session that is actively working spawns `caffeinate -i -t 300`
as a child and renews it while busy. Note that the *presence* of a tool is not the signal, only that
assertion: idle sessions can sit around for weeks, and holding the Mac awake for those would mean
never sleeping again.

## Quiet, not finished

The setting that matters most is the **quiet window**, and it exists because of one awkward fact:
an assertion is dropped and re-taken constantly. Between two turns of an agent, between phases of a
build, while one process waits on another, nothing is caffeinating at all. "No assertion right now"
therefore does not mean "the work is finished", and only the LENGTH of the quiet period tells the
two apart.

So the rule is not "sleep when work stops". It is:

    sleep only once EVERYTHING has been quiet for the whole window

Any activity inside the window cancels the countdown, and the Mac stays awake. Real numbers from a
machine running two Claude sessions: the assertion dropped to zero twice in 35 minutes of work that
looked continuous from the outside. With a short window, that Mac would have slept mid-run.

## Limits

| setting | default | what it does |
| --- | --- | --- |
| `IDLE_WINDOW` | 1h | everything must be quiet this long before sleep is allowed |
| `REMIND_EVERY` | 6h | reminds you the Mac is still being kept awake. `0` disables it |
| `BATTERY_FLOOR` | 15% | stops keeping awake when discharging at or below this |
| `WAKE_DAILY` | off | `HH:MM` to wake this Mac every day |
| `NOTIFY` | all | `all`, `forced` (limits only), or `none` |
| `MATCH` | caffeinate | process name that counts as work in progress |

**There is deliberately no maximum hold.** A run that takes all weekend must not be cut off halfway
because a timer expired. `REMIND_EVERY` replaces that protection: it tells you a hold is still
active, without ending it, so a forgotten hold surfaces rather than being silently enforced.

**The battery limit is the one thing that still ends a hold**, because an unplugged Mac held awake
runs itself flat, and that failure is not recoverable by noticing it later. It latches, so it cannot
re-arm on the next check, and clears on mains power or once the charge is comfortably above the
floor. A desktop has no battery, reports 100% on mains, and so is never affected.

`disablesleep` survives reboots, so the helper sets it back to `0` as its first action at every
boot. A crash while holding cannot leave a Mac permanently unable to sleep.

## Long runs and agent fleets

If you start a long scenario, several agents working, communicating, and idling for long stretches
while they wait on each other, there are two ways to keep the Mac up, and they are complementary.

**Automatic**, with the quiet window set to cover the longest gap you expect between bursts of
activity. Nothing to remember. The risk is that a gap longer than the window looks exactly like
"finished".

**Explicit**, with `stayawake keep until 08:00` or the app's *or until* row. Nothing is inferred, so
no gap length can catch you out. This is the better choice for a run you deliberately start, and the
two layers coexist: the explicit hold simply wins while it lasts.

**Know this before relying on either: sleep ENDS a run, it does not pause it.** Local timers do not
fire while a Mac is asleep, so an orchestration that expects to resume at 04:00 does not resume, it
stops. If that matters, set a daily wake (`WAKE_DAILY`, or the checkbox in the app) so the machine
comes back by itself and work can continue.

`WAKE_DAILY` uses `pmset repeat`, which holds a single repeating schedule for the whole machine.
Setting it here replaces any repeating power schedule you set up yourself, and turning it off
cancels that schedule rather than restoring what was there before.

## Install

Needs macOS 14 or newer and the command line tools (`xcode-select --install`), which provide the
Swift compiler for the menu bar app. The installer checks both and stops if either is missing.

    git clone https://github.com/experc/mac-stay-awake.git
    cd mac-stay-awake
    ./install.sh

It asks for your password once, to install the helper. Nothing afterwards needs one: the app and the
CLI only write small files that the helper reads.

To remove it:

    ./uninstall.sh

## What goes where

    /usr/local/sbin/stayawaked                        the helper, running as root
    /usr/local/bin/stayawake                          the command
    /Library/LaunchDaemons/com.macstayawake.helper.plist
    ~/Applications/StayAwake.app                      the menu bar app
    ~/Library/LaunchAgents/com.macstayawake.app.plist  starts the app at login
    ~/.stayawake/config                               your settings, created on first run
    ~/.stayawake/state                                what the helper last saw
    /var/log/stayawaked.log                           what it did, and when

Settings are per machine and deliberately not in this repo, so a laptop and a desktop can disagree
about the battery limit.

## Notes for different machines

**Desktops** report no battery at all, which reads as 100% on mains, so the battery limit simply
never fires there.

**Apple Silicon and Intel** both work; the app is built for whatever `uname -m` reports.

**Several accounts on one Mac**: the helper follows whoever is logged in at the console, reading
their own settings, rather than being tied to the account that installed it.

## Design notes

The helper runs as root and the config file does not, so the config is **parsed, never sourced**.
Only known keys are read, and every value is range-checked. Sourcing it would let anything running
as the user execute code as root.

For the same reason the helper is installed into `/usr/local/sbin` instead of being run from a
checkout in a home directory: a root process should not execute a file an ordinary user can rewrite.

The app never touches `pmset`. It reads the helper's state file and writes small marker files the
helper picks up, which is why it needs no privileges of its own. The app also posts the
notifications, so that clicking one opens the app; the helper only posts them itself when the app is
not running.
