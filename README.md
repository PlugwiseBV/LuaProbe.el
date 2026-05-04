# LuaProbe.el

<img width="1080" height="608" alt="simplescreenrecorder-2026-05-04_10 36 30" src="https://github.com/user-attachments/assets/61b86834-7afc-4e16-9a8e-13cb07f482ed" />


Emacs front-end for the [LuaProbe](https://github.com/PlugwiseBV/LuaProbe)
Lua debugger.

Set persistent breakpoints (plain, log-only, conditional) from your
Lua source buffers, launch your project under LuaProbe with one
command, and have the source window auto-jump to the line LuaProbe
pauses on — whether driven from inside Emacs or from an external TUI
like pwdebug.

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
- **External pause-beacon watcher**: when an external driver (e.g.
  the pwdebug TUI) writes `luaprobe-paused-file`, Emacs instantly
  jumps the source window to the paused location — no in-Emacs
  launch required.

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
   paused line and `*luaprobe-locals*` opens on the right showing
   the call stack, locals, upvalues, and coroutines.
   Type `c` / `s` / `n` / `f` at the `(luaprobe)` prompt to
   continue / step into / step over / finish.

### Using with an external TUI (pwdebug / headless)

The pause-beacon watcher starts automatically when `luaprobe.el` is
loaded. When an external driver writes `luaprobe-paused-file`
(default `~/.config/luaprobe/paused.lua`) in the format:

```lua
file="path/to/source.lua", line=42
```

Emacs immediately jumps the source window to that location and
highlights the paused line. When the file is deleted (on resume),
the overlay is cleared. No `luaprobe-launch` is needed.

## Configuration

| variable                    | default                                      |
|-----------------------------|----------------------------------------------|
| `luaprobe-points-file`      | `~/.config/luaprobe/breakpoints.lua`         |
| `luaprobe-paused-file`      | `~/.config/luaprobe/paused.lua`              |
| `luaprobe-install-dir`      | `~/.local/share/luaprobe`                    |
| `luaprobe-repo-url`         | `https://github.com/PlugwiseBV/LuaProbe`     |
| `luaprobe-lua-program`      | `"lua5.1"`                                   |
| `luaprobe-source-dirs`      | `'(".")`                                     |
| `luaprobe-jump-on-pause`    | `t`                                          |

`luaprobe-source-dirs` becomes `-s DIR` arguments to `bin/luaprobe`,
which it uses to resolve relative source paths in break events.

Set `luaprobe-paused-debug` to `t` to log every pause-beacon event
to `*Messages*` for troubleshooting.

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

In the `*luaprobe-locals*` side buffer:

| key       | action                                                       |
|-----------|--------------------------------------------------------------|
| `RET`     | on a **frame**: jump source window there + select that frame |
| `RET`     | on a **variable**: jump to its declaration; if it is a function, choose `[f]` body or `[v]` declaration |
| `RET`     | on a **coroutine**: jump to its top source location          |
| `SPC`     | on a frame: select frame only (no source jump)               |
| `TAB`     | on a variable with `▶`: expand / collapse inline table       |
| `n` / `p` | navigate between items (frames, variables, coroutines)       |
| `↑` / `↓` | move line by line                                            |

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
│  • pause-beacon watcher  │                    └────────────────────────┘
│    (external TUI support)│                                │ FIFOs
└──────────────────────────┘                                ▼
          ↑ file-notify                     ┌────────────────────────┐
    paused.lua written                      │ target process (lua5.1)│
    by external driver                      │  + luaprobe_stub.lua   │
                                            │    via LUA_INIT        │
                                            └────────────────────────┘
```

## License

GPL-3.0-or-later. See `LICENSE`.
