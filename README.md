# T3 Live

An [Omarchy](https://omarchy.org) bar widget for [T3 Code](https://t3.codes) agents, styled after phone live updates.

The bar stays small: a pill such as `T3  3 live │ 1 input │ 1 perm` shows how many threads are working, how many have a question for you, and how many want permission. When a thread finishes, the pill says `T3  Done` (or `Failed`) for a few seconds. It hides when nothing is running.

Click the pill for a list with one entry per thread:

- **Working**: what it is doing right now ("Editing Hero.tsx", "$ pnpm test"), its project and machine, its pull request ("#214 checks failing"), and how long it has run.
- **Input**: the question it asks, and an **Answer** button that opens the thread in T3 Code.
- **Perm**: what it wants to do ("Wants to run: pnpm test"), and a **Review** button that opens the thread.
- **Done / failed**: how long it took; these stay listed for 2 minutes.

Anything that needs a decision opens in T3 Code itself, where you have the full thread.

## Notifications

A toast arrives when a thread starts waiting on you or finishes, with a button that opens it. If a question or permission is still waiting after 5 minutes, one critical toast follows. Turn toasts off with the widget's **Notifications** setting (`"notify": false` in its bar entry).

## Install

```sh
omarchy plugin add https://github.com/EhsanulHaqueSiam/omarchy-t3-live.git --enable
```

You need T3 Code on the same machine. It works with the default `~/.t3` folder, or with `T3CODE_HOME` if you set it. `sqlite3` and `jq` come with Omarchy.

Links open in the T3 Code desktop app. If the app isn't installed, they open in this machine's T3 web UI.

## Other machines

To include threads running on other machines, add their ssh hosts under the widget's **Other machines** setting, or put them in its bar entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "siam.t3-live", "sshHosts": "mac, server" }
```

Each host needs key-based ssh (the plugin connects with `BatchMode=yes`), plus T3 Code and `sqlite3`. macOS ships `sqlite3`. A host that can't be reached drops out of the counts, and the plugin tries it again every 30 seconds.

## Keyboard

`omarchy-shell siam.t3-live toggle` opens the list on the focused monitor. To bind it to a key, add a line like this to `~/.config/hypr/bindings.conf`:

```
bindd = SUPER ALT, T, T3 agents, exec, omarchy-shell siam.t3-live toggle
```

`omarchy-shell siam.t3-live status` prints the counts and threads as JSON.

## How it works

`feed.sh` reads T3 Code's database read-only every 2 seconds and prints a line only when something changes. It runs once on this machine, and on each ssh host over one long-lived `ssh host sh -s` session, so nothing gets installed on those hosts. All bars share one set of feeds.

A thread counts as live while it has a run in progress. A pending question (or MCP elicitation, or sign-in) makes it **input**; a pending request to run a command, read or edit files makes it **perm**. It never writes to T3's database or sends anything to T3.

## Development

```sh
node tests/model.test.mjs
omarchy plugin validate .
```

After editing the QML, run `omarchy-restart-shell`. Hot reload can keep the old widget.

MIT licensed.
