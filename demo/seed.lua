-- The demo notebook's cells, shared by both demo entry points (scripted and
-- real kernel). The python is real: against the real kernel these cells
-- actually compute; the scripted client pattern-matches the same sources
-- (sleep -> slow, raise -> error).

local M = {}

function M.fill(st)
  st:insert_cell(1, {
    type = "markdown",
    source = table.concat({
      "# jotdown demo",
      "",
      "A notebook in Neovim. Markdown cells render rich, math included:",
      "$e^{i\\pi} + 1 = 0$, and display math too:",
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
    source = 'greeting = "hello"\nprint(f"{greeting} from a code cell")\nsum(k**2 for k in range(1, 11))',
  })
  st:insert_cell(3, {
    type = "code",
    source = "import time\ntime.sleep(60)  # interrupt me with <C-j>i",
  })
  st:insert_cell(4, {
    type = "code",
    source = 'raise ValueError("this one fails")',
  })
end

return M
