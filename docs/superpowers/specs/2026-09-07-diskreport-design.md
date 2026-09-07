# DiskReport — Design Spec

Date: 2026-09-07
Status: Draft for review

## 1. Purpose

`~/Workspace` (about 305 GB today on a 926 GB disk that is 94% full) is hard to keep under control: it is not obvious which folders are growing, which are stale, or where the space went. DiskReport gives daily visibility: it scans configured roots each morning, records a snapshot, and shows a native macOS report of size, growth since yesterday / last week / last month, and staleness, with one-click reveal in Finder so the user can act manually.

Non-negotiable constraint: DiskReport never modifies anything under a scanned root. It is read-only by design and enforced at multiple independent layers (section 6).

## 2. Scope

### In scope (v1)

- Full daily scan of one or more configured roots (default `~/Workspace`).
- Per-directory allocated size, file count, and newest modification time, stored for every directory at every depth.
- Comparison of the current scan against the most recent completed scans at ≥1, ≥7, and ≥30 days old.
- Staleness bucketing: this week, this month, within 6 months, older than 6 months.
- Menu bar app with a report window: outline table expanded three levels by default, sortable columns, quick filters, search, reveal in Finder.
- launchd schedule at 07:00 daily, catching up on wake if missed.
- Retention pruning of old snapshots.
- Extension points for classification (`node_modules`, virtualenvs, `.git`, build output, archives) and for a "notable" menu bar icon state.

### Out of scope (v1)

- Any delete, move, rename, or cleanup action.
- File-level rows in the database (directories only).
- Incremental or FSEvents-based scanning.
- Classification logic itself (only the hook).
- Threshold-based notifications or icon changes (only the hook).
- UI for editing config (config is a JSON file).
- Scanning across mounted volumes or into Time Machine snapshot paths.

## 3. Architecture

One Swift package (Swift 6, macOS 26 SDK, Xcode 26.4) with three targets:

| Target | Kind | Responsibility |
|---|---|---|
| `DiskReportCore` | library | Filesystem walk, snapshot model, SQLite store, comparison and staleness queries, retention, classifier protocol, notable-state rules. No UI, no launchd. |
| `diskreport-scan` | executable | CLI entry point. Parses args, loads config, runs the walk per root, writes snapshots, prunes, prints a one-line summary, exits. The only process that reads scanned roots. |
| `DiskReport.app` | SwiftUI app (`LSUIElement`, no Dock icon) | Menu bar item and report window. Reads the database, watches it for changes, reveals paths in Finder via `NSWorkspace`. Contains no walk code. |

Process separation is deliberate: the scanner runs under an OS sandbox that only permits writes to its own data folder; the app never touches the scanned roots at all.

### Data flow

```
launchd (07:00) ──▶ sandbox-exec ──▶ diskreport-scan ──▶ diskreport.sqlite
                                                              │
                     open -a DiskReport --show-report ◀───────┘ (after scan)
                                                              │
                              DiskReport.app ◀── file watch ──┘
                                     │
                                     └──▶ NSWorkspace.activateFileViewerSelecting
```

## 4. Scanner (`DiskReportCore.Walker` + `diskreport-scan`)

### Walk

- Depth-first walk per root using POSIX `opendir` / `readdir` / `fstatat` with `AT_SYMLINK_NOFOLLOW`. Directories are opened with `O_RDONLY | O_DIRECTORY | O_NOFOLLOW`. macOS does not offer `O_NOATIME`; APFS does not update access times on directory reads by default, and the read-only manifest test (section 6) verifies atimes are unchanged on the fixture volume.
- Symlinks are recorded as entries (their own allocated size) and never followed.
- Hard links: files are keyed by `(st_dev, st_ino)`; a second occurrence contributes 0 bytes.
- Size is allocated blocks (`st_blocks * 512`), not logical size, so APFS clones, sparse and compressed files reflect real disk usage.
- The walk stays on the starting device: an entry whose `st_dev` differs from the root's is recorded but not descended.
- Unreadable entries (EACCES, ENOENT races, etc.) are logged with the path and skipped. They never abort the scan.
- Every directory yields one `DirStat`: absolute path, depth relative to root, allocated bytes (recursive), file count (recursive), newest mtime of any entry beneath it (recursive, including the directory itself), and a nullable `kind`.
- Runs at low priority: `setpriority` for CPU and `IOPOL_THROTTLE` for I/O.

