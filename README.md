# fishmonger.nvim

> It's where I go for my fish. 🐟

A tmux-style tab manager for a single side terminal in Neovim, built on
[snacks.nvim][]'s terminal. One side window hosts many shells as numbered tabs:
they stay alive but hidden when you switch away (the tmux-pane model), with a
`<C-b>` prefix, `move-window` semantics, and a tab strip rendered in the tabline.
No tmux backend — the window semantics are reimplemented natively over nvim
terminal buffers.

## Requirements

- Neovim 0.10+
- **[snacks.nvim][]** — fishmonger manages snacks terminal windows (accessed via
  the `Snacks` global).

## Install

[lazy.nvim][]:

```lua
{
  "RossRKK/fishmonger.nvim",
  dependencies = { "folke/snacks.nvim" },
  config = function()
    require("fishmonger").setup()
    require("fishmonger").setup_keymaps() -- <C-b>{1-9} tab keys, etc.
    require("fishmonger").setup_exit()
  end,
}
```

Or wire it from inside your snacks `config` if you already configure snacks by
hand (call `require("fishmonger").setup()` after `require("snacks").setup(opts)`).

## API

| Function                       | Description                                         |
| ------------------------------ | --------------------------------------------------- |
| `setup(opts?)`                 | Initialise slot state and the side window.          |
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

[snacks.nvim]: https://github.com/folke/snacks.nvim
[lazy.nvim]: https://github.com/folke/lazy.nvim
