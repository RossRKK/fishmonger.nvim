# fishmonger.nvim

> It's where I go for my fish. 🐟

A tmux-style tab manager for a single side terminal in Neovim. One side window
hosts many shells as numbered tabs: they stay alive but hidden when you switch
away (the tmux-pane model), with a `<C-b>` prefix, `move-window` semantics, and
a tab strip rendered in the tabline. No tmux backend — the window semantics are
reimplemented natively over nvim terminal buffers, spawned directly with
`jobstart`.

## Requirements

- Neovim 0.10+

## Install

[lazy.nvim][]:

```lua
{
  "RossRKK/fishmonger.nvim",
  config = function()
    require("fishmonger").setup()
    require("fishmonger").setup_keymaps() -- <C-b>{1-9} tab keys, etc.
    require("fishmonger").setup_exit()
  end,
}
```

## Agent view

Terminals running a coding agent can report what the agent is *doing* —
crucially, whether it has finished or is **blocked on you**, which nothing in the
terminal's byte stream distinguishes. `<C-b>a` opens a list of every agent across
every tabpage, blocked ones first, one key per row to jump to it (switch tabpage
and surface its terminal). `fishmonger.view.items()` returns the same rows as
data for embedding elsewhere — a dashboard, a statusline.

It's fed by the agent writing a small JSON file per session into
`$XDG_RUNTIME_DIR/claude-agents`, which `fishmonger.agent` watches:

```json
{ "session": "…", "state": "permission", "detail": "needs Bash",
  "cwd": "/path", "agent_pid": 1234, "pids": [1234, 99, 1] }
```

`state` is one of `busy`, `permission`, `asking`, `plan`, `asked`, `idle`,
`done`. `pids` is the writer's process-ancestor chain: a session belongs to the
terminal whose shell pid appears in it, which stays exact with several agents in
one directory. `agent_pid` is checked against `/proc`, so a killed agent's file
is reaped rather than showing as blocked forever.

Read and unread are yours, kept in nvim rather than in the file: `<C-b>r` shows
the current terminal's agent as read (an empty circle) and `<C-b>u` as unread
(a question mark), whatever its state, until the agent writes its next status.
Entering terminal mode in a finished agent's terminal marks it read.

For Claude Code, an `agent-status` hook script writes those files from
`UserPromptSubmit` / `PreToolUse` / `Notification` / `Stop` / `SessionEnd`. Any
agent that writes the same shape works.

## API

| Function                       | Description                                         |
| ------------------------------ | --------------------------------------------------- |
| `setup(opts?)`                 | Initialise slot state and the side window. `opts.shell` overrides the shell command spawned in each terminal (default: `vim.o.shell`); `opts.agent` configures agent-status tracking (`{ dir, enabled }`); `opts.project_name(tab)` names a tabpage in the agent view; `opts.workspace(n)` resolves `<C-b>mN`'s workspace number to a tabpage. |
| `setup_keymaps()`              | Register the `<C-b>` prefix tab keymaps.            |
| `setup_exit()`                 | Wire terminal-exit cleanup.                          |
| `show(slot, opts?)`            | Reveal/create the terminal in `slot` in the target window: the current terminal window, else the one used last, else the side panel. A tab already showing in another window swaps places with it. `opts.insert` controls whether focus enters insert mode; `opts.shell` starts a terminal the call creates with that command instead of the configured shell. |
| `here()`                       | `<C-b>t`: a terminal in the current window, like `:edit` (`<C-o>` goes back), showing the most recent tab not on screen. |
| `cycle()`                      | `<C-b>o`: focus the next terminal window. |
| `split(direction)`             | `<C-b>"` (`"below"`) / `<C-b>%` (`"right"`): tmux split-window. Split the target terminal window and start a new shell in the lowest free slot. A pane split from the side panel carries `w:fishmonger_side` too; a docking layout manager that only stacks (edgy) stacks it whichever way it was split. |
| `kill_pane()`                  | `<C-b>x`: tmux kill-pane. Shut down the target terminal's shell and close its window (`<C-b>&` keeps the window, showing another tab). |
| `select(direction)`            | `<C-b>` arrow: tmux select-pane. `wincmd h/j/k/l`, for when the terminal program keeps the ctrl keys. |
| `zoom()`                       | `<C-b>z`: tmux zoom. The side terminal fills the screen and keeps its tab strip, and tab keys still switch inside it. Press again, or enter another split, to dock it. |
| `maximise()`                   | `<C-b>Z`: the side terminal moves into the main window (the widest one outside the panel) and the panel closes: a real layout change, so a file tree beside it stays usable. From a terminal in the editor area it docks back into the panel and the window returns to its file. |
| `tabs(tab?)`                   | A tabpage's terminals as `{ slot, title, icon, hl, agent }`. `icon` is the status glyph: the agent's reported state, else the OSC title's leading glyph. |
| `agents()`                     | Every reporting agent across every tabpage, blocked ones first. |
| `focus(entry)`                 | Switch to an `agents()` entry's tabpage and surface its terminal. |
| `mark(kind)`                   | `<C-b>r` (`"read"`) / `<C-b>u` (`"unread"`): mark the current terminal's agent until its next status write. |
| `transfer(tab)`                | Carry the current terminal (live process, scrollback and all) into tabpage `tab`'s lowest free slot and follow it. The process's cwd does not change. |
| `transfer_to(n)`               | `<C-b>mN`: `transfer` to workspace N — `setup({ workspace = fn(n) -> tab })`'s numbering, else the Nth tabpage. |
| `transfer_pick()`              | `vim.ui.select` over the other tabpages by project name, then `transfer`. |
| `view.items()` / `view.popup()`| The agent view as data / as a floating chooser. |

See the source for the full slot API (new / move / transfer / toggle / kill).

The side panel and the panes split from it carry `w:fishmonger_side`. A layout manager that docks it
(edgy, say) should filter on that rather than the `fishmonger` filetype, so a
terminal opened in the editor area with `<C-b>t` stays where it is.

## Tests

```bash
make test
```

Headless plenary/busted; covers the slot bookkeeping (which terminal occupies the
panel, which stay hidden, and how renumbering moves them). `vim.fn.jobstart` is
faked so no real pty is needed.

[lazy.nvim]: https://github.com/folke/lazy.nvim
