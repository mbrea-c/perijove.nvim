-- The kernel-client boundary — the coarse pluggable seam (see AGENTS.md).
-- The notebook store consumes THIS interface and nothing else about how
-- kernels are reached; implementations include the scripted client
-- (tests/demo), the Jupyter Server REST+websocket client, and potentially a
-- jupyter_client python sidecar.
--
-- Interface every implementation satisfies:
--
--   client:attach(handlers)
--     Kernel-level events, wired once by the store:
--       on_status(status)     "busy" | "idle" | "starting" | "dead" | ...
--
--   client:execute(code, handlers)
--     Run one code string. The client delivers, in kernel order:
--       on_stream(name, text)             stdout/stderr chunks
--       on_result(data, metadata)         execute_result mime bundle
--       on_display(data, metadata)        display_data mime bundle
--       on_error(ename, evalue, traceback)
--       on_input(prompt, password, reply) stdin ask — the kernel is blocked
--                                         in input() until reply(text)
--       on_done(reply)                    exactly once, last:
--                                         { status = "ok"|"error"|"aborted",
--                                           execution_count = n }
--     The store sends ONE execute at a time (it owns the queue); a client
--     never sees concurrent executions from one store.
--
--   client:interrupt()      best-effort; the running execute still settles
--                           through its own on_error/on_done
--   client:restart(cb)      the in-flight execute never settles; the store
--                           backs its cells out locally
--   client:shutdown(cb)
--
-- All callbacks arrive on the main loop.

local M = {}

-- Structural check used by consumers that accept injected clients.
function M.is_client(t)
  return type(t) == "table"
    and type(t.attach) == "function"
    and type(t.execute) == "function"
    and type(t.interrupt) == "function"
end

return M
