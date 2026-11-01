# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Filename search over every fixed NTFS drive, read straight from the master file table
- `elephant.exe`, the search in a terminal, and `elephant-gui.exe`, the same search in a window
- Fuzzy, exact, wildcard and full path terms
- `--under` and `:in` to search under one directory
- A saved index that catches up from the change journal on the next run
- Results that follow file changes while the search is open
- Sizes and dates, read in the background
- Shell icons, bold matches, sortable columns and Explorer's own right click menu in the window
- Dark mode that follows the switch in Settings
- "Search with ElephantSearch" in Explorer's right click menu, with `--add-to-explorer`
- The saved index without administrator rights, with a button to restart with them
- A background service that reads the drives, so searching needs no administrator rights, with `--install-service` and `--uninstall-service`
- "Install the service" in the window when it can't read the drives
- `--version`
