# Log writer & search tool — design doc

Oct 25, 2026 · Søren

> Rationale and design. The observable, testable behaviour is pinned down in `docs/contract.md`; where the two disagree, the contract wins and the disagreement goes to `docs/contract-questions.md`.

## Introduction

`log` is a log writer and search tool for programs that log to stdout and stderr. It stamps every line with its arrival time, writes compressed files under hard limits for size, age and free disk space, and makes those files fast to search.

**Motivating example: Tomcat.** Some webapps write heavily to `System.out`, and changing them is not practical. Tomcat appends that output to `catalina.out`, which shows every problem this tool addresses:

- **Unbounded growth.** `catalina.out` grows to many GB. The JVM holds the file open, so logrotate either rotates a file that keeps being written, or falls behind with `copytruncate`, even when run every minute from cron.
- **No timestamps.** Lines printed with `System.out.println` carry no time, so there is no way to tell when something happened.
- **Full disks.** A runaway log can fill the partition, and then logins, the database and other services fail with it.
- **Slow search.** `zgrep` is limited by single-threaded gzip decompression, and `less` stalls for long periods when searching or scrolling backwards in a multi-GB file.

Existing pipe loggers such as Apache's `rotatelogs` fix the open-file problem, but none add timestamps, enforce a free-space floor or help with search. The same gaps apply to any long-running program that logs to stdout: daemons, batch jobs, scripts under a supervisor.

## Goals and non-goals

The writer must never hurt the program it logs for. Every other goal ranks below that.

**Goals**

1. Never block or crash the producing program, whatever happens to the disk.
2. Stamp every line with its arrival time, so output without timestamps becomes usable.
3. Enforce four limits: max file size, rotation interval, max age and max total size.
4. Keep a minimum amount of free space on the partition, and discard output rather than fill it.
5. Compress everything, while keeping files readable with standard `zstd` tools.
6. Make time-range queries and "last match" searches fast on many GB of logs.
7. Ship as one static binary with no daemon, database or config server.

**Non-goals**

- Central log collection across servers. Loki or a similar system fits that better.
- Parsing or structuring log content (fields, JSON, SQL queries).
- Replacing a program's own logging framework or the files it writes itself. Only stdout and stderr are in scope.
- Windows and macOS. macOS already has a `log` command for its unified logging system.

## Architecture

`log` is one Go binary with three groups of subcommands. `pipe` (or `run`) sits on a program's stdout and writes the files. `grep`, `cat`, `view`, `tail`, `stat` and `export` read them. `init` and `doc` help set it up.

```
                 ┌──────────────── log pipe: hot path ─────────────────┐
┌─────────────┐  │ ┌──────────────┐   ┌──────────────┐   ┌───────────┐ │
│  Program    │──┼▶│ Reader       │──▶│ Ring buffer  │──▶│ Frame     │ │
│ stdout+err  │  │ │ stamps lines │   │ keeps newest │   │ writer    │ │
└─────────────┘  │ └──────────────┘   └──────────────┘   │ 1 MB/60 s │ │
                 │                                       └─────┬─────┘ │
                 └─────────────────────────────────────────────┼──▲────┘
                                                               │  │ discard
┌──────────────┐        ┌────────────────────┐        ┌────────▼──┴───┐
│ log search   │◀───────│ Log files          │◀───────│ Disk guard    │
│ grep,cat,tail│        │ zstd + meta frames │        │ prunes, keeps │
│ by time range│        │ size/time rotation │        │ min free space│
└──────────────┘        └────────────────────┘        └───────────────┘
```

Only the reader, ring buffer and frame writer run on the hot path; the reader stamps each line as it arrives. The disk guard runs beside them: it prunes old files, and switches the writer into discard mode when free space runs out. Search never touches the pipe.

## Writer

`log pipe` reads stdin until EOF and never stops reading, because a stalled reader stalls the producer. A pipe buffer holds only about 64 KB; once it is full, every write to stdout in the producer blocks. If the writer exits instead, the producer gets `EPIPE` or `SIGPIPE`. Many runtimes, Java's `PrintStream` among them, swallow that error, and output is lost silently.

