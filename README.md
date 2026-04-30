# LuaProbe.el

Emacs front-end for the [LuaProbe](https://github.com/PlugwiseBV/LuaProbe)
Lua debugger.

Set persistent breakpoints (plain, log-only, conditional) from your
Lua source buffers, launch your project under LuaProbe with one
command, and have the source window auto-jump to the line LuaProbe
pauses on.

## What this package does

- Adds **fringe markers** for breakpoints (●) and log-only points
  (◆) in any Lua buffer where you enable `luaprobe-mode`.
- **Persists points** across sessions in
  `~/.config/luaprobe/breakpoints.lua`. On launch, enabled points
  are converted to LuaProbe spec syntax (`FILE:LINE[!] [if EXPR]`)
  and passed via `-b` flags to `bin/luaprobe`.
- **Conditional breakpoints**: the runtime evaluates a Lua
  expression against the current locals / upvalues / globals at
  hit time and only pauses when truthy. The condition is shown
  inline above the source line as a faded fake line
  (`╎ IF user.id == 5`).
- **Log-only breakpoints**: don't pause; LuaProbe writes the break
  event and the program keeps running. Inline annotation `╎ LOG`.
- **`luaprobe-install`**: one-time clone of the LuaProbe Lua repo.
- **`luaprobe-launch`**: spawns `bin/luaprobe` with the right
  arguments in a comint buffer; the gdb-style `(luaprobe)` REPL is
  available for `c` / `s` / `n` / `f` / `b` / `d` / `bt` / `e` /
  `p` etc. The source window auto-jumps when the target pauses.

## Installation

### From MELPA *(once published)*

```elisp
(use-package luaprobe
  :hook (lua-mode . luaprobe-mode)
  :bind-keymap ("C-c d" . luaprobe-prefix-map))
```

### Manual

```elisp
(add-to-list 'load-path "/path/to/LuaProbe.el")
(require 'luaprobe)
(add-hook 'lua-mode-hook #'luaprobe-mode)
(global-set-key (kbd "C-c d") luaprobe-prefix-map)
```

`luaprobe-prefix-map` is **not bound by default**: Emacs reserves
`C-c LETTER` sequences for user customisations, so the package
ships the keymap as a free-standing variable for you to bind.

### Then bring in the LuaProbe Lua tool

```
M-x luaprobe-install
```

Clones https://github.com/PlugwiseBV/LuaProbe into
`~/.local/share/luaprobe` (overridable via `luaprobe-install-dir`).
With a prefix arg, runs `git pull` to update an existing clone.

## Usage

1. Open a Lua source buffer; turn on `luaprobe-mode`.
2. Move point to a line and press `C-c d b` to set a breakpoint.
   For a conditional one, `C-u C-c d b` and type the Lua condition.
   For a log-only one, `C-c d L`.
3. `M-x luaprobe-launch` (or `C-c d r`) — pick a Lua file (defaults
   to the current buffer) and any extra args. A `*luaprobe*` comint
   buffer pops up; the target runs under LuaProbe with your
   breakpoints loaded.
4. When the target pauses, the source window auto-jumps to the
   line. Type `c` / `s` / `n` / `f` at the `(luaprobe)` prompt to
   continue / step into / step over / finish.

## Configuration

| variable                    | default                                      |
|-----------------------------|----------------------------------------------|
| `luaprobe-points-file`      | `~/.config/luaprobe/breakpoints.lua`         |
| `luaprobe-install-dir`      | `~/.local/share/luaprobe`                    |
| `luaprobe-repo-url`         | `https://github.com/PlugwiseBV/LuaProbe`     |
| `luaprobe-lua-program`      | `"lua5.1"`                                   |
| `luaprobe-source-dirs`      | `'(".")`                                     |
| `luaprobe-jump-on-pause`    | `t`                                          |

`luaprobe-source-dirs` becomes `-s DIR` arguments to `bin/luaprobe`,
which it uses to resolve relative source paths in break events.

## Key bindings

In any Lua buffer with `luaprobe-mode` on (under `C-c d` if you
bound it as recommended):

| key       | command                                          |
|-----------|--------------------------------------------------|
| `b`       | toggle plain breakpoint                          |
| `C-u b`   | toggle CONDITIONAL breakpoint (prompts)          |
| `B`       | set / replace the condition on this line         |
| `L`       | toggle log-only breakpoint                       |
| `e`       | edit the condition on the point at point         |
| `t`       | toggle enabled / disabled                        |
| `l`       | list every configured point                      |
| `C`       | clear ALL points                                 |
| `r`       | run (alias for `M-x luaprobe-launch`)            |
| `I`       | install / update the LuaProbe Lua repo           |
| `?` / `h` | full help popup                                  |

In the `*luaprobe*` comint buffer (these are LuaProbe REPL commands,
not Emacs bindings — see `bin/luaprobe --help`):

| key            | meaning                                      |
|----------------|----------------------------------------------|
| `c`            | continue                                     |
| `s`            | step into                                    |
| `n`            | step over                                    |
| `f`            | finish (step out)                            |
| `bt`           | backtrace                                    |
| `l [N]`        | list source                                  |
| `locals`       | show locals + upvalues                       |
| `p NAME`       | deep-inspect a variable                      |
| `e EXPR`       | evaluate Lua expression in the current frame |
| `frame N`      | select stack frame N                         |
| `b FILE:L[!]…` | add breakpoint at runtime                    |
| `d FILE:L`     | delete breakpoint at runtime                 |
| `bps`          | list breakpoints                             |
| `q`            | quit (kills the target)                      |

## How it fits together

```
┌──────────────────────────┐                    ┌────────────────────────┐
│ Emacs (luaprobe.el)      │                    │ bin/luaprobe (LuaJIT)  │
│  • point persistence     │  comint stdin/out  │  • controller library  │
│  • fringe markers        │ ←────────────────→ │  • two FIFOs to child  │
│  • condition fake-lines  │                    │  • REPL                │
│  • auto-jump on *** BREAK│                    │                        │
└──────────────────────────┘                    └────────────────────────┘
                                                            │ FIFOs
                                                            ▼
                                               ┌────────────────────────┐
                                               │ target process (lua5.1)│
                                               │  + luaprobe_stub.lua   │
                                               │    via LUA_INIT        │
                                               └────────────────────────┘
```

## Roadmap

- Replace the comint REPL with a structured break-event handler:
  parse the JSON-style break events from a small bridge script
  and render frames + locals + upvalues as a collapsible tree
  (similar to gud / dap-mode), with `inspect` for deep dumps.
- Persistent expansion state across pauses.
- `luaprobe-eval-region` to send the region as `e` to the running
  session.

## License

GPL-3.0-or-later. See `LICENSE`.
