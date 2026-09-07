# DiskReport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A read-only, scheduled disk usage reporter for macOS: a sandboxed CLI scans configured roots into SQLite each morning, and a menu bar app shows size, growth (day/week/month), and staleness per directory with reveal-in-Finder.

**Architecture:** One Swift package with a pure library (`DiskReportCore`: walk, SQLite store, queries, retention), a headless scanner CLI (`diskreport-scan`) run by launchd under a `sandbox-exec` profile that only permits writes to its own data folder, a UI-logic library (`DiskReportUI`: view models, formatting, no SwiftUI views) and a SwiftUI menu bar app (`DiskReport`) that reads the database and never touches scanned roots.

**Tech Stack:** Swift 6.3 compiler in Swift 5 language mode (swift-tools-version 5.10), SwiftPM, XCTest, system `SQLite3` module (no third-party dependencies), SwiftUI `MenuBarExtra` + AppKit `NSWindow`, `sandbox-exec`, launchd.

Spec: `docs/superpowers/specs/2026-09-07-diskreport-design.md`. Read it first.

## Global Constraints

- macOS 26 host, Xcode 26.4, `swift` 6.3.1. Deployment target `.macOS(.v14)`.
- **No third-party dependencies.** SQLite via `import SQLite3`.
- **Read-only against scanned roots.** Only `opendir`/`fdopendir`/`readdir`/`fstatat(..., AT_SYMLINK_NOFOLLOW)`/`open(O_RDONLY|O_DIRECTORY|O_NOFOLLOW)`/`lstat`/`statfs` touch root paths. The lint `Scripts/lint-readonly.sh` must pass on every commit.
- Only `Sources/DiskReportCore/Store/` and `Sources/DiskReportCore/Logging/` may contain write-capable filesystem calls, plus the single exempt file `Sources/diskreport-scan/SelfTestWrite.swift`.
- The app target contains no filesystem walk code and never opens files under a root.
- Data folder: `~/Library/Application Support/DiskReport/` (database `diskreport.sqlite`, `config.json`, `scan.lock`, `bin/`). Logs: `~/Library/Logs/DiskReport/`, keep 14 files.
- Sizes are **allocated** bytes (`st_blocks * 512`). Hard links counted once. Symlinks never followed. Never descend into a different `st_dev`.
- Baselines: latest `completed` scan with `finished_at <= current.finished_at - W*86400` for W ∈ {1, 7, 30}; otherwise "no data". `deleted` uses the 1-day baseline only.
- Staleness buckets: `< 7d` week, `< 30d` month, `< 183d` sixMonths, else older.
- Retention: keep all scans ≤ 45 days; one per ISO week ≤ 52 weeks; one per calendar month beyond. Failed scans older than 45 days deleted.
- Exit codes for `diskreport-scan`: 0 ok, 1 config error, 2 lock held, 3 refused (running as root), 4 at least one root failed, 10 self-test write succeeded (sandbox NOT enforcing).
- Human sizes use base 1000 (Finder convention): `1.2 GB`.
- Commit after every task with a conventional message; `Scripts/lint-readonly.sh && swift test` must pass before each commit from Task 3 onward.

---

## File Structure

```
diskreport/
  Package.swift
  Makefile
  README.md
  Resources/
    scan.sb                                   sandbox profile (params DATA_DIR, LOG_DIR)
    run-scan.sh                               launchd entry: sandboxed scan, then open app
    com.andyfloyd.diskreport.scan.plist       launchd agent template (__HOME__ substituted at install)
    Info.plist                                app bundle plist (LSUIElement)
  Scripts/
    lint-readonly.sh                          fails build on write-capable calls outside Store/ Logging/
    bundle-app.sh                             assembles build/DiskReport.app from swift build output
  Sources/
    DiskReportCore/
      Model/DirStat.swift                     DirStat, ScanRecord, ScanStatus, ScanSummary
      Model/Config.swift                      Config, Retention, ConfigError, root resolution
      Classifier/DirectoryClassifier.swift    protocol + NoClassifier + DirectoryEntrySummary
      Walker/Walker.swift                     POSIX walk → WalkResult
      Walker/VolumeInfo.swift                 statfs free/total
      Store/DataPaths.swift                   standard paths, ensureDirectoriesExist
      Store/Database.swift                    thin sqlite3 wrapper
      Store/Store.swift                       schema, writes, reads
      Store/LockFile.swift                    flock-based single-instance lock
      Logging/Logger.swift                    daily log files, rotation
      Queries/Window.swift                    Window enum, baseline cutoff
      Queries/Staleness.swift                 StalenessBucket
      Queries/ReportBuilder.swift             Delta, ReportRow, rows(current:baselines:)
      Queries/ReportLoader.swift              RootReport, loadRootReports(store:)
      Queries/Retention.swift                 RetentionPolicy.scansToDelete
      Notable/Notable.swift                   ReportSummary, Notice, NotableRule, NotableEvaluator
    diskreport-scan/
      main.swift                              CLI flow
      Arguments.swift                         argument parsing
      SelfTestWrite.swift                     --self-test-write (lint-exempt)
    DiskReportUI/
      DirNode.swift                           tree node
      TreeBuilder.swift                       [ReportRow] → [DirNode] forest
      ReportViewModel.swift                   expansion, flatten, sort, filter, search
      QuickFilter.swift                       filter enum + predicate
      Formatting.swift                        ByteFormatter, DeltaFormatter, DateFormatting
      RevealTarget.swift                      URL for Finder reveal
      BannerState.swift                       warning banner text
    DiskReport/
      DiskReportApp.swift                     @main, MenuBarExtra
      AppDelegate.swift                       report NSWindow, reopen handling, --show-report
      AppModel.swift                          loads reports, watches DB, runs scans
      DatabaseWatcher.swift                   DispatchSource file watcher with debounce
      ScanRunner.swift                        Process: sandbox-exec + diskreport-scan
      Views/MenuView.swift
      Views/ReportWindowView.swift
      Views/SummaryBar.swift
      Views/FilterStrip.swift
      Views/ReportTable.swift
  Tests/
    DiskReportCoreTests/
      Fixtures.swift                          temp fixture tree helpers
      ConfigTests.swift
      WalkerTests.swift
      StoreTests.swift
      ReportBuilderTests.swift
      StalenessTests.swift
      RetentionTests.swift
      NotableTests.swift
      ScannerCLITests.swift                   runs built binary
      SandboxTests.swift                      manifest + refused write under sandbox-exec
    DiskReportUITests/
      TreeBuilderTests.swift
      ReportViewModelTests.swift
      FormattingTests.swift
      RevealTargetTests.swift
      BannerStateTests.swift
  docs/superpowers/specs/…
  docs/superpowers/plans/…
```

Deviation from the spec's layout: view models live in a `DiskReportUI` library rather than inside the app target so `swift test` can test them (SwiftPM test targets cannot depend on executable targets).

---

### Task 1: Package scaffold, lint script, Makefile skeleton

**Files:**
- Create: `Package.swift`
- Create: `Sources/DiskReportCore/Model/DirStat.swift` (placeholder types replaced fully in Task 2 — here only a marker to make the package build)
- Create: `Sources/DiskReportUI/DirNode.swift` (placeholder, replaced in Task 10)
- Create: `Sources/diskreport-scan/main.swift` (placeholder, replaced in Task 8)
- Create: `Sources/DiskReport/DiskReportApp.swift` (placeholder, replaced in Task 13)
- Create: `Tests/DiskReportCoreTests/PackageSmokeTests.swift`
- Create: `Tests/DiskReportUITests/PackageSmokeUITests.swift`
- Create: `Scripts/lint-readonly.sh`
- Create: `Makefile`
- Create: `.gitignore`

**Interfaces:**
- Produces: package layout and target names `DiskReportCore`, `DiskReportUI`, `diskreport-scan`, `DiskReport`; `make lint`, `make test`, `make build`.

- [ ] **Step 1: Create Package.swift**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "diskreport",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskReportCore", targets: ["DiskReportCore"]),
        .library(name: "DiskReportUI", targets: ["DiskReportUI"]),
        .executable(name: "diskreport-scan", targets: ["diskreport-scan"]),
        .executable(name: "DiskReport", targets: ["DiskReport"]),
    ],
    targets: [
        .target(name: "DiskReportCore"),
        .target(name: "DiskReportUI", dependencies: ["DiskReportCore"]),
        .executableTarget(name: "diskreport-scan", dependencies: ["DiskReportCore"]),
        .executableTarget(name: "DiskReport", dependencies: ["DiskReportCore", "DiskReportUI"]),
        .testTarget(name: "DiskReportCoreTests", dependencies: ["DiskReportCore"]),
        .testTarget(name: "DiskReportUITests", dependencies: ["DiskReportUI"]),
    ]
)
```

- [ ] **Step 2: Create placeholder sources so every target compiles**

`Sources/DiskReportCore/Model/DirStat.swift`:
```swift
// Replaced in Task 2.
public enum DiskReportCoreMarker { public static let version = "0.1.0" }
```

`Sources/DiskReportUI/DirNode.swift`:
```swift
// Replaced in Task 10.
import DiskReportCore
public enum DiskReportUIMarker { public static let version = DiskReportCoreMarker.version }
```

`Sources/diskreport-scan/main.swift`:
```swift
// Replaced in Task 8.
import DiskReportCore
print("diskreport-scan \(DiskReportCoreMarker.version)")
```

`Sources/DiskReport/DiskReportApp.swift`:
```swift
// Replaced in Task 13.
import SwiftUI

@main
struct DiskReportApp: App {
    var body: some Scene {
        MenuBarExtra("DiskReport", systemImage: "externaldrive") { Text("placeholder") }
    }
}
```

- [ ] **Step 3: Create smoke tests**

`Tests/DiskReportCoreTests/PackageSmokeTests.swift`:
```swift
import XCTest
@testable import DiskReportCore

final class PackageSmokeTests: XCTestCase {
    func testPackageBuilds() { XCTAssertEqual(DiskReportCoreMarker.version, "0.1.0") }
}
```

`Tests/DiskReportUITests/PackageSmokeUITests.swift`:
```swift
import XCTest
@testable import DiskReportUI

final class PackageSmokeUITests: XCTestCase {
    func testPackageBuilds() { XCTAssertEqual(DiskReportUIMarker.version, "0.1.0") }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test 2>&1 | tail -5`
Expected: `Executed 2 tests, with 0 failures`

- [ ] **Step 5: Create the read-only lint script**

`Scripts/lint-readonly.sh`:
```sh
#!/bin/sh
# Fails if any write-capable filesystem call appears in DiskReportCore or diskreport-scan
# outside the modules explicitly allowed to write (Store/, Logging/) and the lint-exempt self-test file.
set -eu
cd "$(dirname "$0")/.."

PATTERN='unlink\(|rmdir\(|rename\(|truncate\(|utimes\(|chmod\(|chown\(|O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|O_APPEND|removeItem|moveItem\(|copyItem\(|createFile\(|createDirectory\(|\.write\(to|FileHandle\(forWritingTo|FileHandle\(forUpdating|fopen\(|mkdir\('

FILES=$(find Sources/DiskReportCore Sources/diskreport-scan -name '*.swift' \
  | grep -v '/Store/' \
  | grep -v '/Logging/' \
  | grep -v 'SelfTestWrite.swift' || true)

if [ -z "$FILES" ]; then
  echo "lint-readonly: no files to check"
  exit 0
fi

if grep -nE "$PATTERN" $FILES; then
  echo "lint-readonly: FAIL — write-capable call found outside Store/ or Logging/"
  exit 1
fi
echo "lint-readonly: ok"
```

Run: `chmod +x Scripts/lint-readonly.sh && Scripts/lint-readonly.sh`
Expected: `lint-readonly: ok`

- [ ] **Step 6: Create Makefile skeleton and .gitignore**

`Makefile`:
```make
.PHONY: build test lint release clean

build:
	swift build

test: lint
	swift test

lint:
	Scripts/lint-readonly.sh

release: lint
	swift build -c release

clean:
	rm -rf .build build
```

`.gitignore`:
```
.build/
build/
*.xcodeproj
.DS_Store
.swiftpm/
```

- [ ] **Step 7: Verify and commit**

Run: `make test 2>&1 | tail -3`
Expected: lint ok and `Executed 2 tests, with 0 failures`

```bash
git add -A
git commit -m "chore: scaffold Swift package, lint script, Makefile"
```

---

### Task 2: Core models and config

**Files:**
- Replace: `Sources/DiskReportCore/Model/DirStat.swift`
- Create: `Sources/DiskReportCore/Model/Config.swift`
- Create: `Sources/DiskReportCore/Store/DataPaths.swift`
- Create: `Tests/DiskReportCoreTests/Fixtures.swift`
- Create: `Tests/DiskReportCoreTests/ConfigTests.swift`
- Delete: `Tests/DiskReportCoreTests/PackageSmokeTests.swift`; update `Sources/DiskReportUI/DirNode.swift` and `Sources/diskreport-scan/main.swift` to not reference the marker.

**Interfaces:**
- Produces:
  - `public struct DirStat: Equatable, Sendable { path, parentPath: String?, depth: Int, bytes: Int64, fileCount: Int64, newestMtime: Int64, kind: String? }`
  - `public enum ScanStatus: String, Sendable { case running, completed, failed }`
  - `public struct ScanRecord: Equatable, Sendable { id, rootID, startedAt, finishedAt: Int64?, status, totalBytes: Int64?, fileCount: Int64?, dirCount: Int64?, volumeFreeBytes: Int64?, volumeTotalBytes: Int64?, skippedCount: Int64?, error: String? }`
  - `public struct ScanSummary: Equatable, Sendable { totalBytes, fileCount, dirCount, volumeFreeBytes, volumeTotalBytes, skippedCount: Int64 }`
  - `public struct Retention: Codable, Equatable, Sendable { dailyDays: Int, weeklyWeeks: Int }` default 45 / 52
  - `public struct Config: Codable, Equatable, Sendable { roots: [String], retention: Retention; static func load(from: URL) throws -> Config; static func parse(_ data: Data) throws -> Config; func resolvedRoots(isDirectory: (String) -> Bool = Config.defaultIsDirectory) throws -> [String] }`
  - `public enum ConfigError: Error, Equatable { case noRoots, rootNotDirectory(String), nestedRoots(outer: String, inner: String), unreadable(String) }`
  - `public struct DataPaths { dataDir: URL, logDir: URL; databaseURL, configURL, lockURL, binDir; static func standard() -> DataPaths; func ensureDirectoriesExist() throws }`

- [ ] **Step 1: Write failing config tests**

`Tests/DiskReportCoreTests/Fixtures.swift`:
```swift
import Foundation
import XCTest

/// An isolated temp directory. Create with `makeTempDir()` (below) so XCTest removes it in teardown;
/// removal is deliberately not tied to deinit, because a local can be released before a subprocess finishes.
final class TempDir {
    let url: URL
    init(_ name: String = "diskreport-test") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    func path(_ relative: String) -> String { url.appendingPathComponent(relative).path }

    @discardableResult
    func mkdir(_ relative: String) -> String {
        let p = path(relative)
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// Writes `size` bytes of non-zero data so allocated size is real.
    @discardableResult
    func file(_ relative: String, size: Int = 16, mtime: Date? = nil) -> String {
        let p = path(relative)
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = Data(repeating: 0x41, count: size)
        FileManager.default.createFile(atPath: p, contents: data)
        if let mtime { try! FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: p) }
        return p
    }

    func setMtime(_ relative: String, _ date: Date) {
        try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relative))
    }
}

extension XCTestCase {
    /// Temp directory removed in this test's teardown, even if the test fails.
    func makeTempDir() -> TempDir {
        let tmp = TempDir()
        addTeardownBlock { tmp.remove() }
        return tmp
    }
}

/// Resolves /var → /private/var etc. so comparisons against walker output are stable.
func realpathString(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}
```

`Tests/DiskReportCoreTests/ConfigTests.swift`:
```swift
import XCTest
@testable import DiskReportCore

