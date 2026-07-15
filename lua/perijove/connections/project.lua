-- perijove.json: project-level connections, resolved UPWARD from the
-- notebook's directory (nearest file wins, like .editorconfig). Schema:
--
--   {
--     "connections": [ { "name": ..., "kind": "local"|"remote"|"command", ... } ],
--     "default": "name"
--   }
--
-- Only the declarative kinds are allowed here (JSON cannot carry lua
-- functions; register those via setup() or the lua API instead). Errors are
-- loud: a malformed file returns nil + err rather than being half-applied.

local connections = require("perijove.connections")

local M = {}

M.FILENAME = "perijove.json"

-- Load the nearest perijove.json above `path`. Returns nil when there is
-- none, nil+err when there is one but it is broken, or
-- { file, connections = { [name] = spec }, default? }.
function M.load_for(path)
  local found = vim.fs.find(M.FILENAME, {
    upward = true,
    path = vim.fs.dirname(vim.fs.normalize(path)),
  })[1]
  if not found then
    return nil
  end
  local text = table.concat(vim.fn.readfile(found), "\n")
  local ok, doc = pcall(vim.json.decode, text)
  if not ok or type(doc) ~= "table" then
    return nil, ("%s: not valid JSON: %s"):format(found, doc)
  end
  local proj = { file = found, connections = {}, default = doc.default }
  for _, spec in ipairs(doc.connections or {}) do
    if spec.kind == "lua" or spec.connect ~= nil then
      return nil, ("%s: the lua kind cannot live in JSON; use setup() or the API"):format(found)
    end
    local okv, err = pcall(connections.validate, spec)
    if not okv then
      return nil, ("%s: %s"):format(found, err)
    end
    if type(spec.name) ~= "string" or spec.name == "" then
      return nil, ("%s: every connection needs a `name`"):format(found)
    end
    spec.source = "json"
    proj.connections[spec.name] = spec
  end
  return proj
end

return M
