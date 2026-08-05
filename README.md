# fishmonger.nvim

> It's where I go for my fish. 🐟

A tmux-style tab manager for a single side terminal in Neovim. One side window
hosts many shells as numbered tabs: they stay alive but hidden when you switch
away (the tmux-pane model), with a `<C-b>` prefix, `move-window` semantics, and
a tab strip rendered in the tabline. No tmux backend — the window semantics are
reimplemented natively over nvim terminal buffers, spawned directly with
`jobstart`.

Yanks from a fishmonger terminal join lines that soft-wrapped at the terminal
edge (nvim stores each screen row as its own buffer line), so a wrapped shell
line pastes as one line instead of carrying a hard newline at every wrap point.

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

## API

| Function                       | Description                                         |
| ------------------------------ | --------------------------------------------------- |
| `setup(opts?)`                 | Initialise slot state and the side window. `opts.shell` overrides the shell command spawned in each terminal (default: `vim.o.shell`). |
| `setup_keymaps()`              | Register the `<C-b>` prefix tab keymaps.            |
| `setup_exit()`                 | Wire terminal-exit cleanup.                          |
| `show(slot, opts?)`            | Reveal/create the terminal in `slot`. `opts.insert` controls whether focus enters insert mode. |

See the source for the full slot API (new / move / toggle / kill).

## Tests

```bash
make test
```

Headless plenary/busted; covers the slot bookkeeping (which terminal occupies the
panel, which stay hidden, and how renumbering moves them). `vim.fn.jobstart` is
faked so no real pty is needed.

[lazy.nvim]: https://github.com/folke/lazy.nvim
