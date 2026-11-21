# DevLoadBar

A native macOS menu bar utility for developers running Codex, Claude Code, Git worktrees and local Docker containers. Use background rules to bound agent workloads, reclaim disk space from completed work, and stop selected containers on battery.

## Run

On macOS 13 or later with Xcode Command Line Tools and Swift 5.9 or later:

```sh
git clone https://github.com/Noxr3/DevLoadBar.git
cd DevLoadBar
./build.sh
open .build/DevLoadBar.app
```

The build produces an ad-hoc signed app for the current Mac. Drag the app to Applications to keep it. Closing the window leaves the menu bar item available. Use its Quit command to exit.

## Automatic management

Click the menu bar gauge to open **Automatic Management**. Select **Disk**, **Memory** or **Battery** to set up that resource. The manager checks once a minute while the app runs, including with the window closed. In **Settings** (⌘,), enable **Launch at login** after moving the app into Applications to resume management after signing in. The master switch pauses all rules.

| Resource | Trigger | Automatic action |
| --- | --- | --- |
| Memory | Three samples at or above a per-process RSS budget (initial setting 8 GiB), or three samples of macOS memory pressure with combined Codex and Claude RSS at or above a second budget (20 GiB) | Send SIGTERM to at most one eligible current-user process per pass, largest first. Eligible workers are Node, Bun, Deno, esbuild, Vite and Next servers in an identified agent process tree. Under the combined budget rule a worker must use at least 256 MiB. A separate toggle includes identified Codex and Claude CLI processes. An active job may be interrupted. PID and process start time are checked before signalling. |
| Disk | On AC power with free space below 10% or 25 GiB, in an enrolled repository | Examine up to eight registered linked checkouts every 15 minutes, rotating across them. Remove at most one eligible checkout per pass using Git. Preserve its branch. Optional cache cleanup can reclaim one cold, ignored directory in a checkout that cannot be removed. |
| Battery | Five minutes on battery with a reachable local Docker engine | Stop running containers enrolled by full ID and socket or carrying the label `devloadbar.stop-on-battery=true`. Check power again before stopping. Auto-remove containers are skipped. Stopped services can be restarted manually on AC. |

To start, select a repository in **Disk** and enable checkout cleanup. Enable the memory budget for agent workers. In **Battery → Choose containers**, select **Stop on battery** for existing services, or add the label when creating a container. The battery rule starts enabled for these enrolled targets. Memory termination and repository removal require initial enrollment. The most recent 100 actions and errors are available under **Activity**.

Checkout removal requires an unlocked linked worktree, HEAD reachable from the locally recorded origin default branch (falling back to local main or master), a branch outside the protected default/main/master/staging/develop names, week-old directory and Git metadata, no visible open files beneath the checkout, and clean tracked, untracked and ignored-file checks. Index flags and ongoing Git operations can also exclude a checkout. Open-file visibility depends on macOS permissions. Reachability and age cannot establish that a human has finished a task. Choose repositories where this lifecycle is appropriate.

Optional cache cleanup covers exactly `.next/cache` and `node_modules/.cache` in linked checkouts. It requires an ignored, untracked cache tree with week-old contents and skips active checkouts, symlinked cache roots, nested Git metadata and volume boundaries. Session transcripts, other ignored files and Docker volumes are outside these cleanup rules.

## Inspect a workload

- **Processes** shows processes owned by the current user, sortable by RSS and CPU. Locate displays a PID's current working directory. Executable names and parent PIDs associate descendants with Codex, Claude Code or Docker Desktop. Shared pages can be counted more than once in summed RSS. Detached children and renamed wrappers may remain unattributed. Several conversations may share one host process.
- **Disk** accepts a repository or linked checkout, lists its registered Git worktrees and shows branch, detached, locked and prunable indicators. Inspect checks tracked and untracked changes and measures allocated directory size. Reveal opens Finder. Agent session and worktree folders can be measured separately. A clean Git status can still contain ignored files, unpublished commits and valuable build products. APFS clones and shared blocks affect the space actually reclaimable.
- **Containers** queries a local Unix socket on request and during the battery policy. Socket discovery uses Docker Desktop, default Colima, OrbStack, then the system socket, in that order. A stopped or inaccessible engine can leave a socket on disk. The app does not launch it. Stop asks for confirmation and targets the full container ID at the inspected socket.
- **Power** follows macOS power-source events. The menu bar icon changes on battery. The overview shows the current power source. CPU, RSS and power-source readings do not measure per-process watts.

Process snapshots refresh when opening the dashboard and on request. Disk scans run one at a time with a 90-second timeout. Rules, enrolled targets and activity history are saved in local app preferences. No analytics, transcripts or remote services are used.

## Terminal

```sh
bin=.build/DevLoadBar.app/Contents/MacOS/DevLoadBar
"$bin" --snapshot
"$bin" --worktrees /path/to/repository
"$bin" --containers
```

See the [community reports and open-source comparison](RESEARCH.zh-CN.md). Licensed under [MIT](LICENSE).
