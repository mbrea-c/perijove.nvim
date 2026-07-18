-- The jupyter config window (requests.md): a floating fibrous mount with a
-- dropdown per configurable axis — which CONNECTION a notebook talks to and
-- which KERNEL it boots — plus the current connection's facts and a
-- new-connection action. Pure view: it renders what it is given and reports
-- picks through callbacks; the notebook_file glue owns the side effects.

local ConfigWindow = require("perijove.view.config_window")

local function wait_for(cond)
  vim.wait(500, cond, 5)
  return cond()
end

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

local function buffer_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

-- The window's dropdown input floats, keyed by the committed value each shows.
local function inputs_of(handle)
  local by_value = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win].fibrous_anchor == handle.winid and vim.api.nvim_win_get_config(win).focusable ~= false then
      local buf = vim.api.nvim_win_get_buf(win)
      by_value[vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1]] = { win = win, buf = buf }
    end
  end
  return by_value
end

local function popup_open(handle)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win].fibrous_anchor == handle.winid and vim.api.nvim_win_get_config(win).focusable == false then
      return true
    end
  end
  return false
end

-- Find "needle" in the buffer; returns 1-based row and 0-based col.
local function locate(bufnr, needle)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local col = l:find(needle, 1, true)
    if col then
      return i, col - 1
    end
  end
  error("not found in buffer: " .. needle)
end

local CONNECTIONS = {
  { name = "local", kind = "local", source = "builtin" },
  { name = "lab", kind = "remote", source = "json" },
}

local function open_window(overrides)
  local calls = { connection = {}, kernel = {}, new = 0 }
  local opts = {
    connections = CONNECTIONS,
    current = "lab",
    default_name = "local",
    kernel = "python3",
    on_connection = function(name)
      calls.connection[#calls.connection + 1] = name
    end,
    on_kernel = function(name)
      calls.kernel[#calls.kernel + 1] = name
    end,
    on_new = function()
      calls.new = calls.new + 1
    end,
  }
  for k, v in pairs(overrides or {}) do
    opts[k] = v
  end
  return ConfigWindow.open(opts), calls
end

describe("view.config_window", function()
  it("renders connection + kernel dropdowns with the current values and facts", function()
    local handle = open_window()
    local text = buffer_text(handle.bufnr)
    assert.truthy(text:find("Jupyter configuration", 1, true))
    assert.truthy(text:find("Connection:", 1, true))
    assert.truthy(text:find("Kernel:", 1, true))
    -- the CURRENT connection's facts: kind + where the spec came from
    assert.truthy(text:find("remote", 1, true))
    assert.truthy(text:find("json", 1, true))

    local inputs = inputs_of(handle)
    assert.is_not_nil(inputs["lab"])
    assert.is_not_nil(inputs["python3"])
    handle.close()
  end)

  it("picking a connection fires on_connection and refreshes the facts", function()
    local handle, calls = open_window()
    local input = inputs_of(handle)["lab"]
    vim.api.nvim_set_current_win(input.win)
    assert.is_true(wait_for(function()
      return popup_open(handle)
    end))
    press("<C-p>") -- lab (2nd option) → local (1st)
    press("<CR>")
    assert.is_true(wait_for(function()
      return #calls.connection == 1
    end))
    assert.same({ "local" }, calls.connection)
    -- the facts now describe the pick, default marker included
    assert.is_true(wait_for(function()
      local text = buffer_text(handle.bufnr)
      return text:find("builtin", 1, true) ~= nil and text:find("default", 1, true) ~= nil
    end))
    handle.close()
  end)

  it("the kernel dropdown is free text: an unlisted kernel commits on blur", function()
    local handle, calls = open_window()
    local input = inputs_of(handle)["python3"]
    vim.api.nvim_set_current_win(input.win)
    press("ccjulia-1.10")
    -- let the change propagate (the popup filters to no match) before blurring
    assert.is_true(wait_for(function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.w[win].fibrous_anchor == handle.winid and vim.api.nvim_win_get_config(win).focusable == false then
          if buffer_text(vim.api.nvim_win_get_buf(win)):find("(no match)", 1, true) then
            return true
          end
        end
      end
      return false
    end))
    vim.api.nvim_set_current_win(handle.winid) -- blur commits the typed text
    assert.is_true(wait_for(function()
      return #calls.kernel == 1
    end))
    assert.same({ "julia-1.10" }, calls.kernel)
    handle.close()
  end)

  it("set_kernels feeds the kernel dropdown's options", function()
    local handle = open_window()
    handle.set_kernels({
      { name = "julia-1.10", display_name = "Julia 1.10" },
      { name = "python3", display_name = "Python 3 (ipykernel)" },
    })
    local input = inputs_of(handle)["python3"]
    vim.api.nvim_set_current_win(input.win)
    assert.is_true(wait_for(function()
      return popup_open(handle)
    end))
    -- both kernelspec names are offered
    local listed = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.w[win].fibrous_anchor == handle.winid and vim.api.nvim_win_get_config(win).focusable == false then
        local lines = buffer_text(vim.api.nvim_win_get_buf(win))
        listed = lines:find("julia-1.10", 1, true) ~= nil and lines:find("python3", 1, true) ~= nil
      end
    end
    assert.is_true(listed)
    handle.close()
  end)

  it("without on_kernel there is no kernel field", function()
    local handle = open_window({ on_kernel = false, kernel = false })
    assert.is_nil(buffer_text(handle.bufnr):find("Kernel:", 1, true))
    assert.is_nil(inputs_of(handle)["python3"])
    handle.close()
  end)

  it("new connection reaches on_new; q closes", function()
    local handle, calls = open_window()
    local row, col = locate(handle.bufnr, "new connection")
    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { row, col })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
    press("<CR>")
    assert.equal(1, calls.new)

    press("q")
    assert.is_false(handle.is_open())
    assert.is_false(vim.api.nvim_win_is_valid(handle.winid))
  end)
end)
