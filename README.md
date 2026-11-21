# DevLoadBar

A native macOS menu bar utility for developers running Codex, Claude Code, Git worktrees and local Docker containers. Open the gauge to find a large process and its working directory, inspect a checkout, or stop a selected container before unplugging.

## Run

On macOS 13 or later with Xcode Command Line Tools and Swift 5.9 or later:

```sh
git clone https://github.com/Noxr3/DevLoadBar.git
cd DevLoadBar
./build.sh
open .build/DevLoadBar.app
```

The build produces an ad-hoc signed app for the current Mac. Drag the app to Applications to keep it. Closing the window leaves the menu bar item available. Use its Quit command to exit.

## Inspect a workload

- **Processes** shows processes owned by the current user, sortable by RSS and CPU. Locate displays a PID's current working directory. Executable names and parent PIDs associate descendants with Codex, Claude Code or Docker Desktop. Shared pages can be counted more than once in summed RSS. Detached children and renamed wrappers may remain unattributed. Several conversations may share one host process.
- **Disk** accepts a repository or linked checkout, lists its registered Git worktrees and shows branch, detached, locked and prunable indicators. Inspect checks tracked and untracked changes and measures allocated directory size. Reveal opens Finder. Agent session and worktree folders can be measured separately. A clean Git status can still contain ignored files, unpublished commits and valuable build products. APFS clones and shared blocks affect the space actually reclaimable.
- **Containers** queries a local Unix socket only on request. Socket discovery uses Docker Desktop, default Colima, OrbStack, then the system socket, in that order. The selected socket is shown after a successful query. A stopped or inaccessible engine can leave a socket on disk. The app does not launch it. Stop asks for confirmation and targets the full container ID at the inspected socket.
- **Power** follows macOS power-source events. The menu bar icon changes on battery. The Containers view adds a battery reminder. CPU, RSS and power-source readings do not measure per-process watts.

Process snapshots refresh when opening the dashboard and on request. Disk scans run one at a time with a 90-second timeout. Only the selected repository path is saved in app preferences. No analytics, transcripts or remote services are used.

## Terminal

```sh
bin=.build/DevLoadBar.app/Contents/MacOS/DevLoadBar
"$bin" --snapshot
"$bin" --worktrees /path/to/repository
"$bin" --containers
```

See the [community reports and open-source comparison](RESEARCH.zh-CN.md). Licensed under [MIT](LICENSE).
