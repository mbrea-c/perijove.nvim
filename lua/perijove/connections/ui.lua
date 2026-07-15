-- Interactive connection management over vim.ui: a picker to choose a
-- connection and a guided flow to create one. Pure glue over the registry —
-- UI-created connections live in memory for this session; persist them via
-- setup({ connections }) or a perijove.json instead.

local connections = require("perijove.connections")

local M = {}

-- Pick a connection from the merged registry+project view.
-- opts: { project? (from connections.project.load_for), current? (name) };
-- cb(spec | nil) — nil when the picker is cancelled.
function M.pick(opts, cb)
  opts = opts or {}
  local view = connections.view(opts.project)
  local default_name = view.default()
  vim.ui.select(view.list(), {
    prompt = "Jupyter connection",
    format_item = function(spec)
      local marks = {}
      if spec.name == opts.current then
        marks[#marks + 1] = "current"
      end
      if spec.name == default_name then
        marks[#marks + 1] = "default"
      end
      local suffix = #marks > 0 and ("  (" .. table.concat(marks, ", ") .. ")") or ""
      return ("%s  [%s, %s]%s"):format(spec.name, spec.kind, spec.source, suffix)
    end,
  }, cb)
end

-- Chain vim.ui.input prompts: prompts is a list of { key, prompt,
-- required? }. Cancelling (nil) aborts the whole flow; an empty answer
-- omits an optional field and aborts a required one.
local function ask(prompts, i, acc, done)
  local p = prompts[i]
  if not p then
    done(acc)
    return
  end
  vim.ui.input({ prompt = p.prompt }, function(answer)
    if answer == nil or (p.required and answer == "") then
      return -- cancelled / required field left blank: abort, register nothing
    end
    if answer ~= "" then
      acc[p.key] = answer
    end
    ask(prompts, i + 1, acc, done)
  end)
end

local KIND_LABELS = {
  remote = "remote   - a Jupyter server that is already running (url + token)",
  command = "command  - spawn a tunnel command that prints a JSON handshake line",
  ["local"] = "local    - spawn jupyter-server on this machine",
}

-- The per-kind field prompts (name always comes first). Command lines are
-- whitespace-split into argv: anything that needs shell quoting belongs in
-- perijove.json or setup(), where argv is a real list.
local KIND_PROMPTS = {
  remote = {
    { key = "url", prompt = "Server url: ", required = true },
    { key = "token", prompt = "Token (empty for none): " },
  },
  command = {
    { key = "command", prompt = "Tunnel command: ", required = true },
  },
  ["local"] = {
    { key = "root_dir", prompt = "Server root dir (empty for tmp): " },
  },
}

-- Guided creation: kind, name, then the kind's fields. Registers the spec
-- (source "api") and calls cb(spec). Any cancelled prompt aborts silently.
function M.create(cb)
  cb = cb or function() end
  vim.ui.select({ "remote", "command", "local" }, {
    prompt = "Connection kind",
    format_item = function(kind)
      return KIND_LABELS[kind]
    end,
  }, function(kind)
    if not kind then
      return
    end
    local prompts = { { key = "name", prompt = "Connection name: ", required = true } }
    vim.list_extend(prompts, KIND_PROMPTS[kind])
    ask(prompts, 1, { kind = kind }, function(fields)
      if fields.command then
        fields.argv = vim.split(fields.command, "%s+", { trimempty = true })
        fields.command = nil
      end
      cb(connections.add(fields))
    end)
  end)
end

return M