**Pipeline.** A reader goroutine reads stdin, splits it into lines, stamps each line and appends it to an in-memory ring buffer of `ring_size` bytes (default 16 MB). A writer goroutine drains the ring, compresses the lines and writes frames. When the ring is full, the reader overwrites the oldest data instead of waiting, so it never blocks. The read position then skips to the next newline, so no half line is ever written, and the dropped bytes are counted for a discard marker.

- **One structure, two jobs.** The ring absorbs bursts while the disk is slow, and in discard mode it keeps the newest output (see Disk-space safety). A larger `ring_size` rides out longer disk stalls and keeps more output; memory use is fixed at that size.
- **Synchronization.** A mutex protects only the ring's data; all signals are channels, so the writer waits on everything in one `select`. After appending, the reader sends on a doorbell channel of capacity 1 without blocking, which coalesces any number of appends into one wakeup. The writer's loop selects on the doorbell, a flush ticker, a rotation timer and an EOF channel that the reader closes. The doorbell is only a hint: on every wakeup the writer drains the whole ring under the mutex, so no wakeup can be lost. It copies each span out under the lock before compressing it, so the reader never overwrites bytes in use. Closing the EOF channel also notifies the pruner and the free-space checker.
- **Partial lines.** A line still being read is stamped when its first byte arrives.

```go
// reader, after appending under the mutex: ring the doorbell, never block
select {
case r.ready <- struct{}{}:
default:
}

// writer
for {
    select {
    case <-r.ready:  // drain the whole ring
    case <-flush.C:  // flush a block; close the frame at 1 MB / 60 s
    case <-rotate.C: // rotate the file
    case <-r.eof:    // drain, flush, exit
    }
}
```

**Timestamps.** The reader stamps each line with the time it arrived, in UTC at microsecond precision. The stamp is written in front of the line as fixed-width text, for example `2026-10-25T06:30:12.345678Z`. UTC avoids the repeated hour when daylight saving time ends; `log` commands and the plain mirror show local time instead. Consecutive stamps share most of their bytes, so they cost little after compression, and `zstdcat` output is timestamped even without `log`.

- Arrival time is close to event time when the producer flushes each line, as Java's `System.out.println` does.
- Programs that block-buffer stdout when it is a pipe (C stdio, for example) deliver lines in bursts that share one stamp. `stdbuf -oL` fixes that for most of them.
- For producers that already timestamp their lines, `stamp = "none"` turns the prefix off. Frame metadata still records arrival times, so time-range search keeps working.
- **Clock steps.** The wall clock can step backwards, for example on an NTP correction. Within a file, stamps never decrease: a step back of up to 1 second is absorbed by reusing the previous stamp until the clock catches up. A larger step rotates to a new file and writes a `[log] clock stepped back` record, so every file stays sorted. Search treats files as separate time spans that may overlap. Forward steps need no handling.

**Lines, not records.** The writer stores lines and does not try to group them. Grouping a stack trace with the line that introduced it happens at search time (see Search and viewing), so the rules can change without rewriting any file.

**Awkward input.** The writer stores bytes, not text, and handles four edge cases:

- **Long lines.** A line longer than `max_line` (default 64 KB) is split into pieces. Later pieces carry the same stamp followed by `+` instead of a space, so search can rejoin them. `max_line` must be at most a quarter of `ring_size`.
- **Encoding.** Bytes are stored as received, with no transcoding by default. For producers known to write a legacy encoding, `input_charset = "latin1"` converts to UTF-8 on write, so patterns like `æøå` match.
- **Line endings.** `\r\n` is normalized to `\n`.
- **Unterminated lines.** A line still incomplete when a frame closes stays in the ring until it ends or reaches `max_line`. At EOF, a final line without a newline is written with one added.

**Errors.** Write errors such as `ENOSPC`, `EACCES` or `EIO` are counted and treated as discard. They are never fatal. The writer retries opening a file at most once a second.

