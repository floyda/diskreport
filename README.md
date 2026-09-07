# DiskReport

Read-only, scheduled disk usage reporter for macOS. A sandboxed scanner records the size, growth and
last-modified time of every directory under your configured roots each morning; a menu bar app shows
what grew since yesterday / last week / last month and what is stale, and reveals folders in Finder so
you can act on them yourself.

DiskReport never modifies anything under a scanned root. See `docs/superpowers/specs/` for the guardrails.

## Install

    make install      # builds, installs to ~/Applications and ~/Library/Application Support/DiskReport, schedules 07:00 daily
    make scan-now     # trigger a scan immediately
    make status       # launchd state and log files

Config lives at `~/Library/Application Support/DiskReport/config.json`:

    { "roots": ["~/Workspace"], "retention": { "dailyDays": 45, "weeklyWeeks": 52 } }

Add more roots (e.g. `"~/Library"`) as separate entries; a root inside another root is rejected.
Scanning `~/Library` may need Full Disk Access for `diskreport-scan` in System Settings → Privacy & Security.

## Use

The disk icon in the menu bar opens the report. Double-click a row (or ⌘R) to reveal it in Finder with the
folder selected. Right-click for Copy Path and Open in Terminal. Filters: Grew today / this week, New,
Deleted, Stale > 1 month / > 6 months. Search matches any part of the path.

## Uninstall

    make uninstall           # removes app, scanner, launchd agent; keeps config + database
    make uninstall PURGE=1   # also removes config, database and logs

## Develop

    make test                # lint-readonly + swift test (includes sandbox verification tests)
    make bundle              # build/DiskReport.app for local runs: open build/DiskReport.app --args --show-report
