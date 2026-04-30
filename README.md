# pwdebug.el

Emacs front-end for the [pwdebug](https://github.com/PlugwiseBV/pwdebug)
Lua debugger.

Set conditional breakpoints from your Lua source buffers, drill into
the paused target's tables interactively, and step with the keys you
already know from gdb / lldb.

![paused](docs/screenshot-paused.png)

## What this package does

- Adds **fringe markers** for breakpoints (●) and info-points (◆) in
  any Lua buffer where you enable `pwdebug-mode`.
- **Persists points** to `~/.config/pwdebug/debug_points.lua`, the
  same file the pwdebug TUI reads — set a breakpoint here, it works
  there, and vice-versa.
- Renders the live pause snapshot from the runtime as an interactive
  **value tree** in a side window: frames, args, locals, upvalues,
  per-function `_ENV`, `_G`. Tables are collapsible — `RET` / `TAB`
  expands; the runtime is asked on demand for tables that weren't
  captured at pause time.
- Cycle-safe: a table that contains itself terminates with `↺`
  instead of recursing forever.
- **Conditional breakpoints**: pause only when a Lua expression is
  truthy, evaluated against the current locals / upvalues / globals.
  The condition is rendered above the source line as a faded fake
  line (`╎ IF user.id == 5`).
- **Info-points**: capture a snapshot + evaluated expression value
  without ever pausing the target — useful for tracing.
- **gdb-style stepping**: continue, step-into, step-over, step-out.

## Installation

The package depends on the pwdebug Lua runtime — it only does
anything useful when the target Lua process has been launched with
`LUA_INIT="@.../src/dbg_runtime.lua"`. See the pwdebug project for
how to set that up.

### From MELPA *(once published)*

```elisp
(use-package pwdebug
  :hook (lua-mode . pwdebug-enable-here)
  :bind-keymap ("C-c d" . pwdebug-prefix-map))
```

### Manual

Clone this repo and add it to your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/pwdebug.el")
(require 'pwdebug)
(add-hook 'lua-mode-hook #'pwdebug-enable-here)
(global-set-key (kbd "C-c d") pwdebug-prefix-map)
```

`pwdebug-prefix-map` is **not bound by default**: Emacs reserves
`C-c LETTER` sequences for user customisations, so the package
ships the keymap as a free-standing variable for you to bind on
your own prefix.

## Configuration

`pwdebug-enable-here` only turns the minor mode on for files under
the `pwcore_root` configured in `~/.config/pwdebug/config.lua`. If
you want the mode in every Lua buffer instead, just add `pwdebug-mode`
to `lua-mode-hook` directly.

| variable                    | default                                      |
|-----------------------------|----------------------------------------------|
| `pwdebug-points-file`       | `~/.config/pwdebug/debug_points.lua`         |
| `pwdebug-config-file`       | `~/.config/pwdebug/config.lua`               |
| `pwdebug-snapshot-file`     | `/tmp/pwdebug/snapshot.json`                 |
| `pwdebug-state-file`        | `/tmp/pwdebug/state`                         |
| `pwdebug-cmd-file`          | `/tmp/pwdebug/cmd`                           |
| `pwdebug-poll-interval`     | `0.5` seconds                                |
| `pwdebug-locals-window-width` | `60` columns                               |

## Key bindings

In any Lua buffer with `pwdebug-mode` on:

| key            | command                                      |
|----------------|----------------------------------------------|
| `C-c d b`      | toggle plain breakpoint                      |
| `C-u C-c d b`  | toggle CONDITIONAL breakpoint (prompts)      |
| `C-c d B`      | set / replace the condition on this line     |
| `C-c d i`      | toggle info-point (prompts for expression)   |
| `C-c d e`      | edit the expression on the point at point    |
| `C-c d l`      | pop up the list of all configured points     |
| `C-c d C`      | clear ALL points                             |
| `C-c d c/s/n/f`| continue / step in / step over / finish      |
| `C-c d ?`      | full help popup                              |

In `*pwdebug-locals*` (when paused):

| key             | command                                     |
|-----------------|---------------------------------------------|
| `RET` / `TAB`   | expand / collapse (or jump to source on a frame) |
| `+` / `→`       | expand only                                 |
| `-` / `←`       | collapse only / step up to parent           |
| `j` / `↓`       | next row                                    |
| `k` / `↑`       | previous row                                |
| `M-n` / `M-p`   | next / previous stack frame                 |
| `c`             | continue                                    |
| `s`             | step into                                   |
| `n`             | step over                                   |
| `f`             | finish (step out)                           |
| `g`             | refresh from snapshot file                  |
| `?`             | help                                        |
| `q`             | hide the locals window                      |

## How conditional breakpoints work

When a breakpoint has a non-empty `expr`, the runtime builds an
environment from the user frame's **locals** + **upvalues** at the
breakpoint line (with `_G` as fallback), evaluates the expression
via `loadstring("return " .. expr)`, and only pauses when the
result is truthy. Errors in the expression also pause (so you can
see the error message in the locals view) — they don't silently
hide a misconfigured condition.

## Roadmap

- Optional `tree-widget` rendering of the value tree
- Persistent expansion state across runs
- `pwdebug-eval-region` for ad-hoc evaluation in the paused frame

## License

GPL-3.0-or-later. See `LICENSE`.
