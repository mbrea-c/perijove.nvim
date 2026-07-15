-- The default transport shells out to curl (HTTP) and websocat (websocket).
-- Everything that can be pure IS pure — argv construction, response parsing,
-- stream line-splitting — so the suite covers it without network or processes.

local cw = require("perijove.transport.curl_websocat")

describe("curl_websocat", function()
  describe("curl_args", function()
    it("builds a GET with headers in deterministic order", function()
      local args = cw.curl_args("curl", {
        method = "GET",
        url = "http://localhost:8888/api/kernels",
        headers = { ["Authorization"] = "token abc", ["X-Two"] = "2" },
      })
      assert.equal("curl", args[1])
      -- headers sorted by name, each as one "-H", "Name: value" pair
      local rendered = table.concat(args, " ")
      assert.truthy(rendered:find("-H Authorization: token abc", 1, true))
      assert.truthy(rendered:find("-H X-Two: 2", 1, true))
      assert.truthy(rendered:find("Authorization") < rendered:find("X-Two"))
      assert.equal("http://localhost:8888/api/kernels", args[#args])
    end)

    it("sends bodies via stdin, never argv", function()
      local args = cw.curl_args("curl", {
        method = "POST",
        url = "http://h/api/sessions",
        body = '{"name":"nb"}',
      })
      local rendered = table.concat(args, " ")
      assert.truthy(rendered:find("--data-binary @-", 1, true))
      assert.falsy(rendered:find("nb", 1, true))
    end)

    it("wires cookie jar and timeout when given", function()
      local args = cw.curl_args("curl", {
        method = "GET",
        url = "http://h/",
        cookie_jar = "/tmp/jar",
        timeout_ms = 2500,
      })
      local rendered = table.concat(args, " ")
      assert.truthy(rendered:find("-b /tmp/jar", 1, true))
      assert.truthy(rendered:find("-c /tmp/jar", 1, true))
      assert.truthy(rendered:find("--max-time 3", 1, true)) -- ceil to whole seconds
    end)
  end)

  describe("parse_curl_output", function()
    it("splits body from the appended status line", function()
      local res = cw.parse_curl_output('{"id":"k1"}\n201')
      assert.equal(201, res.status)
      assert.equal('{"id":"k1"}', res.body)
    end)

    it("handles an empty body", function()
      local res = cw.parse_curl_output("\n204")
      assert.equal(204, res.status)
      assert.equal("", res.body)
    end)

    it("keeps newlines inside the body intact", function()
      local res = cw.parse_curl_output("line1\nline2\n200")
      assert.equal(200, res.status)
      assert.equal("line1\nline2", res.body)
    end)

    it("rejects output without a status marker", function()
      local res = cw.parse_curl_output("garbage")
      assert.is_nil(res)
    end)
  end)

  describe("ws_args", function()
    it("builds a text-mode stdio bridge with headers in the = form", function()
      local args = cw.ws_args("websocat", {
        url = "ws://localhost:8888/api/kernels/k1/channels",
        headers = { ["Authorization"] = "token abc" },
      })
      assert.equal("websocat", args[1])
      local rendered = table.concat(args, " ")
      assert.truthy(rendered:find("-t", 1, true))
      -- websocat's -H is multi-value: the separate-argument form eats every
      -- following arg INCLUDING THE URL ("No URL specified"); only the
      -- equals form is safe
      assert.truthy(rendered:find("-H=Authorization: token abc", 1, true))
      assert.equal("ws://localhost:8888/api/kernels/k1/channels", args[#args])
    end)
  end)

  describe("line_splitter", function()
    it("reassembles messages across arbitrary chunk boundaries", function()
      local got = {}
      local feed = cw.line_splitter(function(line)
        table.insert(got, line)
      end)
      feed('{"a"')
      feed(':1}\n{"b":2}\n{"c"')
      feed(":3}\n")
      assert.same({ '{"a":1}', '{"b":2}', '{"c":3}' }, got)
    end)

    it("flushes a trailing unterminated line on eof", function()
      local got = {}
      local feed = cw.line_splitter(function(line)
        table.insert(got, line)
      end)
      feed("tail-without-newline")
      feed(nil) -- eof
      assert.same({ "tail-without-newline" }, got)
    end)

    it("ignores empty lines (websocat keepalive noise)", function()
      local got = {}
      local feed = cw.line_splitter(function(line)
        table.insert(got, line)
      end)
      feed("\n\n{}\n")
      assert.same({ "{}" }, got)
    end)
  end)
end)
