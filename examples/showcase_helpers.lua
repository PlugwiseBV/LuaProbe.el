-- examples/showcase_helpers.lua — companion file for showcase.lua.
--
-- Defining coroutine bodies + a counter factory in a SECOND file
-- demonstrates LuaProbe's cross-file jumping: a breakpoint inside
-- `producer` / `consumer' / the inner `make_counter' closure pauses
-- here, and RET on a #2 / #3 frame in the *luaprobe-locals* window
-- jumps you back to the call site in showcase.lua.
--
-- The showcase prelude does:
--
--   package.path = SCRIPT_DIR .. "?.lua;" .. package.path
--   local h = require("showcase_helpers")
--
-- so this file is loaded once and every function ends up as an
-- upvalue of the consumer in showcase.lua.

local M = {}

-- ===========================================================
-- COROUTINES
-- ===========================================================
-- Try:
--   1.  Set a stop bp on ★bp6 (inside `producer`).  When it
--       fires, the *luaprobe-locals* PAUSED line shows
--       `thread: coroutine co:XXXXXXXX` and `created: showcase.lua:N`
--       — the coroutine creation site.  Frames #2 onward live
--       in showcase.lua; click them and Emacs jumps across files.
--   2.  Set a bp on ★bp7 (inside `consumer`).  Different stack
--       chain again — `consumer` was launched as its own coroutine.
--   3.  Add a CONDITIONAL bp at ★bp6: `if i == 4`.  Only the
--       4th yield triggers it.

function M.producer(n)
  for i = 1, n do
    coroutine.yield(i)                             -- ★bp6
  end
end

function M.consumer(prod_co)
  while true do
    local ok, x = coroutine.resume(prod_co)
    if not ok or x == nil then break end
    coroutine.yield(x * x)                         -- ★bp7
  end
end

function M.pump(_, cons_co)
  local out = {}
  while true do
    local ok, sq = coroutine.resume(cons_co)
    if not ok or sq == nil then break end
    out[#out + 1] = sq
  end
  return out
end

-- ===========================================================
-- CLOSURES (per-instance upvalues)
-- ===========================================================
-- `make_counter` returns a function that closes over `count'.
-- Each returned counter has its OWN `count` upvalue.  Set a bp
-- on ★bp8 and inspect upvalues: `count' here is the value of
-- THIS counter, not the one created earlier.  Try `o' to pop
-- the *luaprobe* REPL and `p count' for a deep dump, then `M-n`
-- to step to a different frame and watch the upvalue change.

function M.make_counter(start)
  local count = start
  return function(step)
    count = count + (step or 1)                    -- ★bp8
    return count
  end
end

return M
