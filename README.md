<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-000000?style=for-the-badge&logo=apple&logoColor=white" />
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?style=for-the-badge&logo=swift&logoColor=white" />
  <img src="https://img.shields.io/badge/SwiftUI-MenuBarExtra-007AFF?style=for-the-badge&logo=swift&logoColor=white" />
  <img src="https://img.shields.io/badge/dependencies-zero-brightgreen?style=for-the-badge" />
</p>

# Uncommit

A lightweight, native macOS menu bar app that keeps an eye on all your Git repositories at once. See uncommitted changes, unpulled commits, and repo health — without leaving your workflow.

<br>

## Features

### Repository monitoring
- Tracks **staged**, **modified**, **untracked** and **conflicted** files across every repo
- **Click any status badge** to see the exact file names
- Changes appear as they happen: a single **FSEvents** stream watches every repo and
  refreshes only the ones that actually changed, with a periodic sweep as a backstop
- Health indicators use a distinct glyph *and* colour per state, mirrored in the menu bar
  icon and the dirty-repo count badge

### Remote sync
- **Checks remotes automatically** in the background (on by default, every 15 minutes,
  configurable) so incoming commits show up on their own
- See how many commits you are **ahead** or **behind**, and click either to read the
  actual commits in a resizable window
- **Pull** (always `--ff-only`, never a surprise merge) and **push** per repo, or
  **Pull all** for everything with incoming commits
- One-click **Check Remote** per repo, or **Fetch All** across every repo

### Branches and submodules
- Switch branches from the row, including checking out a remote-only branch
- Submodules whose pointer, branch or content diverged get their own block — never
  rendered as a plain "modified file" — with the recorded → checked-out commit range and
  a one-click `git submodule update`

### Organisation
- Add repos manually or point at a **root folder** and let it discover nested repos
  (configurable depth 2–5), skipping `node_modules`, `Pods`, `DerivedData` and friends
- **Pin** repos to the top; repos needing attention float above clean ones
- **Group by root folder** or show one flat list, and **search** across them
- Repos whose folder was deleted are dropped automatically — an unmounted volume is not
  mistaken for a deletion

### Editors and shortcuts
- Open any repo in **VS Code**, **Cursor**, **Zed**, **Xcode**, JetBrains IDEs and 20+
  more, with a global default and per-repo overrides
- Right-click any repo for pin, copy path, Show in Finder and open-in-editor
- ⌘R refresh · ⇧⌘R fetch all · ⌘F search · ⌘, settings · ⌘Q quit

<br>

## Tech Stack

| | |
|---|---|
| **Language** | Swift 6.0 with strict concurrency |
| **UI** | SwiftUI `MenuBarExtra` (`.window` style popover) |
| **Concurrency** | `async/await`, `TaskGroup`, `@MainActor` |
| **Architecture** | MVVM with `@Observable` macro |
| **Persistence** | `UserDefaults` + `JSONEncoder` |
| **Dependencies** | **None** — pure Swift, no SPM packages |

<br>

## Requirements

- **macOS 14.0** (Sonoma) or later
- **Xcode 16.0+**
- [**XcodeGen**](https://github.com/yonaskolb/XcodeGen) (for project generation)

<br>

## Getting Started

```bash
# Clone the repo
git clone git@github.com:israel-gs/uncommit-app.git
cd uncommit-app

# Generate the Xcode project
xcodegen generate

# Open in Xcode and run (Cmd + R)
open Uncommit.xcodeproj
```

Or build from the command line:

```bash
xcodegen generate
xcodebuild -project Uncommit.xcodeproj -scheme Uncommit -configuration Release build
```

The built app will be in `~/Library/Developer/Xcode/DerivedData/Uncommit-*/Build/Products/Release/Uncommit.app`.

Run the test suite:

```bash
xcodebuild test \
  -project Uncommit.xcodeproj \
  -scheme Uncommit \
  -destination 'platform=macOS'
```

<br>

## Project Structure

```
Uncommit/
├── UncommitApp.swift                # App entry point (MenuBarExtra + commits window)
│
├── Models/
│   ├── GitRepository.swift          # Repo model with per-repo editor + pin state
│   ├── GitStatus.swift              # Status snapshot, submodules, health level
│   ├── RepoState.swift              # Per-repo observable transient state
│   ├── AppConfiguration.swift       # Persisted settings + InstalledApp model
│   └── WatchedFolder.swift          # Root folder for auto-discovery
│
├── ViewModels/
│   └── AppViewModel.swift           # Central @Observable state manager
│
├── Views/
│   ├── PopoverContentView.swift     # Main popover container + search
│   ├── RepoListView.swift           # Flat sorted list
│   ├── GroupedRepoListView.swift    # Grouped-by-root-folder tabs
│   ├── RepoRowView.swift            # Row: status, branches, submodules, actions
│   ├── CommitsWindowView.swift      # Shared window listing pending commits
│   ├── StatusIndicatorView.swift    # Health glyph
│   ├── SettingsView.swift           # Settings panel with editor picker
│   └── EmptyStateView.swift         # Onboarding empty state
│
├── Services/
│   ├── GitService.swift             # Git CLI wrapper + porcelain v2 parser
│   ├── ShellExecutor.swift          # Non-blocking Process execution
│   ├── RepoMonitor.swift            # Refresh engine (events + fallback sweep)
│   ├── RepoWatcher.swift            # FSEvents stream over every repo
│   ├── RepoDiscoveryService.swift   # Recursive .git scanner
│   └── PersistenceService.swift     # UserDefaults read/write
│
└── Utilities/
    ├── EditorHelper.swift           # Editor detection + open-in-app logic
    ├── LaunchAtLoginHelper.swift    # SMAppService login item
    ├── MenuBarIconProvider.swift    # Symbol, colour and description per health
    └── Constants.swift              # Shipped defaults
```

<br>

## How It Works

1. **Startup** — launches as a menu-bar-only process (`LSUIElement = true`). No Dock icon,
   no main window.
2. **Watching** — one FSEvents stream covers every tracked repo. When files change, only
   those repos are re-read, coalesced so a `git checkout` costs one refresh rather than
   one per file. Build output and dependency directories are filtered out.
3. **Status** — a single `git status --porcelain=v2 --branch -z` per repo returns the
   working tree, the current branch, whether it tracks a remote, and the ahead/behind
   counts. One process per repo, parsed from NUL-delimited records so no filename needs
   escaping.
4. **Fallback sweep** — a periodic pass catches whatever file events miss (dropped
   events, remounted volumes). It is a backstop, not the mechanism.
5. **Remote checks** — `git fetch --prune` on the branch's own remote, on a background
   cadence, then a re-read for the new ahead/behind counts.
6. **UI updates** — each repo owns an `@Observable` state object, so a status update
   re-renders only that row. The menu bar icon and badge reflect the worst health across
   every repo.
7. **Persistence** — configuration is JSON-encoded into `UserDefaults` after every
   mutation, with a version stamp so shipped defaults can change without resetting it.

<br>

## Configuration

| Setting | Options | Default |
|---|---|---|
| Check remotes automatically | On / off | On |
| Remote check interval | 5m, 15m, 30m, 1h | 15m |
| Fallback refresh | 30s, 2m, 5m, 15m | 30s |
| Discovery scan depth | 2–5 levels | 3 |
| Default editor | Any installed app | Not set |
| Per-repo editor | Any installed app | Inherits global |
| Launch at login | On / off | Off |

All settings are accessible from the **gear icon** in the popover.

<br>

## License

MIT

<br>

---

<p align="center">
  Built with SwiftUI and lots of <code>git status</code> calls.
</p>
