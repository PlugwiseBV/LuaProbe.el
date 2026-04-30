-- examples/showcase.lua — guided tour of LuaProbe.el features.
--
-- Run me under the debugger from inside Emacs:
--
--   M-x luaprobe-install    (one-time clone of the LuaProbe Lua tool)
--   open this file, M-x luaprobe-launch
--
-- …or drive the debugger by hand:
--
--   ~/.local/share/luaprobe/bin/luaprobe -i lua5.1 examples/showcase.lua
--
-- This file pairs with examples/showcase_helpers.lua.  The tour
-- exercises CROSS-FILE jumping: a breakpoint inside the helpers'
-- `producer` / `consumer` coroutines pauses there; clicking the
-- caller frame in *luaprobe-locals* jumps Emacs back to this file.
--
-- Each section has a `-- ★bpN' anchor on the line where you should
-- set a breakpoint.  In Emacs, place point on a ★ line and:
--   C-c d b           plain breakpoint
--   C-u C-c d b       conditional breakpoint (prompts)
--   C-c d L           log-only breakpoint
--   C-c d ?           full key map
--
-- When the target pauses, the *luaprobe-locals* side window opens
-- on the right with a toolbar:
--   c / s / N / f      continue / step into / step over / finish
--   RET on a frame     jump source to that frame AND select it
--                      in the debugger (so locals/upvalues update)
--   o                  pop up the hidden *luaprobe* REPL for `p`,
--                      `e`, `bt', etc.
--   q                  hide the locals window

-- Set up package.path so we can require the helpers file from the
-- same directory regardless of where the script was launched from.
local script_dir = (arg[0] or ""):match("^(.*/)") or "./"
package.path = script_dir .. "?.lua;" .. package.path

local helpers = require("showcase_helpers")

-- ===========================================================
-- SECTION 1 — locals, upvalues, and `e EXPR`
-- ===========================================================
-- `PI` and `seen` become upvalues of the closures defined below.
-- Set a STOP bp on ★bp1.  When it fires:
--   • *luaprobe-locals* shows: `name`, `message` under locals,
--     `PI`, `seen`, `add`, `helpers' under upvalues
--   • Press `o' to pop the REPL, then:
--     `e PI * 2`        prints 6.28318
--     `e #seen`         prints how many times greet has run
--     `p seen`          deep-dumps the visited table

local PI   = 3.14159
local seen = {}

local function add(a, b)
  -- Single-stepping with `s` from the loop in main stops here.
  return a + b
end

local function greet(name)
  seen[#seen + 1] = name                           -- ★bp1
  local message = string.format("hello %s, pi=%.3f", name, PI)
  print(message)
  return message
end

-- ===========================================================
-- SECTION 2 — step into / step over / finish
-- ===========================================================
-- Set a plain bp on ★bp2 (inside `outer`).  When it hits:
--   • `s` steps into `middle`  → then into `inner` → then `add`
--   • Try again, but use `N` (capital) instead of `s` at ★bp2.
--     `middle` runs to completion without dropping you into its
--     body.
--   • Now set a bp on ★bp3 (inside `inner`).  When it fires,
--     `f` resumes execution and pauses again on the line in
--     `outer` right after `inner` returns.

local function inner(n)
  return add(n, 1)                                 -- ★bp3
end

local function middle(n)
  return inner(n) * 2
end

local function outer(n)
  return middle(n) + 7                             -- ★bp2
end

-- ===========================================================
-- SECTION 3 — conditional breakpoints
-- ===========================================================
-- Set a CONDITIONAL bp on ★bp4 with the condition `i == 7`.
-- The Emacs side renders it inline above the source as
--   ╎ IF i == 7
-- Run.  The breakpoint fires exactly once: when the outer
-- counter reaches 7.  Pop the REPL with `o', then `e i, j, sum'.

local function sum_of_products(limit)
  local sum = 0
  for i = 1, limit do
    for j = 1, i do
      sum = sum + (i * j)                          -- ★bp4
    end
  end
  return sum
end

-- ===========================================================
-- SECTION 4 — log-only breakpoints
-- ===========================================================
-- Set a LOG breakpoint on ★bp5 (`C-c d L`).  The Emacs side
-- shows `╎ LOG' inline above the source.
-- Run.  Each iteration logs the snapshot without pausing —
-- useful for tracing a hot loop without disturbing timing.

local function trace_sequence(start, n)
  local x = start
  for _ = 1, n do
    x = x * 2 + 1                                  -- ★bp5
  end
  return x
end

-- ===========================================================
-- SECTION 5 — coroutines (cross-file jumps)
-- ===========================================================
-- The producer / consumer / pump bodies live in showcase_helpers.lua.
-- Set a bp on ★bp6 in THAT file (open showcase_helpers.lua, place
-- point on the `coroutine.yield(i)' line, C-c d b).
--
-- When it fires:
--   • The PAUSED line shows `thread: coroutine co:XXX' plus
--     `created: showcase.lua:LINE' — the line below where we
--     called coroutine.create.
--   • Frame #1 is in showcase_helpers.lua; frame #2 is in this
--     file (the call site).  Press RET on frame #2 → Emacs
--     jumps across files AND the locals view updates to show
--     this frame's variables.

-- ===========================================================
-- SECTION 6 — closures + per-instance upvalues
-- ===========================================================
-- See showcase_helpers.lua's `make_counter' (★bp8).  When the bp
-- fires, the same source-line is hit twice — once for c1, once
-- for c2 — but the upvalue `count' is different each time
-- because each closure has its own.  After RET on frame #2,
-- Emacs jumps back here to the call site.

-- ===========================================================
-- main
-- ===========================================================

print("=== Section 1: locals + upvalues ===")
greet("world")
greet("luaprobe")

print("\n=== Section 2: deep call stack ===")
print("outer(10) =", outer(10))

print("\n=== Section 3: conditional bp ===")
print("sum_of_products(10) =", sum_of_products(10))

print("\n=== Section 4: log-only bp ===")
print("trace_sequence(1, 6) =", trace_sequence(1, 6))

print("\n=== Section 5: coroutines (cross-file) ===")
local prod = coroutine.create(function() helpers.producer(5) end)
local cons = coroutine.create(function() helpers.consumer(prod) end)
local squares = helpers.pump(prod, cons)
print("squares =", table.concat(squares, ", "))

print("\n=== Section 6: closures (cross-file) ===")
local c1 = helpers.make_counter(0)
local c2 = helpers.make_counter(100)
print("c1: ", c1(), c1(), c1())            -- 1, 2, 3
print("c2: ", c2(2), c2(2), c2(2))         -- 102, 104, 106

print("\nshowcase done.")