**Own events.** The writer's stderr is often not captured anywhere; under `CATALINA_OUT_CMD` it usually goes nowhere. So the writer records its own events in the log stream itself, as lines starting with `[log]`: discards, write errors, clock steps, lock conflicts, config reloads, a disabled mirror. Events that cannot be written there, because the disk is the problem, go to stderr and, with `syslog = true`, to syslog. `log stat` counts the `[log]` events per file.

**One pruner per prefix.** On start, `log pipe` tries to take an exclusive `flock` on `.<prefix>.lock` in the log directory. During a restart the old writer may still be draining when the new one starts. Both can write safely at once, because each new file claims its sequence number with an exclusive create, so the new writer never waits and never blocks the producer. The lock decides only who prunes: the holder enforces `max_age` and `max_total` for the whole prefix, and the other instance records a `[log]` event and checks the lock again at each rotation. Every instance still enforces `min_free` for its own output.

**Signals.** SIGINT and SIGTERM are ignored; the process ends only on stdin EOF, after flushing the current frame. This keeps the producer's last output when it crashes or shuts down. SIGHUP reloads the config file, because `log pipe` lives as long as its producer and changing a limit should not require restarting Tomcat. Limits, mirror settings and `continuation` take effect at once; `dir`, `prefix` and `ring_size` apply only at the next start. A config that fails validation is rejected with a `[log]` event, and the old settings stay.

**Flushing.** Every second, the writer flushes the open frame: it ends the current zstd block and writes it, so the data is on disk and decodable while the frame stays open. A frame is closed after 1 MB of input or 60 seconds, whichever comes first. Keeping the two apart holds durability at about one second while frames stay large enough to compress almost as well as one continuous stream. Closing a frame every second would make files several times larger at low traffic, because each frame starts compressing from scratch.

**Plain mirror (optional).** With `mirror = true`, the writer also appends each stamped line to a plain text file, `app.current.log`, so people can use `tail -f`, `less` and `grep` on the live output with standard tools. No `log` command reads it; search, export and the index always use the zst files.

- **Local time.** Mirror lines are stamped in local time with the UTC offset, for example `2026-10-26T14:30:12.345678+08:00`, so people reading it with standard tools see their own clock. The offset keeps the repeated hour at the end of daylight saving time unambiguous. The writer formats each stamp twice, once in UTC for the zst file and once in local time for the mirror; the line text is otherwise identical.
- **Size.** The mirror has its own cap, `mirror_max` (default 256 MB), because plain text is many times larger than the compressed active file. When it reaches the cap, the writer removes the oldest half in place with `fallocate(FALLOC_FL_COLLAPSE_RANGE)`, so the file never goes empty. ext4 and XFS support this.
- **Clean cut.** The removed range must be a multiple of the filesystem block size, so it usually ends mid-line. The writer overwrites that partial first line with a marker of the same length, such as `[log] mirror trimmed`, padded with spaces.
- **Fallback.** If the filesystem does not support collapsing (`EOPNOTSUPP`), the writer renames the file to `app.previous.log` and starts a new mirror, so the older half stays readable under a fixed name.
- **Readers.** `tail -F` and `less +F` keep following when the file shrinks, though GNU `tail` reports it as truncated and may print the kept half once more.
- **Disk limits.** The mirror counts toward `max_total` and `min_free`. Under disk pressure it is the first thing to go: the writer stops writing it and deletes it before touching any archives.
- **Hot path.** The frame writer writes the mirror right after the zst data. A failed mirror write disables the mirror until the next rotation, and zst output continues unaffected.

The mirror is written immediately, so unlike the zst file it does not lose the last second of output if the writer is killed.

## Rotation and retention

Files rotate on size or time, whichever comes first, and a pruner enforces age and total-size limits after each rotation.

| Limit | Flag | Default | Measured as |
| --- | --- | --- | --- |
| Max file size | `--max-size` | 100 MB | Compressed bytes on disk |
| Rotation interval | `--rotate-every` | 24 h, aligned to local midnight | Wall-clock time |
| Max age | `--max-age` | 14 days | Arrival time of a file's last line |
| Max total size | `--max-total` | 2 GB | Compressed bytes of all files |

