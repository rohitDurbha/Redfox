# Redfox notes for Claude

Redfox is Rohit's personal macOS menu bar app (Swift Package, SwiftUI plus AppKit, macOS 13+). It shows a radial glass wheel when a Finder drag is in progress and a modifier is tapped (Shift = convert, Command = tools, Control = actions).

## Releasing

- Pushing to `main` runs `.github/workflows/release.yml` on `macos-15`, builds `build/Redfox.dmg` and publishes release `v1.0.<run_number>`.
- The app's updater (`Updater.swift`) reads `releases/latest` from `rohitDurbha/Redfox` and expects a `.dmg` asset containing `Redfox.app`.
- After pushing, check the run with `gh run list --repo rohitDurbha/Redfox` and `gh run view <id> --log-failed`. Fix compile errors before telling Rohit a release is ready.

## Bundled ffmpeg

- A static Apple silicon ffmpeg ships inside the app at `Contents/MacOS/ffmpeg`. `scripts/fetch-ffmpeg.sh` pins the build and verifies its checksum, and `scripts/smoke-test-ffmpeg.sh` runs in CI to prove every encoder Redfox calls still works.
- When adding a new ffmpeg conversion, add a matching line to the smoke test.

## Commit identity

- Every commit must be authored and committed as `Rohit Durbha <55520009+rohitDurbha@users.noreply.github.com>`. Set this with `git config user.name` and `git config user.email` in the clone before committing.
- Do not add `Co-Authored-By` or `Claude-Session` trailers, or any other Claude attribution, to commit messages or pull requests. Rohit asked for these to be left out.

## Code rules

- Do not use `@State`. On the newest command line tools it is a macro whose plugin only ships with full Xcode, so local builds break. Use `@StateObject private var x = ViewState(value)` and `$x.value` instead (`ViewState` lives in App.swift).
- Keep `swift-tools-version:5.9` and Swift 5 language mode.
- Never put `try await` inside a ternary or another operator expression. Assign it to a local first.
- UI types are `@MainActor`. Heavy work runs inside `JobRunner.each` or `JobRunner.batch` closures, which are `@Sendable` and run off the main thread.
- Results are always written beside the original via `Paths.output(for:ext:suffix:)` and never overwrite the source.
- APIs newer than macOS 13.0 need `#available` checks (for example the PDF write options need 13.4 and background removal needs 14).

## Writing style for docs and messages to Rohit

Warm, plain prose with no colons, semicolons, em dashes or contractions in sentences, and no sentences shorter than eight words.
