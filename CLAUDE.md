# CLAUDE.md — `log`

`log` is a single Go binary that sits on a program's stdout (`log pipe` / `log run`), writes timestamped, zstd-compressed, size- and age-bounded log files, and searches them fast (`log grep|cat|tail|view|stat|export`). Linux only.

## Sources of truth

| File | Role | Who may change it |
| --- | --- | --- |
| `docs/contract.md` | Observable behaviour. Every rule has an ID (`C7.4`). | Human, or `spec-keeper` with human approval |
| `docs/design.md` | Rationale and internal design | Human, or `spec-keeper` with human approval |
| `docs/tasks.md` | Work breakdown with acceptance criteria | Human; agents tick checkboxes |
| `docs/contract-questions.md` | Ambiguities found while working | Anyone may append |

If code and contract disagree, do not "fix" the contract to match the code. Append a question to `docs/contract-questions.md` and stop on that point.

## Invariants (never trade these away)

1. **`log pipe` never blocks the producer.** No disk state, error, lock or full buffer may stop stdin from being read (C5.1).
2. **`log pipe` never exits before stdin EOF** and always exits 0 (C5.7, C5.9). No `log.Fatal`, no `os.Exit`, no unrecovered panic on the write path.
3. **Disk limits hold**: `max_total`, `min_free`, `max_age` (C7).
4. **Gaps are never silent**: every lost byte is reported by a `discarded` event (C7.9, C7.11).
5. **Files stay readable by standard zstd tools**, including after a crash (C8.6).
6. **Memory is bounded** by `ring_size` plus a fixed overhead.

## Stack

- Go ≥ 1.25 (required by coregex). Standard library first.
- Approved dependencies: `github.com/klauspost/compress/zstd`, `github.com/coregx/coregex` (behind an interface, stdlib `regexp` fallback), a TOML parser (`github.com/BurntSushi/toml` or `github.com/pelletier/go-toml/v2` — pick one in T0.1), `golang.org/x/sys/unix`.
- Any other dependency needs human approval. No cgo.

## Layout (proposed; refine in T0.1)

```
cmd/log/            main, subcommand dispatch
internal/config/    TOML, sizes, durations, validation, defaults struct (source for `log init`)
internal/stamp/     stamp formatting/parsing, monotonic clock handling
internal/ring/      byte ring buffer, overwrite-oldest, doorbell
internal/format/    data/metadata/footer frames: encode, decode, frame walker
internal/writer/    pipe pipeline, rotation, naming, current link, flushing
internal/guard/     free-space checks, discard mode, pruner, locks
internal/mirror/    plain mirror, collapse-range trimming
internal/events/    [log] event formatting
internal/search/    file/frame selection, decode, records, matcher, merge
internal/export/    gz, zst, tzst, txt
internal/presets/   embedded program presets for init/doc
test/blackbox/      separate Go module; execs the binary; written from the contract only
```

## Commands

```sh
make build       # go build -o bin/log ./cmd/log
make check       # gofmt check, go vet, go test -race ./..., blackbox tests
make blackbox    # LOG_BIN=$(pwd)/bin/log go test ./... in test/blackbox
make fuzz-smoke  # each fuzz target for 30 s
```

`make check` must pass before any task is reported done.

## Working rules for all agents

- One task from `docs/tasks.md` at a time. Cite contract IDs in commit messages (`T2.3: pruner skips locked files (C7.4)`).
- Write unit tests with the code. Run `go test -race` on what you touched.
- Do not edit `test/blackbox/` unless you are the `blackbox-tester`. Do not edit `docs/contract.md` or `docs/design.md` unless you are the `spec-keeper` acting on an approved question.
- Do not weaken a test to make it pass. If a test looks wrong, raise it in `docs/contract-questions.md`.
- Inject time, filesystem and `statfs` behind small interfaces so tests can simulate clock steps, `ENOSPC`, `EIO` and slow writes.
- Keep the write path free of anything that can block on disk: no synchronous pruning, `statfs` or mirror trimming in the reader goroutine.
- Never print or log the content of log lines in error messages beyond what the contract specifies; logs may contain personal data.