**File names.** Each file is named after the configured prefix, a local date and a sequence number: `app.2026-10-26.001.log.zst`. The date means the file holds only lines that arrived on that local date, so people can pick files by date without converting time zones. Sequence numbers start at 001 each day and are zero-padded to three digits, growing to four if a day ever passes 999 files; readers sort them numerically, not as text. Stamps inside the files stay in UTC.

A new file claims the next free number for its date by creating it with `O_CREAT|O_EXCL`, so two writers can never pick the same name. A hard link `app.current.log.zst` points at the file being written. It is replaced atomically on rotation, by linking under a temporary name and renaming over the old link. `log tail -f` watches the directory with inotify and falls back to polling once a second.

**Time alignment.** Every file is closed at local midnight, whatever the other limits say, so no file spans two dates. `rotate_every` therefore applies within a day and must divide 24 hours (for example `6h` or `24h`); boundaries are counted from local midnight, not from process start. When daylight saving time ends, the repeated hour stays on the same date, so file names are unambiguous. If the clock steps back across midnight, the writer opens a new file for the earlier date with that date's next free number.

**Pruning.** After each rotation, a goroutine deletes files older than the max age, then deletes the oldest files until the total is under the max. It never touches the file being written. Pruning runs off the write path, so slow deletes cannot stall input.

**Permissions and retention.** Files are created with mode `file_mode` (default `0640`), owned by the user the writer runs as; a log directory that does not exist is created with `0750`. Logs often contain personal data, so `max_age` is in effect the retention period for that data and should match the organisation's retention policy. Exported files carry the same data and fall outside `log`'s retention.

## Disk-space safety

`log` keeps at least `--min-free` (default 2 GB) available on the log partition: it deletes its own old files first, and discards new output only when that is not enough.

**Measuring free space.** Free space is `Bavail × Bsize` from `statfs`. `Bfree` would include root's reserved blocks, which a writer running as a normal user cannot use. After each check, the writer knows its headroom (free minus `min_free`) and checks again after using half of it, or after 1 second, whichever comes first. An `ENOSPC` between checks switches straight to discard mode.

**Order of actions when free space drops below `min_free`:**

1. Delete the writer's own archives, oldest first, until free space is back above the limit.
2. If all archives are gone and space is still short, something else is filling the disk. Enter discard mode.
3. Skip compressing or copying anything that needs temporary extra space.

**Hysteresis.** Discard mode starts below `min_free` and ends only above `min_free + resume_margin` (default 512 MB), so the writer does not flap at the boundary.

**Markers.** On leaving discard mode, the writer writes a record such as `[log] discarded 1.2 GB between 14:02:11 and 14:37:50 (low disk space)`, and reports the same on stderr. A gap in the log is never silent.

**Last output kept.** In discard mode the writer stops draining the ring. The reader keeps overwriting the oldest data, so the ring always holds the newest `ring_size` bytes. The writer writes them out when space returns or at EOF, so the last output before a crash survives.

**Backstop.** For a hard guarantee, put the log directory on its own small filesystem or LV, or use an XFS project quota.

## File format

Each file is a plain sequence of zstd frames, so `zstdcat` reads it unchanged; `log` adds a small skippable metadata frame after each data frame, which standard tools ignore.

**Layout of one file:**

```
[data 0][meta 0][data 1][meta 1] … [data N][meta N][footer]
```

**Data first.** Every file starts with the standard zstd magic number, so tools that detect formats by signature (7-Zip, `file`, Explorer) recognise it. Each metadata frame describes the data frame just before it. A last data frame without its metadata frame, left by a crash, is still read; its times come from its stamped lines.

**Data frame.** One complete zstd frame holding whole stamped lines, closed after 1 MB of input or 60 s, with a block flushed every second. Level 3 via `github.com/klauspost/compress/zstd`. Because frames are independent, a crash or a corrupt byte costs at most one frame, and frames can be decompressed in parallel.

