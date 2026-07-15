-- Resolution of the external tools the default transport shells out to.
--
-- The nix package substitutes the @curl@/@websocat@ placeholders below with
-- absolute store paths at build time (see flake.nix), so the packaged plugin
-- is closed over the exact binaries it was tested with — reproducible, no
-- PATH dependence. From a plain source checkout the placeholders survive
-- verbatim; we detect the leftover "@" and fall back to a PATH lookup. An
-- explicit override from setup({ tools = { ... } }) beats both.

local M = {}

local NIX = {
  curl = "@curl@/bin/curl",
  websocat = "@websocat@/bin/websocat",
}

local overrides = {}

-- Called from perijove.setup with opts.tools; replaces the whole override set
-- so tests (and repeated setup calls) stay order-independent.
function M.configure(tbl)
  overrides = tbl or {}
end

-- The command to run for `name`: override > substituted store path > PATH.
function M.path(name)
  if overrides[name] then
    return overrides[name]
  end
  local nix = NIX[name]
  if nix and not nix:find("@", 1, true) then
    return nix
  end
  return name
end

return M
