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

    { "roots": ["~/Workspace"], "retention": { "dailyDays": 45, "weeklyWeeks": 52 }, "minRecordedBytes": 1000000 }

Add more roots (e.g. `"~/Library"`) as separate entries; a root inside another root is rejected.
Scanning `~/Library` may need Full Disk Access for `diskreport-scan` in System Settings → Privacy & Security.

## Disk footprint

DiskReport should never become a meaningful consumer of the space it diagnoses, so it does not store a row
for every directory it walks. `minRecordedBytes` (default 1 MB) is the floor: smaller directories are still
walked and still count toward their parents' size, file count and last-modified time, they just get no row of
their own. Measured on a 511,116-directory `~/Workspace`:

| `minRecordedBytes` | Rows per snapshot | Database per snapshot |
|---|---|---|
| `0` (everything) | 511,116 | ~284 MB |
| `100000` (100 KB) | 58,853 | ~33 MB |
| `1000000` (default) | 18,688 | ~10 MB |
| `10000000` (10 MB) | 7,516 | ~4 MB |

With the default retention (45 daily + 52 weekly + monthly snapshots) that is a few GB at `0` per day — hence
the default. Tuning:

- **Want more detail?** Lower `minRecordedBytes` (e.g. `100000`). It applies to future scans only.
- **Database too big?** Raise `minRecordedBytes` and/or shorten `retention`. Both are applied to *existing*
  snapshots on the next scan, which then `VACUUM`s, so the file shrinks on disk without any manual step.
- Each scan logs `dirs=` (rows recorded) and `walked=` (directories visited) in its summary line, plus the
  trimmed row count and resulting database size when it shrinks anything.

Side effects worth knowing:

- A directory that grows past the threshold between two scans has no row in the older snapshot, so the
  report shows it as **new** for that window with its full size as the delta.
- A directory that shrinks from above the threshold to below it between two scans has a baseline row but no
  current row, so the report shows it greyed as **deleted**, with Δ Day equal to minus its old size, even
  though the directory still exists. The misclassification is bounded by the threshold.
- Lowering `minRecordedBytes` produces a one-time flood of **new** rows in every comparison window, one scan
  after the change, because trimmed rows are never re-added to old snapshots.
- `VACUUM` builds its transient copy in memory (`temp_store=MEMORY`, so the sandbox needs no temp-file
  write), which at very low thresholds on large roots can mean a few hundred MB of scanner RSS during the
  vacuum.

## Use

The disk icon in the menu bar opens the report. Double-click a row (or ⌘R) to reveal it in Finder with the
folder selected. Right-click for Copy Path and Open in Terminal. Filters: Grew today / this week, New,
Deleted, Stale > 1 month / > 6 months. Search matches any part of the path. The tree opens one level deep;
use Expand All (⌘⇧E) or Collapse All (⌘⇧C) to dig deeper or reset it.

## Uninstall

    make uninstall           # removes app, scanner, launchd agent; keeps config + database
    make uninstall PURGE=1   # also removes config, database and logs

## Develop

    make test                # lint-readonly + swift test (includes sandbox verification tests)
    make bundle              # build/DiskReport.app for local runs: open build/DiskReport.app --args --show-report