**Metadata frame.** A zstd skippable frame (magic `0x184D2A50`, 4-byte length, payload) with a fixed binary layout:

| Field | Type | Meaning |
| --- | --- | --- |
| version | uint8 | Format version, starts at 1 |
| first_ts | int64 | Arrival time of the first line, Unix ns |
| last_ts | int64 | Arrival time of the last line, Unix ns |
| lines | uint32 | Number of lines in the data frame |
| raw_size | uint32 | Uncompressed bytes in the data frame |
| data_size | uint32 | Compressed bytes of the data frame |
| flags | uint8 | Bit 0: a discard marker is in this frame |

**Footer.** On a clean close, the writer appends one more skippable frame, with magic `0x184D2A51` so it can't be mistaken for a metadata frame. It indexes every data frame, so readers can jump straight to a time range. A file without a footer (crash, or the current file) is indexed by walking the metadata frames instead, which costs one small read per frame. All integers in the metadata frames and the footer are little-endian, like zstd's own headers.

The footer payload has three parts: a header, one entry per data frame, and a fixed 16-byte trailer at the very end.

| Part | Field | Type | Meaning |
| --- | --- | --- | --- |
| Header | version | uint8 | Format version, starts at 1 |
| Header | flags | uint8 | Bit 0: the file contains discard markers |
| Header | first_ts | int64 | Arrival time of the file's first line, Unix ns |
| Header | last_ts | int64 | Arrival time of the file's last line, Unix ns |
| Header | lines | uint64 | Lines in the whole file |
| Header | log_events | uint32 | `[log]` event lines in the file |
| Header | discarded | uint64 | Bytes discarded while this file was open |
| Entry | offset | uint64 | Byte offset of the data frame in the file |
| Entry | data_size | uint32 | Compressed bytes of the data frame |
| Entry | raw_size | uint32 | Uncompressed bytes of the data frame |
| Entry | first_ts | int64 | Arrival time of the frame's first line, Unix ns |
| Entry | last_ts | int64 | Arrival time of the frame's last line, Unix ns |
| Entry | lines | uint32 | Lines in the data frame |
| Trailer | entries | uint32 | Number of entries |
| Trailer | payload_size | uint32 | Size of the whole footer payload, trailer included |
| Trailer | crc32 | uint32 | CRC-32C of the payload before the trailer |
| Trailer | magic | uint32 | `0x464F474C` ("LGOF" read as little-endian bytes) |

**Finding the footer.** A reader reads the last 16 bytes of the file. If `magic` matches, it reads `payload_size` bytes back from the end and checks the CRC. If the magic is missing or the CRC fails, the file has no usable footer, and the reader walks the metadata frames instead. Each entry is 36 bytes; at low traffic a frame closes every 60 seconds, so a file rotated at midnight has at most 1,440 entries, about 52 KB of footer, read only when the file is searched.

`log stat` reads the header alone to report time spans, line counts, `[log]` events and discarded bytes per file, without decompressing anything.

**Versioning.** Metadata frames and the footer both start with a version byte. Readers must read every older version. A metadata frame or footer with a newer version than the reader knows is skipped, and the reader falls back to decoding the data frames without the index, which is slower but complete. Data frames are plain zstd and never change format.

**Crash handling.** The writer never appends to an existing file; each start opens a new one. Readers decode an unfinished last frame up to its last complete block, then report a truncated tail instead of failing.

## Search and viewing

Search speed comes from reading less: time ranges skip whole files and frames using the metadata, and newest-first order makes "last match" instant.

| Command | Does |
| --- | --- |
| `log grep PATTERN [--since T] [--until T] [--newest-first] [-n N]` | Prints matching records, whole stack traces included |
| `log cat --since T --until T` | Prints every record in a time window |
| `log view --since T --until T` | Same as `cat`, piped into `less -n` |
| `log tail [-f]` | Shows the newest records and follows across rotations |
| `log stat` | Lists files, time spans, sizes and discard markers |
| `log export --since T --until T [--format gz\|zst\|tzst\|txt] -o FILE` | Writes a time window to one portable file (see Interoperability) |

