-- The jupyter config window (requests.md): connection / kernel / server
-- configuration as a floating fibrous mount built on ui.dropdown. Pure view:
-- it renders the catalog it is given and reports picks through callbacks —
-- the notebook_file glue owns the side effects (set_connection, set_kernel,
-- the guided create flow) and feeds async data back in (set_kernels once the
-- connected server answered /api/kernelspecs).

local nr = require("fibrous")
local ui = nr.ui

local M = {}

local FIELD_W = 24
-- "Connection:" is the widest field label; the others pad to it
local LABEL_W = 11

local function dim(text)
  return { comp = ui.label, props = { text = { { text, hl = "@comment" } } } }
end

local function blank()
  return { comp = ui.label, props = { text = "" } }
end

local function field(label, dropdown_props)
  return {
    comp = ui.row,
    props = { gap = 1 },
    children = {
      { comp = ui.label, props = { text = label .. (" "):rep(LABEL_W - #label) } },
      { comp = ui.dropdown, props = dropdown_props },
    },
  }
end

--- @param props table see M.open
local function Window(_, props)
  local rows = {
    { comp = ui.label, props = { text = { { "Jupyter configuration", hl = "Title" } } } },
    blank(),
  }

  local names, by_name = {}, {}
  for _, spec in ipairs(props.connections) do
    names[#names + 1] = spec.name
    by_name[spec.name] = spec
  end
  rows[#rows + 1] = field("Connection:", {
    options = names,
    value = props.current or "",
    width = FIELD_W,
    on_select = props.on_connection,
  })
  local cur = by_name[props.current]
  if cur then
    local facts = cur.kind .. " · " .. (cur.source or "api")
    if props.default_name == cur.name then
      facts = facts .. " · default"
    end
    rows[#rows + 1] = dim((" "):rep(LABEL_W + 1) .. facts)
  end

  if props.on_kernel then
    rows[#rows + 1] = blank()
    local options = {}
    for _, k in ipairs(props.kernels or {}) do
      options[#options + 1] = k.name
    end
    if #options == 0 and props.kernel then
      options[1] = props.kernel
    end
    rows[#rows + 1] = field("Kernel:", {
      options = options,
      value = props.kernel or "",
      width = FIELD_W,
      -- free text: a kernelspec the server did not list (or could not be
      -- asked for yet) is still a valid thing to boot
      free_text = true,
      on_select = props.on_kernel,
    })
    if not props.kernels then
      rows[#rows + 1] = dim((" "):rep(LABEL_W + 1) .. "(kernel list loads from the connected server)")
    end
  end

  if props.on_new then
    rows[#rows + 1] = blank()
    rows[#rows + 1] = { comp = ui.button, props = { label = "+ new connection…", on_press = props.on_new } }
  end
  rows[#rows + 1] = blank()
  rows[#rows + 1] = dim("<C-n>/<C-p> move · <CR>/<C-y> pick · q close")

  return { comp = ui.col, props = {}, children = rows }
end

--- Open the config window.
--- opts: {
---   connections: spec[]            the merged registry+project catalog,
---   current: string|nil            the effective connection name,
---   default_name: string|nil       marked "default" in the facts line,
---   kernel: string|nil             the kernel the next boot asks for,
---   kernels: {name,display_name}[]|nil   server kernelspecs, when known,
---   on_connection: fun(name),      a connection pick,
---   on_kernel: fun(name)|nil       a kernel pick; absent = no kernel field,
---   on_new: fun()|nil              the "+ new connection…" action,
--- }
--- Returns { bufnr, winid, close, is_open, set_kernels(list),
--- set_connections(list, current?) } — the setters re-render in place.
function M.open(opts)
  local open = true
  local app
  local state = {
    connections = opts.connections,
    current = opts.current,
    kernel = opts.kernel,
    kernels = opts.kernels,
  }

  local function close()
    if not open then
      return
    end
    open = false
    app.unmount()
  end

  local build_props
  build_props = function()
    return {
      connections = state.connections,
      current = state.current,
      default_name = opts.default_name,
      kernel = state.kernel,
      kernels = state.kernels,
      on_connection = function(name)
        state.current = name
        opts.on_connection(name)
        app.set_props(build_props())
      end,
      on_kernel = opts.on_kernel and function(name)
        state.kernel = name
        opts.on_kernel(name)
      end or nil,
      on_new = opts.on_new or nil,
    }
  end

  -- title + blank + connection field + facts + blank + kernel field + note +
  -- blank + button + blank + hint, plus one row of slack
  app = nr.mount(Window, build_props(), {
    width = 52,
    height = 12,
    mode = "fixed",
    border = "rounded",
    backdrop = true,
  })

  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, close, { buffer = app.bufnr, nowait = true, desc = "perijove: close config window" })
  end
  app.focus()

  return {
    bufnr = app.bufnr,
    winid = app.winid,
    close = close,
    is_open = function()
      return open
    end,
    set_kernels = function(list)
      state.kernels = list
      app.set_props(build_props())
    end,
    set_connections = function(list, current)
      state.connections = list
      if current then
        state.current = current
      end
      app.set_props(build_props())
    end,
  }
end

return M
