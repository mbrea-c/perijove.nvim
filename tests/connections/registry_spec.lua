-- The connection registry: one plugin-global, named catalog of ways to reach
-- a Jupyter Server. A connection is a declarative spec; resolving it yields
-- an endpoint { base_url, token?, headers?, stop? } the server client dials.
-- The builtin "local" connection (spawn jupyter-server) is always present.

local connections = require("perijove.connections")

describe("connection registry", function()
  before_each(function()
    connections._reset()
  end)

  it("ships the builtin local connection", function()
    local c = connections.get("local")
    assert.is_not_nil(c)
    assert.equal("local", c.kind)
    assert.equal("builtin", c.source)
  end)

  it("registers and gets by name", function()
    connections.add({ name = "gpu-box", kind = "remote", url = "http://gpu:8888", token = "t" })
    local c = connections.get("gpu-box")
    assert.equal("remote", c.kind)
    assert.equal("http://gpu:8888", c.url)
    assert.equal("api", c.source)
  end)

  it("upserts on re-add (reload friendly)", function()
    connections.add({ name = "a", kind = "remote", url = "http://one" })
    connections.add({ name = "a", kind = "remote", url = "http://two" })
    assert.equal("http://two", connections.get("a").url)
    local names = {}
    for _, c in ipairs(connections.list()) do
      names[#names + 1] = c.name
    end
    assert.same({ "a", "local" }, names)
  end)

  it("removes by name, but never the builtin", function()
    connections.add({ name = "a", kind = "remote", url = "http://one" })
    connections.remove("a")
    assert.is_nil(connections.get("a"))
    assert.has_error(function()
      connections.remove("local")
    end, "builtin")
  end)

  it("lists sorted by name", function()
    connections.add({ name = "zeta", kind = "remote", url = "http://z" })
    connections.add({ name = "alpha", kind = "remote", url = "http://a" })
    local names = {}
    for _, c in ipairs(connections.list()) do
      names[#names + 1] = c.name
    end
    assert.same({ "alpha", "local", "zeta" }, names)
  end)

  it("validates specs on add", function()
    assert.has_error(function()
      connections.add({ kind = "remote", url = "http://x" })
    end, "name")
    assert.has_error(function()
      connections.add({ name = "x", kind = "remote" })
    end, "url")
    assert.has_error(function()
      connections.add({ name = "x", kind = "command" })
    end, "argv")
    assert.has_error(function()
      connections.add({ name = "x", kind = "no-such-kind" })
    end, "kind")
  end)

  it("accepts a raw lua connect function as its own kind", function()
    connections.add({
      name = "dyn",
      connect = function(_, cb)
        cb(nil, { base_url = "http://dialed" })
      end,
    })
    assert.equal("lua", connections.get("dyn").kind)
  end)

  it("defaults to local until set_default", function()
    assert.equal("local", connections.get_default())
    connections.add({ name = "a", kind = "remote", url = "http://one" })
    connections.set_default("a")
    assert.equal("a", connections.get_default())
    assert.has_error(function()
      connections.set_default("nope")
    end, "unknown")
  end)
end)

describe("connection resolve", function()
  before_each(function()
    connections._reset()
  end)

  it("remote resolves purely to its endpoint", function()
    connections.add({ name = "r", kind = "remote", url = "http://gpu:8888/", token = "tok" })
    local ep
    connections.resolve("r", function(err, e)
      assert.is_nil(err)
      ep = e
    end)
    assert.equal("http://gpu:8888", ep.base_url) -- trailing slash trimmed
    assert.equal("tok", ep.token)
  end)

  it("remote headers may be a function (dynamic creds)", function()
    connections.add({
      name = "r",
      kind = "remote",
      url = "http://gpu",
      headers = function()
        return { Authorization = "Bearer fresh" }
      end,
    })
    local ep
    connections.resolve("r", function(_, e)
      ep = e
    end)
    assert.same({ Authorization = "Bearer fresh" }, ep.headers())
  end)

  it("lua kind resolves through its connect function", function()
    local got_spec
    connections.add({
      name = "dyn",
      connect = function(spec, cb)
        got_spec = spec
        cb(nil, { base_url = "http://dialed", token = "d" })
      end,
    })
    local ep
    connections.resolve("dyn", function(err, e)
      assert.is_nil(err)
      ep = e
    end)
    assert.equal("dyn", got_spec.name)
    assert.equal("http://dialed", ep.base_url)
  end)

  it("resolves an anonymous spec table directly", function()
    local ep
    connections.resolve({ kind = "remote", url = "http://adhoc" }, function(_, e)
      ep = e
    end)
    assert.equal("http://adhoc", ep.base_url)
  end)

  it("errors on unknown names", function()
    local err
    connections.resolve("ghost", function(e)
      err = e
    end)
    assert.truthy(err:find("ghost", 1, true))
  end)

  it("command kind spawns argv, reads a JSON handshake line, stop kills", function()
    local killed = false
    local fake_spawner = function(argv, on_line)
      assert.same({ "my-tunnel", "--up" }, argv)
      on_line('{"url": "http://127.0.0.1:9999", "token": "tuntok"}')
      return {
        kill = function()
          killed = true
        end,
      }
    end
    connections.add({ name = "tun", kind = "command", argv = { "my-tunnel", "--up" } })
    local ep
    connections.resolve("tun", function(err, e)
      assert.is_nil(err)
      ep = e
    end, { spawner = fake_spawner })
    assert.equal("http://127.0.0.1:9999", ep.base_url)
    assert.equal("tuntok", ep.token)
    ep.stop()
    assert.is_true(killed)
  end)

  it("local kind spawns a server, waits ready, endpoint owns it", function()
    local stopped = false
    local fake_localserver = {
      spawn = function(opts)
        assert.equal("/nb/root", opts.root_dir)
        return {
          base_url = "http://127.0.0.1:1234",
          token = "loctok",
          stop = function()
            stopped = true
          end,
        }
      end,
      wait_ready = function()
        return true
      end,
    }
    connections.add({ name = "here", kind = "local", root_dir = "/nb/root" })
    local ep
    connections.resolve("here", function(err, e)
      assert.is_nil(err)
      ep = e
    end, { localserver = fake_localserver, transport = {} })
    assert.equal("http://127.0.0.1:1234", ep.base_url)
    assert.equal("loctok", ep.token)
    ep.stop()
    assert.is_true(stopped)
  end)

  it("local kind reports a server that never comes up, without leaking it", function()
    local stopped = false
    local fake_localserver = {
      spawn = function()
        return {
          base_url = "http://127.0.0.1:1234",
          token = "t",
          stop = function()
            stopped = true
          end,
        }
      end,
      wait_ready = function()
        return false
      end,
    }
    local err
    connections.resolve("local", function(e)
      err = e
    end, { localserver = fake_localserver, transport = {} })
    assert.truthy(err)
    assert.is_true(stopped)
  end)

  it("command kind reports a bad handshake as an error", function()
    local killed = false
    local fake_spawner = function(_, on_line)
      on_line("not json at all")
      return {
        kill = function()
          killed = true
        end,
      }
    end
    connections.add({ name = "tun", kind = "command", argv = { "t" } })
    local err
    connections.resolve("tun", function(e)
      err = e
    end, { spawner = fake_spawner })
    assert.truthy(err)
    assert.is_true(killed) -- a half-open tunnel must not leak
  end)
end)