Times accept absolute values (`2026-10-25 14:00`) and relative ones (`-2h`).

**How a query runs:**

1. Pick files whose time span overlaps the range, from file names and footers.
2. Pick frames whose `first_ts`–`last_ts` overlap the range, from metadata frames.
3. Decompress the chosen frames on all cores, oldest first, or newest first with `--newest-first`.
4. Match records and print them in order. With `-n N`, stop after N matches.

**Records.** Search groups lines into records with continuation rules, because untimestamped output has no other marker of where a message starts. A line that matches a continuation pattern joins the record before it; any other line starts a new record. The default rules cover Java stack traces:

- a line starting with whitespace (`\tat …`, `\t... 12 more`)
- a line starting with `Caused by:` or `Suppressed:`

Rules come from the config file or `--continuation`, and `--lines` turns grouping off. Java's `printStackTrace` holds the stream's lock while printing, so a trace is not interleaved with other threads' output. A record that spans two frames is completed by reading the tail of the earlier frame.

**Output.** Commands print each line with its stamp converted to local time with the UTC offset, matching the mirror. `--utc` prints the stored UTC stamps instead, and `--no-stamp` prints the original text.

**Matching.** Search uses `github.com/coregx/coregex`, a pure-Go engine built like Rust's regex crate: literal prefilters (memchr, memmem, Teddy), a lazy DFA, and a PikeVM fallback, with linear-time matching. Go's own `regexp` has no DFA and is several times slower. The binary stays static.

- **Whole frames, not lines.** Each regex runs over a decompressed frame buffer, about 1 MB, and match offsets are mapped back to lines and records afterwards. This keeps per-call overhead negligible and lets the prefilters skip most of the buffer.
- **No separate literal path.** coregex extracts literals from the pattern itself, so a plain string already runs through memmem. `-F` only escapes the pattern with `regexp.QuoteMeta`.
- **Behind an interface.** coregex is pre-1.0, so the matcher sits behind a small interface with the stdlib `regexp` as a fallback.

Matching is case-sensitive unless `-i` is given.

**Later, if needed.** Per-frame bloom filters of trigrams would let a search skip frames that cannot contain the term. Add them only if time-range skipping proves insufficient.

## Interoperability

People download log files and open them on Windows, so the files must work without `log`.

- **Raw files.** Each file is standard zstd that starts with a normal data frame. 7-Zip 24.01 and later and the official `zstd` CLI decompress it; the metadata frames are skipped, and the output is the stamped text. Windows 11 Explorer handles `.tar.zst` but not bare `.zst`, so it is not a supported viewer.
- **Export.** `log export --since T --until T [--format gz|zst|tzst|txt] -o FILE` writes one self-contained file for a time window. Gzip is the default because every archiver opens it; `zst` writes plain frames without metadata, and `txt` writes uncompressed text. Lines appear as `log cat` prints them, and `--grep PATTERN` limits the export to matching records.
- **tar.zst for Explorer.** `--format tzst` wraps the export in a tar archive with one member per source log file in the range, then compresses it with zstd. Windows 11 Explorer opens it as a folder with no extra software. It uses Go's `archive/tar` and the existing zstd encoder. Because a tar header must state the member's size before its data, each member is first written to a temp file. Tar is used only for export: the live files from `log pipe` stay plain zstd, since their size is unknown until they close and a header compressed into the first frame cannot be patched.

**Compatibility test.** Before production use, decompress sample files with 7-Zip, the official `zstd` CLI, and the Go and Python zstd libraries, including a file without a footer and one with a truncated last frame. 7-Zip uses its own zstd decoder rather than the reference implementation, so its handling of skippable and multiple frames must be checked, not assumed. If any tool fails, the format changes before the first release.

## Integration and configuration

Any program whose stdout can be piped works with `log`. There are two ways to attach it:

- **As a pipe target:** `myapp 2>&1 | log pipe --config /etc/log/myapp.toml`. This suits launchers that already offer a hook for an output command.
- **As a wrapper:** `log run --config … -- myapp args`. `log` starts the program with its stdout and stderr connected, forwards signals to it, and exits with its exit code. This suits systemd units and supervisors that expect one process.

**log run details.** `log run` starts the program as its child, with stdout and stderr on one pipe. It forwards SIGTERM, SIGINT, SIGQUIT (Java thread dumps), SIGUSR1 and SIGUSR2 to the child. SIGHUP is forwarded too, and also reloads `log`'s own config. When running as PID 1 in a container, it reaps orphaned processes. When the child exits, `log` drains the pipe, flushes and exits with the child's exit code, or 128 plus the signal number if the child was killed by a signal. If `log` itself dies, the child gets `EPIPE` on its next write, the same risk as in pipe mode.

**Setup helpers.** Two subcommands get a program running without reading this document:

- `log init [path]` writes a config file with every option at its default, each with a one-line comment. It writes `./log.toml` by default or stdout with `-`, and refuses to overwrite an existing file without `--force`. `--for tomcat` starts from that program's preset instead.
- `log doc <program>` prints how to use `log` with that program. It always includes the integration hook as a ready-to-paste snippet, plus where it goes: for Tomcat, the `CATALINA_OUT_CMD` line for `bin/setenv.sh`; for a systemd service, the `ExecStart=` line using `log run`. It then covers the preset settings and known pitfalls. Given `--config <path>`, it fills that path into the snippet. `log doc` without an argument lists the programs it knows.

Both draw on the same data: one file per program, compiled into the binary with `go:embed`, holding the instructions and the preset values. The defaults `log init` writes come from the Go struct the config parser uses, so the generated file cannot drift from the code.

All settings live in a TOML config file, since some launchers pass the command line through a shell without quoting:

```toml
dir           = "/var/log/myapp"
prefix        = "myapp"
max_size      = "100MB"
rotate_every  = "24h"
max_age       = "14d"
max_total     = "2GB"
min_free      = "2GB"
resume_margin = "512MB"
ring_size     = "16MB"
max_line      = "64KB"
file_mode     = "0640"
syslog        = false
stamp         = "arrival"   # or "none"
mirror        = false
mirror_max    = "256MB"
continuation  = ['^\s', '^Caused by: ', '^Suppressed: ']
```

The search commands read the same file, so `continuation` applies when records are grouped.

**Precedence.** Command-line flags override the config file, which overrides built-in defaults. Each config key has a flag of the same name with dashes, so `max_size` is `--max-size`.

**Validation.** The config is checked at start and on every reload: sizes must be positive, `max_size` below `max_total`, `max_line` at most a quarter of `ring_size`, and `min_free` smaller than the filesystem. `log pipe` must never refuse to run, since that would hurt the producer. At start, an invalid value falls back to its default with a `[log]` event, and an unusable `dir` puts the writer in discard mode while it keeps draining stdin. `log init --check FILE` validates a config without running.

**Finding files.** Search commands locate logs in this order: `--config`, then `$LOG_CONFIG`, then `./log.toml`, then every file in `/etc/log/`. `--dir` and `--prefix` skip the config entirely. Several prefixes can be searched together with `--prefix a,b`; results are merged by timestamp.

### Example: Tomcat

Tomcat 7.0.91+, 8.5.34+ and 9+ pipe stdout into the command in `CATALINA_OUT_CMD`, set in `bin/setenv.sh`:

```sh
CATALINA_OUT_CMD="/usr/local/bin/log pipe --config $CATALINA_BASE/conf/log.toml"
```

`catalina.sh` runs this command unquoted, so the path must not contain spaces. With `dir` set to Tomcat's `logs` directory and `prefix = "catalina"`, rollout is:

1. Install the binary and config, and add `CATALINA_OUT_CMD` to `setenv.sh`.
2. Restart Tomcat, then remove or archive the old `catalina.out`.
3. Check with `log stat` that files rotate and limits hold.
4. Remove the logrotate config and the minutely cron entry for `catalina.out`.