### Roots and config

`~/Library/Application Support/DiskReport/config.json`:

```json
{
  "roots": ["~/Workspace"],
  "retention": { "dailyDays": 45, "weeklyWeeks": 52 },
  "minRecordedBytes": 1000000
}
```

- `minRecordedBytes` (default 1 MB) is the floor for storing a directory row; see section 5.
- Tilde is expanded. Each root must resolve to an existing directory on a local volume.
- The scanner rejects a config where one root contains another (would double count) with a message naming both and advising keeping the outer one.
- Each root produces its own `scans` row per run, so a failure in one root does not invalidate another.
- Some folders (e.g. `~/Library/Mail`, Photos library) require Full Disk Access for the scanner binary if `~/Library` or `~` is ever added as a root. Without it they are skipped and logged; the summary line reports the skipped count.

### Preconditions and safety

- Refuses to run as root.
- Refuses to run if a root does not resolve to a directory. External or network volumes are only scanned if listed explicitly as a root; the stay-on-device rule prevents wandering into them from another root.
- Holds an exclusive lock file `~/Library/Application Support/DiskReport/scan.lock`; a second invocation exits immediately with a message.
- Writes only under `~/Library/Application Support/DiskReport/` and `~/Library/Logs/DiskReport/`.

### Classifier hook

```swift
public protocol DirectoryClassifier {
    /// Returns a kind label (e.g. "node_modules", "venv", "git", "build", "archive") or nil.
    func classify(path: String, name: String, entries: DirectoryEntrySummary) -> String?
}
public struct NoClassifier: DirectoryClassifier { func classify(...) -> String? { nil } }
```

The walk calls the classifier once per directory with its name and a cheap summary of immediate children (names only). v1 wires `NoClassifier`. Adding classification later means implementing one type and showing the `kind` column.

## 5. Data model and queries

SQLite at `~/Library/Application Support/DiskReport/diskreport.sqlite`, WAL mode.

```sql
CREATE TABLE roots (
  id INTEGER PRIMARY KEY,
  path TEXT NOT NULL UNIQUE          -- absolute, expanded
);

CREATE TABLE scans (
  id INTEGER PRIMARY KEY,
  root_id INTEGER NOT NULL REFERENCES roots(id),
  started_at INTEGER NOT NULL,       -- unix seconds
  finished_at INTEGER,
  status TEXT NOT NULL,              -- 'running' | 'completed' | 'failed'
  total_bytes INTEGER,
  file_count INTEGER,
  dir_count INTEGER,
  volume_free_bytes INTEGER,
  volume_total_bytes INTEGER,
  skipped_count INTEGER,
  error TEXT
);
CREATE INDEX scans_root_finished ON scans(root_id, status, finished_at);

CREATE TABLE dir_stats (
  scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
  path TEXT NOT NULL,                -- absolute
  parent_path TEXT,                  -- NULL for the root itself
  depth INTEGER NOT NULL,            -- 0 for the root
  bytes INTEGER NOT NULL,
  file_count INTEGER NOT NULL,
  newest_mtime INTEGER NOT NULL,
  kind TEXT,                         -- reserved for classification
  PRIMARY KEY (scan_id, path)
);
CREATE INDEX dir_stats_parent ON dir_stats(scan_id, parent_path);
```

### Recorded-size threshold

