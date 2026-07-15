-- The demo notebook's cells, shared by both demo entry points (scripted and
-- real kernel). The python is real: against the real kernel these cells
-- actually compute; the scripted client pattern-matches the same sources
-- (sleep -> slow, raise -> error).

local M = {}

function M.fill(st)
  st:insert_cell(1, {
    type = "markdown",
    source = table.concat({
      "# perijove demo",
      "",
      "A notebook in Neovim. Markdown cells render rich, math included:",
      "$e^{i\\pi} + 1 = 0$, and display math too:",
      "",
      "$$",
      "f'(x) = \\lim_{h \\to 0} \\frac{f(x + h) - f(x)}{h}",
      "$$",
      "",
      "Code cells are real python buffers — enter one with `<CR>` or `i`,",
      "edit it, step out with `hjkl` at the edge. Every perijove bind is a",
      "chord under `<C-j>`:",
      "",
      "- `r` run the hovered cell · `<CR>` run and advance",
      "- `o`/`O` add a cell below/above · `d` delete · `J`/`K` move",
      "- `m` retype code ↔ markdown · `e` edit THIS cell in a split preview",
      "- `c` fold a cell's outputs · `C` clear them · `x` clear all",
      "- `a` run all · `i` interrupt (the sleep cell earns it) · `q` quit",
    }, "\n"),
  })
  st:insert_cell(2, {
    type = "code",
    source = 'greeting = "hello"\nprint(f"{greeting} from a code cell")\nsum(k**2 for k in range(1, 11))',
  })
  st:insert_cell(3, {
    type = "code",
    source = "from IPython.display import Markdown\nMarkdown('rich outputs: **markdown** and math, $\\\\sqrt{2}$')",
  })
  st:insert_cell(4, {
    type = "code",
    source = 'name = input("who runs this notebook? ")\nprint(f"hi, {name}")',
  })
  st:insert_cell(5, {
    type = "code",
    source = "import time\ntime.sleep(60)  # interrupt me with <C-j>i",
  })
  st:insert_cell(6, {
    type = "code",
    source = 'raise ValueError("this one fails")',
  })
end

return M
