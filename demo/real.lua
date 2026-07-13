-- The REAL demo: the same notebook, but over an actual jupyter kernel —
-- spawns a local jupyter-server on loopback, creates a session, and every
-- run is genuine python. Needs jupyter-server, curl and websocat on PATH:
--   nix run .#demo-real            (brings all three)
--   nix develop -c make demo-real  (ditto, against the working tree)
--
-- Same keybinds as the scripted demo: <C-j>r run hovered cell, <C-j>a run
-- all, <C-j>i interrupt (the sleep cell earns it here), <C-j>q quit.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")
local fibrous = vim.env.FIBROUS_PATH or (root .. "/../fibrous.nvim")

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(fibrous)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/?.lua",
  fibrous .. "/lua/?.lua",
  fibrous .. "/lua/?/init.lua",
  package.path,
}, ";")

if vim.fn.executable("jupyter-server") == 0 then
  io.write("jotdown demo-real: jupyter-server not on PATH — use `nix run .#demo-real`\n")
  vim.cmd("cquit 1")
end

local nr = require("fibrous")
local store = require("jotdown.store")
local localserver = require("jotdown.localserver")
local transport = require("jotdown.transport")
local server_client = require("jotdown.client.server")
local notebook = require("jotdown.view.notebook")
local seed = require("demo.seed")

-- Boot: spawn + ready-poll + session create, blocking (a couple of seconds)
-- with progress on the way. The plugin proper will do this async behind a
-- "starting kernel…" status; a demo can afford to be simple.
print("jotdown: starting local jupyter server…")
local srv = localserver.spawn()
local wire = transport.create(nil, {})
if not localserver.wait_ready(srv, wire, 60000) then
  io.write("jotdown demo-real: jupyter server did not come up\n")
  vim.cmd("cquit 1")
end

local client = server_client.new({
  transport = wire,
  base_url = srv.base_url,
  token = srv.token,
})
local st = store.new(client)

print("jotdown: starting kernel…")
local connect_err, connected
client:connect(function(e)
  connect_err, connected = e, true
end)
vim.wait(30000, function()
  return connected
end, 100)
if not connected or connect_err then
  io.write("jotdown demo-real: connect failed: " .. tostring(connect_err) .. "\n")
  vim.cmd("cquit 1")
end

seed.fill(st)

local handle = nr.mount_window(notebook.Notebook, { store = st }, { winid = 0, mode = "scroll", keys = notebook.KEYS })
handle.focus()

local prefix = notebook.PREFIX
vim.keymap.set("n", prefix .. "a", function()
  st:run_all()
end, { desc = "jotdown: run all cells" })
vim.keymap.set("n", prefix .. "i", function()
  st:interrupt()
end, { desc = "jotdown: interrupt the kernel" })
vim.keymap.set("n", prefix .. "q", function()
  vim.cmd("qa!")
end, { desc = "jotdown: quit the demo" })

-- Leave nothing behind: end the session (kills the kernel) and stop the
-- server on the way out, however the user quits.
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    pcall(function()
      client:shutdown()
    end)
    pcall(srv.stop)
  end,
})
