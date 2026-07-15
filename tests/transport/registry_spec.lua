-- The wire-transport boundary is pluggable: implementations register under a
-- name, consumers construct by name (or hand in an instance directly), and
-- "curl-websocat" ships as the default.

local transport = require("perijove.transport")

describe("transport registry", function()
  it("ships curl-websocat as the registered default", function()
    assert.equal("curl-websocat", transport.default)
    local t = transport.create("curl-websocat", {})
    assert.is_not_nil(t)
    assert.equal("function", type(t.request))
    assert.equal("function", type(t.ws_open))
  end)

  it("constructs the default when no name is given", function()
    local t = transport.create(nil, {})
    assert.equal("function", type(t.request))
  end)

  it("accepts custom registrations", function()
    transport.register("fake", function(opts)
      return { request = function() end, ws_open = function() end, opts = opts }
    end)
    local t = transport.create("fake", { marker = 7 })
    assert.equal(7, t.opts.marker)
  end)

  it("rejects unknown names with a helpful error", function()
    assert.has_error(function()
      transport.create("no-such-transport", {})
    end, "no-such-transport")
  end)

  it("passes a ready-made instance through create untouched", function()
    -- a table with request/ws_open is already a transport; used by tests and
    -- by users wiring an out-of-tree implementation straight into setup()
    local inst = { request = function() end, ws_open = function() end }
    assert.rawequal(inst, transport.create(inst, {}))
  end)
end)
