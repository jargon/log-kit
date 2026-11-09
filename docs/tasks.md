# Tasks

Each task names the contract rules it must satisfy. A task is done when `make check` passes, the black-box tests for its rules pass (none skipped except `pending Q<n>`), and the adversarial review has no open blocker or major finding.

Per phase: `blackbox-tester` writes the phase's tests first (they should fail) → `implementer` works through the tasks → `adversarial-reviewer` and `fault-fuzz-engineer` attack → fixes → human review and merge.

## Phase 0 — Scaffolding

- [ ] **T0.1 Repo skeleton.** `go.mod` (Go ≥ 1.25), package layout from `CLAUDE.md`, `Makefile` targets wired up, CI green on an empty `log --version`. Pick the TOML library. *Refs: C2.2*
- [ ] **T0.2 Black-box module.** `test/blackbox/go.mod`, helpers to exec `$LOG_BIN`, temp dirs, a C8 parser written from the contract, `zstd -dc` wrapper. *Owner: blackbox-tester*
- [ ] **T0.3 Config and units.** Sizes, durations, time arguments, TOML loading, defaults struct, validation, discovery, flag precedence. *Refs: C1, C2.3, C4, C4.2, C4.3*

## Phase 1 — Writer core

- [ ] **T1.1 Stamps.** UTC stamp format, local stamp format, monotonic within a file, ≤ 1 s step absorption. *Refs: C5.3, C5.5, C9.1 (format only)*
- [ ] **T1.2 Line handling.** Split on `\n`, strip `\r`, final newline, long-line pieces with `+`, UTF-8-safe splits, `latin1` option, `stamp = "none"`. *Refs: C5.2, C5.3, C5.4*
- [ ] **T1.3 Ring buffer.** Byte ring, overwrite-oldest at a line boundary, dropped-byte accounting, doorbell channel; race-free copy-out. *Refs: C5.1, C7.11 (accounting)*
- [ ] **T1.4 Data frames.** zstd level 3 frames with checksum, 1 s block flush, close at 1 MiB / 60 s, whole lines only. *Refs: C8.2, C5.10, C4.4*
- [ ] **T1.5 Files and rotation.** Naming, `O_EXCL` seq claim, `current` link swap, rotation on size / `rotate_every` / midnight / clock step, never append, `LOCK_SH` on the open file. *Refs: C3.1–C3.6, C5.6, C5.11, C7.4 (lock)*
- [ ] **T1.6 Pipe lifecycle.** Read until EOF, signals, `start`/`stop` events, always exit 0, unknown flags as events. *Refs: C5.1, C5.7, C5.9, C5.12, C10 (start, stop, config-invalid)*

## Phase 2 — Retention and safety

- [ ] **T2.1 Event lines.** Formatting, quoting, key order, stderr copy, syslog. *Refs: C10*
- [ ] **T2.2 Pruner.** Age then total, oldest first, skips locked files, pruner lock, `lock-held`/`lock-acquired`, `pruned` events, runs off the write path. *Refs: C7.1–C7.6*
- [ ] **T2.3 Free-space guard.** `f_bavail`, headroom-based checking, mirror first, own files next, discard mode, hysteresis, retained newest lines, `discarded` event. *Refs: C7.7–C7.9*
- [ ] **T2.4 Write errors and no-dir.** Treat as discard, retry ≤ 1/s, `write-error` and `discarded reason=no-dir`. *Refs: C4.1, C7.10*
- [ ] **T2.5 SIGHUP reload.** Validate all-or-nothing, apply "at once" keys, `config-reload` event with `ignored=`. *Refs: C5.8*
- [ ] **T2.6 Plain mirror.** Local-time lines, collapse-range trim with marker, `EOPNOTSUPP` fallback, disable on failure. *Refs: C9*

## Phase 3 — Metadata, stat, compatibility

- [ ] **T3.1 Metadata frames.** Written after each data frame, exact layout. *Refs: C8.1, C8.3*
- [ ] **T3.2 Footer.** Header, entries, trailer, CRC-32C; written only on clean close. *Refs: C8.4, C5.9*
- [ ] **T3.3 Frame reader.** Footer lookup, frame walk, version skipping, foreign skippable frames, truncated tail, corrupt frame skip. *Refs: C8.5*
- [ ] **T3.4 `log stat`.** Human table and `--json`. *Refs: C11.10*
- [ ] **T3.5 Compatibility test.** Automated: `zstd -dc`, Python `zstandard`, klauspost on closed, footer-less and truncated files. Manual checklist for 7-Zip ≥ 24.01. *Refs: C8.6*
- [ ] **T3.6 First deployment.** Tomcat test instance with `CATALINA_OUT_CMD`; one week of `log stat` checks. *Owner: human*

## Phase 4 — Search

- [ ] **T4.1 Source selection.** Discovery, `--prefix a,b`, file selection by name and footer, frame selection by metadata. *Refs: C4.3, C11.1, C11.3*
- [ ] **T4.2 Parallel decode and merge.** Decode frames on all cores; merge overlapping files by stamp; newest-first. *Refs: C11.5*
- [ ] **T4.3 Records.** Continuation rules, piece rejoining, records across frame boundaries, `--lines`. *Refs: C11.2*
- [ ] **T4.4 Matcher.** coregex behind an interface with stdlib fallback, whole-frame matching, `-i`, `-F`. *Refs: C11.7*
- [ ] **T4.5 `cat`, `grep`, `view`.** Output modes, exit codes, `-n`. *Refs: C11.4, C11.6, C11.7, C11.9, C2.4*
- [ ] **T4.6 `tail`.** Newest N, `-f` across rotations and other writers' files (inotify + polling). *Refs: C11.8*
- [ ] **T4.7 Damaged input.** Never fail on bad files; stderr reports; exit codes. *Refs: C11.11*
- [ ] **T4.8 Benchmarks.** Writer throughput/CPU, search GB/s, last-match latency, compression vs one continuous stream at 1/10/100 KB/s on real Tomcat output. *Refs: design "Performance targets"*

## Phase 5 — Integration helpers and export

- [ ] **T5.1 `log run`.** Child process, signal forwarding, PID 1 reaping, exit codes, `run-failed`. *Refs: C6*
- [ ] **T5.2 Presets.** Embedded `tomcat` and `systemd` presets shared by init and doc. *Refs: C13.5*
- [ ] **T5.3 `log init`.** Commented config from the defaults struct, `--for`, `--force`, `--check`. *Refs: C13.1, C13.2*
- [ ] **T5.4 `log doc`.** List, per-program Markdown with snippet, `--config` substitution. *Refs: C13.3, C13.4*
- [ ] **T5.5 `log export`.** `gz`, `zst`, `txt`, `tzst`; byte-identical to `cat`; no partial files. *Refs: C12*

## Later

- [ ] **T6.1 Trigram bloom filters per frame**, only if T4.8 shows time-range skipping is not enough.