Measured on the first real scan of `~/Workspace`: 511,116 directories walked in 525 s, and storing one row
for each of them cost 284 MB. Under the retention policy below that grows to roughly 26 GB — on a volume with
59 GB free, the tool would become a meaningful consumer of the space it exists to diagnose.

So not every walked directory is stored. A directory is written to `dir_stats` only when
`bytes >= minRecordedBytes` (default 1,000,000) **or** it is the root itself (`depth = 0`). Smaller
directories are still walked, and their bytes, file counts and mtimes still roll up into their ancestors;
they simply do not get a row. The measured distribution for `~/Workspace`:

| Threshold | Directories stored |
|---|---|
| 0 (every directory) | 511,116 |
| 100 KB | 58,853 |
| 1 MB (default) | 18,688 |
| 10 MB | 7,516 |

At the default this is roughly 10 MB per snapshot and a few GB across the full retention window.

Consequences of the threshold, both accepted:

- A directory that crosses `minRecordedBytes` between two scans has no row in the older snapshot, so it is
  reported as **new** for that window with its full size as the delta — which is the useful reading anyway.
- Lowering the threshold only affects future scans; raising it is applied to existing snapshots on the next
  run (see retention below), which shrinks the database.


### Comparisons

For a given root, the *baseline* for window `W` (1, 7, or 30 days) is the most recent `completed` scan whose `finished_at` is ≤ `current.finished_at − W days + slack`, where slack is 6 hours. If none exists, the column reports "no data" rather than falling back to the oldest scan, so a fresh install never claims growth it did not observe.

The slack exists because scans start at a fixed 07:00 but take a variable amount of time. Without it, yesterday's scan only qualifies as today's day-baseline if it finished at least as fast as today's, so a scan that runs a few minutes longer than the previous one silently reports "no data" for Δ Day. Six hours absorbs that variance while staying far short of the 24-hour spacing between scheduled runs, so it can never pull in a scan from the same day.

Per directory: `delta = current.bytes − baseline.bytes`. A path present in current but not in a baseline is `new` for that window (delta shown as its full size). `deleted` uses the 1-day baseline only: a path present there but not in current is shown from the baseline row, greyed, with its size as a negative Δ Day; week and month columns for such rows show "—".

### Staleness

Computed at query time from `newest_mtime` relative to scan time: `week` (< 7 days), `month` (< 30), `sixMonths` (< 183), `older` (≥ 183). Buckets are a display concern; the raw mtime is stored.

### Retention

After each successful run, per root:

1. Keep every scan from the last `dailyDays` (45) days.
2. Older than that and within `weeklyWeeks` (52) weeks: keep the last completed scan of each ISO week.
3. Older than that: keep the last completed scan of each calendar month.
4. Delete the rest (cascades to `dir_stats`). Failed scans older than 45 days are deleted.
5. Delete `dir_stats` rows with `bytes < minRecordedBytes AND depth > 0` across all remaining scans of the
   root, so a raised threshold (or one introduced after a snapshot was taken) shrinks existing data.
6. If anything was pruned or trimmed, `VACUUM` once at the end of the run to return the pages to the volume.

Pruning is the only delete the system performs and it only touches its own database.

### Notable-state hook

```swift
public protocol NotableRule { func evaluate(_ report: ReportSummary) -> Notice? }
```

`DiskReportCore` exposes `NotableEvaluator` taking a list of rules. v1 ships an empty list. The app asks the evaluator for notices and, when non-empty, will later swap the menu bar icon. No thresholds are defined in v1.

## 6. Guardrails (read-only enforcement)

Four independent layers; any one failing is caught by another.

1. **OS sandbox.** launchd and the app's "Scan Now" both run the scanner as `sandbox-exec -f scan.sb diskreport-scan`. The profile:
   - `(allow file-read*)` everywhere;
   - `(allow file-write*)` only under `~/Library/Application Support/DiskReport/`, `~/Library/Logs/DiskReport/`, and the process temp dir;
   - `(deny network*)`;
   - default deny for everything else.
   Any write attempt to a scanned root is refused by the kernel. `sandbox-exec` is deprecated by Apple but ships and works on macOS 26; if it is ever removed, the migration path is an App Sandbox entitlement on a signed scanner bundle with `com.apple.security.files.user-selected.read-only` scoped to the roots.
