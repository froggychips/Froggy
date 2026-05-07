# Contributing to Froggy

Thanks for your interest. Before opening an issue or PR, please skim
[`docs/POSITIONING.md`](docs/POSITIONING.md) and
[`docs/THESIS.md`](docs/THESIS.md) — they explain what this project is
trying to be and what it isn't, which determines whether your idea
fits.

Froggy is a personal research project under MIT. Contributions are
welcome but evaluated against the thesis, not against general
"making it better."

## Before opening an issue

- **Bug reports**: include macOS version, Apple Silicon model, RAM
  size, and `froggy decisions --limit 50` output if relevant. Trace
  data is local-only and contains no screen content; redact bundle
  ids you don't want to share.
- **Feature requests**: explain why the feature passes the
  qualitative-vs-quantitative test from `THESIS.md`. "It would be
  nice if Froggy ran on Intel Macs" is out of scope by design;
  please don't open issues like that. "It would be nice if Froggy
  could detect screen-share sessions to avoid freezing the sharing
  app" is in scope and welcome.
- **Questions**: Telegram [@froggychips](https://t.me/froggychips)
  is faster than GitHub Issues for open-ended questions.

## Before opening a PR

1. **Discuss first** for anything beyond a typo, a small bug fix, or
   an obvious code-quality improvement. Open an issue or ping on
   Telegram before writing the patch — saves you time if the change
   doesn't fit the thesis.
2. **Architectural changes go through ADRs.** If your PR adds a
   subsystem or changes a load-bearing decision, write an ADR in
   `docs/adr/` as part of the PR. See existing ADRs for the format.
3. **New components get design-docs first.** If your PR introduces
   a new actor, IPC command, or major component, write a design-doc
   in `docs/design/` and merge it before the implementation PR. See
   `docs/design/activity-detection.md` for the format.
4. **Mind the documentation/implementation order.** Per
   [ADR 0009](docs/adr/0009-design-docs-after-implementation.md),
   design-docs for layers beyond the one currently being built are
   declined by default — they create documentation gravity trap.

## Code conventions

- Swift 6, strict concurrency, `ExistentialAny`. No relaxations,
  including in tests.
- New system calls (`task_for_pid`, `mach_vm_*`, `dispatch_source_*`,
  `posix_spawn`, etc.) go through a thin Swift wrapper for
  testability — see existing patterns in `Pageout.swift`,
  `MemoryPressureMonitor.swift`.
- Logging via `os_log` / `os_signpost`, not `print`.
- No new runtime dependencies in `Package.swift` unless the task is
  physically unsolvable without one. SQLite goes through `sqlite3`
  C-API, not `SQLite.swift`.
- Comments explain *why*, not *what*. Function names explain *what*.
  See operating principles in [`docs/THESIS.md`](docs/THESIS.md).

## Tests

- Run `swift test --parallel` locally before pushing. CI will run it
  again, but a green local run saves a round-trip.
- New components get unit tests with injected fakes for OS
  dependencies (audio HAL, AX, MLX, etc.). See `MemoryPressureMonitorTests`,
  `PageoutChainTests` for the pattern.
- Integration tests that need real macOS resources go behind an env
  flag (`FROGGY_RUN_INTEGRATION_TESTS=1`) and are skipped in CI.

## Commit messages

Either English or Russian — the project codebase is bilingual. Follow
the style of recent commits in `git log`. Conventional Commits
(`feat:`, `fix:`, `docs:`, `chore:`) preferred but not enforced.
Multi-line is welcome — reasoning beats brevity.

## Pull request format

Look at recent merged PRs (#9, #10, #11, #16, #18, #19) for the
expected shape:

- Title: short, imperative.
- Body: **Зачем** / **Что** / **Тесты** / **Что осталось**, or the
  English equivalent. Explain the *why* in the first paragraph.
- Reference the relevant ADR or design-doc.
- Include test results summary.

## License

By submitting a PR, you agree your contribution is licensed under
[MIT](LICENSE). Don't include code under incompatible licenses
(GPL, AGPL, source-available, etc.) without flagging it explicitly.

## Code of conduct

Don't be a jerk. The author runs this project for fun; if
contributions stop being fun for either side, the project loses.
