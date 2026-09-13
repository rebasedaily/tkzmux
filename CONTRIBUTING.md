# Contributing to tkzmux

tkzmux is a personal project (see the "Status" section of [README.md](README.md)): no roadmap, no
compatibility promise, no commitment to answer issues. That said, patches are welcome — this file
is how to build it, test it, and get a change in.

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon only — the app, `swift build`, and `swift test` all
  require it, since `Package.swift` targets it and the vendored `libghostty-vt` xcframework is
  arm64-only.
- Xcode 26.1 (CI builds against it explicitly). `xcrun metal` needs its toolchain, which on a
  fresh Xcode install is a separate download:
  ```sh
  xcodebuild -downloadComponent MetalToolchain
  ```
- [Claude Code](https://claude.com/claude-code) installed and working in your shell, to actually
  exercise the app.

## Getting the code

```sh
git clone https://github.com/tkz0/tkzmux
cd tkzmux
```

Pure SwiftPM — there is no `.xcodeproj` to generate or open.

## Building and running

```sh
swift build              # debug build of every target
swift run tkzmux         # run the app outside a bundle (the window still appears)
make app                 # release build → build/tkzmux.app, ad-hoc signed
open build/tkzmux.app
```

`swift run` is the fastest inner loop for most changes. Reach for `make app` when you need a real
`.app` bundle — e.g. to test anything that depends on bundle identity, Launch Services, or the
statusline/hook shim install path.

`make app` derives its version from `git describe`; override it with `VERSION=1.2.3 make app` if
you need a specific one. A real (non-ad-hoc) code signature — needed for Gatekeeper-sensitive
testing — is one variable:

```sh
SIGN_IDENTITY="Developer ID Application: …" make app
```

If you're touching `vendor/ghostty-vt`, `make vendor` rebuilds the xcframework from the pinned
commit in `vendor/ghostty-vt/COMMIT` (needs zig 0.16.x, `xcodebuild`, and `tic`, plus network
access) — most changes never need this.

## Replacing a Homebrew install with a local build

If you normally install via the tap:

```sh
brew tap tkz0/tap
brew trust --cask tkz0/tap/tkzmux
brew install --cask tkzmux
```

and want to switch to a build from your working tree instead:

1. `brew uninstall --cask tkzmux` (the tap itself is harmless to leave; `brew untap tkz0/tap` if
   you want it gone too).
2. `make app` from the repo root, then either:
   - run it in place — `open build/tkzmux.app` — which is enough for day-to-day use and gets
     rebuilt in place every time you re-run `make app`, or
   - install it like the cask did: `cp -R build/tkzmux.app /Applications/`.

Both builds share the same bundle identifier, so don't keep a brew-installed copy and a
locally-built copy in `/Applications` at the same time — Launch Services will pick one
unpredictably. Uninstall the cask first (step 1) before copying a local build into `/Applications`.

## Testing

```sh
swift test                          # all test targets (Swift Testing: `import Testing`, `@Test`, `#expect`)
scripts/test-memory-probe.sh        # per-target, watched: RSS cap + stall timeout, diagnoses before killing
scripts/test-memory-probe.sh ALL    # the unfiltered `swift test`, under the same watchdog
```

Prefer `scripts/test-memory-probe.sh` over a bare `swift test` when a run looks suspicious (new
process-spawning code, a suite that hangs). A runaway `swift test` is billed to whatever process
started it, not to itself — on this project that has taken a machine down before — so the probe
watches RSS and stalls and diagnoses before killing, instead of letting it run unbounded.

CI (`.github/workflows/ci.yml`) runs `swift build` then `swift test --no-parallel` on a macOS 26 /
Xcode 26.1 runner for every push and PR; `--no-parallel` isn't a style preference there, some
suites assert timing behavior that a starved runner makes flaky. Match that before you push if you
can (`swift test --no-parallel` locally), since CI is the actual gate.

## Code conventions

The full list of hard rules — Swift 6 strict concurrency (no `-strict-concurrency=minimal`, no
`@unchecked Sendable`), no SwiftUI on hot paths, no `@Observable` for the store, no third-party
dependencies beyond `libghostty-vt`, never copy code from cmux (GPL-3; Ghostty is MIT and may be
read for reference, but only used through libghostty-vt's public C API), no personal names or
account labels in code — lives in [CLAUDE.md](CLAUDE.md), along with the module map. Read it before
your first change; it's the same file a Claude Code session in this repo is bound by, so it's kept
current on purpose.

## Making a change

- One topic per PR. `CLAUDE.md`'s own convention for larger work is one ticket per branch/worktree
  (`claude -w <name>` from the main checkout, if you're using Claude Code) — not required for a
  small PR, but a useful habit for anything that touches more than one module.
- Add or update tests under `Tests/<Module>Tests` alongside the module you changed — there's one
  test target per Swift library target.
- Keep `swift build` and `swift test --no-parallel` green before opening the PR.
- Describe *why* in the PR description, not just what changed — the diff already shows what.
- Release notes group commits into *New features*, *Bug fixes* and *Other changes* by guessing
  from the subject line. To steer the guess, label the PR `bug`, `enhancement` or `documentation`,
  or start the subject with `fix:` / `feat:` / `docs:` / `chore:`. Preview what the next release
  would say with `scripts/release-notes.sh HEAD`.

## Release process

Cutting a signed, notarized release (`make dist`, the `release.yml` workflow, credential rotation)
is documented in `docs/release.md`, which is intentionally not checked into the repo — it's a
personal runbook full of machine-specific and credential details. Not needed to contribute a
change; only relevant if you're cutting a release.