`log doc tomcat` prints these steps, and `log init --for tomcat` writes the matching config.

## Alternatives considered

Each alternative covers part of the problem; none combines timestamping, hard disk limits, a free-space guard and fast search in one tool without a server.

| Option | Covers | Falls short on |
| --- | --- | --- |
| logrotate + minutely cron | Size and age, after the fact | Open file descriptor: rotates a file the program keeps writing, or loses lines with `copytruncate` |
| `rotatelogs` + prune script via `-p` | Size, time; age and total via script | No timestamps, no free-space guard, no compressed frames, no search |
| `lumberjack` Go library | Size, age, backup count, gzip | Library only; no time rotation, free-space guard or search |
| systemd + journald namespace | Size, age, total, keep-free | Needs the program in the foreground under systemd; binary journal; slow free-text search |
| lnav | Viewing, merged timelines, SQL | Indexes whole files on open, slow on multi-GB; does not write logs |
| Grafana Loki + agent | Central search, time ranges | Several services plus Grafana; brute-force content search; does not bound local disk use |

**Fallback.** If `log` is not built, `rotatelogs` with a prune script, or journald with a log namespace, solves the disk problem on its own.

## Performance targets and testing

The targets below are starting points to confirm with benchmarks on a production-like server; a miss changes the design (compression level, frame size), not just the numbers.

| Area | Target |
| --- | --- |
| Writer throughput | Sustain 100 MB/s of input on one core at zstd level 3 |
| Writer CPU | Under 5% of one core at a typical 1 MB/s |
| Writer memory | `ring_size` plus about 20 MB |
| Writer latency | A line is flushed to disk within 1 s of arrival |
| Search | At least 1 GB/s of decompressed text per core for literal patterns |
| Last match | Under 1 s for the newest match in 10 GB of logs |

**Tests**

- **Fault injection.** Run the writer against a filesystem that returns `ENOSPC`, `EIO` and slow writes on demand, and check that the producer never blocks and every gap gets a `[log]` record.
- **Fuzzing.** Go's native fuzzing feeds the reader corrupt, truncated and reordered files; it must never crash or hang, and must return every intact frame.
- **Kill tests.** Kill the writer at random points under load, then check that at most about one second of output is lost and every file stays readable.
- **Soak test.** Run a fast producer for several days across rotations, clock steps and restarts, watching memory, file counts and disk limits.
- **Compatibility test.** As described under Interoperability.
- **Benchmarks.** Throughput and search speed in CI, so regressions show up per commit. Compression is measured on real Tomcat output at several input rates and compared with one continuous zstd stream; the target is under 10% extra size at 10 KB/s.

## Phased plan and open questions

Ship the writer first, since it fixes the disk problem on its own; search builds on the file format afterwards.

1. **Writer core.** Read loop, ring buffer, signal handling, single-writer lock, size and time rotation, zstd data frames. Test by piping a fast generator through it and killing it mid-stream.
2. **Retention and safety.** Pruner for age and total size, `min_free` guard with hysteresis, discard markers, `[log]` events. Test on a small loopback filesystem filled from outside.
3. **Metadata.** Skippable metadata frames, footer, `log stat`. Run the compatibility test. Deploy behind one Tomcat instance as the first real user.
4. **Search.** `cat`, `grep`, `view` and `tail` with time ranges, newest-first order and parallel frame decoding.
5. **Optional.** Trigram bloom filters per frame, if search on real logs needs them.

**Open questions**

- [ ] Are 1 MB / 60 s frames the right size, or should frame size adapt to traffic?
- [ ] Which continuation rules besides Java stack traces should ship as defaults (Python tracebacks, Go panics)?
- [ ] Is microsecond arrival time enough, or should stamps also carry a per-file sequence number to keep order exact?
- [ ] Should `log run` keep stderr as a separate stream, or always merge it with stdout?
- [ ] Which programs get a doc page and preset after Tomcat?