final class ConfigTests: XCTestCase {
    func testParseDefaultsRetention() throws {
        let cfg = try Config.parse(Data(#"{"roots":["~/Workspace"]}"#.utf8))
        XCTAssertEqual(cfg.roots, ["~/Workspace"])
        XCTAssertEqual(cfg.retention, Retention(dailyDays: 45, weeklyWeeks: 52))
    }

    func testParseExplicitRetention() throws {
        let cfg = try Config.parse(Data(#"{"roots":["/a"],"retention":{"dailyDays":10,"weeklyWeeks":4}}"#.utf8))
        XCTAssertEqual(cfg.retention, Retention(dailyDays: 10, weeklyWeeks: 4))
    }

    func testResolvedRootsExpandsTildeAndStripsTrailingSlash() throws {
        let cfg = Config(roots: ["~/Some/Dir/"], retention: Retention())
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = try cfg.resolvedRoots(isDirectory: { _ in true })
        XCTAssertEqual(roots, ["\(home)/Some/Dir"])
    }

    func testResolvedRootsRejectsEmpty() {
        let cfg = Config(roots: [], retention: Retention())
        XCTAssertThrowsError(try cfg.resolvedRoots(isDirectory: { _ in true })) { error in
            XCTAssertEqual(error as? ConfigError, .noRoots)
        }
    }

    func testResolvedRootsRejectsMissingDirectory() {
        let cfg = Config(roots: ["/definitely/missing"], retention: Retention())
        XCTAssertThrowsError(try cfg.resolvedRoots(isDirectory: { _ in false })) { error in
            XCTAssertEqual(error as? ConfigError, .rootNotDirectory("/definitely/missing"))
        }
    }

    func testResolvedRootsRejectsNestedRoots() {
        let cfg = Config(roots: ["/Users/x/Workspace/inner", "/Users/x/Workspace"], retention: Retention())
        XCTAssertThrowsError(try cfg.resolvedRoots(isDirectory: { _ in true })) { error in
            XCTAssertEqual(error as? ConfigError, .nestedRoots(outer: "/Users/x/Workspace", inner: "/Users/x/Workspace/inner"))
        }
    }

    func testResolvedRootsAllowsSiblingWithSharedPrefix() throws {
        let cfg = Config(roots: ["/Users/x/Work", "/Users/x/Workspace"], retention: Retention())
        XCTAssertEqual(try cfg.resolvedRoots(isDirectory: { _ in true }), ["/Users/x/Work", "/Users/x/Workspace"])
    }

    func testLoadFromFile() throws {
        let tmp = makeTempDir()
        let p = tmp.file("config.json", size: 0)
        try Data(#"{"roots":["/tmp"]}"#.utf8).write(to: URL(fileURLWithPath: p))
        let cfg = try Config.load(from: URL(fileURLWithPath: p))
        XCTAssertEqual(cfg.roots, ["/tmp"])
    }

    func testLoadMissingFileThrowsUnreadable() {
        XCTAssertThrowsError(try Config.load(from: URL(fileURLWithPath: "/nope/config.json"))) { error in
            XCTAssertEqual(error as? ConfigError, .unreadable("/nope/config.json"))
        }
    }

    func testDataPathsDerivedURLs() {
        let p = DataPaths(dataDir: URL(fileURLWithPath: "/d"), logDir: URL(fileURLWithPath: "/l"))
        XCTAssertEqual(p.databaseURL.path, "/d/diskreport.sqlite")
        XCTAssertEqual(p.configURL.path, "/d/config.json")
        XCTAssertEqual(p.lockURL.path, "/d/scan.lock")
        XCTAssertEqual(p.binDir.path, "/d/bin")
    }

    func testDataPathsStandard() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = DataPaths.standard()
        XCTAssertEqual(p.dataDir.path, "\(home)/Library/Application Support/DiskReport")
        XCTAssertEqual(p.logDir.path, "\(home)/Library/Logs/DiskReport")
    }

    func testEnsureDirectoriesExistCreatesBoth() throws {
        let tmp = makeTempDir()
        let p = DataPaths(dataDir: URL(fileURLWithPath: tmp.path("data")), logDir: URL(fileURLWithPath: tmp.path("logs")))
        try p.ensureDirectoriesExist()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.dataDir.path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.logDir.path, isDirectory: &isDir) && isDir.boolValue)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigTests 2>&1 | grep -E "error:|Executed" | head`
Expected: compile errors, `cannot find 'Config' in scope`

- [ ] **Step 3: Implement models**

`Sources/DiskReportCore/Model/DirStat.swift`:
```swift
import Foundation

/// One directory as observed by a single scan. `bytes`, `fileCount`, `newestMtime` are recursive.
public struct DirStat: Equatable, Sendable {
    public var path: String
    public var parentPath: String?
    public var depth: Int
    public var bytes: Int64
    public var fileCount: Int64
    public var newestMtime: Int64
    public var kind: String?

    public init(path: String, parentPath: String?, depth: Int, bytes: Int64, fileCount: Int64, newestMtime: Int64, kind: String? = nil) {
        self.path = path
        self.parentPath = parentPath
        self.depth = depth
        self.bytes = bytes
        self.fileCount = fileCount
        self.newestMtime = newestMtime
        self.kind = kind
    }
}

public enum ScanStatus: String, Sendable {
    case running, completed, failed
}

public struct ScanSummary: Equatable, Sendable {
    public var totalBytes: Int64
    public var fileCount: Int64
    public var dirCount: Int64
    public var volumeFreeBytes: Int64
    public var volumeTotalBytes: Int64
    public var skippedCount: Int64

    public init(totalBytes: Int64, fileCount: Int64, dirCount: Int64, volumeFreeBytes: Int64, volumeTotalBytes: Int64, skippedCount: Int64) {
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.dirCount = dirCount
        self.volumeFreeBytes = volumeFreeBytes
        self.volumeTotalBytes = volumeTotalBytes
        self.skippedCount = skippedCount
    }
}

public struct ScanRecord: Equatable, Sendable {
    public var id: Int64
    public var rootID: Int64
    public var startedAt: Int64
    public var finishedAt: Int64?
    public var status: ScanStatus
    public var totalBytes: Int64?
    public var fileCount: Int64?
    public var dirCount: Int64?
    public var volumeFreeBytes: Int64?
    public var volumeTotalBytes: Int64?
    public var skippedCount: Int64?
    public var error: String?

    public init(id: Int64, rootID: Int64, startedAt: Int64, finishedAt: Int64?, status: ScanStatus,
                totalBytes: Int64? = nil, fileCount: Int64? = nil, dirCount: Int64? = nil,
                volumeFreeBytes: Int64? = nil, volumeTotalBytes: Int64? = nil, skippedCount: Int64? = nil,
                error: String? = nil) {
        self.id = id
        self.rootID = rootID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.dirCount = dirCount
        self.volumeFreeBytes = volumeFreeBytes
        self.volumeTotalBytes = volumeTotalBytes
        self.skippedCount = skippedCount
        self.error = error
    }
}
```

`Sources/DiskReportCore/Model/Config.swift`:
```swift
import Foundation

public struct Retention: Codable, Equatable, Sendable {
    public var dailyDays: Int
    public var weeklyWeeks: Int

    public init(dailyDays: Int = 45, weeklyWeeks: Int = 52) {
        self.dailyDays = dailyDays
        self.weeklyWeeks = weeklyWeeks
    }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case noRoots
    case rootNotDirectory(String)
    case nestedRoots(outer: String, inner: String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .noRoots: return "config has no roots"
        case .rootNotDirectory(let p): return "root is not a directory: \(p)"
        case .nestedRoots(let outer, let inner): return "root \(inner) is inside root \(outer); keep only the outer root"
        case .unreadable(let p): return "cannot read config: \(p)"
        }
    }
}

public struct Config: Codable, Equatable, Sendable {
    public var roots: [String]
    public var retention: Retention

    public init(roots: [String], retention: Retention = Retention()) {
        self.roots = roots
        self.retention = retention
    }

    enum CodingKeys: String, CodingKey { case roots, retention }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roots = try c.decode([String].self, forKey: .roots)
        retention = try c.decodeIfPresent(Retention.self, forKey: .retention) ?? Retention()
    }

    public static func parse(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    public static func load(from url: URL) throws -> Config {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ConfigError.unreadable(url.path)
        }
        return try parse(data)
    }

    /// Expands `~`, strips trailing slashes, validates each root is a directory, rejects nested roots.
    public func resolvedRoots(isDirectory: (String) -> Bool = Config.defaultIsDirectory) throws -> [String] {
        guard !roots.isEmpty else { throw ConfigError.noRoots }
        let expanded = roots.map { raw -> String in
            var p = (raw as NSString).expandingTildeInPath
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            return p
        }
        for p in expanded where !isDirectory(p) {
            throw ConfigError.rootNotDirectory(p)
        }
        for outer in expanded {
            for inner in expanded where inner != outer && inner.hasPrefix(outer + "/") {
                throw ConfigError.nestedRoots(outer: outer, inner: inner)
            }
        }
        return expanded
    }

    public static func defaultIsDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
```

`Sources/DiskReportCore/Store/DataPaths.swift`:
```swift
import Foundation

/// Where DiskReport keeps its own state. Always outside any scanned root.
public struct DataPaths: Sendable {
    public let dataDir: URL
    public let logDir: URL

    public init(dataDir: URL, logDir: URL) {
        self.dataDir = dataDir
        self.logDir = logDir
    }

    public static func standard() -> DataPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return DataPaths(
            dataDir: home.appendingPathComponent("Library/Application Support/DiskReport", isDirectory: true),
            logDir: home.appendingPathComponent("Library/Logs/DiskReport", isDirectory: true)
        )
    }

    public var databaseURL: URL { dataDir.appendingPathComponent("diskreport.sqlite") }
    public var configURL: URL { dataDir.appendingPathComponent("config.json") }
    public var lockURL: URL { dataDir.appendingPathComponent("scan.lock") }
    public var binDir: URL { dataDir.appendingPathComponent("bin", isDirectory: true) }

    public func ensureDirectoriesExist() throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }
}
```

Update placeholders: `Sources/DiskReportUI/DirNode.swift` → `import DiskReportCore\npublic enum DiskReportUIMarker { public static let version = "0.1.0" }`; `Sources/diskreport-scan/main.swift` → `print("diskreport-scan placeholder")`. Delete `Tests/DiskReportCoreTests/PackageSmokeTests.swift`.

- [ ] **Step 4: Run tests and lint**

Run: `Scripts/lint-readonly.sh && swift test --filter ConfigTests 2>&1 | grep Executed`
Expected: `lint-readonly: ok` and `Executed 12 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(core): models, config loading and root validation, data paths"
```

---

### Task 3: Filesystem walker and classifier hook

**Files:**
- Create: `Sources/DiskReportCore/Classifier/DirectoryClassifier.swift`
- Create: `Sources/DiskReportCore/Walker/Walker.swift`
- Create: `Sources/DiskReportCore/Walker/VolumeInfo.swift`
- Create: `Tests/DiskReportCoreTests/WalkerTests.swift`

**Interfaces:**
- Consumes: `DirStat` (Task 2).
- Produces:
  - `public struct DirectoryEntrySummary: Sendable { childNames: [String] }`
  - `public protocol DirectoryClassifier: Sendable { func classify(path: String, name: String, entries: DirectoryEntrySummary) -> String? }`
  - `public struct NoClassifier: DirectoryClassifier`
  - `public struct SkippedEntry: Equatable, Sendable { path: String, reason: String }`
  - `public struct WalkResult: Sendable { stats: [DirStat], skipped: [SkippedEntry], totalBytes: Int64, fileCount: Int64 }`
  - `public enum WalkError: Error, Equatable { case notADirectory(String) }`
  - `public struct Walker { init(classifier: DirectoryClassifier = NoClassifier()); func walk(root: String) throws -> WalkResult; static func shouldDescend(entryDevice: dev_t, rootDevice: dev_t) -> Bool }`
  - `public struct VolumeInfo: Equatable, Sendable { freeBytes, totalBytes: Int64; static func query(path: String) throws -> VolumeInfo }`

- [ ] **Step 1: Write failing walker tests**

`Tests/DiskReportCoreTests/WalkerTests.swift`:
```swift
import XCTest
@testable import DiskReportCore

final class WalkerTests: XCTestCase {
    private func stat(_ result: WalkResult, _ path: String) -> DirStat? {
        result.stats.first { $0.path == realpathString(path) }
    }

    func testCountsFilesAndBytesRecursivelyPerDirectory() throws {
        let tmp = makeTempDir()
        tmp.file("root/a/one.bin", size: 4096)
        tmp.file("root/a/b/two.bin", size: 4096)
        tmp.file("root/three.bin", size: 4096)
        let root = realpathString(tmp.path("root"))

        let result = try Walker().walk(root: root)

        let r = try XCTUnwrap(stat(result, root))
        XCTAssertEqual(r.depth, 0)
        XCTAssertNil(r.parentPath)
        XCTAssertEqual(r.fileCount, 3)
        XCTAssertGreaterThanOrEqual(r.bytes, 3 * 4096)

        let a = try XCTUnwrap(stat(result, root + "/a"))
        XCTAssertEqual(a.depth, 1)
        XCTAssertEqual(a.parentPath, root)
        XCTAssertEqual(a.fileCount, 2)

        let b = try XCTUnwrap(stat(result, root + "/a/b"))
        XCTAssertEqual(b.depth, 2)
        XCTAssertEqual(b.fileCount, 1)
        XCTAssertEqual(result.fileCount, 3)
        XCTAssertEqual(result.totalBytes, r.bytes)
        XCTAssertEqual(result.stats.count, 3)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testEmptyDirectoryHasZeroFilesButOwnAllocation() throws {
        let tmp = makeTempDir()
        tmp.mkdir("root/empty")
        let root = realpathString(tmp.path("root"))
        let result = try Walker().walk(root: root)
        let e = try XCTUnwrap(stat(result, root + "/empty"))
        XCTAssertEqual(e.fileCount, 0)
        XCTAssertGreaterThanOrEqual(e.bytes, 0)
    }

    func testNewestMtimePropagatesToAncestors() throws {
        let tmp = makeTempDir()
        let old = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_000)
        tmp.file("root/a/b/deep.txt", mtime: newer)
        tmp.file("root/c/old.txt", mtime: old)
        tmp.setMtime("root/a/b", old); tmp.setMtime("root/a", old); tmp.setMtime("root/c", old); tmp.setMtime("root", old)
        let root = realpathString(tmp.path("root"))

        let result = try Walker().walk(root: root)

        XCTAssertEqual(stat(result, root)?.newestMtime, 1_700_000_000)
        XCTAssertEqual(stat(result, root + "/a")?.newestMtime, 1_700_000_000)
        XCTAssertEqual(stat(result, root + "/c")?.newestMtime, 1_000_000)
    }

    func testSymlinksAreNotFollowed() throws {
        let tmp = makeTempDir()
        tmp.file("outside/big.bin", size: 1_000_000)
        tmp.mkdir("root")
        try FileManager.default.createSymbolicLink(atPath: tmp.path("root/link"), withDestinationPath: tmp.path("outside"))
        let root = realpathString(tmp.path("root"))

        let result = try Walker().walk(root: root)

        XCTAssertNil(stat(result, root + "/link"), "symlink must not appear as a walked directory")
        XCTAssertNil(result.stats.first { $0.path.contains("outside") })
        XCTAssertLessThan(stat(result, root)!.bytes, 100_000)
        XCTAssertEqual(stat(result, root)?.fileCount, 1, "the symlink itself counts as one entry")
    }

    func testHardLinksCountedOnce() throws {
        let tmp = makeTempDir()
        let original = tmp.file("root/a/orig.bin", size: 100_000)
        tmp.mkdir("root/b")
        try FileManager.default.linkItem(atPath: original, toPath: tmp.path("root/b/copy.bin"))
        let root = realpathString(tmp.path("root"))

        let result = try Walker().walk(root: root)

        let r = try XCTUnwrap(stat(result, root))
        XCTAssertEqual(r.fileCount, 2)
        XCTAssertLessThan(r.bytes, 150_000, "hard-linked file must be counted once")
    }

    func testAllocatedSizeIsUsed() throws {
        let tmp = makeTempDir()
        tmp.file("root/f.bin", size: 1_048_576)
        let root = realpathString(tmp.path("root"))
        let result = try Walker().walk(root: root)
        let r = try XCTUnwrap(stat(result, root))
        XCTAssertGreaterThanOrEqual(r.bytes, 1_048_576)
        XCTAssertEqual(r.bytes % 512, 0, "allocated size is a multiple of 512-byte blocks")
    }

