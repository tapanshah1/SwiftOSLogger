# Changelog

All notable changes to SwiftOSLogger are listed here. Versions follow [Semantic Versioning](https://semver.org).

## [1.1.0] — 2026-09-15

Caps the memory used by file logging and makes logging much faster. Log output is unchanged: text and JSON lines are byte-for-byte identical to 1.0.0, and the only API change is a new parameter with a default, so 1.0.0 code keeps compiling.

### Added

- `FileDestinationConfiguration.maxPendingBytes` (default 4 MB) caps the memory used by entries waiting for the background writer.
  - When logging outpaces the disk, further entries are dropped rather than growing memory, and a line such as `# SwiftOSLogger dropped 1532 entries: more than 4194304 bytes were waiting to be written` is written once the writer catches up.
  - An entry is always accepted when nothing else is waiting, however large it is.
  - Logging still never waits for the disk. Set `maxPendingBytes: nil` for the old unlimited behaviour.
- README: **Requirements** and **Memory** sections, the latter covering the memory cap, capturing weakly in `onInternalError`, and keeping category names fixed.

### Changed

- File writes are drained in batches by one background writer instead of one queue block per entry.
- Dates for the numeric patterns the framework uses are formatted with integer arithmetic instead of `DateFormatter`; other patterns still use `DateFormatter`.
- JSON lines are written directly instead of through `JSONSerialization`.
- Metadata capture allocates less: cached type names, one derived logger per `Loggable` call, no per-call copy of the destination list, and a byte scan for the file name.

### Performance

Per log call, measured on a 2019 Intel MacBook Pro (release build):

| | 1.0.0 | 1.1.0 |
|---|---:|---:|
| Log to a file, text | 14.1 µs | 3.8 µs |
| Log to a file, JSON | 53 µs | 5.0 µs |
| `Loggable` `log.info` (capture only) | 6.4 µs | 1.1 µs |
| Log to unified logging | 6.0 µs | 3.7 µs |
| Memory left behind per call in a tight loop | 58 bytes | 1 byte |

In a stress test of 1M log calls from 8 threads, peak memory dropped from 376 MB to about 13 MB and the run took 0.9 s instead of about 7 s.

## [1.0.0] — 2026-09-15

First release.

- `OSLogger` with levels `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical`, plus custom levels and `.off`.
- Destinations: `OSLogDestination` (unified logging), `ConsoleDestination`, `FileDestination`, and your own via `LogDestination`.
- Every entry records date and time with milliseconds, level, thread ID and name, category, file, class, function and line.
- File rotation by size, by entry count and by number of files, with a header on each file naming the logger, app, bundle ID, app version, process, PID, OS and device model.
- `TextLogFormatter` and `JSONLogFormatter`, or your own via `LogFormatter`.
- `Loggable` gives a type a `log` property that records its class name.
- Buffered file writes on a background queue, flushed on app background/terminate, at `flushLevel` and on `flush()`.
- Swift Package Manager, plus `scripts/build-xcframework.sh` for a static XCFramework.
- iOS 15+, macOS 12+, tvOS 15+, watchOS 8+, visionOS 1+. No dependencies.

[1.1.0]: https://github.com/tapanshah1/SwiftOSLogger/compare/1.0.0...1.1.0
[1.0.0]: https://github.com/tapanshah1/SwiftOSLogger/releases/tag/1.0.0
