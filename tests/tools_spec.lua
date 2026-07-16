-- External tool resolution: the nix package substitutes @curl@/@websocat@
-- placeholders with absolute store paths; a source checkout falls back to
-- PATH names; explicit configuration beats both.

local tools = require("perijove.tools")

describe("tools.path", function()
  after_each(function()
    tools.configure({})
  end)

  it("falls back to the bare PATH name in a source checkout", function()
    -- in-repo the placeholders are unsubstituted, so "@" is still present
    assert.equal("curl", tools.path("curl"))
    assert.equal("websocat", tools.path("websocat"))
  end)

  it("prefers a configured override over any default", function()
    tools.configure({ curl = "/opt/custom/curl" })
    assert.equal("/opt/custom/curl", tools.path("curl"))
    assert.equal("websocat", tools.path("websocat"))
  end)

  it("passes unknown names through as PATH lookups", function()
    assert.equal("jq", tools.path("jq"))
  end)

  it("resolves jupyter-server like the transport tools", function()
    -- source checkout: placeholder unsubstituted, PATH fallback
    assert.equal("jupyter-server", tools.path("jupyter-server"))
    tools.configure({ ["jupyter-server"] = "/opt/env/bin/jupyter-server" })
    assert.equal("/opt/env/bin/jupyter-server", tools.path("jupyter-server"))
  end)
end)
