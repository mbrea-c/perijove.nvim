-- setup()-preconfigured connections: specs given in setup({ connections })
-- land in the global registry (source "setup"), and default_connection sets
-- the global default.

local connections = require("perijove.connections")
local perijove = require("perijove")

describe("setup({ connections })", function()
  before_each(function()
    connections._reset()
    perijove._reset_config()
  end)

  it("registers preconfigured connections and the default", function()
    perijove.setup({
      connections = {
        { name = "gpu", kind = "remote", url = "http://gpu:8888", token = "t" },
        {
          name = "dyn",
          connect = function(_, cb)
            cb(nil, { base_url = "http://dialed" })
          end,
        },
      },
      default_connection = "gpu",
    })
    assert.equal("remote", connections.get("gpu").kind)
    assert.equal("setup", connections.get("gpu").source)
    assert.equal("lua", connections.get("dyn").kind)
    assert.equal("gpu", connections.get_default())
  end)

  it("re-running setup upserts instead of duplicating", function()
    perijove.setup({ connections = { { name = "gpu", kind = "remote", url = "http://one" } } })
    perijove.setup({ connections = { { name = "gpu", kind = "remote", url = "http://two" } } })
    assert.equal("http://two", connections.get("gpu").url)
    assert.equal(2, #connections.list()) -- gpu + builtin local
  end)

  it("leaves the default alone when none is configured", function()
    perijove.setup({ connections = { { name = "gpu", kind = "remote", url = "http://one" } } })
    assert.equal("local", connections.get_default())
  end)
end)
