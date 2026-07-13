-- END-TO-END: a real jupyter server, a real ipykernel, the real
-- curl+websocat transport — the one place the whole stack is exercised
-- against the actual thing. Loopback only; skipped (loudly) when
-- jupyter-server isn't on PATH, so the default suite stays hermetic on
-- machines without it. The nix devShell and the flake check both provide it.

if vim.fn.executable("jupyter-server") == 0 then
  io.write("[skip] integration: jupyter-server not on PATH\n")
  return
end

local localserver = require("jotdown.localserver")
local transport_mod = require("jotdown.transport")
local server_client = require("jotdown.client.server")

describe("integration: real kernel", function()
  it("executes code end to end: stream, result, error, interrupt-free done", function()
    local srv = localserver.spawn()
    local transport = transport_mod.create(nil, {})
    assert.is_true(localserver.wait_ready(srv, transport, 60000))

    local client = server_client.new({
      transport = transport,
      base_url = srv.base_url,
      token = srv.token,
    })

    local connect_err, connected = nil, false
    client:connect(function(e)
      connect_err, connected = e, true
    end)
    vim.wait(30000, function()
      return connected
    end, 100)
    assert.is_true(connected)
    assert.is_nil(connect_err)

    -- one helper: run code, pump until on_done, return events
    local function run(code)
      local events, done = {}, false
      client:execute(code, {
        on_stream = function(name, text)
          table.insert(events, { "stream", name, text })
        end,
        on_result = function(data)
          table.insert(events, { "result", data["text/plain"] })
        end,
        on_display = function(data)
          table.insert(events, { "display", data })
        end,
        on_error = function(ename)
          table.insert(events, { "error", ename })
        end,
        on_done = function(reply)
          table.insert(events, { "done", reply.status, reply.execution_count })
          done = true
        end,
      })
      vim.wait(60000, function()
        return done
      end, 100)
      assert.is_true(done)
      return events
    end

    -- stream + result
    local events = run("print(40 + 2)\n'the result'")
    local streamed, resulted = "", nil
    for _, e in ipairs(events) do
      if e[1] == "stream" then
        streamed = streamed .. e[3]
      elseif e[1] == "result" then
        resulted = e[2]
      end
    end
    assert.equal("42\n", streamed)
    assert.equal("'the result'", resulted)
    assert.equal("ok", events[#events][2])
    assert.equal(1, events[#events][3]) -- first execution

    -- state persists across cells (it is one kernel)
    run("x = 10")
    local again = run("x * 2")
    local got
    for _, e in ipairs(again) do
      if e[1] == "result" then
        got = e[2]
      end
    end
    assert.equal("20", got)

    -- an error travels the error path and still settles
    local failed = run('raise ValueError("boom")')
    local seen_error = false
    for _, e in ipairs(failed) do
      if e[1] == "error" and e[2] == "ValueError" then
        seen_error = true
      end
    end
    assert.is_true(seen_error)
    assert.equal("error", failed[#failed][2])

    client:shutdown()
    srv.stop()
  end)
end)
