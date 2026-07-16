-- Local jupyter-server argv construction (the pure part of spawn). The
-- default binary resolves through perijove.tools, so the nix package pins
-- jupyter-server by store path exactly like curl and websocat.

local tools = require("perijove.tools")
local localserver = require("perijove.localserver")

describe("localserver.argv", function()
  after_each(function()
    tools.configure({})
  end)

  it("defaults the binary through tools.path and appends the server flags", function()
    tools.configure({ ["jupyter-server"] = "/nix/store/env/bin/jupyter-server" })
    local argv = localserver.argv({}, 8888, "tok")
    assert.equal("/nix/store/env/bin/jupyter-server", argv[1])
    assert.is_true(vim.tbl_contains(argv, "--ServerApp.port=8888"))
    assert.is_true(vim.tbl_contains(argv, "--ServerApp.token=tok"))
  end)

  it("an explicit cmd prefix wins over the resolved default", function()
    tools.configure({ ["jupyter-server"] = "/nix/store/env/bin/jupyter-server" })
    local argv = localserver.argv({ cmd = { "ssh", "box", "jupyter-server" } }, 9999, "t")
    assert.same({ "ssh", "box", "jupyter-server" }, { argv[1], argv[2], argv[3] })
    assert.is_true(vim.tbl_contains(argv, "--ServerApp.port=9999"))
  end)
end)
