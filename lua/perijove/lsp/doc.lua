-- Pure bookkeeping for ONE notebook document under LSP 3.17 notebookDocument
-- synchronization (the protocol VSCode drives; core Neovim has none, so
-- perijove builds the payloads itself and the session manager owns the wire).
--
-- The document holds the ordered list of SYNCED cells (the session decides
-- which cells those are; today: code cells), the notebook version, and each
-- cell text document's version. Cell inputs are `{ id, text }`; every builder
-- either returns a ready-to-notify params table or nil for "nothing to say".
--
-- Cell URIs ride the notebook's path under the `vscode-notebook-cell` scheme
-- with the cell id as fragment — the shape servers with notebook support
-- (basedpyright, ruff) already know from VSCode.

local M = {}

local CODE = 2 -- NotebookCellKind.Code

function M.new(notebook_uri)
  return {
    uri = notebook_uri,
    version = 0,
    cells = {}, -- ordered cell ids, mirroring what the server holds
    cell_versions = {}, -- id -> text document version
  }
end

function M.uri_of(d, id)
  return d.uri:gsub("^%w[%w+.-]*:", "vscode-notebook-cell:") .. "#" .. id
end

local function notebook_cell(d, id)
  return { kind = CODE, document = M.uri_of(d, id) }
end

local function text_document_item(d, cell)
  return { uri = M.uri_of(d, cell.id), languageId = "python", version = 0, text = cell.text }
end

function M.open_params(d, cells)
  local nb_cells, docs = {}, {}
  d.cells, d.cell_versions = {}, {}
  for i, cell in ipairs(cells) do
    d.cells[i] = cell.id
    d.cell_versions[cell.id] = 0
    nb_cells[i] = notebook_cell(d, cell.id)
    docs[i] = text_document_item(d, cell)
  end
  return {
    notebookDocument = {
      uri = d.uri,
      notebookType = "jupyter-notebook",
      version = d.version,
      cells = nb_cells,
    },
    cellTextDocuments = docs,
  }
end

-- Reconcile the server's cell sequence with `cells`: one contiguous splice
-- (common prefix and suffix trimmed away), didOpen for ids entering the
-- document, didClose for ids leaving. A pure move is a splice of already-open
-- cells. Returns nil when the sequence is unchanged.
function M.change_structure(d, cells)
  local old, new = d.cells, {}
  for i, cell in ipairs(cells) do
    new[i] = cell.id
  end
  local prefix = 0
  while prefix < #old and prefix < #new and old[prefix + 1] == new[prefix + 1] do
    prefix = prefix + 1
  end
  local suffix = 0
  while suffix < #old - prefix and suffix < #new - prefix and old[#old - suffix] == new[#new - suffix] do
    suffix = suffix + 1
  end
  local delete_count = #old - prefix - suffix
  if delete_count == 0 and #new == #old then
    return nil
  end

  local old_set = {}
  for _, id in ipairs(old) do
    old_set[id] = true
  end
  local new_set = {}
  for _, id in ipairs(new) do
    new_set[id] = true
  end

  local spliced, did_open, did_close
  for i = prefix + 1, #new - suffix do
    spliced = spliced or {}
    spliced[#spliced + 1] = notebook_cell(d, new[i])
  end
  for _, cell in ipairs(cells) do
    if not old_set[cell.id] then
      did_open = did_open or {}
      did_open[#did_open + 1] = text_document_item(d, cell)
      d.cell_versions[cell.id] = 0
    end
  end
  for _, id in ipairs(old) do
    if not new_set[id] then
      did_close = did_close or {}
      did_close[#did_close + 1] = { uri = M.uri_of(d, id) }
      d.cell_versions[id] = nil
    end
  end

  d.cells = new
  d.version = d.version + 1
  return {
    notebookDocument = { uri = d.uri, version = d.version },
    change = {
      cells = {
        structure = {
          array = { start = prefix, deleteCount = delete_count, cells = spliced },
          didOpen = did_open,
          didClose = did_close,
        },
      },
    },
  }
end

-- Full-text replacement (a change event with no range); incremental edits are
-- a noted follow-up. Nil for a cell the document does not hold.
function M.change_text(d, id, text)
  local v = d.cell_versions[id]
  if not v then
    return nil
  end
  d.cell_versions[id] = v + 1
  d.version = d.version + 1
  return {
    notebookDocument = { uri = d.uri, version = d.version },
    change = {
      cells = {
        textContent = {
          { document = { uri = M.uri_of(d, id), version = v + 1 }, changes = { { text = text } } },
        },
      },
    },
  }
end

function M.save_params(d)
  return { notebookDocument = { uri = d.uri } }
end

function M.close_params(d)
  local docs = {}
  for i, id in ipairs(d.cells) do
    docs[i] = { uri = M.uri_of(d, id) }
  end
  return { notebookDocument = { uri = d.uri }, cellTextDocuments = docs }
end

return M