2. **Code discipline.** `DiskReportCore` and `diskreport-scan` use only `opendir`/`readdir`/`fstatat`/`open(O_RDONLY)` against scanned paths. A build-phase lint (`Scripts/lint-readonly.sh`) greps those two targets for write-capable calls (`unlink`, `rmdir`, `rename`, `truncate`, `utimes`, `chmod`, `chown`, `O_WRONLY`, `O_RDWR`, `O_CREAT`, `FileManager.removeItem`, `moveItem`, `createFile`, `write(to:`) outside the `Store/` directory, and fails the build on a hit. `Store/` (database, lock file) and `Logging/` (log files) are the only modules allowed to write, and both are constrained to the DiskReport data and log folders.
3. **Process separation.** The app has no walk code and never opens files under a root. Its only root-related call is `NSWorkspace.shared.activateFileViewerSelecting([url])`, which cannot modify the filesystem.
4. **Verification test.** An integration test builds a fixture tree, records a manifest (`path, size, mtime, ctime, inode, mode`, plus atime where the fixture volume preserves it), runs the real scanner binary under the sandbox profile, and asserts the manifest is unchanged.

Operational: refuse root, lock file, low priority, logs rotated (keep 14 files).

## 7. App (`DiskReport.app`)

### Menu bar item

- Monochrome disk template icon, `LSUIElement = true` (no Dock icon).
- Menu: headline "Last scan: 07:04 today · 61 GB free" (or "No completed scan yet"), then **Open Report**, **Scan Now**, **Reveal Database in Finder**, **Quit**.
- **Scan Now** launches the scanner binary under the same sandbox via `Process`; never an in-process walk. While running, the menu shows "Scanning…" and the report window banner shows progress.
- The icon has a `notable` variant (badged) wired to `NotableEvaluator`; with no rules in v1 it never appears.

### Report window

Single window, opened by launchd after each scan (`open -a DiskReport --args --show-report`) and by the menu item. Three regions:

1. **Summary bar.** Volume free space with delta vs yesterday; per-root total and delta; last scan time and duration; skipped-entry count if non-zero. Warning banner when the latest scan for any root failed or is older than 48 hours, showing the last error line from the log.
2. **Outline table.** One top-level node per root, expanded to depth 3 by default, deeper levels expandable on demand (lazy-loaded per node from `dir_stats` by `parent_path`). Columns: Name, Size, Δ Day, Δ Week, Δ Month, Last Modified, Files, (Kind — hidden in v1). Deltas show signed human sizes, tinted by direction; "—" when no baseline. All columns sort; sort applies within each level. Deleted directories appear greyed with strikethrough.
3. **Filter strip.** Segmented quick filters: All · Grew today · Grew this week · New · Deleted · Stale > 1 month · Stale > 6 months. A search field matches path substrings case-insensitively. Filters apply at every depth and auto-expand ancestors of matches.

### Acting on a row

- **Reveal in Finder** (double-click, toolbar button, context menu, ⌘R): calls `NSWorkspace.shared.activateFileViewerSelecting([folderURL])`. Finder opens the *parent* folder with the target folder selected, so ⌘⌫ acts on it immediately without navigating up. Requirement: the URL passed is the folder itself, never its parent or a child. Unit test asserts this.
- **Copy Path** (context menu, ⌘C).
- **Open in Terminal** (context menu): opens a Terminal window *inside* the folder.
- No delete/move/rename anywhere in the app.

### Data refresh

