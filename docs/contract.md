# `log` — behaviour contract

Status: **draft 0.1** · Source: `docs/design.md` (rationale) · Questions: `docs/contract-questions.md`

This document defines everything about `log` that can be observed from outside the process: commands, flags, exit codes, config, file names, byte layouts, output formats and event lines. Black-box tests are written from this document alone. Implementation details that are not observable (goroutines, the ring buffer's internals, package layout) are deliberately absent; see the design doc.

The keywords MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119. Every rule has an ID (`C3.2`) so tests, tasks and review findings can cite it.

Items marked **[decided here]** were not settled in the design doc and were fixed by this draft. They are listed again in C14 for review.

---

## C1. Conventions

**C1.1 Sizes.** A size is a decimal integer with an optional unit: `B`, `KB`, `MB`, `GB`, `TB`, case-insensitive, no space allowed between number and unit. Units are binary: `1KB` = 1024 bytes. A bare number means bytes. **[decided here]**

**C1.2 Durations.** A duration is a Go duration (`90s`, `1h30m`) or an integer followed by `d` (days, 24 h each). Durations combining `d` with other units are invalid.

**C1.3 Time arguments** (`--since`, `--until`). Accepted forms:

| Form | Meaning |
| --- | --- |
| `2026-10-25` | Local midnight at the start of that date |
| `2026-10-25 14:00` / `2026-10-25 14:00:05` | Local time; the space MAY be `T` |
| RFC 3339 with offset or `Z` | That instant |
| `-2h`, `-30m`, `-3d` | Now minus the duration |
| `now` | The current instant |

`--since` is inclusive and `--until` is exclusive. A local time that falls in a DST gap is invalid; in a DST overlap, the earlier instant is used. **[decided here]** Invalid times exit with code 2.

**C1.4 Local time** is the zone from `$TZ`, else `/etc/localtime`, else UTC.

**C1.5 Byte order.** All integers in `log`-specific binary structures are little-endian.

---

## C2. Command line

**C2.1** Usage: `log <command> [flags] [args]`. Commands: `pipe`, `run`, `grep`, `cat`, `view`, `tail`, `stat`, `export`, `init`, `doc`.

**C2.2** Global flags valid for every command: `--config FILE`, `--help`, `--version`. `log --version` prints `log <semver>` and exits 0.

**C2.3** Every config key `k_ey` (C4) has a flag `--k-ey`. Precedence: flag > config file > built-in default.

**C2.4 Exit codes.**

| Code | Meaning |
| --- | --- |
| 0 | Success (for `grep`: at least one match) |
| 1 | `grep` only: no match |
| 2 | Usage error, invalid config, invalid argument |
| 3 | I/O error while reading logs or writing an export |

`log pipe` and `log run` have their own rules (C5.9, C6.3).

**C2.5** Error messages go to stderr and start with `log: `.

---

## C3. Files on disk

**C3.1 Data file name:** `<prefix>.<YYYY-MM-DD>.<seq>.log.zst`

- `<prefix>` matches `^[A-Za-z0-9_-]{1,64}$` (no dots). **[decided here]**
- `<YYYY-MM-DD>` is the **local** date on which every line in the file arrived.
- `<seq>` is a decimal number ≥ 1, zero-padded to at least 3 digits (`001`, `999`, `1000`). Readers MUST sort by numeric value.
- Full pattern: `^<prefix>\.(\d{4}-\d{2}-\d{2})\.(\d{3,})\.log\.zst$`

**C3.2 Other names in the directory:**

| Name | What |
| --- | --- |
| `<prefix>.current.log.zst` | Hard link to the data file being written |
| `<prefix>.current.log` | Plain mirror (only with `mirror = true`) |
| `<prefix>.previous.log` | Older mirror half, fallback mode only (C9.5) |
| `.<prefix>.lock` | Pruner lock file (C7.6) |
| `.<prefix>.*.tmp` | Temporary files; readers MUST ignore them |

**C3.3** New data files are created with `O_CREAT|O_EXCL`, mode `file_mode` (default `0640`). A missing log directory is created with mode `0750` (one level only; parents MUST exist). **[decided here: one level]**

**C3.4** A writer never appends to an existing data file. Each start of `log pipe`/`log run` opens a new file.

**C3.5** `<prefix>.current.log.zst` is replaced atomically on rotation (link to a temp name, rename over). At no instant MAY the name be missing while a writer is running, except before its first file is created.

**C3.6** A data file contains only lines whose arrival local date equals the date in its name. Exception: C5.6 (clock steps).

---

## C4. Configuration file

TOML. Unknown keys are reported (C10) and ignored. All keys are optional.

| Key | Type | Default | Validation | Reload (C5.8) |
| --- | --- | --- | --- | --- |
| `dir` | path | `.` **[decided here]** | must be creatable/writable | next start |
| `prefix` | string | `app` **[decided here]** | C3.1 | next start |
| `max_size` | size | `100MB` | > 0, < `max_total` | at once |
| `rotate_every` | duration | `24h` | divides 24 h exactly, ≥ `1m` | at once |
| `max_age` | duration | `14d` | > 0 | at once |
| `max_total` | size | `2GB` | > `max_size` | at once |
| `min_free` | size | `2GB` | ≥ 0, < filesystem size | at once |
| `resume_margin` | size | `512MB` | ≥ 0 | at once |
| `ring_size` | size | `16MB` | ≥ `1MB` | next start |
| `max_line` | size | `64KB` | ≥ `1KB`, ≤ `ring_size`/4 | at once |
| `file_mode` | octal string | `"0640"` | ≤ `0666` | at once (new files) |
| `syslog` | bool | `false` | | at once |
| `stamp` | `"arrival"` \| `"none"` | `"arrival"` | | next file |
| `input_charset` | `""` \| `"latin1"` | `""` | | at once |
| `mirror` | bool | `false` | | at once |
| `mirror_max` | size | `256MB` | ≥ `1MB` | at once |
| `continuation` | array of regex | `['^\s', '^Caused by: ', '^Suppressed: ']` | each compiles | at once |

**C4.1 Validation at start of `pipe`/`run`:** an invalid value falls back to its default and produces a `config-invalid` event (C10). An invalid config never stops the writer. An unusable `dir` (cannot create, not writable) puts the writer in discard mode (reason `no-dir`) while it keeps draining stdin, retrying once per second.

**C4.2 Validation in every other command:** an invalid value exits with code 2 and a message naming the key.

**C4.3 Config discovery** (all commands): `--config FILE`, else `$LOG_CONFIG`, else `./log.toml`, else every `*.toml` in `/etc/log/` (read-only commands only; each file is one log source). `--dir` and `--prefix` together skip discovery entirely. If nothing is found, built-in defaults apply.

**C4.4** Fixed constants, not configurable in 0.1: flush interval 1 s; frame close at 1 MiB of uncompressed input or 60 s; zstd level 3; clock-step tolerance 1 s.

---

## C5. `log pipe`

**C5.1** Reads stdin until EOF. It MUST keep reading stdin at the rate the producer writes, regardless of disk state: a full disk, `EIO`, an unwritable directory, a stalled filesystem or a full ring MUST NOT cause a write by the producer to block for more than 100 ms. **[decided here: 100 ms bound]**

**C5.2 Line splitting.** Input is split at `\n`. A `\r` immediately before `\n` is removed. A final line without `\n` at EOF is written with `\n` added. Bytes are otherwise stored unchanged, including invalid UTF-8 and NUL bytes, unless `input_charset = "latin1"`, in which case every byte ≥ 0x80 is converted to its UTF-8 encoding.

**C5.3 Stored line format** (`stamp = "arrival"`):

```
<stamp><sep><text>\n
```

- `<stamp>` is exactly 27 bytes: `YYYY-MM-DDTHH:MM:SS.ffffffZ`, UTC, microseconds, the arrival time of the line's first byte.
- `<sep>` is a space for a line's first piece, `+` for continuation pieces (C5.4).
- With `stamp = "none"`, lines are stored as `<text>\n` and continuation pieces are not marked. **[decided here]**

**C5.4 Long lines.** A line whose text exceeds `max_line` bytes is split into pieces of at most `max_line` bytes. Every piece is stored with the same stamp; the first with `<sep>` = space, later ones with `+`. Splits MUST NOT break a UTF-8 sequence when the input is valid UTF-8 at that point. **[decided here]**

**C5.5 Monotonic stamps.** Within a data file, stamps never decrease. If the clock steps back by ≤ 1 s, the previous stamp is reused until the clock passes it.

**C5.6 Clock step back > 1 s.** The current file is closed, a `clock-step` event is written as the first line of the new file, and the new file is named for the local date of the new clock (taking that date's next free `seq`). This is the only case where a file's date may be earlier than an existing file's.

**C5.7 Signals.** SIGINT and SIGTERM MUST be ignored. SIGPIPE MUST NOT terminate the process. SIGHUP reloads the config (C5.8). The process ends only after stdin EOF.

**C5.8 Reload on SIGHUP.** The config is re-read and validated. If any value is invalid, the whole reload is rejected, a `config-reload` event with `result=rejected` is written, and the old settings stay. Otherwise settings marked "at once" in C4 apply before the next line is written, and a `config-reload result=ok` event is written. Changes to "next start" keys are ignored and listed in the event's `ignored=` field.

**C5.9 Exit.** On EOF the writer writes all buffered data that disk space allows, writes a `stop` event as the last stored line, closes the data frame, writes its metadata frame and the footer (C8.4), and exits **0**. `log pipe` always exits 0 (except `--help` and `--version`, which print and exit 0 without reading stdin): unknown or invalid flags produce a `config-invalid` event and are ignored, because refusing to run would hurt the producer. **[decided here]**

**C5.10 Durability.** A line MUST be decodable from the data file (C8.6) within 2 s of its arrival while the disk is healthy. If the writer is killed with SIGKILL, at most the last ~1 s of output may be missing; every other line MUST be recoverable.

**C5.11 Rotation.** The current file is closed and a new one opened when any of these happen:

1. Its size on disk reaches `max_size`. The file MAY exceed `max_size` by at most the size of one data frame plus 64 KiB.
2. A `rotate_every` boundary passes, counted in local time from local midnight.
3. Local midnight passes (always, whatever `rotate_every` says).
4. A clock step back > 1 s (C5.6).
5. A `seq` claim races with another writer: the writer takes the next free number.

**C5.12 Events at start.** The first line of the first file written by a process is a `start` event.

---

## C6. `log run`

**C6.1** `log run [flags] -- PROGRAM [ARGS...]` starts `PROGRAM` with stdin inherited and stdout and stderr connected to one pipe, which is processed exactly as `log pipe` processes stdin.

**C6.2** SIGTERM, SIGINT, SIGQUIT, SIGUSR1, SIGUSR2 and SIGHUP received by `log` are forwarded to the child. SIGHUP also reloads `log`'s config. When `log` is PID 1, it reaps orphaned descendants.

**C6.3 Exit code.** After the child exits and the pipe reaches EOF, `log` flushes and exits with the child's exit code, or `128 + N` if the child was killed by signal N. If `PROGRAM` cannot be started, `log` writes a `run-failed` event and exits 127.

---

## C7. Retention, pruning and disk space

**C7.1 Age.** A closed data file whose newest line is older than `max_age` is deleted. "Newest line" is `last_ts` from the footer, else from the last metadata frame, else the file's mtime.

**C7.2 Total.** After age pruning, the oldest closed data files (by date, then numeric `seq`) are deleted until the sum of all data files, the mirror and `previous.log` is ≤ `max_total`.

**C7.3 When.** Pruning runs at start and after every rotation, only in the process holding the pruner lock (C7.6).

**C7.4 Never deleted by pruning:** any data file currently open by a running writer. Each writer MUST hold `flock(LOCK_SH)` on its open data file; the pruner MUST skip any file on which `flock(LOCK_EX|LOCK_NB)` fails. **[decided here]**

**C7.5 Pruned files** are reported in one `pruned` event per pruning run that deleted anything.

**C7.6 Pruner lock.** On start, the writer tries `flock(LOCK_EX|LOCK_NB)` on `.<prefix>.lock`. If it fails, the writer writes a `lock-held` event, does not prune, and retries at each rotation; on success it writes `lock-acquired`. Two writers for the same prefix MUST both be able to write concurrently without blocking and without name collisions.

**C7.7 Free space.** Free space is `f_bavail × f_bsize` of the log directory's filesystem. When it drops below `min_free`, the writer, in this order:

1. stops writing the mirror and deletes `<prefix>.current.log` and `<prefix>.previous.log`;
2. deletes its own closed data files, oldest first, until free space ≥ `min_free` (only if it holds the pruner lock; otherwise it skips this step);
3. if still below `min_free`, enters discard mode.

**C7.8 Discard mode** ends only when free space ≥ `min_free + resume_margin`. While in discard mode, the writer keeps reading stdin, keeps the newest `ring_size` bytes of lines in memory and drops older ones.

**C7.9 Leaving discard mode** (or reaching EOF while in it), the writer writes one `discarded` event (C10) followed by the retained newest lines, then resumes normally. Lines written after a discard keep their original arrival stamps.

**C7.10** Any other write error (`EIO`, `EACCES`, `EROFS`…) is handled like discard mode with `reason=write-error`, retried at most once per second, and produces a `write-error` event when writing works again.

**C7.11** The ring overflowing because the disk is slower than the input produces a `discarded` event with `reason=ring-full` covering the dropped lines.

---

## C8. Data file format

**C8.1 Layout.** A data file is a concatenation of frames:

```
D0 M0 D1 M1 … Dn Mn F
```

- `Di` — a zstd data frame (RFC 8878), the first frame in the file.
- `Mi` — a metadata skippable frame describing `Di`, written immediately after `Di` closes.
- `F` — the footer skippable frame, present only after a clean close.
- A file being written, or left by a crash, ends with `Dn` (possibly unfinished) and no `Mn` or `F`.

**C8.2 Data frames.** Standard zstd frames: content checksum flag set, frame content size absent, window size ≤ 8 MiB. Each frame contains only whole stored lines (C5.3). Concatenating the decompressed content of all data frames in order yields the stored lines in arrival order. An open frame is flushed (a complete block written) at least once per second.

**C8.3 Metadata frame.** Skippable frame: magic `0x184D2A50` (u32), frame size `30` (u32), then a 30-byte payload:

| Offset | Field | Type | Meaning |
| --- | --- | --- | --- |
| 0 | version | u8 | `1` |
| 1 | first_ts | i64 | Arrival of first line in `Di`, Unix ns |
| 9 | last_ts | i64 | Arrival of last line in `Di`, Unix ns |
| 17 | lines | u32 | Stored lines in `Di` (each piece counts) |
| 21 | raw_size | u32 | Decompressed bytes of `Di` |
| 25 | data_size | u32 | Bytes of `Di` on disk, from its magic to its end |
| 29 | flags | u8 | Bit 0: `Di` contains a `discarded` event; bits 1–7: 0 |

The metadata frame is therefore 38 bytes on disk, and `offset(Mi) = offset(Di) + data_size`.

**C8.4 Footer.** Skippable frame: magic `0x184D2A51` (u32), frame size `P` (u32), then a `P`-byte payload: header (38 bytes), `n` entries (36 bytes each), trailer (16 bytes). `P = 38 + 36n + 16`.

Header:

| Offset | Field | Type | Meaning |
| --- | --- | --- | --- |
| 0 | version | u8 | `1` |
| 1 | flags | u8 | Bit 0: file contains a `discarded` event |
| 2 | first_ts | i64 | Arrival of the file's first line, Unix ns |
| 10 | last_ts | i64 | Arrival of the file's last line, Unix ns |
| 18 | lines | u64 | Stored lines in the file |
| 26 | log_events | u32 | Event lines (C10) in the file |
| 30 | discarded | u64 | Bytes discarded while this file was current |

Entry `i` (at payload offset `38 + 36i`):

| Offset | Field | Type | Meaning |
| --- | --- | --- | --- |
| 0 | offset | u64 | File offset of `Di` |
| 8 | data_size | u32 | As in C8.3 |
| 12 | raw_size | u32 | As in C8.3 |
| 16 | first_ts | i64 | As in C8.3 |
| 24 | last_ts | i64 | As in C8.3 |
| 32 | lines | u32 | As in C8.3 |

Trailer (the last 16 bytes of the payload, and therefore of the file):

| Offset | Field | Type | Meaning |
| --- | --- | --- | --- |
| 0 | entries | u32 | `n` |
| 4 | payload_size | u32 | `P` |
| 8 | crc32c | u32 | CRC-32C (Castagnoli) of payload bytes `[0, P−16)` |
| 12 | magic | u32 | `0x464F474C` (bytes `4C 47 4F 46`, "LGOF") |

**C8.5 Reading rules.**

1. A reader finds the footer by reading the last 16 bytes; it is valid only if `magic` matches, `payload_size` fits the file, the 8 bytes before the payload are the footer skippable header with frame size `P`, and the CRC matches.
2. Without a valid footer, the reader walks frames from offset 0 using frame headers.
3. A metadata frame or footer whose `version` is greater than the reader supports MUST be ignored; the reader falls back to decoding data frames.
4. Skippable frames with other magic numbers (`0x184D2A52`–`0x184D2A5F`) MUST be skipped.
5. An unfinished last data frame is decoded up to its last complete block; the remaining bytes are reported as a truncated tail, not an error.
6. A corrupt data frame is skipped (using `data_size` from its metadata frame when available) and reported; reading continues with the next frame.

**C8.6 Compatibility.** Every closed data file and every crash-truncated data file MUST decompress with `zstd -dc` (reference CLI ≥ 1.5) to exactly the stored lines, ignoring a truncation error for crash-truncated files. Same for 7-Zip ≥ 24.01, Python `zstandard`, and klauspost `zstd`. (The 7-Zip check is manual; the others are automated.)

---

## C9. Plain mirror

**C9.1** With `mirror = true`, every stored line (after splitting and charset handling) is also appended to `<prefix>.current.log` immediately, as:

```
<local-stamp><sep><text>\n
```

`<local-stamp>` is exactly 32 bytes: `YYYY-MM-DDTHH:MM:SS.ffffff±hh:mm`, the same instant as the stored stamp, in local time. `<sep>` and `<text>` are identical to the stored line. With `stamp = "none"`, mirror lines are `<text>\n`.

**C9.2** The mirror is never read by any `log` command.

**C9.3** When the mirror reaches `mirror_max`, its oldest part is removed in place with `FALLOC_FL_COLLAPSE_RANGE`: the largest multiple of the filesystem block size that is ≤ half the file. The partial line now at the start of the file is overwritten with `[log] mirror trimmed` padded with spaces to the same length (if the partial line is shorter than that text, it is overwritten with spaces). The file MUST never become empty because of trimming.

**C9.4** After trimming, the file MUST still start at a line boundary as seen by `head -1` (the marker line).

**C9.5** If collapsing fails with `EOPNOTSUPP`, the file is renamed to `<prefix>.previous.log` (replacing an older one) and a new mirror is started.

**C9.6** A failed mirror write disables the mirror until the next rotation and produces a `mirror-disabled` event. Data file writing is unaffected.

---

## C10. Event lines

**C10.1** `log` records its own events as stored lines whose text has the form:

```
[log] <event> key=value key=value …
```

Values that contain a space, `"`, `=` or a non-printable byte are written as Go-quoted strings (`strconv.Quote`). Byte counts are plain integers; times are RFC 3339 UTC with microseconds. Keys appear in the order listed below. Future versions MAY append keys; readers MUST ignore unknown keys.

**C10.2 Catalog.**

| Event | Keys | When |
| --- | --- | --- |
| `start` | `version pid config` | First line of a process's first file |
| `stop` | `lines bytes discarded` | Last line before a clean close at EOF |
| `config-invalid` | `key value using` | Invalid value replaced by default (C4.1) |
| `config-reload` | `result reason ignored` | After SIGHUP (C5.8) |
| `clock-step` | `back_by` | First line after C5.6 |
| `lock-acquired` | | Pruner lock taken (C7.6) |
| `lock-held` | | Pruner lock busy (C7.6) |
| `pruned` | `files bytes reason` | `reason` = `age`, `total` or `low-disk` |
| `discarded` | `bytes lines from to reason` | `reason` = `low-disk`, `write-error`, `ring-full`, `no-dir` |
| `write-error` | `op errno count` | Writing recovered after C7.10 |
| `mirror-disabled` | `reason` | C9.6 |
| `run-failed` | `program error` | C6.3 |

**C10.3** Every event is also written to stderr as `log: <event line text>`. With `syslog = true`, it is also sent to syslog (facility `daemon`, tag `log`). Events that cannot be stored because of a disk problem MUST still go to stderr (and syslog).

---

## C11. Reading commands

**C11.1 Sources.** A read command reads all data files of the selected prefix(es) in the selected directory (C4.3). `--prefix a,b` selects several; results are merged by stored stamp.

**C11.2 Records.** Unless `--lines` is given, consecutive lines are grouped into records: a line whose text (after the stamp and separator) matches any `continuation` pattern joins the preceding record; any other line starts a new one. Continuation pieces (`+`) always join their line before grouping, and are output as one line.

**C11.3 Time selection.** A record is in range if its first line's stamp is in `[since, until)`.

**C11.4 Output format.** Each output line is:

| Mode | Format |
| --- | --- |
| default | `<local-stamp> <text>` (C9.1 stamp format) |
| `--utc` | `<stamp> <text>` (stored format) |
| `--no-stamp` | `<text>` |

Lines of files written with `stamp = "none"` are printed as `<text>` in every mode.

**C11.5 Order.** Output is in stamp order, oldest first; files that overlap in time (C5.6) are merged by stamp. `--newest-first` reverses record order (lines within a record keep their order).

**C11.6 `log cat [--since T] [--until T]`** prints every record in range. Without bounds, everything.

**C11.7 `log grep PATTERN`** prints records containing a match in any of their lines. Flags: `--since`, `--until`, `--newest-first`, `-n N` (stop after N records), `-i` (case-insensitive), `-F` (fixed string), `--lines`. Pattern syntax is Go RE2 syntax. Exit 0 if any record matched, 1 if none, 2 on a bad pattern.

**C11.8 `log tail [-n N] [-f]`** prints the newest N records (default 10). With `-f`, it then follows new lines, across rotations and across new files from other writers, until interrupted; new lines appear within 2 s of being flushed.

**C11.9 `log view [--since T] [--until T]`** writes `log cat` output to `$PAGER`, or `less -n -R` if unset.

**C11.10 `log stat [--json]`.** Without `--json`, a human-readable table (format not part of this contract). With `--json`, one JSON object per data file, one per line, oldest first:

```json
{"file":"app.2026-10-26.001.log.zst","date":"2026-10-26","seq":1,"size":123456,
 "first_ts":"2026-10-25T16:00:00.000001Z","last_ts":"2026-10-26T15:59:59.999999Z",
 "lines":1234,"log_events":3,"discarded":0,"footer":true,"truncated":false,"current":false}
```

`footer` is false for files without a valid footer; then `lines`, `log_events` and `discarded` are computed by reading the file. `current` is true for the file `<prefix>.current.log.zst` links to.

**C11.11 Damaged input.** Read commands MUST NOT fail on truncated or corrupt files; they print what is readable, report damage to stderr as `log: <file>: <problem>`, and exit 0 (or the `grep` code) unless no file could be read at all (exit 3).

---

## C12. `log export`

**C12.1** `log export [--since T] [--until T] [--grep PATTERN] [--format gz|zst|tzst|txt] -o FILE`. Default format `gz`. `-o -` writes to stdout (not allowed for `tzst`). An existing `FILE` is an error (exit 2) unless `--force`.

**C12.2 Content.** For `gz`, `zst` and `txt`, the uncompressed content is byte-identical to `log cat` (or `log grep` with `--grep`) with the same range and output flags.

**C12.3 Formats.**

- `gz`: a single gzip member.
- `zst`: standard zstd frames only, no skippable frames.
- `txt`: uncompressed.
- `tzst`: a POSIX ustar/PAX tar archive compressed with zstd. One regular-file member per source data file that contributed lines, named after the source file without `.zst` (`app.2026-10-26.001.log`), containing that file's in-range output. Member mtime = the member's last stamp; mode `0644`.

**C12.4** On error, no partial `FILE` is left behind.

---

## C13. `log init` and `log doc`

**C13.1 `log init [PATH] [--for PROGRAM] [--force]`** writes a TOML config to `PATH` (default `./log.toml`; `-` for stdout) containing every key in C4 with its default (or the preset's value), each preceded by a one-line `#` comment. An existing file is an error (exit 2) unless `--force`. The written file MUST pass `log init --check`.

**C13.2 `log init --check FILE`** validates `FILE`; exit 0 if valid, 2 otherwise, listing every invalid key on stderr.

**C13.3 `log doc`** lists known programs, one per line: `<name>  <one-line description>`. 0.1 knows `tomcat` and `systemd`.

**C13.4 `log doc PROGRAM [--config PATH]`** prints instructions in Markdown, which MUST include a fenced code block with the integration snippet. For `tomcat`, the snippet is the `CATALINA_OUT_CMD=…` line for `bin/setenv.sh`; for `systemd`, an `ExecStart=` line using `log run`. With `--config PATH`, `PATH` appears verbatim in the snippet. An unknown program exits 2.

**C13.5** `log init --for X` and `log doc X` use the same preset: the config values shown by `doc` equal those written by `init`.

---

## C14. Decisions made in this draft

Review these; each was left open by the design doc and fixed here so tests can be written.

1. Binary size units (C1.1).
2. DST overlap resolves to the earlier instant; DST-gap times are invalid (C1.3).
3. Prefix charset excludes dots (C3.1).
4. Only one missing directory level is created (C3.3).
5. Defaults `dir = "."`, `prefix = "app"` (C4).
6. 100 ms bound for "never blocks" (C5.1); 2 s durability bound (C5.10).
7. `stamp = "none"` does not mark continuation pieces (C5.3).
8. Long-line splits respect UTF-8 sequences (C5.4).
9. `log pipe` always exits 0 and ignores unknown flags (C5.9).
10. Writers hold `LOCK_SH` on their open file so the pruner can skip it (C7.4).
11. Event line syntax, keys and the event catalog (C10).
12. `grep` exit codes follow grep (C2.4); damaged files are not fatal (C11.11).
13. `stat --json` schema (C11.10).
14. Export member naming and metadata for `tzst` (C12.3).
15. `log doc` knows `tomcat` and `systemd` in 0.1 (C13.3).
