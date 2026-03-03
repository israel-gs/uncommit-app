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

### Real-time Repository Monitoring
- Track **staged**, **modified**, **untracked**, and **conflicted** files across all repos
- **Hover any status badge** to see the exact file names
- Color-coded health indicators: **green** (clean), **orange** (local changes), **red** (behind remote)
- Dynamic menu bar icon and dirty-repo count badge

### Remote Sync Awareness
- One-click **Check Remote** per repo or **Fetch All** across every repo
- See how many commits you're **ahead** or **behind** the remote
- Detects whether a branch has a remote tracking branch

### Smart Repository Discovery
- Add repos manually or point to a **root project folder**
- Recursively discovers all nested Git repos (configurable depth 2–5)
- Automatically skips `node_modules`, `Pods`, `DerivedData`, `.build`, `vendor`, `dist`, and more

### Custom Editor Integration
- Open any repo in your preferred editor — **VS Code**, **Cursor**, **Zed**, **Xcode**, **Sublime Text**, JetBrains IDEs, and 20+ more
- Set a **global default** editor and **per-repo overrides**
- Auto-detects installed editors; pick any `.app` with the "Other..." option

### Quick Actions
- **Copy path** to clipboard
- **Open in Terminal**
- **Open in editor** (configurable)

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

<br>

## Project Structure

```
Uncommit/
├── UncommitApp.swift               # App entry point (MenuBarExtra)
│
├── Models/
│   ├── GitRepository.swift          # Repo model with per-repo editor config
│   ├── GitStatus.swift              # Status snapshot + health level enum
│   ├── AppConfiguration.swift       # Persisted settings + InstalledApp model
│   └── WatchedFolder.swift          # Root folder for auto-discovery
│
├── ViewModels/
│   └── AppViewModel.swift           # Central @Observable state manager
│
├── Views/
│   ├── PopoverContentView.swift     # Main popover container
│   ├── RepoListView.swift           # Sorted repository list
│   ├── RepoRowView.swift            # Per-repo row with status + actions
│   ├── StatusIndicatorView.swift    # Colored health dot
│   ├── SettingsView.swift           # Settings panel with editor picker
│   └── EmptyStateView.swift         # Onboarding empty state
│
├── Services/
│   ├── GitService.swift             # Git CLI wrapper (status, fetch, branch)
│   ├── ShellExecutor.swift          # Non-blocking Process execution
│   ├── RepoMonitor.swift            # Polling engine with TaskGroup
│   ├── RepoDiscoveryService.swift   # Recursive .git scanner
│   └── PersistenceService.swift     # UserDefaults read/write
│
└── Utilities/
    ├── EditorHelper.swift           # Editor detection + open-in-app logic
    ├── MenuBarIconProvider.swift     # SF Symbol + color for menu bar
    └── Constants.swift              # App-wide constants
```

<br>

## How It Works

1. **Startup** — The app launches as a menu-bar-only process (`LSUIElement = true`). No Dock icon, no main window.
2. **Polling** — A configurable timer (default 30s) triggers concurrent `git status --porcelain=v1` checks across all tracked repos using Swift `TaskGroup`.
3. **Status Parsing** — Porcelain output is parsed line-by-line to extract staged/modified/untracked/conflict file lists and names.
4. **Remote Checks** — `git fetch --all --prune` followed by `git rev-list --count` to compute ahead/behind counts.
5. **UI Updates** — `@Observable` view model drives reactive SwiftUI updates. The menu bar icon, color, and badge reflect the worst health across all repos.
6. **Persistence** — Configuration (repos, folders, editor prefs, intervals) is JSON-encoded to `UserDefaults` after every mutation.

<br>

## Configuration

| Setting | Options | Default |
|---|---|---|
| Refresh interval | 15s, 30s, 60s, 2min | 30s |
| Discovery scan depth | 2–5 levels | 3 |
| Default editor | Any installed app | Not set |
| Per-repo editor | Any installed app | Inherits global |

All settings are accessible from the **gear icon** in the popover.

<br>

## License

MIT

<br>

---

<p align="center">
  Built with SwiftUI and lots of <code>git status</code> calls.
</p>
