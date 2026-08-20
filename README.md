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

For Claude Code, an `agent-status` hook script writes those files from
`UserPromptSubmit` / `PreToolUse` / `Notification` / `Stop` / `SessionEnd`. Any
agent that writes the same shape works.

## API

| Function                       | Description                                         |
| ------------------------------ | --------------------------------------------------- |
| `setup(opts?)`                 | Initialise slot state and the side window. `opts.shell` overrides the shell command spawned in each terminal (default: `vim.o.shell`); `opts.agent` configures agent-status tracking (`{ dir, enabled }`); `opts.project_name(tab)` names a tabpage in the agent view. |
| `setup_keymaps()`              | Register the `<C-b>` prefix tab keymaps.            |
| `setup_exit()`                 | Wire terminal-exit cleanup.                          |
| `show(slot, opts?)`            | Reveal/create the terminal in `slot`. `opts.insert` controls whether focus enters insert mode. |
| `tabs(tab?)`                   | A tabpage's terminals as `{ slot, title, icon, hl, agent }`. `icon` is the status glyph: the agent's reported state, else the OSC title's leading glyph. |
| `agents()`                     | Every reporting agent across every tabpage, blocked ones first. |
| `focus(entry)`                 | Switch to an `agents()` entry's tabpage and surface its terminal. |
| `view.items()` / `view.popup()`| The agent view as data / as a floating chooser. |

See the source for the full slot API (new / move / toggle / kill).

## Tests

```bash
make test
```

Headless plenary/busted; covers the slot bookkeeping (which terminal occupies the
panel, which stay hidden, and how renumbering moves them). `vim.fn.jobstart` is
faked so no real pty is needed.

[lazy.nvim]: https://github.com/folke/lazy.nvim
