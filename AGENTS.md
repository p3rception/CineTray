# AGENTS.md

Rules for anyone contributing to CineTray, human or AI agent. If you use a coding
agent, point it at this file and at `CLAUDE.md` (build commands, platform
constraints, architecture) before it writes anything.

These rules are strict on purpose, since the project is maintained by one person.

## 2. Before writing code, stop at the first rung that holds

1. Does this need to be built at all? If the need is speculative, don't
   build it.
2. Does the Swift standard library or Foundation already do it? Use it.
3. Does a macOS framework or SwiftUI feature cover it? Use it.
4. Does an existing dependency (SwiftVLC) or existing code in this repo solve
   it? Use it. Search the repo before writing a helper.
5. Can it be one line? Make it one line.
6. Only then: write the minimum code that works.

Deletion over addition. Boring over clever. Fewest files possible. The
shortest diff that works wins.

Never simplify away: validation of data from servers, files or the user,
error handling that prevents data loss, security, or accessibility.

## 3. Abstractions

- No protocol with a single conformer. No generic with a single concrete
  type. No factory, builder, coordinator, manager, service or wrapper for one
  use. `MediaProvider` is a protocol because there are three providers.
- Extract a shared function on the third duplicate, not the second.
- No new layers between existing ones (no view models over `AppState`, no
  repositories over providers, no "service" in front of `URLSession`).
- No settings, flags or parameters for values nobody has asked to change.
- No code "for later": no unused parameters, empty extension points, stub
  cases or scaffolding.
- Extend the file that already owns the concern. A new file needs a reason
  the pull request states.
- No new dependencies. If you think one is necessary, open an issue first and
  explain why a few lines of code cannot replace it.

## 4. Comments

A comment must tell the reader something the code cannot: why it is done this
way, a constraint, a server quirk, a platform bug.

```swift
// macOS can't display HEVC in MPEG-TS segments, so ask for fragmented MP4.
```

Not allowed:

- Comments that restate the code (`// Load the items`, `// Increment count`).
- Doc comments that repeat the name and signature. `///` is fine when it adds
  meaning, as in `ArtworkCache.swift`.
- History in comments (`// Changed to fix X`, `// New implementation`,
  `// Added by ...`). That belongs in the commit message.
- Commented-out code, `TODO`s without an issue number, and banner or
  decorative comments.

Match the comment density of the surrounding code.

## 5. Scope

- One change per pull request. A bug fix does not also rename, reformat or
  "clean up" nearby code.
- Do not touch files unrelated to the change: no formatting churn, no
  reordered imports, no unrelated `project.pbxproj` or `Package.resolved`
  changes.
- Remove code your change makes unused. Do not leave `old`, `legacy`, `v2`,
  `new` or `backup` copies behind.
- Do not add documents the project did not ask for (`SUMMARY.md`,
  `IMPLEMENTATION.md`, notes, plans, reports).
- Features and changes over about 200 lines: open an issue and agree on the
  approach first.

## 6. Swift and this codebase

- Follow `CLAUDE.md`: macOS 26 deployment target, no iOS code paths, both
  build paths must work, settings keys in `SettingsKeys` or `KeychainKeys`,
  no tokens in URLs that get saved.
- Do not silence concurrency diagnostics. No `@unchecked Sendable`,
  `nonisolated(unsafe)`, `MainActor.assumeIsolated`, `DispatchQueue.main.async`
  or `Task { @MainActor in }` added only to make the compiler quiet. Fix the
  isolation.
- No force unwraps or `try!` on data from servers, files or the user.
- No `try?` that drops an error the user or the data depends on. Handle the
  errors that can happen; do not add guards for states that cannot.
- No new compiler warnings.
- No `print` debugging left in. No logging of tokens, passwords or server
  responses that contain them.
- Check that every API you call exists in the macOS 26 SDK. Agents invent
  APIs and parameters; the compiler is the proof, not the agent.
- Match the naming and idioms of the surrounding code. No `Enhanced`,
  `Improved`, `Helper`, `Utils` or `Manager` names for new types.
- Do not add a test target, linter or formatter config unless asked.
- Never commit `CineTray/Secrets.swift`.

## 7. Text

- No emojis, anywhere: code, comments, UI,
  commits, pull requests.
- The app is CineTray. Show `MediaType.title` ("Shows") to users, not
  `MediaType.rawValue`.
- User-facing strings are short and plain. Follow the style of the existing
  UI and of `CHANGELOG.md`.
- Every user-visible change adds an entry to `CHANGELOG.md` in the same
  commit, written for users, not developers.

## 8. Commits and pull requests

- Commit messages: imperative subject under 72 characters, then a short body
  saying why, if the subject does not.
- The pull request description should include: what changed,
  why, and how you tested it (which build path, what you clicked, which
  server type). No generated essays, no feature tours, no checklists of
  things you did not do.
- Include a screenshot for UI changes.

## Checklist

Before opening a pull request:

- [ ] `./build.sh build` succeeds, with no new warnings.
- [ ] The Xcode project builds, or you state that you could not check it.
- [ ] You ran the app and exercised the change.
- [ ] The diff contains only this change.
- [ ] No new dependencies, files, abstractions or settings that were not
      agreed on.
- [ ] Every comment says something the code cannot.
- [ ] `CHANGELOG.md` is updated if users will notice the change.
- [ ] AI use is disclosed.
