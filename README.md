# mac-stay-awake

Keeps a Mac awake while work is actually running, **including with the lid closed**, and lets it
sleep again as soon as the work is finished.

Closing the lid normally sleeps a Mac no matter what, which kills long-running work: a build, a
render, a download, an AI coding session. `caffeinate` does not help, because macOS ignores its
assertion once the lid is shut.

## What it does

    stayawake                  is it staying awake right now, and why
    stayawake keep 2h          keep it awake myself
    stayawake let-sleep        let it sleep now, even though work is running
    stayawake auto             back to automatic

There is also a menu bar app with the same controls and the settings:

    ┌─────────────────────────────────┐
    │ Stay Awake         [ ON  ●───]  │
    │                                 │
    │ Staying awake                   │
    │ 2 things working (claude)       │
    │ 14m so far, stops after 8h      │
    │ Battery 76%, on power           │
    │                                 │
    │ [ Keep awake ▾ ] [ Let it sleep ]│
    │                                 │
    │ Stop after      ──────●──  8 h  │
    │ Battery limit   ──●──────  15 % │
    │ Tell me when it changes  [ ✓ ]  │
    └─────────────────────────────────┘

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

## Safety limits

Nothing here can keep a Mac awake indefinitely by accident.

| setting | default | what it does |
| --- | --- | --- |
| `MAX_HOLD` | 8h | gives up after this much continuous hold, even if work continues |
| `BATTERY_FLOOR` | 15% | gives up when discharging at or below this, even if work continues |
| `GRACE` | 15m | waits this long after work ends before allowing sleep |
| `NOTIFY` | all | `all`, `forced` (limits only), or `none` |
| `MATCH` | caffeinate | process name that counts as work in progress |

The grace period is not padding: an assertion is typically re-taken every few minutes, and without
it the Mac could sleep in the gap between two renewals.

A limit that fires **latches**, so it cannot re-arm on the next check while the same work is still
running. The time limit clears when the work ends; the battery limit clears on mains power or once
the charge is more than 5 points above the floor.

`disablesleep` survives reboots, so the helper sets it back to `0` as its first action at every
boot. A crash while holding cannot leave a Mac permanently unable to sleep.

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