    func testUnreadableDirectoryIsSkippedNotFatal() throws {
        try XCTSkipIf(getuid() == 0, "root can read anything")
        let tmp = makeTempDir()
        tmp.file("root/locked/secret.txt")
        tmp.file("root/ok.txt")
        let locked = tmp.path("root/locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        let root = realpathString(tmp.path("root"))

        let result = try Walker().walk(root: root)

        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(result.skipped.first?.path, realpathString(locked))
        XCTAssertTrue(result.skipped.first!.reason.contains("Permission denied"))
        XCTAssertNotNil(stat(result, realpathString(locked)), "skipped dir still gets a row with what could be seen")
        XCTAssertEqual(stat(result, root)?.fileCount, 1)
    }

    func testRootMustBeDirectory() throws {
        let tmp = makeTempDir()
        let f = tmp.file("notadir.txt")
        XCTAssertThrowsError(try Walker().walk(root: f)) { error in
            XCTAssertEqual(error as? WalkError, .notADirectory(f))
        }
    }

    func testShouldDescendOnlyOnSameDevice() {
        XCTAssertTrue(Walker.shouldDescend(entryDevice: 5, rootDevice: 5))
        XCTAssertFalse(Walker.shouldDescend(entryDevice: 6, rootDevice: 5))
    }

    func testClassifierIsCalledPerDirectory() throws {
        struct MarkNodeModules: DirectoryClassifier {
            func classify(path: String, name: String, entries: DirectoryEntrySummary) -> String? {
                name == "node_modules" ? "node_modules" : nil
            }
        }
        let tmp = makeTempDir()
        tmp.file("root/proj/node_modules/x/index.js")
        tmp.file("root/proj/src/main.js")
        let root = realpathString(tmp.path("root"))

        let result = try Walker(classifier: MarkNodeModules()).walk(root: root)

        XCTAssertEqual(stat(result, root + "/proj/node_modules")?.kind, "node_modules")
        XCTAssertNil(stat(result, root + "/proj/src")?.kind)
    }

    func testVolumeInfo() throws {
        let info = try VolumeInfo.query(path: NSHomeDirectory())
        XCTAssertGreaterThan(info.totalBytes, 0)
        XCTAssertGreaterThan(info.freeBytes, 0)
        XCTAssertLessThanOrEqual(info.freeBytes, info.totalBytes)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WalkerTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'Walker' in scope`

- [ ] **Step 3: Implement classifier hook**

`Sources/DiskReportCore/Classifier/DirectoryClassifier.swift`:
```swift
/// Cheap summary of a directory's immediate children, passed to classifiers.
public struct DirectoryEntrySummary: Sendable {
    public var childNames: [String]
    public init(childNames: [String]) { self.childNames = childNames }
}

/// Extension point: label directories (e.g. "node_modules", "venv", "git", "build", "archive").
/// v1 ships only `NoClassifier`.
public protocol DirectoryClassifier: Sendable {
    func classify(path: String, name: String, entries: DirectoryEntrySummary) -> String?
}

public struct NoClassifier: DirectoryClassifier {
    public init() {}
    public func classify(path: String, name: String, entries: DirectoryEntrySummary) -> String? { nil }
}
```

- [ ] **Step 4: Implement the walker**

`Sources/DiskReportCore/Walker/Walker.swift`:
```swift
import Darwin
import Foundation

public struct SkippedEntry: Equatable, Sendable {
    public var path: String
    public var reason: String
    public init(path: String, reason: String) { self.path = path; self.reason = reason }
}

public struct WalkResult: Sendable {
    public var stats: [DirStat]
    public var skipped: [SkippedEntry]
    public var totalBytes: Int64
    public var fileCount: Int64
}

public enum WalkError: Error, Equatable {
    case notADirectory(String)
}

/// Read-only, depth-first directory walk using POSIX APIs.
/// Never follows symlinks, never crosses devices, counts hard links once, uses allocated size.
public struct Walker {
    private let classifier: DirectoryClassifier

    public init(classifier: DirectoryClassifier = NoClassifier()) {
        self.classifier = classifier
    }

    public static func shouldDescend(entryDevice: dev_t, rootDevice: dev_t) -> Bool {
        entryDevice == rootDevice
    }

    public func walk(root: String) throws -> WalkResult {
        var st = stat()
        guard lstat(root, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            throw WalkError.notADirectory(root)
        }
        var ctx = Context(rootDevice: st.st_dev)
        let acc = walkDirectory(path: root, parentPath: nil, depth: 0, dirStat: st, ctx: &ctx)
        return WalkResult(stats: ctx.stats, skipped: ctx.skipped, totalBytes: acc.bytes, fileCount: acc.fileCount)
    }

    // MARK: - Internals

    private struct InodeKey: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    private struct Context {
        let rootDevice: dev_t
        var seenInodes = Set<InodeKey>()
        var stats: [DirStat] = []
        var skipped: [SkippedEntry] = []
    }

    private struct Accum {
        var bytes: Int64
        var fileCount: Int64
        var newest: Int64
    }

    private static func allocated(_ st: stat) -> Int64 { Int64(st.st_blocks) * 512 }
    private static func mtime(_ st: stat) -> Int64 { Int64(st.st_mtimespec.tv_sec) }

    private func walkDirectory(path: String, parentPath: String?, depth: Int, dirStat st: stat, ctx: inout Context) -> Accum {
        var acc = Accum(bytes: Self.allocated(st), fileCount: 0, newest: Self.mtime(st))
        var childNames: [String] = []
        var subdirs: [(path: String, st: stat)] = []

        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd < 0 {
            ctx.skipped.append(SkippedEntry(path: path, reason: String(cString: strerror(errno))))
        } else if let dir = fdopendir(fd) {
            defer { closedir(dir) } // also closes fd
            while let entry = readdir(dir) {
                let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                childNames.append(name)

                var est = stat()
                guard fstatat(fd, name, &est, AT_SYMLINK_NOFOLLOW) == 0 else {
                    ctx.skipped.append(SkippedEntry(path: path + "/" + name, reason: String(cString: strerror(errno))))
                    continue
                }
                acc.newest = max(acc.newest, Self.mtime(est))
                let childPath = path + "/" + name

                if (est.st_mode & S_IFMT) == S_IFDIR {
                    if Self.shouldDescend(entryDevice: est.st_dev, rootDevice: ctx.rootDevice) {
                        subdirs.append((childPath, est))
                    } else {
                        acc.bytes += Self.allocated(est) // mount point itself; do not descend
                    }
                } else {
                    acc.fileCount += 1
                    if est.st_nlink > 1 {
                        let key = InodeKey(dev: est.st_dev, ino: est.st_ino)
                        if !ctx.seenInodes.insert(key).inserted { continue }
                    }
                    acc.bytes += Self.allocated(est)
                }
            }
        } else {
            ctx.skipped.append(SkippedEntry(path: path, reason: String(cString: strerror(errno))))
            close(fd)
        }

        for sub in subdirs {
            let s = walkDirectory(path: sub.path, parentPath: path, depth: depth + 1, dirStat: sub.st, ctx: &ctx)
            acc.bytes += s.bytes
            acc.fileCount += s.fileCount
            acc.newest = max(acc.newest, s.newest)
        }

        let name = (path as NSString).lastPathComponent
        let kind = classifier.classify(path: path, name: name, entries: DirectoryEntrySummary(childNames: childNames))
        ctx.stats.append(DirStat(path: path, parentPath: parentPath, depth: depth,
                                 bytes: acc.bytes, fileCount: acc.fileCount, newestMtime: acc.newest, kind: kind))
        return acc
    }
}
```

`Sources/DiskReportCore/Walker/VolumeInfo.swift`:
```swift
import Darwin
import Foundation

public struct VolumeInfo: Equatable, Sendable {
    public var freeBytes: Int64
    public var totalBytes: Int64

    public enum Error: Swift.Error { case statfsFailed(String) }

    public static func query(path: String) throws -> VolumeInfo {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { throw Error.statfsFailed(String(cString: strerror(errno))) }
        let bsize = Int64(fs.f_bsize)
        return VolumeInfo(freeBytes: Int64(fs.f_bavail) * bsize, totalBytes: Int64(fs.f_blocks) * bsize)
    }
}
```

- [ ] **Step 5: Run tests and lint**

Run: `Scripts/lint-readonly.sh && swift test --filter WalkerTests 2>&1 | grep -E "Executed|error|failed"`
Expected: `lint-readonly: ok`, `Executed 11 tests, with 0 failures`

If `withUnsafePointer(to: entry.pointee.d_name)` fails to compile, use `var dname = entry.pointee.d_name` then `withUnsafePointer(to: &dname)`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(core): read-only POSIX walker, classifier hook, volume info"
```

---

### Task 4: SQLite wrapper and store writes

**Files:**
- Create: `Sources/DiskReportCore/Store/Database.swift`
- Create: `Sources/DiskReportCore/Store/Store.swift`
- Create: `Tests/DiskReportCoreTests/StoreTests.swift`

**Interfaces:**
- Consumes: `DirStat`, `ScanRecord`, `ScanStatus`, `ScanSummary` (Task 2).
- Produces:
  - `public struct RootEntry: Equatable, Sendable { id: Int64, path: String }`
  - `public final class Store { init(url: URL) throws; rootID(for: String) throws -> Int64; roots() throws -> [RootEntry]; beginScan(rootID: Int64, startedAt: Int64) throws -> Int64; insertDirStats(scanID: Int64, _ stats: [DirStat]) throws; completeScan(id: Int64, finishedAt: Int64, summary: ScanSummary) throws; failScan(id: Int64, finishedAt: Int64, error: String) throws; failStaleRunningScans(now: Int64) throws -> Int; scan(id: Int64) throws -> ScanRecord?; dirStatCount(scanID: Int64) throws -> Int }`
  - Read queries are added in Task 5.
  - Internal: `final class Database` and `final class Statement` (not public).

- [ ] **Step 1: Write failing store tests**

`Tests/DiskReportCoreTests/StoreTests.swift`:
```swift
import XCTest
@testable import DiskReportCore

final class StoreTests: XCTestCase {
    private var tmp: TempDir!
    private var store: Store!

    override func setUpWithError() throws {
        tmp = makeTempDir()
        store = try Store(url: URL(fileURLWithPath: tmp.path("test.sqlite")))
    }

    override func tearDown() { store = nil; tmp = nil }

    private func sampleStats(root: String = "/r") -> [DirStat] {
        [
            DirStat(path: root, parentPath: nil, depth: 0, bytes: 300, fileCount: 3, newestMtime: 30),
            DirStat(path: root + "/a", parentPath: root, depth: 1, bytes: 200, fileCount: 2, newestMtime: 30, kind: nil),
            DirStat(path: root + "/a/b", parentPath: root + "/a", depth: 2, bytes: 100, fileCount: 1, newestMtime: 20, kind: "build"),
        ]
    }

    private let summary = ScanSummary(totalBytes: 300, fileCount: 3, dirCount: 3, volumeFreeBytes: 1000, volumeTotalBytes: 5000, skippedCount: 0)

    func testRootIDIsStablePerPath() throws {
        let a = try store.rootID(for: "/r")
        let b = try store.rootID(for: "/r")
        let c = try store.rootID(for: "/other")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(try store.roots(), [RootEntry(id: a, path: "/r"), RootEntry(id: c, path: "/other")])
    }

    func testBeginInsertCompleteRoundTrip() throws {
        let rootID = try store.rootID(for: "/r")
        let scanID = try store.beginScan(rootID: rootID, startedAt: 100)
        XCTAssertEqual(try store.scan(id: scanID)?.status, .running)

        try store.insertDirStats(scanID: scanID, sampleStats())
        try store.completeScan(id: scanID, finishedAt: 160, summary: summary)

        let rec = try XCTUnwrap(try store.scan(id: scanID))
        XCTAssertEqual(rec, ScanRecord(id: scanID, rootID: rootID, startedAt: 100, finishedAt: 160, status: .completed,
                                       totalBytes: 300, fileCount: 3, dirCount: 3, volumeFreeBytes: 1000,
                                       volumeTotalBytes: 5000, skippedCount: 0, error: nil))
        XCTAssertEqual(try store.dirStatCount(scanID: scanID), 3)
    }

    func testFailScanStoresError() throws {
        let rootID = try store.rootID(for: "/r")
        let scanID = try store.beginScan(rootID: rootID, startedAt: 100)
        try store.failScan(id: scanID, finishedAt: 120, error: "boom")
        let rec = try XCTUnwrap(try store.scan(id: scanID))
        XCTAssertEqual(rec.status, .failed)
        XCTAssertEqual(rec.error, "boom")
        XCTAssertEqual(rec.finishedAt, 120)
    }

    func testFailStaleRunningScansMarksAllRunning() throws {
        let rootID = try store.rootID(for: "/r")
        let s1 = try store.beginScan(rootID: rootID, startedAt: 100)
        let s2 = try store.beginScan(rootID: rootID, startedAt: 200)
        try store.completeScan(id: s2, finishedAt: 260, summary: summary)

        XCTAssertEqual(try store.failStaleRunningScans(now: 500), 1)

        XCTAssertEqual(try store.scan(id: s1)?.status, .failed)
        XCTAssertEqual(try store.scan(id: s1)?.error, "interrupted")
        XCTAssertEqual(try store.scan(id: s1)?.finishedAt, 500)
        XCTAssertEqual(try store.scan(id: s2)?.status, .completed)
        XCTAssertEqual(try store.failStaleRunningScans(now: 600), 0)
    }

    func testInsertManyRowsIsFast() throws {
        let rootID = try store.rootID(for: "/r")
        let scanID = try store.beginScan(rootID: rootID, startedAt: 1)
        let rows = (0..<20_000).map { i in
            DirStat(path: "/r/\(i)", parentPath: "/r", depth: 1, bytes: Int64(i), fileCount: 1, newestMtime: 1)
        }
        let start = Date()
        try store.insertDirStats(scanID: scanID, rows)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
        XCTAssertEqual(try store.dirStatCount(scanID: scanID), 20_000)
    }

    func testReopeningKeepsData() throws {
        let url = URL(fileURLWithPath: tmp.path("persist.sqlite"))
        do {
            let s = try Store(url: url)
            let rootID = try s.rootID(for: "/r")
            let id = try s.beginScan(rootID: rootID, startedAt: 1)
            try s.completeScan(id: id, finishedAt: 2, summary: summary)
        }
        let again = try Store(url: url)
        XCTAssertEqual(try again.roots().count, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StoreTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'Store' in scope`

- [ ] **Step 3: Implement the SQLite wrapper**

`Sources/DiskReportCore/Store/Database.swift`:
```swift
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error, CustomStringConvertible {
    case open(String)
    case exec(sql: String, message: String)
    case prepare(sql: String, message: String)
    case step(sql: String, message: String)

    public var description: String {
        switch self {
        case .open(let m): return "sqlite open failed: \(m)"
        case .exec(let sql, let m): return "sqlite exec failed (\(m)): \(sql)"
        case .prepare(let sql, let m): return "sqlite prepare failed (\(m)): \(sql)"
        case .step(let sql, let m): return "sqlite step failed (\(m)): \(sql)"
        }
    }
}

/// Minimal sqlite3 wrapper. Not thread-safe; one Database per thread/actor.
final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw DatabaseError.open(message)
        }
        handle = db
    }

    deinit { sqlite3_close(handle) }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }
    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.exec(sql: sql, message: errorMessage)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepare(sql: sql, message: errorMessage)
        }
        return Statement(stmt: stmt, sql: sql, db: self)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

final class Statement {
    private let stmt: OpaquePointer
    private let sql: String
    private unowned let db: Database

    init(stmt: OpaquePointer, sql: String, db: Database) {
        self.stmt = stmt
        self.sql = sql
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    @discardableResult
    func bind(_ index: Int32, _ value: Int64?) -> Statement {
        if let value { sqlite3_bind_int64(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: String?) -> Statement {
        if let value { sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, index) }
        return self
    }

    /// Advances one row. Returns true when a row is available, false when done.
    func step() throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw DatabaseError.step(sql: sql, message: db.errorMessage)
        }
    }

    /// Runs a statement that returns no rows.
    func run() throws {
        while try step() {}
    }

    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(stmt, column) }
    func optionalInt64(_ column: Int32) -> Int64? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : int64(column)
    }
    func text(_ column: Int32) -> String { String(cString: sqlite3_column_text(stmt, column)) }
    func optionalText(_ column: Int32) -> String? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : text(column)
    }
}
```

- [ ] **Step 4: Implement the store (schema + writes)**

`Sources/DiskReportCore/Store/Store.swift`:
```swift
import Foundation

public struct RootEntry: Equatable, Sendable {
    public var id: Int64
    public var path: String
    public init(id: Int64, path: String) { self.id = id; self.path = path }
}

/// The only component that writes to disk (besides Logging). Owns the SQLite database.
public final class Store {
    let db: Database

    public init(url: URL) throws {
        db = try Database(path: url.path)
        try db.exec("PRAGMA journal_mode=WAL")
        try db.exec("PRAGMA synchronous=NORMAL")
        try db.exec("PRAGMA temp_store=MEMORY")
        try db.exec("PRAGMA foreign_keys=ON")
        try db.exec(Store.schemaV1)
    }

    static let schemaV1 = """
    CREATE TABLE IF NOT EXISTS roots (
      id INTEGER PRIMARY KEY,
      path TEXT NOT NULL UNIQUE
    );
    CREATE TABLE IF NOT EXISTS scans (
      id INTEGER PRIMARY KEY,
      root_id INTEGER NOT NULL REFERENCES roots(id),
      started_at INTEGER NOT NULL,
      finished_at INTEGER,
      status TEXT NOT NULL,
      total_bytes INTEGER,
      file_count INTEGER,
      dir_count INTEGER,
      volume_free_bytes INTEGER,
      volume_total_bytes INTEGER,
      skipped_count INTEGER,
      error TEXT
    );
    CREATE INDEX IF NOT EXISTS scans_root_finished ON scans(root_id, status, finished_at);
    CREATE TABLE IF NOT EXISTS dir_stats (
      scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
      path TEXT NOT NULL,
      parent_path TEXT,
      depth INTEGER NOT NULL,
      bytes INTEGER NOT NULL,
      file_count INTEGER NOT NULL,
      newest_mtime INTEGER NOT NULL,
      kind TEXT,
      PRIMARY KEY (scan_id, path)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS dir_stats_parent ON dir_stats(scan_id, parent_path);
    """

    // MARK: Roots

    public func rootID(for path: String) throws -> Int64 {
        try db.prepare("INSERT OR IGNORE INTO roots(path) VALUES (?)").bind(1, path).run()
        let q = try db.prepare("SELECT id FROM roots WHERE path = ?").bind(1, path)
        guard try q.step() else { throw DatabaseError.step(sql: "rootID", message: "missing after insert") }
        return q.int64(0)
    }

    public func roots() throws -> [RootEntry] {
        let q = try db.prepare("SELECT id, path FROM roots ORDER BY id")
        var out: [RootEntry] = []
        while try q.step() { out.append(RootEntry(id: q.int64(0), path: q.text(1))) }
        return out
    }

    // MARK: Scan writes

    public func beginScan(rootID: Int64, startedAt: Int64) throws -> Int64 {
        try db.prepare("INSERT INTO scans(root_id, started_at, status) VALUES (?, ?, 'running')")
            .bind(1, rootID).bind(2, startedAt).run()
        return db.lastInsertRowID
    }

    public func insertDirStats(scanID: Int64, _ stats: [DirStat]) throws {
        try db.transaction {
            let ins = try db.prepare("""
                INSERT INTO dir_stats(scan_id, path, parent_path, depth, bytes, file_count, newest_mtime, kind)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for s in stats {
                ins.reset()
                try ins.bind(1, scanID).bind(2, s.path).bind(3, s.parentPath).bind(4, Int64(s.depth))
                    .bind(5, s.bytes).bind(6, s.fileCount).bind(7, s.newestMtime).bind(8, s.kind).run()
            }
        }
    }

    public func completeScan(id: Int64, finishedAt: Int64, summary: ScanSummary) throws {
        try db.prepare("""
            UPDATE scans SET finished_at = ?, status = 'completed', total_bytes = ?, file_count = ?, dir_count = ?,
              volume_free_bytes = ?, volume_total_bytes = ?, skipped_count = ?, error = NULL WHERE id = ?
            """)
            .bind(1, finishedAt).bind(2, summary.totalBytes).bind(3, summary.fileCount).bind(4, summary.dirCount)
            .bind(5, summary.volumeFreeBytes).bind(6, summary.volumeTotalBytes).bind(7, summary.skippedCount)
            .bind(8, id).run()
    }

    public func failScan(id: Int64, finishedAt: Int64, error: String) throws {
        try db.prepare("UPDATE scans SET finished_at = ?, status = 'failed', error = ? WHERE id = ?")
            .bind(1, finishedAt).bind(2, error).bind(3, id).run()
    }

    /// Marks every 'running' scan as failed. Safe because the lock file guarantees no other scanner is live.
    @discardableResult
    public func failStaleRunningScans(now: Int64) throws -> Int {
        try db.prepare("UPDATE scans SET finished_at = ?, status = 'failed', error = 'interrupted' WHERE status = 'running'")
            .bind(1, now).run()
        return db.changes
    }

    // MARK: Basic reads (more in Queries via extension in Task 5)

    public func scan(id: Int64) throws -> ScanRecord? {
        let q = try db.prepare(Store.scanSelect + " WHERE id = ?").bind(1, id)
        return try q.step() ? Store.readScan(q) : nil
    }

    public func dirStatCount(scanID: Int64) throws -> Int {
        let q = try db.prepare("SELECT COUNT(*) FROM dir_stats WHERE scan_id = ?").bind(1, scanID)
        _ = try q.step()
        return Int(q.int64(0))
    }

    static let scanSelect = """
        SELECT id, root_id, started_at, finished_at, status, total_bytes, file_count, dir_count,
               volume_free_bytes, volume_total_bytes, skipped_count, error FROM scans
        """

    static func readScan(_ q: Statement) -> ScanRecord {
        ScanRecord(id: q.int64(0), rootID: q.int64(1), startedAt: q.int64(2), finishedAt: q.optionalInt64(3),
                   status: ScanStatus(rawValue: q.text(4)) ?? .failed,
                   totalBytes: q.optionalInt64(5), fileCount: q.optionalInt64(6), dirCount: q.optionalInt64(7),
                   volumeFreeBytes: q.optionalInt64(8), volumeTotalBytes: q.optionalInt64(9),
                   skippedCount: q.optionalInt64(10), error: q.optionalText(11))
    }
}
```

- [ ] **Step 5: Run tests and lint**

Run: `Scripts/lint-readonly.sh && swift test --filter StoreTests 2>&1 | grep -E "Executed|error|failed"`
Expected: `lint-readonly: ok`, `Executed 6 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(core): sqlite wrapper and store schema with scan writes"
```

---

### Task 5: Store read queries

**Files:**
- Create: `Sources/DiskReportCore/Store/StoreQueries.swift`
- Create: `Tests/DiskReportCoreTests/StoreQueryTests.swift`

**Interfaces:**
- Consumes: `Store`, `Statement` (Task 4).
- Produces (extension Store): `scans(rootID: Int64) throws -> [ScanRecord]` (newest `started_at` first), `latestScan(rootID:) throws -> ScanRecord?`, `latestCompletedScan(rootID:) throws -> ScanRecord?`, `baselineScan(rootID: Int64, finishedAtOrBefore: Int64) throws -> ScanRecord?`, `dirStats(scanID: Int64) throws -> [DirStat]` (ordered by path), `deleteScans(ids: [Int64]) throws`.

- [ ] **Step 1: Write failing query tests**

`Tests/DiskReportCoreTests/StoreQueryTests.swift`:
```swift
import XCTest
@testable import DiskReportCore

final class StoreQueryTests: XCTestCase {
    private var tmp: TempDir!
    private var store: Store!
    private var rootID: Int64 = 0
    private let summary = ScanSummary(totalBytes: 1, fileCount: 1, dirCount: 1, volumeFreeBytes: 1, volumeTotalBytes: 2, skippedCount: 0)

    override func setUpWithError() throws {
        tmp = makeTempDir()
        store = try Store(url: URL(fileURLWithPath: tmp.path("q.sqlite")))
        rootID = try store.rootID(for: "/r")
    }

    @discardableResult
    private func completed(startedAt: Int64, finishedAt: Int64, stats: [DirStat] = []) throws -> Int64 {
        let id = try store.beginScan(rootID: rootID, startedAt: startedAt)
        try store.insertDirStats(scanID: id, stats)
        try store.completeScan(id: id, finishedAt: finishedAt, summary: summary)
        return id
    }

    func testLatestScanIncludesFailedAndRunning() throws {
        try completed(startedAt: 100, finishedAt: 150)
        let running = try store.beginScan(rootID: rootID, startedAt: 200)
        XCTAssertEqual(try store.latestScan(rootID: rootID)?.id, running)
        try store.failScan(id: running, finishedAt: 210, error: "x")
        XCTAssertEqual(try store.latestScan(rootID: rootID)?.status, .failed)
    }

    func testLatestCompletedIgnoresFailedAndRunning() throws {
        let c = try completed(startedAt: 100, finishedAt: 150)
        let f = try store.beginScan(rootID: rootID, startedAt: 200)
        try store.failScan(id: f, finishedAt: 210, error: "x")
        _ = try store.beginScan(rootID: rootID, startedAt: 300)
        XCTAssertEqual(try store.latestCompletedScan(rootID: rootID)?.id, c)
    }

    func testLatestCompletedIsNilWhenNoneCompleted() throws {
        _ = try store.beginScan(rootID: rootID, startedAt: 300)
        XCTAssertNil(try store.latestCompletedScan(rootID: rootID))
    }

    func testBaselineScanBoundaries() throws {
        let s100 = try completed(startedAt: 90, finishedAt: 100)
        let s200 = try completed(startedAt: 190, finishedAt: 200)
        _ = try completed(startedAt: 290, finishedAt: 300)
        XCTAssertEqual(try store.baselineScan(rootID: rootID, finishedAtOrBefore: 200)?.id, s200, "inclusive boundary")
        XCTAssertEqual(try store.baselineScan(rootID: rootID, finishedAtOrBefore: 199)?.id, s100)
        XCTAssertNil(try store.baselineScan(rootID: rootID, finishedAtOrBefore: 50))
    }

    func testBaselineIgnoresFailedScansAndOtherRoots() throws {
        let f = try store.beginScan(rootID: rootID, startedAt: 90)
        try store.failScan(id: f, finishedAt: 100, error: "x")
        let other = try store.rootID(for: "/other")
        let oid = try store.beginScan(rootID: other, startedAt: 90)
        try store.completeScan(id: oid, finishedAt: 100, summary: summary)
        XCTAssertNil(try store.baselineScan(rootID: rootID, finishedAtOrBefore: 500))
    }

    func testScansNewestFirst() throws {
        let a = try completed(startedAt: 100, finishedAt: 150)
        let b = try completed(startedAt: 200, finishedAt: 250)
        XCTAssertEqual(try store.scans(rootID: rootID).map(\.id), [b, a])
    }

    func testDirStatsRoundTripOrderedByPath() throws {
        let stats = [
            DirStat(path: "/r/b", parentPath: "/r", depth: 1, bytes: 2, fileCount: 1, newestMtime: 5, kind: "k"),
            DirStat(path: "/r", parentPath: nil, depth: 0, bytes: 3, fileCount: 2, newestMtime: 5),
            DirStat(path: "/r/a", parentPath: "/r", depth: 1, bytes: 1, fileCount: 1, newestMtime: 4),
        ]
        let id = try completed(startedAt: 1, finishedAt: 2, stats: stats)
        XCTAssertEqual(try store.dirStats(scanID: id), [stats[1], stats[2], stats[0]])
    }

    func testDeleteScansCascadesToDirStats() throws {
        let stats = [DirStat(path: "/r", parentPath: nil, depth: 0, bytes: 3, fileCount: 2, newestMtime: 5)]
        let a = try completed(startedAt: 1, finishedAt: 2, stats: stats)
        let b = try completed(startedAt: 3, finishedAt: 4, stats: stats)
        try store.deleteScans(ids: [a])
        XCTAssertNil(try store.scan(id: a))
        XCTAssertEqual(try store.dirStatCount(scanID: a), 0)
        XCTAssertEqual(try store.dirStatCount(scanID: b), 1)
    }

    func testDeleteScansWithEmptyListIsNoop() throws {
        try completed(startedAt: 1, finishedAt: 2)
        try store.deleteScans(ids: [])
        XCTAssertEqual(try store.scans(rootID: rootID).count, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StoreQueryTests 2>&1 | grep -E "error:" | head -3`
Expected: `value of type 'Store' has no member 'latestScan'`

- [ ] **Step 3: Implement queries**

`Sources/DiskReportCore/Store/StoreQueries.swift`:
```swift
import Foundation

public extension Store {
    /// All scans for a root, newest started first.
    func scans(rootID: Int64) throws -> [ScanRecord] {
        let q = try db.prepare(Store.scanSelect + " WHERE root_id = ? ORDER BY started_at DESC, id DESC").bind(1, rootID)
        var out: [ScanRecord] = []
        while try q.step() { out.append(Store.readScan(q)) }
        return out
    }

    func latestScan(rootID: Int64) throws -> ScanRecord? {
        let q = try db.prepare(Store.scanSelect + " WHERE root_id = ? ORDER BY started_at DESC, id DESC LIMIT 1").bind(1, rootID)
        return try q.step() ? Store.readScan(q) : nil
    }

    func latestCompletedScan(rootID: Int64) throws -> ScanRecord? {
        let q = try db.prepare(Store.scanSelect + " WHERE root_id = ? AND status = 'completed' ORDER BY finished_at DESC, id DESC LIMIT 1").bind(1, rootID)
        return try q.step() ? Store.readScan(q) : nil
    }

    /// Latest completed scan with finished_at <= the given time. Nil when none exists (report shows "no data").
    func baselineScan(rootID: Int64, finishedAtOrBefore cutoff: Int64) throws -> ScanRecord? {
        let q = try db.prepare(Store.scanSelect + " WHERE root_id = ? AND status = 'completed' AND finished_at <= ? ORDER BY finished_at DESC, id DESC LIMIT 1")
            .bind(1, rootID).bind(2, cutoff)
        return try q.step() ? Store.readScan(q) : nil
    }

    func dirStats(scanID: Int64) throws -> [DirStat] {
        let q = try db.prepare("SELECT path, parent_path, depth, bytes, file_count, newest_mtime, kind FROM dir_stats WHERE scan_id = ? ORDER BY path").bind(1, scanID)
        var out: [DirStat] = []
        while try q.step() {
            out.append(DirStat(path: q.text(0), parentPath: q.optionalText(1), depth: Int(q.int64(2)), bytes: q.int64(3),
                               fileCount: q.int64(4), newestMtime: q.int64(5), kind: q.optionalText(6)))
        }
        return out
    }

    func deleteScans(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            let del = try db.prepare("DELETE FROM scans WHERE id = ?")
            for id in ids {
                del.reset()
                try del.bind(1, id).run()
            }
        }
    }
}
```

- [ ] **Step 4: Run tests and lint**

Run: `Scripts/lint-readonly.sh && swift test --filter StoreQueryTests 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 9 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(core): store read queries for scans, baselines, dir stats, deletion"
```

---

### Task 6: Report queries: windows, staleness, deltas, loader, notable hook

**Files:**
- Create: `Sources/DiskReportCore/Queries/Window.swift`
- Create: `Sources/DiskReportCore/Queries/Staleness.swift`
- Create: `Sources/DiskReportCore/Queries/ReportBuilder.swift`
- Create: `Sources/DiskReportCore/Queries/ReportLoader.swift`
- Create: `Sources/DiskReportCore/Notable/Notable.swift`
- Create: `Tests/DiskReportCoreTests/StalenessTests.swift`
- Create: `Tests/DiskReportCoreTests/ReportBuilderTests.swift`
- Create: `Tests/DiskReportCoreTests/ReportLoaderTests.swift`
- Create: `Tests/DiskReportCoreTests/NotableTests.swift`

**Interfaces:**
- Consumes: `Store` queries (Task 5), `DirStat`, `ScanRecord`.
- Produces:
  - `public enum Window: Int, CaseIterable, Hashable, Sendable { case day = 1, week = 7, month = 30; var seconds: Int64; func baselineCutoff(currentFinishedAt: Int64) -> Int64 }`
  - `public enum StalenessBucket: String, CaseIterable, Sendable { week, month, sixMonths, older; static func bucket(newestMtime: Int64, now: Int64) -> StalenessBucket }`
  - `public enum Delta: Equatable, Sendable { case noData, new(Int64), changed(Int64); var bytes: Int64? }`
  - `public struct ReportRow: Equatable, Sendable { path, parentPath: String?, depth: Int, bytes, fileCount, newestMtime: Int64, kind: String?, deltas: [Window: Delta], isDeleted: Bool }`
  - `public enum ReportBuilder { static func rows(current: [DirStat], baselines: [Window: [DirStat]]) -> [ReportRow] }`
  - `public struct RootReport: Sendable { rootID: Int64, rootPath: String, current: ScanRecord?, latest: ScanRecord?, baselines: [Window: ScanRecord], rows: [ReportRow] }`
  - `public enum ReportLoader { static func loadRootReports(store: Store) throws -> [RootReport] }`
  - `public struct RootSummary`, `public struct ReportSummary { static func from(_ reports: [RootReport]) -> ReportSummary }`, `public struct Notice`, `public protocol NotableRule`, `public struct NotableEvaluator { init(rules: [NotableRule] = []); func notices(for: ReportSummary) -> [Notice] }`

- [ ] **Step 1: Write failing tests**

`Tests/DiskReportCoreTests/StalenessTests.swift`:
```swift
import XCTest
@testable import DiskReportCore

final class StalenessTests: XCTestCase {
    let now: Int64 = 1_800_000_000
    let day: Int64 = 86_400

    func testBuckets() {
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now, now: now), .week)
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now - 6 * day, now: now), .week)
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now - 7 * day, now: now), .month)
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now - 29 * day, now: now), .month)
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now - 30 * day, now: now), .sixMonths)
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now - 182 * day, now: now), .sixMonths)
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now - 183 * day, now: now), .older)
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now + day, now: now), .week, "future mtimes are treated as fresh")
    }

    func testWindowCutoffs() {
        XCTAssertEqual(Window.day.baselineCutoff(currentFinishedAt: 1_000_000), 1_000_000 - 86_400)
        XCTAssertEqual(Window.week.baselineCutoff(currentFinishedAt: 1_000_000), 1_000_000 - 7 * 86_400)
        XCTAssertEqual(Window.month.baselineCutoff(currentFinishedAt: 1_000_000), 1_000_000 - 30 * 86_400)
        XCTAssertEqual(Window.allCases, [.day, .week, .month])
    }
}
```

`Tests/DiskReportCoreTests/ReportBuilderTests.swift`:
```swift
import XCTest
@testable import DiskReportCore

final class ReportBuilderTests: XCTestCase {
    private func d(_ path: String, _ bytes: Int64, parent: String? = "/r", depth: Int = 1) -> DirStat {
        DirStat(path: path, parentPath: parent, depth: depth, bytes: bytes, fileCount: 1, newestMtime: 10)
    }

    func testChangedNewAndNoData() {
        let current = [d("/r", 300, parent: nil, depth: 0), d("/r/a", 200), d("/r/b", 100)]
        let day = [d("/r", 150, parent: nil, depth: 0), d("/r/a", 150)]
        let rows = ReportBuilder.rows(current: current, baselines: [.day: day])
        let byPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.path, $0) })

        XCTAssertEqual(byPath["/r/a"]?.deltas[.day], .changed(50))
        XCTAssertEqual(byPath["/r/b"]?.deltas[.day], .new(100))
        XCTAssertEqual(byPath["/r/a"]?.deltas[.week], .noData)
        XCTAssertEqual(byPath["/r/a"]?.deltas[.month], .noData)
        XCTAssertEqual(byPath["/r"]?.deltas[.day], .changed(150))
        XCTAssertFalse(byPath["/r/a"]!.isDeleted)
        XCTAssertEqual(rows.count, 3)
    }

    func testShrinkIsNegativeDelta() {
        let current = [d("/r/a", 50)]
        let rows = ReportBuilder.rows(current: current, baselines: [.week: [d("/r/a", 80)]])
        XCTAssertEqual(rows[0].deltas[.week], .changed(-30))
    }

    func testDeletedRowsComeFromDayBaselineOnlyWhenParentStillExists() {
        let current = [d("/r", 10, parent: nil, depth: 0), d("/r/keep", 10)]
        let day = [d("/r", 10, parent: nil, depth: 0), d("/r/keep", 10), d("/r/gone", 40),
                   d("/r/gone/child", 20, parent: "/r/gone", depth: 2)]
        let week = [d("/r/other", 5)]
        let rows = ReportBuilder.rows(current: current, baselines: [.day: day, .week: week])
        let deleted = rows.filter(\.isDeleted)

        XCTAssertEqual(deleted.map(\.path), ["/r/gone"], "child of a deleted dir is not listed separately; week baseline never yields deleted rows")
        XCTAssertEqual(deleted[0].bytes, 40)
        XCTAssertEqual(deleted[0].deltas[.day], .changed(-40))
        XCTAssertEqual(deleted[0].deltas[.week], .noData)
        XCTAssertEqual(deleted[0].deltas[.month], .noData)
        XCTAssertEqual(deleted[0].parentPath, "/r")
    }

    func testNoBaselinesAtAll() {
        let rows = ReportBuilder.rows(current: [d("/r/a", 1)], baselines: [:])
        XCTAssertEqual(rows[0].deltas, [.day: .noData, .week: .noData, .month: .noData])
        XCTAssertTrue(rows.allSatisfy { !$0.isDeleted })
    }

    func testDeltaBytesAccessor() {
        XCTAssertNil(Delta.noData.bytes)
        XCTAssertEqual(Delta.new(5).bytes, 5)
        XCTAssertEqual(Delta.changed(-5).bytes, -5)
    }
}
```

`Tests/DiskReportCoreTests/ReportLoaderTests.swift`:
```swift
import XCTest
@testable import DiskReportCore

final class ReportLoaderTests: XCTestCase {
    private var tmp: TempDir!
    private var store: Store!
    private let day: Int64 = 86_400
    private let t0: Int64 = 1_800_000_000

    override func setUpWithError() throws {
        tmp = makeTempDir()
        store = try Store(url: URL(fileURLWithPath: tmp.path("l.sqlite")))
    }

    private func complete(rootID: Int64, finishedAt: Int64, stats: [DirStat], totalBytes: Int64) throws -> Int64 {
        let id = try store.beginScan(rootID: rootID, startedAt: finishedAt - 60)
        try store.insertDirStats(scanID: id, stats)
        try store.completeScan(id: id, finishedAt: finishedAt, summary: ScanSummary(totalBytes: totalBytes, fileCount: 1, dirCount: Int64(stats.count), volumeFreeBytes: 100, volumeTotalBytes: 200, skippedCount: 0))
        return id
    }

    func testLoadsBaselinesPerWindowAndBuildsRows() throws {
        let rootID = try store.rootID(for: "/r")
        let oldStats = [DirStat(path: "/r", parentPath: nil, depth: 0, bytes: 100, fileCount: 1, newestMtime: 1)]
        let newStats = [DirStat(path: "/r", parentPath: nil, depth: 0, bytes: 160, fileCount: 1, newestMtime: 1)]
        let monthAgo = try complete(rootID: rootID, finishedAt: t0 - 31 * day, stats: oldStats, totalBytes: 100)
        let twoDaysAgo = try complete(rootID: rootID, finishedAt: t0 - 2 * day, stats: [DirStat(path: "/r", parentPath: nil, depth: 0, bytes: 130, fileCount: 1, newestMtime: 1)], totalBytes: 130)
        let current = try complete(rootID: rootID, finishedAt: t0, stats: newStats, totalBytes: 160)

        let reports = try ReportLoader.loadRootReports(store: store)

        XCTAssertEqual(reports.count, 1)
        let r = reports[0]
        XCTAssertEqual(r.rootPath, "/r")
        XCTAssertEqual(r.current?.id, current)
        XCTAssertEqual(r.latest?.id, current)
        XCTAssertEqual(r.baselines[.day]?.id, twoDaysAgo)
        XCTAssertEqual(r.baselines[.week]?.id, monthAgo, "week window falls back to the most recent scan at or before 7 days ago")
        XCTAssertEqual(r.baselines[.month]?.id, monthAgo)
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertEqual(r.rows[0].deltas[.day], .changed(30))
        XCTAssertEqual(r.rows[0].deltas[.week], .changed(60))
        XCTAssertEqual(r.rows[0].deltas[.month], .changed(60))
    }

    func testRootWithoutCompletedScanHasNoRowsButKeepsLatest() throws {
        let rootID = try store.rootID(for: "/r")
        let running = try store.beginScan(rootID: rootID, startedAt: t0)
        let reports = try ReportLoader.loadRootReports(store: store)
        XCTAssertNil(reports[0].current)
        XCTAssertEqual(reports[0].latest?.id, running)
        XCTAssertTrue(reports[0].rows.isEmpty)
        XCTAssertTrue(reports[0].baselines.isEmpty)
    }

    func testNoRootsGivesEmptyList() throws {
        XCTAssertTrue(try ReportLoader.loadRootReports(store: store).isEmpty)
    }
}
```

`Tests/DiskReportCoreTests/NotableTests.swift`:
```swift
import XCTest
@testable import DiskReportCore

final class NotableTests: XCTestCase {
    private func report(path: String, total: Int64, dayTotal: Int64?, free: Int64) -> RootReport {
        let current = ScanRecord(id: 2, rootID: 1, startedAt: 0, finishedAt: 100, status: .completed, totalBytes: total, volumeFreeBytes: free, volumeTotalBytes: 1000)
        var baselines: [Window: ScanRecord] = [:]
        if let dayTotal {
            baselines[.day] = ScanRecord(id: 1, rootID: 1, startedAt: 0, finishedAt: 10, status: .completed, totalBytes: dayTotal, volumeFreeBytes: free + 5, volumeTotalBytes: 1000)
        }
        return RootReport(rootID: 1, rootPath: path, current: current, latest: current, baselines: baselines, rows: [])
    }

    func testSummaryFromReports() {
        let s = ReportSummary.from([report(path: "/a", total: 500, dayTotal: 450, free: 100), report(path: "/b", total: 20, dayTotal: nil, free: 100)])
        XCTAssertEqual(s.volumeFreeBytes, 100)
        XCTAssertEqual(s.volumeTotalBytes, 1000)
        XCTAssertEqual(s.volumeFreeDeltaDay, -5)
        XCTAssertEqual(s.roots, [RootSummary(rootPath: "/a", totalBytes: 500, deltaDay: 50), RootSummary(rootPath: "/b", totalBytes: 20, deltaDay: nil)])
    }

    func testSummaryWithNoCompletedScans() {
        let r = RootReport(rootID: 1, rootPath: "/a", current: nil, latest: nil, baselines: [:], rows: [])
        let s = ReportSummary.from([r])
        XCTAssertNil(s.volumeFreeBytes)
        XCTAssertEqual(s.roots, [RootSummary(rootPath: "/a", totalBytes: 0, deltaDay: nil)])
    }

    func testEvaluatorWithNoRulesIsQuiet() {
        XCTAssertTrue(NotableEvaluator().notices(for: ReportSummary.from([])).isEmpty)
    }

    func testEvaluatorCollectsNoticesFromRules() {
        struct Always: NotableRule {
            func evaluate(_ summary: ReportSummary) -> Notice? { Notice(title: "t", detail: "d") }
        }
        struct Never: NotableRule {
            func evaluate(_ summary: ReportSummary) -> Notice? { nil }
        }
        let notices = NotableEvaluator(rules: [Always(), Never(), Always()]).notices(for: ReportSummary.from([]))
        XCTAssertEqual(notices, [Notice(title: "t", detail: "d"), Notice(title: "t", detail: "d")])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "StalenessTests|ReportBuilderTests|ReportLoaderTests|NotableTests" 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'StalenessBucket' in scope` (and others)

- [ ] **Step 3: Implement Window and Staleness**

`Sources/DiskReportCore/Queries/Window.swift`:
```swift
/// Comparison windows. Raw value is the number of days.
public enum Window: Int, CaseIterable, Hashable, Sendable {
    case day = 1
    case week = 7
    case month = 30

    public var seconds: Int64 { Int64(rawValue) * 86_400 }

    /// Latest allowed finished_at for a baseline scan of this window.
    public func baselineCutoff(currentFinishedAt: Int64) -> Int64 {
        currentFinishedAt - seconds
    }
}
```

`Sources/DiskReportCore/Queries/Staleness.swift`:
```swift
public enum StalenessBucket: String, CaseIterable, Sendable {
    case week, month, sixMonths, older

    public static func bucket(newestMtime: Int64, now: Int64) -> StalenessBucket {
        let age = now - newestMtime
        let day: Int64 = 86_400
        if age < 7 * day { return .week }
        if age < 30 * day { return .month }
        if age < 183 * day { return .sixMonths }
        return .older
    }
}
```

- [ ] **Step 4: Implement ReportBuilder**

`Sources/DiskReportCore/Queries/ReportBuilder.swift`:
```swift
public enum Delta: Equatable, Sendable {
    case noData
    case new(Int64)
    case changed(Int64)

    public var bytes: Int64? {
        switch self {
        case .noData: return nil
        case .new(let b), .changed(let b): return b
        }
    }
}

public struct ReportRow: Equatable, Sendable {
    public var path: String
    public var parentPath: String?
    public var depth: Int
    public var bytes: Int64
    public var fileCount: Int64
    public var newestMtime: Int64
    public var kind: String?
    public var deltas: [Window: Delta]
    public var isDeleted: Bool

    public init(path: String, parentPath: String?, depth: Int, bytes: Int64, fileCount: Int64, newestMtime: Int64,
                kind: String?, deltas: [Window: Delta], isDeleted: Bool) {
        self.path = path
        self.parentPath = parentPath
        self.depth = depth
        self.bytes = bytes
        self.fileCount = fileCount
        self.newestMtime = newestMtime
        self.kind = kind
        self.deltas = deltas
        self.isDeleted = isDeleted
    }
}

public enum ReportBuilder {
    /// Joins the current scan against per-window baselines. Missing window ⇒ `.noData`.
    /// Deleted rows are derived from the day baseline only, and only when their parent still exists.
    public static func rows(current: [DirStat], baselines: [Window: [DirStat]]) -> [ReportRow] {
        let baselineBytes: [Window: [String: Int64]] = baselines.mapValues { stats in
            var m: [String: Int64] = [:]
            m.reserveCapacity(stats.count)
            for s in stats { m[s.path] = s.bytes }
            return m
        }
        let currentPaths = Set(current.map(\.path))

        var rows: [ReportRow] = []
        rows.reserveCapacity(current.count)
        for s in current {
            var deltas: [Window: Delta] = [:]
            for w in Window.allCases {
                guard let base = baselineBytes[w] else { deltas[w] = .noData; continue }
                if let b = base[s.path] { deltas[w] = .changed(s.bytes - b) } else { deltas[w] = .new(s.bytes) }
            }
            rows.append(ReportRow(path: s.path, parentPath: s.parentPath, depth: s.depth, bytes: s.bytes,
                                  fileCount: s.fileCount, newestMtime: s.newestMtime, kind: s.kind,
                                  deltas: deltas, isDeleted: false))
        }

        if let dayBaseline = baselines[.day] {
            for b in dayBaseline where !currentPaths.contains(b.path) {
                guard let parent = b.parentPath, currentPaths.contains(parent) else { continue }
                rows.append(ReportRow(path: b.path, parentPath: parent, depth: b.depth, bytes: b.bytes,
                                      fileCount: b.fileCount, newestMtime: b.newestMtime, kind: b.kind,
                                      deltas: [.day: .changed(-b.bytes), .week: .noData, .month: .noData],
                                      isDeleted: true))
            }
        }
        return rows
    }
}
```

- [ ] **Step 5: Implement ReportLoader**

`Sources/DiskReportCore/Queries/ReportLoader.swift`:
```swift
public struct RootReport: Sendable {
    public var rootID: Int64
    public var rootPath: String
    /// Latest completed scan, the one the rows describe.
    public var current: ScanRecord?
    /// Latest scan of any status, used for banners ("last scan failed", "scanning").
    public var latest: ScanRecord?
    public var baselines: [Window: ScanRecord]
    public var rows: [ReportRow]

    public init(rootID: Int64, rootPath: String, current: ScanRecord?, latest: ScanRecord?,
                baselines: [Window: ScanRecord], rows: [ReportRow]) {
        self.rootID = rootID
        self.rootPath = rootPath
        self.current = current
        self.latest = latest
        self.baselines = baselines
        self.rows = rows
    }
}

public enum ReportLoader {
    public static func loadRootReports(store: Store) throws -> [RootReport] {
        try store.roots().map { root in
            let latest = try store.latestScan(rootID: root.id)
            guard let current = try store.latestCompletedScan(rootID: root.id), let finished = current.finishedAt else {
                return RootReport(rootID: root.id, rootPath: root.path, current: nil, latest: latest, baselines: [:], rows: [])
            }
            var baselines: [Window: ScanRecord] = [:]
            var baselineStats: [Window: [DirStat]] = [:]
            var statsByScan: [Int64: [DirStat]] = [:]
            for w in Window.allCases {
                let cutoff = w.baselineCutoff(currentFinishedAt: finished)
                guard let b = try store.baselineScan(rootID: root.id, finishedAtOrBefore: cutoff) else { continue }
                baselines[w] = b
                if statsByScan[b.id] == nil { statsByScan[b.id] = try store.dirStats(scanID: b.id) }
                baselineStats[w] = statsByScan[b.id]
            }
            let rows = ReportBuilder.rows(current: try store.dirStats(scanID: current.id), baselines: baselineStats)
            return RootReport(rootID: root.id, rootPath: root.path, current: current, latest: latest,
                              baselines: baselines, rows: rows)
        }
    }
}
```

- [ ] **Step 6: Implement the notable hook**

`Sources/DiskReportCore/Notable/Notable.swift`:
```swift
public struct RootSummary: Equatable, Sendable {
    public var rootPath: String
    public var totalBytes: Int64
    public var deltaDay: Int64?
    public init(rootPath: String, totalBytes: Int64, deltaDay: Int64?) {
        self.rootPath = rootPath
        self.totalBytes = totalBytes
        self.deltaDay = deltaDay
    }
}

/// Compact view of the latest report for rule evaluation and the summary bar.
public struct ReportSummary: Equatable, Sendable {
    public var volumeFreeBytes: Int64?
    public var volumeTotalBytes: Int64?
    public var volumeFreeDeltaDay: Int64?
    public var roots: [RootSummary]

    public init(volumeFreeBytes: Int64?, volumeTotalBytes: Int64?, volumeFreeDeltaDay: Int64?, roots: [RootSummary]) {
        self.volumeFreeBytes = volumeFreeBytes
        self.volumeTotalBytes = volumeTotalBytes
        self.volumeFreeDeltaDay = volumeFreeDeltaDay
        self.roots = roots
    }

    public static func from(_ reports: [RootReport]) -> ReportSummary {
        let firstCurrent = reports.compactMap(\.current).first
        let firstWithDay = reports.first { $0.current != nil && $0.baselines[.day] != nil }
        var freeDelta: Int64?
        if let r = firstWithDay, let now = r.current?.volumeFreeBytes, let then = r.baselines[.day]?.volumeFreeBytes {
            freeDelta = now - then
        }
        let roots = reports.map { r -> RootSummary in
            let total = r.current?.totalBytes ?? 0
            var delta: Int64?
            if let cur = r.current?.totalBytes, let base = r.baselines[.day]?.totalBytes { delta = cur - base }
            return RootSummary(rootPath: r.rootPath, totalBytes: total, deltaDay: delta)
        }
        return ReportSummary(volumeFreeBytes: firstCurrent?.volumeFreeBytes, volumeTotalBytes: firstCurrent?.volumeTotalBytes,
                             volumeFreeDeltaDay: freeDelta, roots: roots)
    }
}

public struct Notice: Equatable, Sendable {
    public var title: String
    public var detail: String
    public init(title: String, detail: String) { self.title = title; self.detail = detail }
}

/// Extension point for "something to notify about". v1 ships no rules.
public protocol NotableRule: Sendable {
    func evaluate(_ summary: ReportSummary) -> Notice?
}

public struct NotableEvaluator: Sendable {
    public var rules: [NotableRule]
    public init(rules: [NotableRule] = []) { self.rules = rules }

    public func notices(for summary: ReportSummary) -> [Notice] {
        rules.compactMap { $0.evaluate(summary) }
    }
}
```

- [ ] **Step 7: Run tests and lint**

Run: `Scripts/lint-readonly.sh && swift test --filter "StalenessTests|ReportBuilderTests|ReportLoaderTests|NotableTests" 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 14 tests, with 0 failures`

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(core): comparison windows, staleness, report rows, loader, notable hook"
```

---

### Task 7: Retention policy

**Files:**
- Create: `Sources/DiskReportCore/Queries/Retention.swift`
- Create: `Tests/DiskReportCoreTests/RetentionTests.swift`

**Interfaces:**
- Consumes: `ScanRecord`, `Retention` (Task 2).
- Produces: `public enum RetentionPolicy { static func scansToDelete(_ scans: [ScanRecord], now: Int64, retention: Retention) -> [Int64] }`. Week and month buckets use the ISO 8601 calendar in UTC.

- [ ] **Step 1: Write failing tests**

`Tests/DiskReportCoreTests/RetentionTests.swift`:
```swift
import XCTest
@testable import DiskReportCore

final class RetentionTests: XCTestCase {
    private func ts(_ iso: String) -> Int64 {
        let f = ISO8601DateFormatter()
        return Int64(f.date(from: iso)!.timeIntervalSince1970)
    }
    // Monday 2026-09-07 07:00 UTC
    private lazy var now = ts("2026-09-07T07:00:00Z")
    private var nextID: Int64 = 1

    private func scan(_ iso: String, status: ScanStatus = .completed) -> ScanRecord {
        defer { nextID += 1 }
        let t = ts(iso)
        return ScanRecord(id: nextID, rootID: 1, startedAt: t - 60, finishedAt: status == .running ? nil : t, status: status)
    }

    func testRecentScansAllKept() {
        let scans = [scan("2026-09-07T07:00:00Z"), scan("2026-09-06T07:00:00Z"), scan("2026-07-24T07:00:00Z")]
        XCTAssertEqual(RetentionPolicy.scansToDelete(scans, now: now, retention: Retention()), [])
    }

    func testOneScanPerISOWeekBeyondDailyWindow() {
        // Wed 8 Jul and Thu 9 Jul 2026 share ISO week 28; Mon 13 Jul is week 29. All older than 45 days.
        let wed = scan("2026-07-08T07:00:00Z")
        let thu = scan("2026-07-09T07:00:00Z")
        let mon = scan("2026-07-13T07:00:00Z")
        let del = RetentionPolicy.scansToDelete([wed, thu, mon], now: now, retention: Retention())
        XCTAssertEqual(del, [wed.id])
    }

    func testOnePerMonthBeyondWeeklyWindow() {
        // June 2025 is more than 52 weeks before 2026-09-07.
        let early = scan("2025-06-10T07:00:00Z")
        let late = scan("2025-06-20T07:00:00Z")
        let july = scan("2025-07-01T07:00:00Z")
        let del = RetentionPolicy.scansToDelete([early, late, july], now: now, retention: Retention())
        XCTAssertEqual(del, [early.id])
    }

    func testFailedScansKeptOnlyWithinDailyWindow() {
        let recentFailed = scan("2026-09-01T07:00:00Z", status: .failed)
        let oldFailed = scan("2026-06-01T07:00:00Z", status: .failed)
        let del = RetentionPolicy.scansToDelete([recentFailed, oldFailed], now: now, retention: Retention())
        XCTAssertEqual(del, [oldFailed.id])
    }

    func testRunningScansNeverDeleted() {
        let running = scan("2026-01-01T07:00:00Z", status: .running)
        XCTAssertEqual(RetentionPolicy.scansToDelete([running], now: now, retention: Retention()), [])
    }

    func testCustomRetention() {
        let a = scan("2026-09-01T07:00:00Z") // 6 days old
        let b = scan("2026-09-02T07:00:00Z") // 5 days old, same ISO week as a
        let del = RetentionPolicy.scansToDelete([a, b], now: now, retention: Retention(dailyDays: 2, weeklyWeeks: 52))
        XCTAssertEqual(del, [a.id])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RetentionTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'RetentionPolicy' in scope`

- [ ] **Step 3: Implement**

`Sources/DiskReportCore/Queries/Retention.swift`:
```swift
import Foundation

public enum RetentionPolicy {
    /// Returns ids to delete. Keeps: all completed scans within `dailyDays`; the newest completed scan per ISO week
    /// within `weeklyWeeks`; the newest completed scan per calendar month beyond that; failed scans within `dailyDays`;
    /// every running scan.
    public static func scansToDelete(_ scans: [ScanRecord], now: Int64, retention: Retention) -> [Int64] {
        let day: Int64 = 86_400
        let dailyCutoff = now - Int64(retention.dailyDays) * day
        let weeklyCutoff = now - Int64(retention.weeklyWeeks) * 7 * day

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        var keep = Set<Int64>()
        var newestPerWeek: [String: ScanRecord] = [:]
        var newestPerMonth: [String: ScanRecord] = [:]

        for s in scans {
            if s.status == .running { keep.insert(s.id); continue }
            guard let finished = s.finishedAt else { keep.insert(s.id); continue }
            if finished >= dailyCutoff { keep.insert(s.id); continue }
            guard s.status == .completed else { continue } // old failed scans are dropped

            let date = Date(timeIntervalSince1970: TimeInterval(finished))
            if finished >= weeklyCutoff {
                let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
                let key = "\(c.yearForWeekOfYear!)-W\(c.weekOfYear!)"
                if let existing = newestPerWeek[key], (existing.finishedAt ?? 0) >= finished { continue }
                newestPerWeek[key] = s
            } else {
                let c = calendar.dateComponents([.year, .month], from: date)
                let key = "\(c.year!)-M\(c.month!)"
                if let existing = newestPerMonth[key], (existing.finishedAt ?? 0) >= finished { continue }
                newestPerMonth[key] = s
            }
        }
        keep.formUnion(newestPerWeek.values.map(\.id))
        keep.formUnion(newestPerMonth.values.map(\.id))
        return scans.map(\.id).filter { !keep.contains($0) }
    }
}
```

- [ ] **Step 4: Run tests and lint**

Run: `Scripts/lint-readonly.sh && swift test --filter RetentionTests 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(core): retention policy (daily/weekly/monthly)"
```

---

### Task 8: Logging, lock file, and the scanner CLI

**Files:**
- Create: `Sources/DiskReportCore/Logging/Logger.swift`
- Create: `Sources/DiskReportCore/Store/LockFile.swift`
- Replace: `Sources/diskreport-scan/main.swift`
- Create: `Sources/diskreport-scan/Arguments.swift`
- Create: `Sources/diskreport-scan/SelfTestWrite.swift`
- Create: `Tests/DiskReportCoreTests/LoggerTests.swift`
- Create: `Tests/DiskReportCoreTests/LockFileTests.swift`
- Create: `Tests/DiskReportCoreTests/ScannerCLITests.swift`

**Interfaces:**
- Consumes: `Config`, `DataPaths`, `Walker`, `VolumeInfo`, `Store` (+queries), `RetentionPolicy`.
- Produces:
  - `public final class Logger { init(directory: URL, maxFiles: Int = 14, now: Date = Date()) throws; func log(_ message: String); static func fileName(for: Date) -> String; var fileURL: URL }`
  - `public final class LockFile { init(url: URL) throws; enum Error: Swift.Error, Equatable { case alreadyHeld, cannotOpen(String) } }`
  - CLI: `diskreport-scan [--config PATH] [--data-dir PATH] [--log-dir PATH] [--self-test-write PATH]`. Exit codes per Global Constraints. Summary lines on stdout: `diskreport-scan: root=<path> status=completed total=<bytes> files=<n> dirs=<n> skipped=<n> duration=<s>s` for a completed root, `diskreport-scan: root=<path> status=failed error=<message>` for a failed root, and `diskreport-scan: done status=<ok|failed>` at the end. Retention pruning runs in its own do/catch after completion; a pruning failure only logs a warning.

- [ ] **Step 1: Write failing tests for Logger and LockFile**

`Tests/DiskReportCoreTests/LoggerTests.swift`:
```swift
import XCTest
@testable import DiskReportCore

final class LoggerTests: XCTestCase {
    func testFileNameUsesDate() {
        let d = ISO8601DateFormatter().date(from: "2026-09-07T07:00:00Z")!
        XCTAssertEqual(Logger.fileName(for: d), "scan-2026-09-07.log")
    }

    func testWritesTimestampedLinesAndAppends() throws {
        let tmp = makeTempDir()
        let dir = URL(fileURLWithPath: tmp.path("logs"))
        let d = ISO8601DateFormatter().date(from: "2026-09-07T07:00:00Z")!
        do {
            let log = try Logger(directory: dir, now: d)
            log.log("hello")
        }
        let log2 = try Logger(directory: dir, now: d)
        log2.log("again")
        let text = try String(contentsOf: dir.appendingPathComponent("scan-2026-09-07.log"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" hello"))
        XCTAssertTrue(lines[1].hasSuffix(" again"))
        XCTAssertTrue(lines[0].hasPrefix("20"), "line starts with an ISO timestamp")
    }

    func testRotationKeepsNewestFiles() throws {
        let tmp = makeTempDir()
        let dir = URL(fileURLWithPath: tmp.path("logs"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for day in 1...16 {
            let name = String(format: "scan-2026-08-%02d.log", day)
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        let d = ISO8601DateFormatter().date(from: "2026-09-07T07:00:00Z")!
        _ = try Logger(directory: dir, maxFiles: 14, now: d)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("scan-") }.sorted()
        XCTAssertEqual(remaining.count, 14)
        XCTAssertEqual(remaining.first, "scan-2026-08-04.log")
        XCTAssertEqual(remaining.last, "scan-2026-09-07.log")
    }
}
```

`Tests/DiskReportCoreTests/LockFileTests.swift`:
```swift
import XCTest
@testable import DiskReportCore

final class LockFileTests: XCTestCase {
    func testSecondHolderIsRefusedUntilFirstReleases() throws {
        let tmp = makeTempDir()
        let url = URL(fileURLWithPath: tmp.path("scan.lock"))
        var first: LockFile? = try LockFile(url: url)
        XCTAssertThrowsError(try LockFile(url: url)) { error in
            XCTAssertEqual(error as? LockFile.Error, .alreadyHeld)
        }
        first = nil
        XCTAssertNoThrow(try LockFile(url: url))
        _ = first
    }

    func testUnopenablePathThrows() {
        XCTAssertThrowsError(try LockFile(url: URL(fileURLWithPath: "/nonexistent-dir/x.lock"))) { error in
            if case .cannotOpen = error as? LockFile.Error {} else { XCTFail("expected cannotOpen, got \(error)") }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "LoggerTests|LockFileTests" 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'Logger' in scope`

- [ ] **Step 3: Implement Logger and LockFile**

`Sources/DiskReportCore/Logging/Logger.swift`:
```swift
import Foundation

/// Appends timestamped lines to `scan-YYYY-MM-DD.log` and keeps at most `maxFiles` such files.
public final class Logger {
    public let fileURL: URL
    private let handle: FileHandle

    public static func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return "scan-\(f.string(from: date)).log"
    }

    public init(directory: URL, maxFiles: Int = 14, now: Date = Date()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(Logger.fileName(for: now))
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        Logger.rotate(directory: directory, maxFiles: maxFiles)
    }

    deinit { try? handle.close() }

    public func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        if let data = "\(stamp) \(message)\n".data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private static func rotate(directory: URL, maxFiles: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let logs = names.filter { $0.hasPrefix("scan-") && $0.hasSuffix(".log") }.sorted()
        guard logs.count > maxFiles else { return }
        for name in logs.prefix(logs.count - maxFiles) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
```

`Sources/DiskReportCore/Store/LockFile.swift`:
```swift
import Darwin
import Foundation

/// Exclusive advisory lock so two scanners never run at once. Released on deinit or process exit.
public final class LockFile {
    public enum Error: Swift.Error, Equatable {
        case alreadyHeld
        case cannotOpen(String)
    }

    private let fd: Int32

    public init(url: URL) throws {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Error.cannotOpen(String(cString: strerror(errno))) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw Error.alreadyHeld
        }
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
```

- [ ] **Step 4: Run Logger and LockFile tests**

Run: `Scripts/lint-readonly.sh && swift test --filter "LoggerTests|LockFileTests" 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: Write failing CLI tests**

`Tests/DiskReportCoreTests/ScannerCLITests.swift`:
```swift
import XCTest
@testable import DiskReportCore

struct CLIResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Shared helpers for running the built `diskreport-scan` binary.
enum CLI {
    static var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("couldn't find the products directory")
    }

    static var scannerURL: URL { productsDirectory.appendingPathComponent("diskreport-scan") }

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @discardableResult
    static func run(executable: URL = scannerURL, _ args: [String]) throws -> CLIResult {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return CLIResult(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }

    /// Writes a config pointing at `roots` and returns the standard argument list for an isolated run.
    static func standardArgs(tmp: TempDir, roots: [String]) throws -> [String] {
        let data = tmp.mkdir("data")
        let logs = tmp.mkdir("logs")
        let cfg = tmp.path("config.json")
        let json = try JSONSerialization.data(withJSONObject: ["roots": roots])
        try json.write(to: URL(fileURLWithPath: cfg))
        return ["--config", cfg, "--data-dir", data, "--log-dir", logs]
    }
}

final class ScannerCLITests: XCTestCase {
    func testScansFixtureAndRecordsCompletedScan() throws {
        let tmp = makeTempDir()
        tmp.file("root/a/x.bin", size: 4096)
        tmp.file("root/b/y.bin", size: 4096)
        let root = realpathString(tmp.path("root"))
        let args = try CLI.standardArgs(tmp: tmp, roots: [root])

        let r = try CLI.run(args)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertTrue(r.stdout.contains("root=\(root) status=completed"), r.stdout)
        XCTAssertTrue(r.stdout.contains("files=2"), r.stdout)
        XCTAssertTrue(r.stdout.contains("dirs=3"), r.stdout)
        XCTAssertTrue(r.stdout.contains("done status=ok"), r.stdout)

        let store = try Store(url: URL(fileURLWithPath: tmp.path("data/diskreport.sqlite")))
        let rootID = try store.rootID(for: root)
        let scan = try XCTUnwrap(try store.latestCompletedScan(rootID: rootID))
        XCTAssertEqual(scan.dirCount, 3)
        XCTAssertEqual(scan.fileCount, 2)
        XCTAssertGreaterThan(scan.volumeFreeBytes ?? 0, 0)
        XCTAssertEqual(try store.dirStatCount(scanID: scan.id), 3)

        let logs = try FileManager.default.contentsOfDirectory(atPath: tmp.path("logs"))
        XCTAssertEqual(logs.filter { $0.hasPrefix("scan-") }.count, 1)
    }

    func testSecondRunAddsSecondScan() throws {
        let tmp = makeTempDir()
        tmp.file("root/x.bin")
        let root = realpathString(tmp.path("root"))
        let args = try CLI.standardArgs(tmp: tmp, roots: [root])
        XCTAssertEqual(try CLI.run(args).status, 0)
        XCTAssertEqual(try CLI.run(args).status, 0)
        let store = try Store(url: URL(fileURLWithPath: tmp.path("data/diskreport.sqlite")))
        XCTAssertEqual(try store.scans(rootID: try store.rootID(for: root)).count, 2)
    }

    func testMissingConfigExits1() throws {
        let tmp = makeTempDir()
        let r = try CLI.run(["--config", tmp.path("nope.json"), "--data-dir", tmp.mkdir("d"), "--log-dir", tmp.mkdir("l")])
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.stderr.contains("cannot read config"), r.stderr)
    }

    func testNestedRootsExits1WithExplanation() throws {
        let tmp = makeTempDir()
        tmp.mkdir("root/inner")
        let root = realpathString(tmp.path("root"))
        let args = try CLI.standardArgs(tmp: tmp, roots: [root, root + "/inner"])
        let r = try CLI.run(args)
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.stderr.contains("keep only the outer root"), r.stderr)
    }

    func testMissingRootExits1ButStillScansNothing() throws {
        let tmp = makeTempDir()
        let args = try CLI.standardArgs(tmp: tmp, roots: [tmp.path("does-not-exist")])
        let r = try CLI.run(args)
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.stderr.contains("not a directory"), r.stderr)
    }

    func testLockHeldExits2() throws {
        let tmp = makeTempDir()
        tmp.mkdir("root")
        let args = try CLI.standardArgs(tmp: tmp, roots: [realpathString(tmp.path("root"))])
        let held = try LockFile(url: URL(fileURLWithPath: tmp.path("data/scan.lock")))
        let r = try CLI.run(args)
        XCTAssertEqual(r.status, 2)
        XCTAssertTrue(r.stderr.contains("another scan is running"), r.stderr)
        _ = held
    }

    func testUnknownFlagExits1WithUsage() throws {
        let r = try CLI.run(["--bogus"])
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.stderr.contains("usage:"), r.stderr)
    }

    func testRunningScanFromPreviousCrashIsMarkedFailed() throws {
        let tmp = makeTempDir()
        tmp.mkdir("root")
        let root = realpathString(tmp.path("root"))
        let args = try CLI.standardArgs(tmp: tmp, roots: [root])
        do {
            let store = try Store(url: URL(fileURLWithPath: tmp.path("data/diskreport.sqlite")))
            _ = try store.beginScan(rootID: try store.rootID(for: root), startedAt: 1)
        }
        XCTAssertEqual(try CLI.run(args).status, 0)
        let store = try Store(url: URL(fileURLWithPath: tmp.path("data/diskreport.sqlite")))
        let scans = try store.scans(rootID: try store.rootID(for: root))
        XCTAssertEqual(scans.map(\.status), [.completed, .failed])
        XCTAssertEqual(scans[1].error, "interrupted")
    }
}
```

- [ ] **Step 6: Run to verify they fail**

Run: `swift test --filter ScannerCLITests 2>&1 | grep -E "Executed|error|failed" | head -5`
Expected: tests fail (placeholder binary exits 0 without writing anything); e.g. `XCTAssertTrue failed` on `status=completed`.

- [ ] **Step 7: Implement argument parsing and the self-test file**

`Sources/diskreport-scan/Arguments.swift`:
```swift
import Foundation

struct Arguments {
    var configPath: String?
    var dataDir: String?
    var logDir: String?
    var selfTestWrite: String?

    static let usage = """
    usage: diskreport-scan [--config PATH] [--data-dir PATH] [--log-dir PATH] [--self-test-write PATH]
      --config           config.json path (default: <data-dir>/config.json)
      --data-dir         database/lock directory (default: ~/Library/Application Support/DiskReport)
      --log-dir          log directory (default: ~/Library/Logs/DiskReport)
      --self-test-write  attempt to create PATH and exit: 0 if refused (sandbox works), 10 if it succeeded
    """

    enum ParseError: Error, CustomStringConvertible {
        case unknown(String)
        case missingValue(String)
        var description: String {
            switch self {
            case .unknown(let f): return "unknown argument: \(f)"
            case .missingValue(let f): return "missing value for \(f)"
            }
        }
    }

    static func parse(_ argv: [String]) throws -> Arguments {
        var a = Arguments()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < argv.count else { throw ParseError.missingValue(flag) }
            return argv[i]
        }
        while i < argv.count {
            let flag = argv[i]
            switch flag {
            case "--config": a.configPath = try value(flag)
            case "--data-dir": a.dataDir = try value(flag)
            case "--log-dir": a.logDir = try value(flag)
            case "--self-test-write": a.selfTestWrite = try value(flag)
            default: throw ParseError.unknown(flag)
            }
            i += 1
        }
        return a
    }
}
```

`Sources/diskreport-scan/SelfTestWrite.swift` (lint-exempt by file name; the only deliberate write outside Store/Logging):
```swift
import Darwin
import Foundation

/// Tries to create a file at `path`. Used by tests to prove the sandbox refuses writes into scanned roots.
/// Returns the process exit code: 0 when the write was refused, 10 when it succeeded.
func runSelfTestWrite(path: String) -> Int32 {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
    if fd >= 0 {
        close(fd)
        unlink(path)
        FileHandle.standardError.write(Data("self-test-write: SUCCEEDED at \(path) — sandbox is NOT enforcing\n".utf8))
        return 10
    }
    FileHandle.standardError.write(Data("self-test-write: refused (\(String(cString: strerror(errno))))\n".utf8))
    return 0
}
```

- [ ] **Step 8: Implement main.swift**

`Sources/diskreport-scan/main.swift`:
```swift
import Darwin
import DiskReportCore
import Foundation

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("diskreport-scan: \(message)\n".utf8))
    exit(code)
}

let args: Arguments
do {
    args = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("diskreport-scan: \(error)\n\(Arguments.usage)\n".utf8))
    exit(1)
}

if let target = args.selfTestWrite {
    exit(runSelfTestWrite(path: target))
}

guard getuid() != 0 else { fail("refusing to run as root", code: 3) }

// Be polite to the interactive user.
setpriority(PRIO_PROCESS, 0, 10)
setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_THROTTLE)

let standard = DataPaths.standard()
let paths = DataPaths(
    dataDir: args.dataDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? standard.dataDir,
    logDir: args.logDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? standard.logDir
)
do { try paths.ensureDirectoriesExist() } catch { fail("cannot create data/log directories: \(error)", code: 1) }

let logger: Logger
do { logger = try Logger(directory: paths.logDir) } catch { fail("cannot open log: \(error)", code: 1) }

let lock: LockFile
do {
    lock = try LockFile(url: paths.lockURL)
} catch LockFile.Error.alreadyHeld {
    fail("another scan is running (lock held: \(paths.lockURL.path))", code: 2)
} catch {
    fail("cannot open lock file: \(error)", code: 1)
}

let configURL = args.configPath.map { URL(fileURLWithPath: $0) } ?? paths.configURL
let config: Config
let roots: [String]
do {
    config = try Config.load(from: configURL)
    roots = try config.resolvedRoots()
} catch {
    logger.log("config error: \(error)")
    fail("\(error)", code: 1)
}

let store: Store
do { store = try Store(url: paths.databaseURL) } catch { fail("cannot open database: \(error)", code: 1) }

func now() -> Int64 { Int64(Date().timeIntervalSince1970) }

do {
    let stale = try store.failStaleRunningScans(now: now())
    if stale > 0 { logger.log("marked \(stale) interrupted scan(s) as failed") }
} catch {
    logger.log("warning: could not mark stale scans: \(error)")
}

var anyFailed = false
for root in roots {
    let started = now()
    let startDate = Date()
    var scanID: Int64 = -1
    do {
        let rootID = try store.rootID(for: root)
        scanID = try store.beginScan(rootID: rootID, startedAt: started)
        logger.log("scan \(scanID) start root=\(root)")

        let result = try Walker().walk(root: root)
        for s in result.skipped { logger.log("skipped \(s.path): \(s.reason)") }
        let volume = try VolumeInfo.query(path: root)
        try store.insertDirStats(scanID: scanID, result.stats)
        let summary = ScanSummary(totalBytes: result.totalBytes, fileCount: result.fileCount,
                                  dirCount: Int64(result.stats.count), volumeFreeBytes: volume.freeBytes,
                                  volumeTotalBytes: volume.totalBytes, skippedCount: Int64(result.skipped.count))
        try store.completeScan(id: scanID, finishedAt: now(), summary: summary)

        let duration = Int(Date().timeIntervalSince(startDate))
        let line = "root=\(root) status=completed total=\(summary.totalBytes) files=\(summary.fileCount) dirs=\(summary.dirCount) skipped=\(summary.skippedCount) duration=\(duration)s"
        logger.log(line)
        print("diskreport-scan: \(line)")

        let toDelete = RetentionPolicy.scansToDelete(try store.scans(rootID: rootID), now: now(), retention: config.retention)
        if !toDelete.isEmpty {
            try store.deleteScans(ids: toDelete)
            logger.log("pruned \(toDelete.count) old scan(s) for root=\(root)")
        }
    } catch {
        anyFailed = true
        let message = "\(error)"
        logger.log("scan \(scanID) FAILED root=\(root): \(message)")
        if scanID >= 0 { try? store.failScan(id: scanID, finishedAt: now(), error: message) }
        print("diskreport-scan: root=\(root) status=failed error=\(message)")
    }
}

print("diskreport-scan: done status=\(anyFailed ? "failed" : "ok")")
withExtendedLifetime(lock) {}
exit(anyFailed ? 4 : 0)
```

- [ ] **Step 9: Run all tests and lint**

Run: `Scripts/lint-readonly.sh && swift test 2>&1 | grep -E "Executed|error:|failed"`
Expected: `lint-readonly: ok` and `Executed N tests, with 0 failures` (N = all so far, 63).

If the lint flags `SelfTestWrite.swift`, confirm the grep exclusion in `Scripts/lint-readonly.sh` matches the file name exactly.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat(scan): logger, lock file, diskreport-scan CLI with exit codes"
```

---

### Task 9: Sandbox profile, launchd wrapper, read-only verification tests

**Files:**
- Create: `Resources/scan.sb`
- Create: `Resources/run-scan.sh`
- Create: `Resources/com.andyfloyd.diskreport.scan.plist`
- Create: `Tests/DiskReportCoreTests/SandboxTests.swift`

**Interfaces:**
- Consumes: built `diskreport-scan` binary and `CLI` helpers (Task 8).
- Produces: `Resources/scan.sb` taking params `DATA_DIR` and `LOG_DIR`; `Resources/run-scan.sh` (used by launchd in Task 14); the launchd plist template with `__HOME__` placeholders.

- [ ] **Step 1: Write the sandbox profile**

`Resources/scan.sb`:
```scheme
;; DiskReport scanner sandbox.
;; Read anywhere; write only under the DiskReport data and log folders (and /dev/null); no network.
;; Usage: sandbox-exec -D DATA_DIR=<path> -D LOG_DIR=<path> -f scan.sb diskreport-scan ...
(version 1)
(allow default)
(deny network*)
(deny file-write*)
(allow file-write* (subpath (param "DATA_DIR")))
(allow file-write* (subpath (param "LOG_DIR")))
(allow file-write-data (literal "/dev/null"))
```

- [ ] **Step 2: Write the launchd wrapper and plist template**

`Resources/run-scan.sh`:
```sh
#!/bin/sh
# launchd entry point: run the sandboxed scan, then bring the app forward regardless of outcome.
DATA_DIR="$HOME/Library/Application Support/DiskReport"
LOG_DIR="$HOME/Library/Logs/DiskReport"
mkdir -p "$LOG_DIR"

/usr/bin/sandbox-exec -D "DATA_DIR=$DATA_DIR" -D "LOG_DIR=$LOG_DIR" -f "$DATA_DIR/bin/scan.sb" \
  "$DATA_DIR/bin/diskreport-scan" --data-dir "$DATA_DIR" --log-dir "$LOG_DIR"
status=$?

/usr/bin/open -a "$HOME/Applications/DiskReport.app" --args --show-report
exit $status
```

`Resources/com.andyfloyd.diskreport.scan.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.andyfloyd.diskreport.scan</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>__HOME__/Library/Application Support/DiskReport/bin/run-scan.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>7</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
  <key>Nice</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>__HOME__/Library/Logs/DiskReport/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>__HOME__/Library/Logs/DiskReport/launchd.err.log</string>
</dict>
</plist>
```

Run: `plutil -lint Resources/com.andyfloyd.diskreport.scan.plist`
Expected: `Resources/com.andyfloyd.diskreport.scan.plist: OK`

- [ ] **Step 3: Write the sandbox tests**

`Tests/DiskReportCoreTests/SandboxTests.swift`:
```swift
import Darwin
import XCTest
@testable import DiskReportCore

/// Runs the real scanner binary under the real sandbox profile and proves nothing under the root changed.
final class SandboxTests: XCTestCase {
    private var profileURL: URL { CLI.packageRoot.appendingPathComponent("Resources/scan.sb") }

    private func sandboxedArgs(tmp: TempDir, scannerArgs: [String]) -> [String] {
        ["-D", "DATA_DIR=\(realpathString(tmp.path("data")))", "-D", "LOG_DIR=\(realpathString(tmp.path("logs")))",
         "-f", profileURL.path, CLI.scannerURL.path] + scannerArgs
    }

    struct Entry: Equatable {
        let path: String, size: Int64, mtime: Int64, mtimeNs: Int, ctime: Int64, ctimeNs: Int
        let inode: UInt64, mode: UInt16, nlink: UInt16, atime: Int64?
    }

    /// Full metadata manifest of a tree. Includes atime only when the volume preserves it on directory reads.
    private func manifest(_ root: String, includeAtime: Bool) throws -> [Entry] {
        var entries: [Entry] = []
        let e = FileManager.default.enumerator(atPath: root)!
        var paths = [root]
        while let rel = e.nextObject() as? String { paths.append(root + "/" + rel) }
        for p in paths.sorted() {
            var st = stat()
            XCTAssertEqual(lstat(p, &st), 0, "lstat \(p)")
            entries.append(Entry(path: p, size: Int64(st.st_size), mtime: Int64(st.st_mtimespec.tv_sec), mtimeNs: st.st_mtimespec.tv_nsec,
                                 ctime: Int64(st.st_ctimespec.tv_sec), ctimeNs: st.st_ctimespec.tv_nsec,
                                 inode: st.st_ino, mode: st.st_mode, nlink: st.st_nlink,
                                 atime: includeAtime ? Int64(st.st_atimespec.tv_sec) : nil))
        }
        return entries
    }

    /// Probes whether listing a directory changes its atime on this volume.
    private func volumePreservesAtime(_ tmp: TempDir) -> Bool {
        let probe = tmp.mkdir("probe")
        tmp.file("probe/f")
        var before = stat(); lstat(probe, &before)
        Thread.sleep(forTimeInterval: 1.1)
        _ = try? FileManager.default.contentsOfDirectory(atPath: probe)
        var after = stat(); lstat(probe, &after)
        return before.st_atimespec.tv_sec == after.st_atimespec.tv_sec
    }

    func testSandboxedScanLeavesRootMetadataUntouched() throws {
        let tmp = makeTempDir()
        tmp.file("root/a/one.bin", size: 8192)
        tmp.file("root/a/b/two.bin", size: 100)
        tmp.file("root/c/three.txt", size: 10)
        tmp.mkdir("root/empty")
        try FileManager.default.createSymbolicLink(atPath: tmp.path("root/link"), withDestinationPath: tmp.path("root/a"))
        let root = realpathString(tmp.path("root"))
        let includeAtime = volumePreservesAtime(tmp)
        let scannerArgs = try CLI.standardArgs(tmp: tmp, roots: [root])
        Thread.sleep(forTimeInterval: 1.1) // so any accidental touch would move a second-resolution timestamp

        let before = try manifest(root, includeAtime: includeAtime)
        let r = try CLI.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), sandboxedArgs(tmp: tmp, scannerArgs: scannerArgs))
        let after = try manifest(root, includeAtime: includeAtime)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(before, after, "scanner changed something under the root")
        let store = try Store(url: URL(fileURLWithPath: tmp.path("data/diskreport.sqlite")))
        XCTAssertNotNil(try store.latestCompletedScan(rootID: try store.rootID(for: root)))
    }

    func testSandboxRefusesWriteIntoRoot() throws {
        let tmp = makeTempDir()
        tmp.mkdir("root"); tmp.mkdir("data"); tmp.mkdir("logs")
        let target = realpathString(tmp.path("root")) + "/evil.txt"
        let r = try CLI.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                            sandboxedArgs(tmp: tmp, scannerArgs: ["--self-test-write", target]))
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertTrue(r.stderr.contains("refused"), r.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    func testSandboxAllowsWriteIntoDataDir() throws {
        let tmp = makeTempDir()
        tmp.mkdir("data"); tmp.mkdir("logs")
        let target = realpathString(tmp.path("data")) + "/probe.txt"
        let r = try CLI.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                            sandboxedArgs(tmp: tmp, scannerArgs: ["--self-test-write", target]))
        XCTAssertEqual(r.status, 10, "write inside DATA_DIR must be allowed; stderr: \(r.stderr)")
    }

    func testSelfTestWriteSucceedsWithoutSandbox() throws {
        // Proves the self-test is meaningful: unsandboxed, the write goes through.
        let tmp = makeTempDir()
        tmp.mkdir("root")
        let target = realpathString(tmp.path("root")) + "/evil.txt"
        let r = try CLI.run(["--self-test-write", target])
        XCTAssertEqual(r.status, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "self-test cleans up after itself")
    }
}
```

- [ ] **Step 4: Run the sandbox tests**

Run: `swift test --filter SandboxTests 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 4 tests, with 0 failures`

If `testSandboxedScanLeavesRootMetadataUntouched` fails only on `ctime`/`atime` of the temp root itself, check the fixture's temp location is on the same APFS volume as the data dir and that `Thread.sleep` ran before the manifest; do not weaken the assertion.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(scan): sandbox profile, launchd wrapper, read-only verification tests"
```

---

### Task 10: UI library: tree nodes, tree builder, expansion and flattening

**Files:**
- Replace: `Sources/DiskReportUI/DirNode.swift`
- Create: `Sources/DiskReportUI/TreeBuilder.swift`
- Create: `Sources/DiskReportUI/QuickFilter.swift`
- Create: `Sources/DiskReportUI/ReportViewModel.swift`
- Create: `Tests/DiskReportUITests/TestSupport.swift`
- Create: `Tests/DiskReportUITests/TreeBuilderTests.swift`
- Create: `Tests/DiskReportUITests/ReportViewModelTests.swift`
- Delete: `Tests/DiskReportUITests/PackageSmokeUITests.swift`

**Interfaces:**
- Consumes: `RootReport`, `ReportRow`, `Delta`, `Window`, `StalenessBucket` (Task 6).
- Produces:
  - `public final class DirNode: Identifiable { id: String (path), name: String, row: ReportRow, children: [DirNode], weak parent: DirNode?; init(row: ReportRow, name: String); func add(child:) }`
  - `public enum TreeBuilder { static func build(_ reports: [RootReport]) -> [DirNode] }` (one root node per report that has rows; children sorted by name)
  - `public enum QuickFilter: String, CaseIterable, Identifiable, Sendable { all, grewToday, grewThisWeek, new, deleted, staleMonth, staleSixMonths; func matches(_ row: ReportRow, now: Int64) -> Bool; var title: String }`
  - `public enum SortKey: Equatable, Sendable { name, bytes, deltaDay, deltaWeek, deltaMonth, mtime, files }`
  - `public struct VisibleRow: Identifiable, Equatable { id: String, name, depth: Int, hasChildren, isExpanded, isDeleted: Bool, bytes, fileCount, newestMtime: Int64, deltaDay, deltaWeek, deltaMonth: Delta, kind: String?, deltaDaySort, deltaWeekSort, deltaMonthSort: Int64 }`
  - `@MainActor public final class ReportViewModel: ObservableObject { @Published visibleRows: [VisibleRow]; @Published filter: QuickFilter; @Published searchText: String; @Published sortKey: SortKey; @Published sortAscending: Bool; now: Int64; roots: [DirNode]; static let defaultVisibleDepth = 3; func load(reports: [RootReport], now: Int64); func toggle(_ id: String); func isExpanded(_ id: String) -> Bool; func setSort(key: SortKey, ascending: Bool) }`

- [ ] **Step 1: Write failing tests**

`Tests/DiskReportUITests/TestSupport.swift`:
```swift
import DiskReportCore
@testable import DiskReportUI

enum Fx {
    static let day: Int64 = 86_400
    static let now: Int64 = 1_800_000_000

    static func row(_ path: String, bytes: Int64 = 10, files: Int64 = 1, mtime: Int64 = now,
                    day: Delta = .noData, week: Delta = .noData, month: Delta = .noData,
                    deleted: Bool = false, kind: String? = nil) -> ReportRow {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        let depth = max(0, comps.count - 1)
        let parent = depth == 0 ? nil : "/" + comps.dropLast().joined(separator: "/")
        return ReportRow(path: path, parentPath: parent, depth: depth, bytes: bytes, fileCount: files, newestMtime: mtime,
                         kind: kind, deltas: [.day: day, .week: week, .month: month], isDeleted: deleted)
    }

    static func report(_ rootPath: String, rows: [ReportRow]) -> RootReport {
        let current = ScanRecord(id: 1, rootID: 1, startedAt: now - 60, finishedAt: now, status: .completed, totalBytes: rows.first?.bytes)
        return RootReport(rootID: 1, rootPath: rootPath, current: current, latest: current, baselines: [:], rows: rows)
    }

    /// A tree 5 levels deep: /w, /w/a, /w/a/b, /w/a/b/c, /w/a/b/c/d, plus /w/x.
    static func deepReport() -> RootReport {
        report("/w", rows: [
            row("/w", bytes: 100), row("/w/a", bytes: 60), row("/w/a/b", bytes: 50), row("/w/a/b/c", bytes: 40),
            row("/w/a/b/c/d", bytes: 30), row("/w/x", bytes: 40),
        ])
    }
}
```

`Tests/DiskReportUITests/TreeBuilderTests.swift`:
```swift
import XCTest
import DiskReportCore
@testable import DiskReportUI

final class TreeBuilderTests: XCTestCase {
    func testBuildsOneTreePerRootWithChildrenSortedByName() {
        let r1 = Fx.report("/w", rows: [Fx.row("/w"), Fx.row("/w/zeta"), Fx.row("/w/alpha"), Fx.row("/w/alpha/inner")])
        let r2 = Fx.report("/other", rows: [Fx.row("/other")])
        let roots = TreeBuilder.build([r1, r2])

        XCTAssertEqual(roots.map(\.id), ["/w", "/other"])
        XCTAssertEqual(roots[0].name, "/w", "root nodes show the full path")
        XCTAssertEqual(roots[0].children.map(\.name), ["alpha", "zeta"])
        XCTAssertEqual(roots[0].children[0].children.map(\.id), ["/w/alpha/inner"])
        XCTAssertTrue(roots[0].children[0].children[0].parent === roots[0].children[0])
    }

    func testReportWithoutRowsProducesNoTree() {
        let empty = RootReport(rootID: 1, rootPath: "/w", current: nil, latest: nil, baselines: [:], rows: [])
        XCTAssertTrue(TreeBuilder.build([empty]).isEmpty)
    }

    func testDeletedRowsAttachToParent() {
        let r = Fx.report("/w", rows: [Fx.row("/w"), Fx.row("/w/gone", day: .changed(-5), deleted: true)])
        let roots = TreeBuilder.build([r])
        XCTAssertEqual(roots[0].children.map(\.id), ["/w/gone"])
        XCTAssertTrue(roots[0].children[0].row.isDeleted)
    }
}
```

`Tests/DiskReportUITests/ReportViewModelTests.swift`:
```swift
import XCTest
import DiskReportCore
@testable import DiskReportUI

@MainActor
final class ReportViewModelTests: XCTestCase {
    func testDefaultExpansionShowsThreeLevels() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.deepReport()], now: Fx.now)
        XCTAssertEqual(vm.visibleRows.map(\.id), ["/w", "/w/a", "/w/a/b", "/w/a/b/c", "/w/x"])
        XCTAssertEqual(vm.visibleRows.map(\.depth), [0, 1, 2, 3, 1])
        XCTAssertTrue(vm.visibleRows[2].isExpanded)
        XCTAssertFalse(vm.visibleRows[3].isExpanded)
        XCTAssertTrue(vm.visibleRows[3].hasChildren)
        XCTAssertFalse(vm.visibleRows[4].hasChildren)
    }

    func testToggleExpandsAndCollapses() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.deepReport()], now: Fx.now)
        vm.toggle("/w/a/b/c")
        XCTAssertTrue(vm.visibleRows.map(\.id).contains("/w/a/b/c/d"))
        vm.toggle("/w/a")
        XCTAssertEqual(vm.visibleRows.map(\.id), ["/w", "/w/a", "/w/x"])
        XCTAssertFalse(vm.isExpanded("/w/a"))
        vm.toggle("/w/a")
        XCTAssertTrue(vm.visibleRows.map(\.id).contains("/w/a/b/c/d"), "nested expansion state is remembered")
    }

    func testMultipleRootsAreListedInOrder() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.report("/b", rows: [Fx.row("/b")]), Fx.report("/a", rows: [Fx.row("/a")])], now: Fx.now)
        XCTAssertEqual(vm.visibleRows.map(\.id), ["/b", "/a"])
    }

    func testNameOfRootIsFullPathAndChildrenAreLastComponent() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.deepReport()], now: Fx.now)
        XCTAssertEqual(vm.visibleRows[0].name, "/w")
        XCTAssertEqual(vm.visibleRows[1].name, "a")
    }

    func testSortByBytesDescendingWithinSiblings() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.report("/w", rows: [Fx.row("/w", bytes: 100), Fx.row("/w/small", bytes: 1), Fx.row("/w/big", bytes: 90), Fx.row("/w/mid", bytes: 9)])], now: Fx.now)
        vm.setSort(key: .bytes, ascending: false)
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "big", "mid", "small"])
        vm.setSort(key: .bytes, ascending: true)
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "small", "mid", "big"])
    }

    func testSortByDeltaPutsNoDataLast() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.report("/w", rows: [Fx.row("/w"), Fx.row("/w/a", day: .noData), Fx.row("/w/b", day: .changed(5)), Fx.row("/w/c", day: .new(3))])], now: Fx.now)
        vm.setSort(key: .deltaDay, ascending: false)
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "b", "c", "a"])
    }

    func testSortByNameIsCaseInsensitive() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.report("/w", rows: [Fx.row("/w"), Fx.row("/w/b"), Fx.row("/w/A"), Fx.row("/w/c")])], now: Fx.now)
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "A", "b", "c"])
    }

    func testFilterGrewTodayShowsMatchesAndAutoExpandsAncestors() {
        let vm = ReportViewModel()
        let rows = [
            Fx.row("/w", day: .changed(10)), Fx.row("/w/a", day: .changed(0)), Fx.row("/w/a/b", day: .changed(0)),
            Fx.row("/w/a/b/c", day: .changed(0)), Fx.row("/w/a/b/c/d", day: .changed(10)), Fx.row("/w/x", day: .changed(-3)),
            Fx.row("/w/y", day: .new(2)),
        ]
        vm.load(reports: [Fx.report("/w", rows: rows)], now: Fx.now)
        vm.filter = .grewToday
        XCTAssertEqual(vm.visibleRows.map(\.id), ["/w", "/w/a", "/w/a/b", "/w/a/b/c", "/w/a/b/c/d", "/w/y"],
                       "ancestors of matches shown and expanded even beyond depth 3; shrinking /w/x hidden; new counts as grew")
        vm.filter = .all
        XCTAssertEqual(vm.visibleRows.map(\.id), ["/w", "/w/a", "/w/a/b", "/w/a/b/c", "/w/x", "/w/y"], "user expansion state unchanged by filtering")
    }

    func testFilterStaleBuckets() {
        let vm = ReportViewModel()
        let rows = [
            Fx.row("/w", mtime: Fx.now), Fx.row("/w/fresh", mtime: Fx.now - 2 * Fx.day),
            Fx.row("/w/month", mtime: Fx.now - 40 * Fx.day), Fx.row("/w/ancient", mtime: Fx.now - 400 * Fx.day),
        ]
        vm.load(reports: [Fx.report("/w", rows: rows)], now: Fx.now)
        vm.filter = .staleMonth
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "ancient", "month"])
        vm.filter = .staleSixMonths
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "ancient"])
    }

    func testFilterDeletedAndNew() {
        let vm = ReportViewModel()
        let rows = [Fx.row("/w"), Fx.row("/w/gone", day: .changed(-5), deleted: true), Fx.row("/w/fresh", day: .new(5)), Fx.row("/w/same", day: .changed(0))]
        vm.load(reports: [Fx.report("/w", rows: rows)], now: Fx.now)
        vm.filter = .deleted
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "gone"])
        XCTAssertTrue(vm.visibleRows[1].isDeleted)
        vm.filter = .new
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "fresh"])
    }

    func testSearchMatchesPathSubstringCaseInsensitively() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.deepReport()], now: Fx.now)
        vm.searchText = "C/D"
        XCTAssertEqual(vm.visibleRows.map(\.id), ["/w", "/w/a", "/w/a/b", "/w/a/b/c", "/w/a/b/c/d"])
        vm.searchText = ""
        XCTAssertEqual(vm.visibleRows.count, 5)
    }

    func testVisibleRowCarriesDeltasAndSortKeys() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.report("/w", rows: [Fx.row("/w", bytes: 7, files: 3, day: .changed(-2), week: .new(7), month: .noData)])], now: Fx.now)
        let r = vm.visibleRows[0]
        XCTAssertEqual(r.bytes, 7)
        XCTAssertEqual(r.fileCount, 3)
        XCTAssertEqual(r.deltaDay, .changed(-2))
        XCTAssertEqual(r.deltaWeek, .new(7))
        XCTAssertEqual(r.deltaMonth, .noData)
        XCTAssertEqual(r.deltaDaySort, -2)
        XCTAssertEqual(r.deltaWeekSort, 7)
        XCTAssertEqual(r.deltaMonthSort, Int64.min)
    }

    func testLoadResetsExpansionState() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.deepReport()], now: Fx.now)
        vm.toggle("/w/a")
        vm.load(reports: [Fx.deepReport()], now: Fx.now)
        XCTAssertEqual(vm.visibleRows.count, 5)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "TreeBuilderTests|ReportViewModelTests" 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'TreeBuilder' in scope`

- [ ] **Step 3: Implement DirNode and TreeBuilder**

`Sources/DiskReportUI/DirNode.swift`:
```swift
import DiskReportCore

public final class DirNode: Identifiable {
    public let id: String
    public let name: String
    public let row: ReportRow
    public private(set) var children: [DirNode] = []
    public private(set) weak var parent: DirNode?

    public init(row: ReportRow, name: String) {
        self.id = row.path
        self.name = name
        self.row = row
    }

    public func add(child: DirNode) {
        child.parent = self
        children.append(child)
    }

    func sortChildrenRecursively(by areInIncreasingOrder: (DirNode, DirNode) -> Bool) {
        children.sort(by: areInIncreasingOrder)
        for c in children { c.sortChildrenRecursively(by: areInIncreasingOrder) }
    }
}
```

`Sources/DiskReportUI/TreeBuilder.swift`:
```swift
import DiskReportCore
import Foundation

public enum TreeBuilder {
    /// One tree per report that has rows. Root nodes are named by full path, children by last path component.
    public static func build(_ reports: [RootReport]) -> [DirNode] {
        reports.compactMap { report in
            guard !report.rows.isEmpty else { return nil }
            var nodes: [String: DirNode] = [:]
            nodes.reserveCapacity(report.rows.count)
            for row in report.rows {
                let name = row.parentPath == nil ? row.path : (row.path as NSString).lastPathComponent
                nodes[row.path] = DirNode(row: row, name: name)
            }
            var root: DirNode?
            for row in report.rows {
                let node = nodes[row.path]!
                if let parentPath = row.parentPath, let parent = nodes[parentPath] {
                    parent.add(child: node)
                } else if row.parentPath == nil {
                    root = node
                }
            }
            guard let root else { return nil }
            root.sortChildrenRecursively { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return root
        }
    }
}
```

- [ ] **Step 4: Implement QuickFilter**

`Sources/DiskReportUI/QuickFilter.swift`:
```swift
import DiskReportCore

public enum QuickFilter: String, CaseIterable, Identifiable, Sendable {
    case all, grewToday, grewThisWeek, new, deleted, staleMonth, staleSixMonths

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .grewToday: return "Grew today"
        case .grewThisWeek: return "Grew this week"
        case .new: return "New"
        case .deleted: return "Deleted"
        case .staleMonth: return "Stale > 1 month"
        case .staleSixMonths: return "Stale > 6 months"
        }
    }

    public func matches(_ row: ReportRow, now: Int64) -> Bool {
        switch self {
        case .all:
            return true
        case .grewToday:
            return !row.isDeleted && (row.deltas[.day]?.bytes ?? 0) > 0
        case .grewThisWeek:
            return !row.isDeleted && (row.deltas[.week]?.bytes ?? 0) > 0
        case .new:
            if case .new = row.deltas[.day] ?? .noData { return true }
            return false
        case .deleted:
            return row.isDeleted
        case .staleMonth:
            let b = StalenessBucket.bucket(newestMtime: row.newestMtime, now: now)
            return !row.isDeleted && (b == .sixMonths || b == .older)
        case .staleSixMonths:
            return !row.isDeleted && StalenessBucket.bucket(newestMtime: row.newestMtime, now: now) == .older
        }
    }
}
```

- [ ] **Step 5: Implement ReportViewModel**

`Sources/DiskReportUI/ReportViewModel.swift`:
```swift
import Combine
import DiskReportCore
import Foundation

public enum SortKey: Equatable, Sendable {
    case name, bytes, deltaDay, deltaWeek, deltaMonth, mtime, files
}

/// One row of the flattened, filtered, sorted table.
public struct VisibleRow: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let depth: Int
    public let hasChildren: Bool
    public let isExpanded: Bool
    public let isDeleted: Bool
    public let bytes: Int64
    public let fileCount: Int64
    public let newestMtime: Int64
    public let deltaDay: Delta
    public let deltaWeek: Delta
    public let deltaMonth: Delta
    public let kind: String?

    /// Sort keys: `.noData` sorts below every real value.
    public var deltaDaySort: Int64 { deltaDay.bytes ?? Int64.min }
    public var deltaWeekSort: Int64 { deltaWeek.bytes ?? Int64.min }
    public var deltaMonthSort: Int64 { deltaMonth.bytes ?? Int64.min }

    init(node: DirNode, isExpanded: Bool) {
        let r = node.row
        id = node.id
        name = node.name
        depth = r.depth
        hasChildren = !node.children.isEmpty
        self.isExpanded = isExpanded
        isDeleted = r.isDeleted
        bytes = r.bytes
        fileCount = r.fileCount
        newestMtime = r.newestMtime
        deltaDay = r.deltas[.day] ?? .noData
        deltaWeek = r.deltas[.week] ?? .noData
        deltaMonth = r.deltas[.month] ?? .noData
        kind = r.kind
    }
}

@MainActor
public final class ReportViewModel: ObservableObject {
    /// Rows with depth <= this are visible by default (root is depth 0).
    public static let defaultVisibleDepth = 3

    @Published public private(set) var visibleRows: [VisibleRow] = []
    @Published public var filter: QuickFilter = .all { didSet { rebuild() } }
    @Published public var searchText: String = "" { didSet { rebuild() } }
    @Published public private(set) var sortKey: SortKey = .name
    @Published public private(set) var sortAscending: Bool = true

    public private(set) var roots: [DirNode] = []
    public private(set) var now: Int64 = 0
    private var expanded: Set<String> = []

    public init() {}

    public func load(reports: [RootReport], now: Int64) {
        roots = TreeBuilder.build(reports)
        self.now = now
        expanded = []
        for root in roots { expandDefault(root) }
        rebuild()
    }

    public func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        rebuild()
    }

    public func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    public func setSort(key: SortKey, ascending: Bool) {
        sortKey = key
        sortAscending = ascending
        rebuild()
    }

    // MARK: - Internals

    private func expandDefault(_ node: DirNode) {
        guard node.row.depth < Self.defaultVisibleDepth, !node.children.isEmpty else { return }
        expanded.insert(node.id)
        for c in node.children { expandDefault(c) }
    }

    private var isFiltering: Bool { filter != .all || !searchText.isEmpty }

    private func matches(_ node: DirNode) -> Bool {
        guard filter.matches(node.row, now: now) else { return false }
        return searchText.isEmpty || node.row.path.localizedCaseInsensitiveContains(searchText)
    }

    /// Whether the node or any descendant matches. Memoized per rebuild.
    private func hasMatch(_ node: DirNode, cache: inout [String: Bool]) -> Bool {
        if let cached = cache[node.id] { return cached }
        var result = matches(node)
        if !result {
            for c in node.children where hasMatch(c, cache: &cache) { result = true; break }
        }
        cache[node.id] = result
        return result
    }

    private func comparator() -> (DirNode, DirNode) -> Bool {
        let asc = sortAscending
        func byName(_ a: DirNode, _ b: DirNode) -> Bool {
            a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        func numeric(_ key: @escaping (DirNode) -> Int64) -> (DirNode, DirNode) -> Bool {
            return { a, b in
                let ka = key(a), kb = key(b)
                if ka == kb { return byName(a, b) }
                return asc ? ka < kb : ka > kb
            }
        }
        switch sortKey {
        case .name: return { a, b in asc ? byName(a, b) : byName(b, a) }
        case .bytes: return numeric { $0.row.bytes }
        case .files: return numeric { $0.row.fileCount }
        case .mtime: return numeric { $0.row.newestMtime }
        case .deltaDay: return numeric { $0.row.deltas[.day]?.bytes ?? Int64.min }
        case .deltaWeek: return numeric { $0.row.deltas[.week]?.bytes ?? Int64.min }
        case .deltaMonth: return numeric { $0.row.deltas[.month]?.bytes ?? Int64.min }
        }
    }

    private func rebuild() {
        var out: [VisibleRow] = []
        var cache: [String: Bool] = [:]
        let less = comparator()
        let filtering = isFiltering

        func visit(_ node: DirNode) {
            if filtering && !hasMatch(node, cache: &cache) { return }
            let shownChildren = node.children.filter { !filtering || hasMatch($0, cache: &cache) }
            let childHasMatch = filtering && shownChildren.contains { hasMatch($0, cache: &cache) }
            let open = !shownChildren.isEmpty && (expanded.contains(node.id) || childHasMatch)
            out.append(VisibleRow(node: node, isExpanded: open))
            guard open else { return }
            for c in shownChildren.sorted(by: less) { visit(c) }
        }
        for root in roots { visit(root) }
        visibleRows = out
    }
}
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter "TreeBuilderTests|ReportViewModelTests" 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 16 tests, with 0 failures`

Note on `testDefaultExpansionShowsThreeLevels`: `/w/a/b/c` (depth 3) is visible but not expanded because only nodes with depth < 3 are expanded by default; `isExpanded` on `/w/a/b` (depth 2) is true.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(ui): tree builder, quick filters, report view model with expansion/sort/filter"
```

---

### Task 11: UI library: formatting, reveal target, banner, sort-key mapping

**Files:**
- Create: `Sources/DiskReportUI/Formatting.swift`
- Create: `Sources/DiskReportUI/RevealTarget.swift`
- Create: `Sources/DiskReportUI/BannerState.swift`
- Create: `Sources/DiskReportUI/SortKey+KeyPath.swift`
- Create: `Tests/DiskReportUITests/FormattingTests.swift`
- Create: `Tests/DiskReportUITests/RevealTargetTests.swift`
- Create: `Tests/DiskReportUITests/BannerStateTests.swift`
- Create: `Tests/DiskReportUITests/SortKeyTests.swift`

**Interfaces:**
- Consumes: `Delta`, `RootReport`, `VisibleRow`, `SortKey`.
- Produces:
  - `public enum ByteFormatter { static func string(_ bytes: Int64) -> String }` base-1000, e.g. `0 B`, `999 B`, `1.0 KB`, `12.3 MB`, `345 MB`, `1.2 GB`, `-1.2 GB`. Unit promotion and the one-decimal rule are decided on the rounded value (promote at >= 999.95, one decimal below 99.95) so 999_950 B is `1.0 MB` and 99_950 B is `100 KB`.
  - `public enum DeltaFormatter { static func string(_ delta: Delta) -> String }`: `—` for noData, `+1.2 GB (new)`, `+340 MB`, `-12 MB`, `0 B` for unchanged
  - `public enum DateFormatting { static func relative(mtime: Int64, now: Int64) -> String; static func absolute(_ t: Int64) -> String }`
  - `public enum RevealTarget { static func url(forFolder path: String) -> URL }`
  - `public enum BannerState { static func message(reports: [RootReport], now: Int64, staleAfter: Int64 = 172_800) -> String? }`. Severity is evaluated across all roots: any failed root first, then any root without a completed scan, then any stale root.
  - `public extension SortKey { init?(keyPath: PartialKeyPath<VisibleRow>) }`

- [ ] **Step 1: Write failing tests**

`Tests/DiskReportUITests/FormattingTests.swift`:
```swift
import XCTest
import DiskReportCore
@testable import DiskReportUI

final class FormattingTests: XCTestCase {
    func testByteFormatterBase1000() {
        XCTAssertEqual(ByteFormatter.string(0), "0 B")
        XCTAssertEqual(ByteFormatter.string(999), "999 B")
        XCTAssertEqual(ByteFormatter.string(1000), "1.0 KB")
        XCTAssertEqual(ByteFormatter.string(12_345_678), "12.3 MB")
        XCTAssertEqual(ByteFormatter.string(345_000_000), "345 MB")
        XCTAssertEqual(ByteFormatter.string(1_234_567_890), "1.2 GB")
        XCTAssertEqual(ByteFormatter.string(95_000_000_000), "95.0 GB")
        XCTAssertEqual(ByteFormatter.string(1_500_000_000_000), "1.5 TB")
        XCTAssertEqual(ByteFormatter.string(-1_234_567_890), "-1.2 GB")
    }

    func testDeltaFormatter() {
        XCTAssertEqual(DeltaFormatter.string(.noData), "—")
        XCTAssertEqual(DeltaFormatter.string(.changed(0)), "0 B")
        XCTAssertEqual(DeltaFormatter.string(.changed(340_000_000)), "+340 MB")
        XCTAssertEqual(DeltaFormatter.string(.changed(-12_000_000)), "-12.0 MB")
        XCTAssertEqual(DeltaFormatter.string(.new(1_200_000_000)), "+1.2 GB (new)")
    }

    func testRelativeDates() {
        let now: Int64 = 1_800_000_000
        let day: Int64 = 86_400
        XCTAssertEqual(DateFormatting.relative(mtime: now, now: now), "today")
        XCTAssertEqual(DateFormatting.relative(mtime: now - 3600, now: now), "today")
        XCTAssertEqual(DateFormatting.relative(mtime: now - day, now: now), "yesterday")
        XCTAssertEqual(DateFormatting.relative(mtime: now - 5 * day, now: now), "5 days ago")
        XCTAssertEqual(DateFormatting.relative(mtime: now - 20 * day, now: now), "2 weeks ago")
        XCTAssertEqual(DateFormatting.relative(mtime: now - 100 * day, now: now), "3 months ago")
        XCTAssertEqual(DateFormatting.relative(mtime: now - 800 * day, now: now), "2 years ago")
        XCTAssertEqual(DateFormatting.relative(mtime: now + day, now: now), "today")
    }

    func testAbsoluteDateIsISODay() {
        let t = Int64(ISO8601DateFormatter().date(from: "2026-09-07T07:00:00Z")!.timeIntervalSince1970)
        XCTAssertEqual(DateFormatting.absolute(t, timeZone: TimeZone(identifier: "UTC")!), "2026-09-07")
    }
}
```

`Tests/DiskReportUITests/RevealTargetTests.swift`:
```swift
import XCTest
@testable import DiskReportUI

final class RevealTargetTests: XCTestCase {
    func testURLIsTheFolderItselfNotParentOrChild() {
        let url = RevealTarget.url(forFolder: "/Users/x/Workspace/proj")
        XCTAssertEqual(url.path, "/Users/x/Workspace/proj")
        XCTAssertTrue(url.hasDirectoryPath)
        XCTAssertTrue(url.isFileURL)
        XCTAssertNotEqual(url.path, "/Users/x/Workspace")
    }
}
```

`Tests/DiskReportUITests/BannerStateTests.swift`:
```swift
import XCTest
import DiskReportCore
@testable import DiskReportUI

final class BannerStateTests: XCTestCase {
    private let now: Int64 = 1_800_000_000

    private func rec(_ id: Int64, status: ScanStatus, finishedAt: Int64?, error: String? = nil) -> ScanRecord {
        ScanRecord(id: id, rootID: 1, startedAt: 0, finishedAt: finishedAt, status: status, error: error)
    }

    func testNoRoots() {
        XCTAssertEqual(BannerState.message(reports: [], now: now), "No roots configured. Edit config.json and run Scan Now.")
    }

    func testFirstScanPending() {
        let r = RootReport(rootID: 1, rootPath: "/w", current: nil, latest: nil, baselines: [:], rows: [])
        XCTAssertEqual(BannerState.message(reports: [r], now: now), "First scan pending. Click Scan Now.")
    }

    func testRunningFirstScanIsAlsoPending() {
        let r = RootReport(rootID: 1, rootPath: "/w", current: nil, latest: rec(1, status: .running, finishedAt: nil), baselines: [:], rows: [])
        XCTAssertEqual(BannerState.message(reports: [r], now: now), "First scan pending. Click Scan Now.")
    }

    func testFailedLatestScan() {
        let cur = rec(1, status: .completed, finishedAt: now - 3600)
        let r = RootReport(rootID: 1, rootPath: "/w", current: cur, latest: rec(2, status: .failed, finishedAt: now, error: "boom"), baselines: [:], rows: [])
        XCTAssertEqual(BannerState.message(reports: [r], now: now), "Last scan of /w failed: boom")
    }

    func testStaleScan() {
        let cur = rec(1, status: .completed, finishedAt: now - 3 * 86_400)
        let r = RootReport(rootID: 1, rootPath: "/w", current: cur, latest: cur, baselines: [:], rows: [])
        XCTAssertEqual(BannerState.message(reports: [r], now: now), "Last completed scan of /w is older than 48 hours.")
    }

    func testHealthyReportHasNoBanner() {
        let cur = rec(1, status: .completed, finishedAt: now - 3600)
        let r = RootReport(rootID: 1, rootPath: "/w", current: cur, latest: cur, baselines: [:], rows: [])
        XCTAssertNil(BannerState.message(reports: [r], now: now))
    }

    func testRunningScanOverHealthyReportHasNoBanner() {
        let cur = rec(1, status: .completed, finishedAt: now - 3600)
        let r = RootReport(rootID: 1, rootPath: "/w", current: cur, latest: rec(2, status: .running, finishedAt: nil), baselines: [:], rows: [])
        XCTAssertNil(BannerState.message(reports: [r], now: now))
    }
}
```

`Tests/DiskReportUITests/SortKeyTests.swift`:
```swift
import XCTest
@testable import DiskReportUI

final class SortKeyTests: XCTestCase {
    func testKeyPathMapping() {
        XCTAssertEqual(SortKey(keyPath: \VisibleRow.name), .name)
        XCTAssertEqual(SortKey(keyPath: \VisibleRow.bytes), .bytes)
        XCTAssertEqual(SortKey(keyPath: \VisibleRow.deltaDaySort), .deltaDay)
        XCTAssertEqual(SortKey(keyPath: \VisibleRow.deltaWeekSort), .deltaWeek)
        XCTAssertEqual(SortKey(keyPath: \VisibleRow.deltaMonthSort), .deltaMonth)
        XCTAssertEqual(SortKey(keyPath: \VisibleRow.newestMtime), .mtime)
        XCTAssertEqual(SortKey(keyPath: \VisibleRow.fileCount), .files)
        XCTAssertNil(SortKey(keyPath: \VisibleRow.depth))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "FormattingTests|RevealTargetTests|BannerStateTests|SortKeyTests" 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'ByteFormatter' in scope`

- [ ] **Step 3: Implement**

`Sources/DiskReportUI/Formatting.swift`:
```swift
import DiskReportCore
import Foundation

public enum ByteFormatter {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Finder-style base-1000 sizes. One decimal below 100 units, none above.
    public static func string(_ bytes: Int64) -> String {
        let sign = bytes < 0 ? "-" : ""
        var value = Double(bytes.magnitude)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(sign)\(Int(value)) \(units[0])" }
        let text = value < 100 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return "\(sign)\(text) \(units[unit])"
    }
}

public enum DeltaFormatter {
    public static func string(_ delta: Delta) -> String {
        switch delta {
        case .noData: return "—"
        case .new(let b): return "+\(ByteFormatter.string(b)) (new)"
        case .changed(let b):
            if b == 0 { return "0 B" }
            return b > 0 ? "+\(ByteFormatter.string(b))" : ByteFormatter.string(b)
        }
    }
}

public enum DateFormatting {
    public static func relative(mtime: Int64, now: Int64) -> String {
        let days = max(0, (now - mtime) / 86_400)
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        case 2..<14: return "\(days) days ago"
        case 14..<60: return "\(days / 7) weeks ago"
        case 60..<730: return "\(days / 30) months ago"
        default: return "\(days / 365) years ago"
        }
    }

    public static func absolute(_ t: Int64, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }
}
```

`Sources/DiskReportUI/RevealTarget.swift`:
```swift
import Foundation

public enum RevealTarget {
    /// The folder itself. Passing this to `NSWorkspace.activateFileViewerSelecting` opens the parent in Finder
    /// with this folder selected, so Command-Delete acts on it immediately.
    public static func url(forFolder path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}
```

`Sources/DiskReportUI/BannerState.swift`:
```swift
import DiskReportCore

public enum BannerState {
    public static func message(reports: [RootReport], now: Int64, staleAfter: Int64 = 172_800) -> String? {
        if reports.isEmpty { return "No roots configured. Edit config.json and run Scan Now." }
        for r in reports {
            if let latest = r.latest, latest.status == .failed {
                return "Last scan of \(r.rootPath) failed: \(latest.error ?? "unknown error")"
            }
            guard let current = r.current, let finished = current.finishedAt else {
                return "First scan pending. Click Scan Now."
            }
            if now - finished > staleAfter {
                return "Last completed scan of \(r.rootPath) is older than 48 hours."
            }
        }
        return nil
    }
}
```

`Sources/DiskReportUI/SortKey+KeyPath.swift`:
```swift
public extension SortKey {
    /// Maps a Table column key path back to a sort key.
    init?(keyPath: PartialKeyPath<VisibleRow>) {
        switch keyPath {
        case \VisibleRow.name: self = .name
        case \VisibleRow.bytes: self = .bytes
        case \VisibleRow.deltaDaySort: self = .deltaDay
        case \VisibleRow.deltaWeekSort: self = .deltaWeek
        case \VisibleRow.deltaMonthSort: self = .deltaMonth
        case \VisibleRow.newestMtime: self = .mtime
        case \VisibleRow.fileCount: self = .files
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter "FormattingTests|RevealTargetTests|BannerStateTests|SortKeyTests" 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 13 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(ui): size/delta/date formatting, reveal target, banner state, sort key mapping"
```

---

### Task 12: Full test run and UI library review checkpoint

**Files:** none new.

- [ ] **Step 1: Run everything**

Run: `make test 2>&1 | grep -E "lint-readonly|Executed|error:|failed"`
Expected: `lint-readonly: ok` and one `Executed N tests, with 0 failures` line where N is at least 96.

- [ ] **Step 2: Confirm the app target has no walk code**

Run: `grep -rlE "opendir|readdir|fstatat|Walker\(" Sources/DiskReport Sources/DiskReportUI || echo "clean"`
Expected: `clean`

- [ ] **Step 3: Commit (only if anything changed)**

```bash
git status --short
```
Expected: empty. If not, fix and commit with `chore: checkpoint before app target`.

---

### Task 13: Menu bar app

**Files:**
- Replace: `Sources/DiskReport/DiskReportApp.swift`
- Create: `Sources/DiskReport/AppDelegate.swift`
- Create: `Sources/DiskReport/AppModel.swift`
- Create: `Sources/DiskReport/DatabaseWatcher.swift`
- Create: `Sources/DiskReport/ScanRunner.swift`
- Create: `Sources/DiskReport/Views/MenuView.swift`
- Create: `Sources/DiskReport/Views/ReportWindowView.swift`
- Create: `Sources/DiskReport/Views/SummaryBar.swift`
- Create: `Sources/DiskReport/Views/FilterStrip.swift`
- Create: `Sources/DiskReport/Views/ReportTable.swift`
- Create: `Resources/Info.plist`
- Create: `Scripts/bundle-app.sh`
- Modify: `Makefile` (add `bundle`)

**Interfaces:**
- Consumes: `DataPaths`, `Store`, `ReportLoader`, `RootReport`, `ReportSummary`, `NotableEvaluator` (Core); `ReportViewModel`, `VisibleRow`, `QuickFilter`, `SortKey`, `ByteFormatter`, `DeltaFormatter`, `DateFormatting`, `RevealTarget`, `BannerState` (UI).
- Produces: `build/DiskReport.app` via `make bundle`. Launch flag `--show-report` opens the window; `open -a DiskReport` on a running instance also opens it (reopen event).

There are no automated tests for this task (spec: no UI automation in v1). Verification is manual, steps 9–10.

Decisions recorded after review: the scanner's stdout goes to `FileHandle.nullDevice` (an unread pipe could hang the scan); `DatabaseWatcher` re-arms the sqlite/-wal file watches on every debounced change and on rename/delete, so a fresh install picks up the first database; `AppModel.reload()` uses a generation counter so overlapping loads cannot land out of order; the summary bar shows a "Loading…" state while `isLoading`.

- [ ] **Step 1: AppModel**

`Sources/DiskReport/AppModel.swift`:
```swift
import Combine
import DiskReportCore
import DiskReportUI
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var reports: [RootReport] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isLoading = false
    @Published var scanRunnerError: String?
    @Published private(set) var lastLoaded: Date?

    let viewModel = ReportViewModel()
    let paths = DataPaths.standard()
    private let evaluator = NotableEvaluator(rules: [])
    private var watcher: DatabaseWatcher?
    private var runner: ScanRunner?

    var summary: ReportSummary { ReportSummary.from(reports) }
    var hasNotices: Bool { !evaluator.notices(for: summary).isEmpty }

    var headline: String {
        guard let current = reports.compactMap(\.current).first, let finished = current.finishedAt else {
            return "No completed scan yet"
        }
        let when = Date(timeIntervalSince1970: TimeInterval(finished))
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        var text = "Last scan: \(f.string(from: when))"
        if let free = current.volumeFreeBytes { text += " · \(ByteFormatter.string(free)) free" }
        return text
    }

    func start() {
        reload()
        let watcher = DatabaseWatcher(directory: paths.dataDir, fileName: paths.databaseURL.lastPathComponent) { [weak self] in
            self?.reload()
        }
        watcher.start()
        self.watcher = watcher
    }

    func reload() {
        let dbURL = paths.databaseURL
        isLoading = true
        Task {
            let loaded: [RootReport] = await Task.detached(priority: .userInitiated) {
                guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }
                do {
                    let store = try Store(url: dbURL)
                    return try ReportLoader.loadRootReports(store: store)
                } catch {
                    NSLog("DiskReport: load failed: \(error)")
                    return []
                }
            }.value
            self.reports = loaded
            self.viewModel.load(reports: loaded, now: Int64(Date().timeIntervalSince1970))
            self.lastLoaded = Date()
            self.isLoading = false
        }
    }

    func scanNow() {
        guard !isScanning else { return }
        isScanning = true
        scanRunnerError = nil
        let runner = ScanRunner(paths: paths)
        self.runner = runner
        runner.run { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isScanning = false
                if case .failure(let error) = result { self.scanRunnerError = error.localizedDescription }
                self.reload()
            }
        }
    }
}
```

- [ ] **Step 2: DatabaseWatcher**

`Sources/DiskReport/DatabaseWatcher.swift`:
```swift
import Darwin
import Foundation

/// Watches the data directory and the database file; calls `onChange` on the main queue, debounced.
final class DatabaseWatcher {
    private let directory: URL
    private let fileName: String
    private let onChange: () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    init(directory: URL, fileName: String, onChange: @escaping () -> Void) {
        self.directory = directory
        self.fileName = fileName
        self.onChange = onChange
    }

    func start() {
        watch(path: directory.path, events: [.write, .rename])
        watch(path: directory.appendingPathComponent(fileName).path, events: [.write, .extend, .rename, .delete])
        watch(path: directory.appendingPathComponent(fileName + "-wal").path, events: [.write, .extend])
    }

    private func watch(path: String, events: DispatchSource.FileSystemEvent) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources.append(source)
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    deinit { sources.forEach { $0.cancel() } }
}
```

- [ ] **Step 3: ScanRunner**

`Sources/DiskReport/ScanRunner.swift`:
```swift
import DiskReportCore
import Foundation

/// Runs the installed scanner binary under the same sandbox profile launchd uses. Never scans in-process.
final class ScanRunner {
    enum RunError: LocalizedError {
        case notInstalled(String)
        case exited(Int32, String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let p): return "Scanner not installed at \(p). Run `make install`."
            case .exited(let code, let stderr): return "Scanner exited with code \(code). \(stderr)"
            }
        }
    }

    private let paths: DataPaths

    init(paths: DataPaths) { self.paths = paths }

    func run(completion: @escaping (Result<Void, RunError>) -> Void) {
        let scanner = paths.binDir.appendingPathComponent("diskreport-scan")
        let profile = paths.binDir.appendingPathComponent("scan.sb")
        for required in [scanner, profile] where !FileManager.default.fileExists(atPath: required.path) {
            completion(.failure(.notInstalled(required.path)))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = [
            "-D", "DATA_DIR=\(paths.dataDir.path)",
            "-D", "LOG_DIR=\(paths.logDir.path)",
            "-f", profile.path,
            scanner.path,
            "--data-dir", paths.dataDir.path,
            "--log-dir", paths.logDir.path,
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        process.terminationHandler = { p in
            let text = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0 { completion(.success(())) } else { completion(.failure(.exited(p.terminationStatus, text))) }
        }
        do {
            try process.run()
        } catch {
            completion(.failure(.exited(-1, error.localizedDescription)))
        }
    }
}
```

- [ ] **Step 4: AppDelegate and App entry**

`Sources/DiskReport/AppDelegate.swift`:
```swift
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        if CommandLine.arguments.contains("--show-report") { showReport() }
    }

    /// `open -a DiskReport` on a running instance lands here; launchd uses that after each scan.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showReport()
        return false
    }

    func showReport() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "DiskReport"
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("DiskReportReportWindow")
            w.contentView = NSHostingView(rootView: ReportWindowView().environmentObject(model))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

`Sources/DiskReport/DiskReportApp.swift`:
```swift
import SwiftUI

@main
struct DiskReportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: delegate.model, showReport: { delegate.showReport() })
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Image(systemName: model.hasNotices ? "externaldrive.badge.exclamationmark" : "externaldrive")
    }
}
```

- [ ] **Step 5: Views**

`Sources/DiskReport/Views/MenuView.swift`:
```swift
import AppKit
import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel
    let showReport: () -> Void

    var body: some View {
        Text(model.headline)
        Divider()
        Button("Open Report") { showReport() }.keyboardShortcut("o")
        Button(model.isScanning ? "Scanning…" : "Scan Now") { model.scanNow() }
            .disabled(model.isScanning)
            .keyboardShortcut("s")
        Button("Reveal Database in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([model.paths.databaseURL])
        }
        Divider()
        Button("Quit DiskReport") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
```

`Sources/DiskReport/Views/ReportWindowView.swift`:
```swift
import SwiftUI

struct ReportWindowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SummaryBar(model: model)
            Divider()
            FilterStrip(viewModel: model.viewModel)
            Divider()
            ReportTable(viewModel: model.viewModel)
        }
        .frame(minWidth: 900, minHeight: 500)
    }
}
```

`Sources/DiskReport/Views/SummaryBar.swift`:
```swift
import DiskReportCore
import DiskReportUI
import SwiftUI

struct SummaryBar: View {
    @ObservedObject var model: AppModel

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 24) {
                volume
                ForEach(model.summary.roots, id: \.rootPath) { root in
                    VStack(alignment: .leading) {
                        Text(root.rootPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(ByteFormatter.string(root.totalBytes)).font(.headline).monospacedDigit()
                            if let d = root.deltaDay { deltaText(d) }
                        }
                    }
                }
                Spacer()
                scanInfo
            }
            if let banner = bannerText {
                Text(banner)
                    .font(.callout)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
    }

    private var volume: some View {
        VStack(alignment: .leading) {
            Text("Free on volume").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(model.summary.volumeFreeBytes.map(ByteFormatter.string) ?? "—").font(.headline).monospacedDigit()
                if let d = model.summary.volumeFreeDeltaDay { deltaText(d) }
            }
        }
    }

    private var scanInfo: some View {
        VStack(alignment: .trailing) {
            if model.isScanning {
                HStack { ProgressView().controlSize(.small); Text("Scanning…") }
            } else if let current = model.reports.compactMap(\.current).first, let f = current.finishedAt {
                Text("Scanned \(DateFormatting.relative(mtime: f, now: now)), \(Int(f - current.startedAt))s")
                    .font(.caption).foregroundStyle(.secondary)
                if let skipped = current.skippedCount, skipped > 0 {
                    Text("\(skipped) entries skipped (see log)").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var bannerText: String? {
        if let e = model.scanRunnerError { return e }
        return BannerState.message(reports: model.reports, now: now)
    }

    private func deltaText(_ d: Int64) -> some View {
        Text(DeltaFormatter.string(.changed(d)))
            .font(.subheadline).monospacedDigit()
            .foregroundStyle(d > 0 ? Color.red : (d < 0 ? Color.green : Color.secondary))
    }
}
```

`Sources/DiskReport/Views/FilterStrip.swift`:
```swift
import DiskReportUI
import SwiftUI

struct FilterStrip: View {
    @ObservedObject var viewModel: ReportViewModel

    var body: some View {
        HStack {
            Picker("Filter", selection: $viewModel.filter) {
                ForEach(QuickFilter.allCases) { f in Text(f.title).tag(f) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Spacer()
            TextField("Search path", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
```

`Sources/DiskReport/Views/ReportTable.swift`:
```swift
import AppKit
import DiskReportCore
import DiskReportUI
import SwiftUI

struct ReportTable: View {
    @ObservedObject var viewModel: ReportViewModel
    @State private var selection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<VisibleRow>] = [KeyPathComparator(\VisibleRow.name)]

    var body: some View {
        Table(viewModel.visibleRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                NameCell(row: row) { viewModel.toggle(row.id) }
            }
            .width(min: 280, ideal: 420)

            TableColumn("Size", value: \.bytes) { row in
                Text(ByteFormatter.string(row.bytes)).monospacedDigit()
            }
            .width(90)

            TableColumn("Δ Day", value: \.deltaDaySort) { row in DeltaCell(delta: row.deltaDay) }.width(110)
            TableColumn("Δ Week", value: \.deltaWeekSort) { row in DeltaCell(delta: row.deltaWeek) }.width(110)
            TableColumn("Δ Month", value: \.deltaMonthSort) { row in DeltaCell(delta: row.deltaMonth) }.width(110)

            TableColumn("Last Modified", value: \.newestMtime) { row in
                Text(DateFormatting.relative(mtime: row.newestMtime, now: viewModel.now))
                    .help(DateFormatting.absolute(row.newestMtime))
            }
            .width(120)

            TableColumn("Files", value: \.fileCount) { row in
                Text("\(row.fileCount)").monospacedDigit()
            }
            .width(80)
        }
        .onChange(of: sortOrder) { _, newValue in
            guard let first = newValue.first, let key = SortKey(keyPath: first.keyPath) else { return }
            viewModel.setSort(key: key, ascending: first.order == .forward)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Reveal in Finder") { reveal(ids) }
            Button("Copy Path") { copyPaths(ids) }
            Button("Open in Terminal") { openInTerminal(ids) }
        } primaryAction: { ids in
            reveal(ids)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(selection.isEmpty ? "Select a folder" : "\(selection.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy Path") { copyPaths(selection) }.disabled(selection.isEmpty)
                Button("Open in Terminal") { openInTerminal(selection) }.disabled(selection.isEmpty)
                Button("Reveal in Finder") { reveal(selection) }
                    .disabled(selection.isEmpty)
                    .keyboardShortcut("r")
                    .buttonStyle(.borderedProminent)
            }
            .padding(8)
            .background(.bar)
        }
    }

    /// Finder opens the parent folder with each target selected, so ⌘⌫ acts on it directly.
    private func reveal(_ ids: Set<String>) {
        let urls = ids.map(RevealTarget.url(forFolder:))
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func copyPaths(_ ids: Set<String>) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(ids.sorted().joined(separator: "\n"), forType: .string)
    }

    private func openInTerminal(_ ids: Set<String>) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let urls = ids.map { URL(fileURLWithPath: $0, isDirectory: true) }
        NSWorkspace.shared.open(urls, withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

private struct NameCell: View {
    let row: VisibleRow
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: CGFloat(row.depth) * 16)
            if row.hasChildren {
                Button(action: toggle) {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }
            Image(systemName: "folder").foregroundStyle(row.isDeleted ? .secondary : .accentColor)
            Text(row.name)
                .strikethrough(row.isDeleted)
                .foregroundStyle(row.isDeleted ? .secondary : .primary)
                .lineLimit(1)
                .help(row.id)
        }
    }
}

private struct DeltaCell: View {
    let delta: Delta

    var body: some View {
        let bytes = delta.bytes ?? 0
        Text(DeltaFormatter.string(delta))
            .monospacedDigit()
            .foregroundStyle(delta.bytes == nil ? Color.secondary : (bytes > 0 ? Color.red : (bytes < 0 ? Color.green : Color.secondary)))
    }
}
```

- [ ] **Step 6: Build**

Run: `swift build 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | tail -5`
Expected: `Build complete!`

Common fixes if it does not: `Table` requires `import SwiftUI` and macOS 14 target (set in Package.swift); `.contextMenu(forSelectionType:menu:primaryAction:)` and `.onChange(of:_:)` two-parameter form both need macOS 14.

- [ ] **Step 7: Info.plist and bundle script**

`Resources/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>DiskReport</string>
  <key>CFBundleIdentifier</key><string>com.andyfloyd.diskreport</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>DiskReport</string>
  <key>CFBundleDisplayName</key><string>DiskReport</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
```

`Scripts/bundle-app.sh`:
```sh
#!/bin/sh
# Assembles build/DiskReport.app from the release build. Ad-hoc signed; no Dock icon (LSUIElement).
set -eu
cd "$(dirname "$0")/.."
BIN="$(swift build -c release --show-bin-path)"
APP="build/DiskReport.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DiskReport" "$APP/Contents/MacOS/DiskReport"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"
echo "bundled $APP"
```

Add to `Makefile`:
```make
bundle: release
	chmod +x Scripts/bundle-app.sh
	Scripts/bundle-app.sh
```
and add `bundle` to `.PHONY`.

Run: `make bundle 2>&1 | tail -2`
Expected: `bundled build/DiskReport.app`

- [ ] **Step 8: Prepare a throwaway scanner install for manual testing (no launchd yet)**

```sh
DATA="$HOME/Library/Application Support/DiskReport"
mkdir -p "$DATA/bin" "$HOME/Library/Logs/DiskReport"
cp "$(swift build -c release --show-bin-path)/diskreport-scan" Resources/scan.sb "$DATA/bin/"
[ -f "$DATA/config.json" ] || printf '{\n  "roots": ["~/Workspace"]\n}\n' > "$DATA/config.json"
```

- [ ] **Step 9: Manual verification of the app**

Run: `open build/DiskReport.app --args --show-report`

Check each item:
1. A disk icon appears in the menu bar and there is no Dock icon.
2. The report window opens and shows the banner "First scan pending. Click Scan Now." (fresh install).
3. Menu → Scan Now: the summary bar shows "Scanning…"; when it finishes (a few minutes for ~300 GB) the table fills with `~/Workspace` expanded three levels, without restarting the app.
4. Click a column header: rows re-sort within siblings. Sorting Δ Day descending puts rows with "—" last.
5. Segmented filter "Stale > 6 months" shows only stale folders with their ancestors; clearing returns the prior expansion.
6. Double-click a row, or select it and press ⌘R or the Reveal in Finder button in the bottom bar: Finder opens the parent folder with that folder selected (⌘⌫ there would delete it; do not).
7. Right-click → Copy Path puts the absolute path on the clipboard; Open in Terminal opens a shell inside the folder.
8. Close the window, then run `open build/DiskReport.app`: the window reopens (reopen path).
9. Quit from the menu: the process exits (check with `pgrep -x DiskReport`).

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat(app): menu bar app with report window, Finder reveal, scan runner, DB watcher"
```

---

### Task 14: Install, uninstall, schedule, README

**Files:**
- Modify: `Makefile`
- Create: `README.md`

**Interfaces:**
- Consumes: `Resources/run-scan.sh`, `Resources/scan.sb`, `Resources/com.andyfloyd.diskreport.scan.plist`, `build/DiskReport.app`, release `diskreport-scan`.
- Produces: `make install`, `make uninstall [PURGE=1]`, `make scan-now`, `make status`.

- [ ] **Step 1: Extend the Makefile**

Replace `Makefile` with:
```make
.PHONY: build test lint release bundle install uninstall scan-now status clean

DATA_DIR := $(HOME)/Library/Application Support/DiskReport
LOG_DIR  := $(HOME)/Library/Logs/DiskReport
AGENT    := com.andyfloyd.diskreport.scan
PLIST    := $(HOME)/Library/LaunchAgents/$(AGENT).plist
APP_DST  := $(HOME)/Applications/DiskReport.app
UID_     := $(shell id -u)

build:
	swift build

test: lint
	swift test

lint:
	Scripts/lint-readonly.sh

release: lint
	swift build -c release

bundle: release
	chmod +x Scripts/bundle-app.sh
	Scripts/bundle-app.sh

install: bundle
	mkdir -p "$(DATA_DIR)/bin" "$(LOG_DIR)" "$(HOME)/Applications" "$(HOME)/Library/LaunchAgents"
	cp "$$(swift build -c release --show-bin-path)/diskreport-scan" "$(DATA_DIR)/bin/diskreport-scan"
	cp Resources/scan.sb Resources/run-scan.sh "$(DATA_DIR)/bin/"
	chmod +x "$(DATA_DIR)/bin/run-scan.sh" "$(DATA_DIR)/bin/diskreport-scan"
	rm -rf "$(APP_DST)"
	cp -R build/DiskReport.app "$(APP_DST)"
	@if [ ! -f "$(DATA_DIR)/config.json" ]; then \
	  printf '{\n  "roots": ["~/Workspace"],\n  "retention": { "dailyDays": 45, "weeklyWeeks": 52 }\n}\n' > "$(DATA_DIR)/config.json"; \
	  echo "wrote default $(DATA_DIR)/config.json"; \
	fi
	sed "s|__HOME__|$(HOME)|g" Resources/$(AGENT).plist > "$(PLIST)"
	plutil -lint "$(PLIST)"
	-launchctl bootout gui/$(UID_) "$(PLIST)" 2>/dev/null
	launchctl bootstrap gui/$(UID_) "$(PLIST)"
	@echo "Installed. Scheduled daily at 07:00. Run 'make scan-now' for a first scan."

scan-now:
	launchctl kickstart -k gui/$(UID_)/$(AGENT)

status:
	launchctl print gui/$(UID_)/$(AGENT) | grep -E "state|last exit|run interval|program" || true
	@ls -la "$(LOG_DIR)" 2>/dev/null || true

uninstall:
	-launchctl bootout gui/$(UID_) "$(PLIST)" 2>/dev/null
	rm -f "$(PLIST)"
	rm -rf "$(APP_DST)" "$(DATA_DIR)/bin"
	@if [ "$(PURGE)" = "1" ]; then rm -rf "$(DATA_DIR)" "$(LOG_DIR)"; echo "purged database, config and logs"; \
	else echo "kept $(DATA_DIR) (config + database). Use PURGE=1 to remove."; fi

clean:
	rm -rf .build build
```

- [ ] **Step 2: Install and run the first scheduled scan**

Run: `make install 2>&1 | tail -3`
Expected: ends with `Installed. Scheduled daily at 07:00. ...`

Run: `make scan-now && sleep 5 && make status`
Expected: `state = running` (or `last exit code = 0` if the scan already finished); the log directory contains `scan-<today>.log` and `launchd.out.log`.

Run after the scan finishes (watch `tail -f ~/Library/Logs/DiskReport/launchd.out.log` for `done status=ok`):
- The DiskReport window comes to the front on its own (launchd's `open -a` after the scan).
- `sqlite3 "$HOME/Library/Application Support/DiskReport/diskreport.sqlite" "select id,status,total_bytes,dir_count from scans"` shows one completed row.

- [ ] **Step 3: Verify the sandbox in the installed layout**

Run:
```sh
DATA="$HOME/Library/Application Support/DiskReport"
/usr/bin/sandbox-exec -D "DATA_DIR=$DATA" -D "LOG_DIR=$HOME/Library/Logs/DiskReport" -f "$DATA/bin/scan.sb" \
  "$DATA/bin/diskreport-scan" --self-test-write "$HOME/Workspace/.diskreport-probe"; echo "exit=$?"
```
Expected: `self-test-write: refused (Operation not permitted)` and `exit=0`, and no file `~/Workspace/.diskreport-probe`.

- [ ] **Step 4: Write README**

`README.md`:
```markdown
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
```

- [ ] **Step 5: Final full test run and commit**

Run: `make test 2>&1 | grep -E "lint-readonly|Executed|error:|failed"`
Expected: `lint-readonly: ok`, `Executed N tests, with 0 failures`.

```bash
git add -A
git commit -m "feat: install/uninstall/schedule targets and README"
```

---

## Self-review notes (already applied)

- Spec §4 "refuses to run as root", lock file, low priority: Task 8 main.swift.
- Spec §5 retention with failed scans older than 45 days deleted: Task 7.
- Spec §6 four layers: sandbox (Task 9), lint (Task 1), process separation (Task 12 check + Task 13 design), manifest test (Task 9).
- Spec §7 reveal opens the parent with the folder selected: `RevealTarget` (Task 11) + `activateFileViewerSelecting` (Task 13).
- Spec §7 window opens from launchd after scan: `run-scan.sh` `open -a … --show-report` + `applicationShouldHandleReopen` (Task 13).
- Spec §8 `open` runs regardless of scan exit status: `run-scan.sh` (Task 9).
- Spec §8 "no completed scan yet" banner: `BannerState` (Task 11).
- Deviations recorded: view models live in `DiskReportUI` (testability); the whole tree for the latest scan is loaded in one query off the main actor instead of per-node lazy loading, since 100k rows load in well under a second and the window opens immediately with a loading state.
