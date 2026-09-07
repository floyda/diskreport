# DiskReport

Read-only, scheduled disk usage reporter for macOS. A sandboxed scanner records the size, growth and
last-modified time of every directory under your configured roots each morning; a menu bar app shows
what grew since yesterday / last week / last month and what is stale, and reveals folders in Finder so
you can act on them yourself.

DiskReport never modifies anything under a scanned root. That promise is enforced at four independent
layers rather than assumed:

1. **OS sandbox.** The scanner runs under `sandbox-exec` with a profile that denies every write outside
   `~/Library/Application Support/DiskReport` and `~/Library/Logs/DiskReport`, and denies network.
2. **Code discipline.** The walker uses only `opendir`/`readdir`/`fstatat` with no-follow flags. A lint
   step (`Scripts/lint-readonly.sh`) fails the build if any write-capable call appears outside the two
   modules allowed to write to DiskReport's own folders.
3. **Process separation.** The menu bar app has no filesystem walk code at all; it reads the database and
   asks Finder to reveal paths.
4. **Verification test.** The test suite records a full metadata manifest of a fixture tree, runs the real
   scanner binary under the real sandbox profile, and asserts nothing changed.

The full design lives in [`docs/superpowers/specs/2026-09-07-diskreport-design.md`](docs/superpowers/specs/2026-09-07-diskreport-design.md).

## Requirements

- macOS 14 or later (built and tested on macOS 26 with Xcode 26). Apple silicon or Intel.
- Xcode command line tools with Swift 5.10+ (`swift --version`).
- No third-party dependencies; SQLite comes from the system.
- No admin rights: everything installs under your home directory.

## How it works

```
launchd (07:00 daily)
  └─ run-scan.sh
       ├─ sandbox-exec -f scan.sb diskreport-scan   # walks roots, writes one snapshot to SQLite
       └─ open -a DiskReport --show-report          # brings the menu bar app's window forward

DiskReport.app (menu bar)
  ├─ reads ~/Library/Application Support/DiskReport/diskreport.sqlite
  ├─ compares the latest snapshot with the ones from 1, 7 and 30 days ago
  └─ Reveal in Finder selects the folder in its parent, so ⌘⌫ acts on it directly
```

The scanner walks every directory under each root once, recording allocated size (what the disk actually
loses, so APFS clones and sparse files are counted correctly), file count and the newest modification time
anywhere beneath it. Symlinks are never followed, hard links are counted once, and other volumes are never
entered. Snapshots are compared against the most recent completed scan at least 1, 7 and 30 days old; where
no such scan exists yet the column shows "—" rather than guessing. Old snapshots are thinned to one per week
after 45 days and one per month after a year.

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

Layout:

    Sources/DiskReportCore    walker, SQLite store, comparison queries, retention, logging (the only writer)
    Sources/diskreport-scan   headless scanner CLI run by launchd
    Sources/DiskReportUI      view-model logic for the report (no SwiftUI, fully unit tested)
    Sources/DiskReport        SwiftUI menu bar app
    Resources/                sandbox profile, launchd wrapper and plist, app Info.plist
    Scripts/                  lint-readonly.sh, bundle-app.sh
    Tests/                    XCTest suites, including the sandbox verification tests
    docs/superpowers/         design spec and implementation plan

Extension points already in place: `DirectoryClassifier` (label `node_modules`, virtualenvs, `.git`,
build output and archives; v1 ships a no-op) and `NotableRule` (rules that badge the menu bar icon when
something needs attention; v1 ships none).

## Roadmap

- Directory classification with a "reclaimable if rebuilt" total per project.
- Menu bar badge and optional notification when free space drops below a threshold or a folder grows
  more than a set amount in a day.
- Add-root UI, size trend sparklines from the retained snapshots.

## License

MIT. See [LICENSE](LICENSE).
