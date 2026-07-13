-- Demo entry point: a clean Neovim (`nvim --clean -u demo/init.lua`, or
-- `make demo` / `nix run .#demo`) with jotdown and fibrous on the path,
-- showing the notebook view against the SCRIPTED kernel client — no jupyter,
-- no network. Mounted over the REAL current window (not a float), like
-- actual usage will be.
--
-- Keybinds are chords under the jotdown prefix (<C-j>, see view/notebook.lua):
--   <C-j>r  run the cell under the cursor (works inside a focused cell too)
--   <C-j>a  run all cells
--   <C-j>i  interrupt the kernel (try it on the sleep cell)
--   <C-j>q  quit the demo
-- Plus the fibrous basics: hjkl glides over cells; <CR>/i on a code cell
-- enters its real buffer (hjkl at the edge steps back out); hover a [run]
-- button and press <CR>/<Space>.

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
  fibrous .. "/lua/?.lua",
  fibrous .. "/lua/?/init.lua",
  package.path,
}, ";")

local nr = require("fibrous")
local store = require("jotdown.store")
local scripted = require("jotdown.client.scripted")
local notebook = require("jotdown.view.notebook")

local st = store.new(scripted.new())

st:insert_cell(1, {
  type = "markdown",
  source = table.concat({
    "# jotdown demo",
    "",
    "A notebook over the **scripted** kernel. Markdown cells render rich,",
    "math included: $e^{i\\pi} + 1 = 0$, and display math too:",
    "",
    "$$",
    "f'(x) = \\lim_{h \\to 0} \\frac{f(x + h) - f(x)}{h}",
    "$$",
    "",
    "Code cells are real python buffers — enter one with `<CR>` or `i`,",
    "edit it, step out with `hjkl` at the edge. Run the cell under the",
    "cursor with `<C-j>r` (or its button); `<C-j>a` runs all,",
    "`<C-j>i` interrupts, `<C-j>q` quits.",
  }, "\n"),
})
st:insert_cell(2, {
  type = "code",
  source = 'greeting = "hello"\nprint(f"{greeting} from a code cell")',
})
st:insert_cell(3, {
  type = "code",
  source = "import time\ntime.sleep(60)  # interrupt me with I",
})
st:insert_cell(4, {
  type = "code",
  source = 'raise ValueError("this one fails")',
})

-- Over the current (only) window — a notebook is a document you open, not a
-- popup. `keys` routes the run chord to the cell under the cursor.
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
