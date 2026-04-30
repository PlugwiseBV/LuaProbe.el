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
-- Each section below has a `-- ★bpN' anchor on the line where you
-- should set a breakpoint.  Anchors are searchable (`C-s ★bp1') so
-- they keep working even if the file shifts around.
--
-- In Emacs, place point on a ★ line and:
--   C-c d b           plain breakpoint
--   C-u C-c d b       conditional breakpoint (prompts)
--   C-c d L           log-only breakpoint
--
-- At the (luaprobe) prompt:
--
--   c / s / n / f      continue / step into / step over / finish
--   bt                 backtrace (full stack)
--   locals             current frame's locals + upvalues
--   p NAME             deep-inspect a local or upvalue
--   e EXPR             evaluate an expression in scope
--   frame N            switch to frame N
--   q                  quit (kills the target)

-- ===========================================================
-- SECTION 1 — locals, upvalues, and `e EXPR`
-- ===========================================================
-- `PI` and `seen` become upvalues of the closures defined below.
-- Set a STOP bp on ★bp1.  When it fires:
--   • `locals`  → `name`, `message`
--   • You'll see `PI`, `seen`, `add` etc. as upvalues
--   • `e PI * 2`           prints 6.28318
--   • `e #seen`            prints how many times greet has run
--   • `p seen`             deep-dumps the visited table

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
--   • Try again, but use `n` instead of `s` at ★bp2.  `middle`
--     runs to completion without dropping you into its body.
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
-- counter reaches 7.  At the prompt, `e i, j, sum` shows all
-- three values.

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
-- SECTION 5 — coroutines
-- ===========================================================
-- Two coroutines that talk to each other.  `producer` yields
-- integers 1..n; `consumer` resumes it, squares each value, and
-- yields the square.  `pump' drives both from the main thread.
--
-- Try:
--   1.  Set a stop bp on ★bp6 (inside `producer`).  When it
--       fires, `bt` shows you're in a coroutine — the stack is
--       just `producer` + the coroutine root, NOT the main
--       chain.
--   2.  Now set a bp on ★bp7 (inside `consumer`).  Same — the
--       stack is the consumer's frame chain, separate again.
--   3.  Add a CONDITIONAL bp at ★bp6: `if i == 4`.  Only the
--       4th yield triggers it.

local function producer(n)
  for i = 1, n do
    coroutine.yield(i)                             -- ★bp6
  end
end

local function consumer(prod_co)
  while true do
    local ok, x = coroutine.resume(prod_co)
    if not ok or x == nil then break end
    coroutine.yield(x * x)                         -- ★bp7
  end
end

local function pump(_, cons_co)
  local out = {}
  while true do
    local ok, sq = coroutine.resume(cons_co)
    if not ok or sq == nil then break end
    out[#out + 1] = sq
  end
  return out
end

-- ===========================================================
-- SECTION 6 — closures + per-instance upvalues
-- ===========================================================
-- `make_counter` returns a function that closes over `count'.
-- Each returned counter has its OWN `count` upvalue.  Set a bp
-- on ★bp8 and inspect upvalues: `count` here is the value of
-- THIS counter, not the one created earlier.  Try `bt` and
-- `frame 2` to see who called this counter — the call site in
-- main has the local you'd expect (`c1` or `c2`).

local function make_counter(start)
  local count = start
  return function(step)
    count = count + (step or 1)                    -- ★bp8
    return count
  end
end

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

print("\n=== Section 5: coroutines ===")
local prod = coroutine.create(function() producer(5) end)
local cons = coroutine.create(function() consumer(prod) end)
local squares = pump(prod, cons)
print("squares =", table.concat(squares, ", "))

print("\n=== Section 6: closures ===")
local c1 = make_counter(0)
local c2 = make_counter(100)
print("c1: ", c1(), c1(), c1())            -- 1, 2, 3
print("c2: ", c2(2), c2(2), c2(2))         -- 102, 104, 106

print("\nshowcase done.")
