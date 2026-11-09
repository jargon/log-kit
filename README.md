# `log` — agent starter kit

Everything needed to start building `log` with Claude Code agents. No Go code yet; Phase 0 creates it.

```
CLAUDE.md                        project rules every session loads
docs/design.md                   design doc (rationale)
docs/contract.md                 observable behaviour, rule IDs C1–C14  ← tests are written from this
docs/tasks.md                    phased tasks with contract refs
docs/contract-questions.md       where agents raise ambiguities
.claude/agents/                  implementer, blackbox-tester, adversarial-reviewer,
                                 fault-fuzz-engineer, spec-keeper
Makefile                         build / check / blackbox / fuzz-smoke
.github/workflows/ci.yml         make check + fuzz smoke on every push/PR
```

## 1. Before any agent runs

1. Create the repo from this folder and push it.
2. Read `docs/contract.md` C14 and answer Q1 in `docs/contract-questions.md`. Those 15 decisions shape every test; changing them later costs rework.
3. Install `zstd` and (optionally) `faketime` and `python3-zstandard` locally; the black-box tests use them.

## 2. Isolate the black-box tester

The tester must not see the implementation. Give it its own worktree that only contains the contract and its test module:

```sh
git worktree add ../log-blackbox
cd ../log-blackbox
git sparse-checkout set --no-cone '/docs/contract.md' '/docs/contract-questions.md' '/test/blackbox/' '/.claude/'
```

Start Claude Code in `../log-blackbox` for tester work, and point `LOG_BIN` at a binary built in the main worktree. This is a guardrail, not a wall: the git objects are still reachable. For a hard boundary, mirror those paths into a separate repository with a CI job. The agent definition also forbids reading `cmd/` and `internal/`.

## 3. Run a phase

In Claude Code, in the main worktree (the tester step in its own worktree):

1. **Tests first.** "Use the blackbox-tester agent to write tests for every contract rule cited in Phase 1 of docs/tasks.md." Commit; the tests should fail.
2. **Implement.** "Use the implementer agent on T1.1." Repeat per task, ideally each in its own git worktree or branch.
3. **Attack.** "Use the adversarial-reviewer agent on this branch." Then "Use the fault-fuzz-engineer agent on the Phase 1 packages." Feed findings back to the implementer as tasks.
4. **Resolve questions.** "Use the spec-keeper agent on docs/contract-questions.md." Approve or reject proposals yourself, then let it apply them and have the tester update affected tests.
5. **Merge** when CI is green and no blocker or major finding is open.

Phase 0 is mostly sequential (T0.1 → T0.2 and T0.3). From Phase 1 on, tasks within a phase that touch different packages can run in parallel worktrees.

## 4. Where ultracode fits

Keep it off for the delicate core (ring buffer, frame flushing, disk guard): that work is sequential and invariant-heavy. Turn it on, per phase, for fan-out work: writing the black-box suite section by section, fuzz targets across packages, a whole-codebase audit against the contract. Read the workflow's planned phases before approving and check that its test and review steps don't grade their own work. Once a phase loop works, save it as a workflow in `.claude/workflows/` and rerun it for later phases.

## 5. Keep the gates mechanical

`make check` (gofmt, vet, `go test -race`, black-box tests) and CI decide whether a task is done, not an agent's own report. Merges stay a human decision.
