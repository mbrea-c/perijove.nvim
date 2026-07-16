-- Demo entry point: a clean Neovim (`nvim --clean -u demo/init.lua`, or
-- `make demo` / `nix run .#demo`) with perijove and fibrous on the path,
-- showing the notebook view against the SCRIPTED kernel client — no jupyter,
-- no network.
--
-- The demo takes the plugin's own path, not a shortcut: the seed cells are
-- serialized into an in-memory .ipynb buffer and opened through
-- notebook_file, so everything a real file gets works here too — the mount
-- over the buffer's window, the <C-j> chords, <C-j>t toggling down to the
-- raw JSON this buffer actually holds, hide-and-remount on window close.
-- Only :w differs: the buffer has no name, so saving asks for :saveas.
--
-- Keybinds are chords under the perijove prefix (<C-j>, the seed's first
-- cell lists them). Plus the fibrous basics: hjkl glides over cells;
-- <CR>/i on a code cell enters its real buffer (hjkl at the edge steps back
-- out); hover a [run] button and press <CR>/<Space>.

-- Resolve paths from this file's own location, not the cwd, so the nix app
-- (`-u /nix/store/...-source/demo/init.lua`) works from anywhere.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")
local fibrous = vim.env.FIBROUS_PATH or (root .. "/../fibrous.nvim")

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(fibrous)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/?.lua", -- demo.seed lives outside lua/
  fibrous .. "/lua/?.lua",
  fibrous .. "/lua/?/init.lua",
  package.path,
}, ";")

local notebook_file = require("perijove.notebook_file")
local scripted = require("perijove.client.scripted")
local ipynb = require("perijove.ipynb")
local notebook = require("perijove.view.notebook")
local seed = require("demo.seed")

-- An in-memory notebook: an unnamed listed buffer holding real nbformat
-- JSON, shown in the current (only) window — a notebook is a document you
-- open, not a popup.
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(0, buf)
local json = ipynb.encode(ipynb.new_meta(), seed.cells())
vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(json:gsub("\n$", ""), "\n"))
vim.bo[buf].modified = false

notebook_file.open(buf, { client = scripted.new() })

vim.keymap.set("n", notebook.PREFIX .. "q", function()
  vim.cmd("qa!")
end, { desc = "perijove: quit the demo" })
