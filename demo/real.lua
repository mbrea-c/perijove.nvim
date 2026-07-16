-- The REAL demo: the same notebook, but over an actual jupyter kernel —
-- spawns a local jupyter-server on loopback, creates a session, and every
-- run is genuine python. Needs jupyter-server, curl and websocat on PATH:
--   nix run .#demo-real            (brings all three)
--   nix develop -c make demo-real  (ditto, against the working tree)
--
-- Like the scripted demo, this goes through the plugin's own path: the seed
-- cells become an in-memory .ipynb buffer opened via notebook_file, with the
-- connected server client injected. Same keybinds (the seed's first cell
-- lists them). Being real python, the input() cell actually prompts and the
-- rich-output cell comes back as rendered markdown with math.

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
  io.write("perijove demo-real: jupyter-server not on PATH — use `nix run .#demo-real`\n")
  vim.cmd("cquit 1")
end

local notebook_file = require("perijove.notebook_file")
local localserver = require("perijove.localserver")
local transport = require("perijove.transport")
local server_client = require("perijove.client.server")
local ipynb = require("perijove.ipynb")
local notebook = require("perijove.view.notebook")
local seed = require("demo.seed")

-- Boot: spawn + ready-poll + session create, blocking (a couple of seconds)
-- with progress on the way. The plugin proper will do this async behind a
-- "starting kernel…" status; a demo can afford to be simple.
print("perijove: starting local jupyter server…")
local srv = localserver.spawn()
local wire = transport.create(nil, {})
if not localserver.wait_ready(srv, wire, 60000) then
  io.write("perijove demo-real: jupyter server did not come up\n")
  vim.cmd("cquit 1")
end

local client = server_client.new({
  transport = wire,
  base_url = srv.base_url,
  token = srv.token,
})

print("perijove: starting kernel…")
local connect_err, connected
client:connect(function(e)
  connect_err, connected = e, true
end)
vim.wait(30000, function()
  return connected
end, 100)
if not connected or connect_err then
  io.write("perijove demo-real: connect failed: " .. tostring(connect_err) .. "\n")
  vim.cmd("cquit 1")
end

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(0, buf)
local json = ipynb.encode(ipynb.new_meta(), seed.cells())
vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(json:gsub("\n$", ""), "\n"))
vim.bo[buf].modified = false

notebook_file.open(buf, { client = client })

vim.keymap.set("n", notebook.PREFIX .. "q", function()
  vim.cmd("qa!")
end, { desc = "perijove: quit the demo" })

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