- Reads the database at launch; watches `diskreport.sqlite-wal` and `diskreport.sqlite` via `DispatchSource` file events and reloads when a scan completes.
- All queries off the main actor. The `DirNode` tree is built on the same background task as the query and
  handed to the main actor complete, so neither the SQLite read nor the tree construction runs on the UI thread.

## 8. Scheduling, installation, failure handling

### launchd

`~/Library/LaunchAgents/com.andyfloyd.diskreport.scan.plist`:
- `StartCalendarInterval` at 07:00; launchd runs missed jobs at next wake.
- `ProgramArguments`: `~/Library/Application Support/DiskReport/bin/run-scan.sh`, which runs `sandbox-exec -f scan.sb diskreport-scan` then `open -a DiskReport --args --show-report` (the `open` runs regardless of scan exit status so failures are visible in the banner).
- `ProcessType = Background`, `LowPriorityIO = true`, `Nice = 10`.
- `StandardOutPath`/`StandardErrorPath` under `~/Library/Logs/DiskReport/`.

### Installation

`make install` (no admin rights, nothing system-wide):
1. `swift build -c release` for the package; assemble `DiskReport.app` bundle (Info.plist with `LSUIElement`, ad-hoc codesign).
2. Copy the app to `~/Applications/DiskReport.app`.
3. Copy `diskreport-scan`, `scan.sb`, `run-scan.sh` to `~/Library/Application Support/DiskReport/bin/`.
4. Write default `config.json` if absent.
5. Install and `launchctl bootstrap` the agent.

`make uninstall` reverses all of the above; the database and config are removed only with `PURGE=1`.

### Failure handling

- Scanner crash or kill: the `scans` row stays `running`; on next start, any `running` rows older than the lock are marked `failed`. Comparisons only ever use `completed` rows.
- No completed scan yet: window shows "First scan pending — click Scan Now".
- Config invalid (missing root, nested roots): scanner exits non-zero with a clear message; the app banner shows it.
- Disk full while writing the database: SQLite error is logged, scan marked `failed`; the scanner never retries into the roots.

## 9. Testing

- **Core unit tests (fixture trees in a temp dir):** walk correctness for nested dirs, symlinks (not followed), hard links (counted once), unreadable entries (skipped, logged), cross-device boundary (not descended), allocated vs logical size; comparison baselines at exact 1/7/30-day boundaries and "no data"; new/deleted detection; staleness buckets; retention pruning across daily/weekly/monthly boundaries; nested-root rejection.
- **Read-only manifest test:** as in section 6, using the built scanner binary under the real sandbox profile.
- **Scanner smoke test:** run the binary under the sandbox against a fixture; assert exit 0, a `completed` row, and that an injected write attempt outside the data folder (behind a test-only flag) is refused.
- **App view-model tests:** sorting, filtering, search auto-expansion, delta formatting, reveal URL correctness (folder itself, not parent), banner conditions.
- **Not in v1:** UI automation tests.

## 10. Future extensions (designed for, not built)

- Classification via `DirectoryClassifier` → `kind` column → "Reclaimable if rebuilt" roll-up per project.
- Notable rules (free space below threshold, folder grew > N GB in a day, weekly digest) → badged menu bar icon and optional macOS notification.
- Add-root UI in the app.
- Size trend sparkline per directory from the retained snapshots.
- App Sandbox entitlement replacing `sandbox-exec` if Apple removes it.

## 11. Repository layout

```
diskreport/
  Package.swift
  Sources/
    DiskReportCore/      Walker/, Model/, Store/, Logging/, Queries/, Classifier/, Notable/
    diskreport-scan/     main.swift
    DiskReport/          App/, MenuBar/, Report/, ViewModels/
  Resources/
    scan.sb              sandbox profile
    run-scan.sh
    com.andyfloyd.diskreport.scan.plist
    Info.plist
  Scripts/
    lint-readonly.sh
    bundle-app.sh
  Tests/
    DiskReportCoreTests/
    DiskReportAppTests/
    Fixtures/
  Makefile
  docs/superpowers/specs/
```
