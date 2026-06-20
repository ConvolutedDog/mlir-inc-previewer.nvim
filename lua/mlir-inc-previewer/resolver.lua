-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

local cfg = require('mlir-inc-previewer.config')
local util = require('mlir-inc-previewer.util')

local M = {}

local function readable(p)
  if p and p ~= '' and vim.fn.filereadable(p) == 1 then
    return p
  end
  return nil
end

local function get_clients(bufnr)
  if vim.lsp.get_clients then
    return vim.lsp.get_clients({ bufnr = bufnr })
  end
  return vim.lsp.get_active_clients({ bufnr = bufnr })
end

local function is_list(t)
  if vim.islist then
    return vim.islist(t)
  end
  return vim.tbl_islist(t)
end

local DEFINITION = 'textDocument/definition'

-- Does any attached client positively support the definition method? We check
-- this first so we never trigger Neovim's "method ... is not supported by any
-- of the servers" error message.
local function any_client_supports(clients, bufnr)
  for _, c in ipairs(clients) do
    local ok, sup = pcall(function()
      if c.supports_method then
        return c:supports_method(DEFINITION, { bufnr = bufnr })
      end
      return false
    end)
    if not ok then
      ok, sup = pcall(function()
        return c.supports_method(c, DEFINITION)
      end)
    end
    if ok and sup then
      return true
    end
  end
  return false
end

-- Ask the language server (clangd) where this include resolves to. Mirrors the
-- VS Code `executeDefinitionProvider` approach.
local function lsp_resolve(bufnr, line0)
  local clients = get_clients(bufnr)
  if not clients or #clients == 0 then
    return nil
  end
  if not any_client_supports(clients, bufnr) then
    return nil
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, line0, line0 + 1, false)[1] or ''
  local q = line:find('["<]')
  local char = q and q or 0 -- 0-based character: point inside the include path

  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = line0, character = char },
  }

  local responses = vim.lsp.buf_request_sync(bufnr, DEFINITION, params, 1000)
  if not responses then
    return nil
  end

  for _, resp in pairs(responses) do
    local result = resp.result
    if result then
      local items = is_list(result) and result or { result }
      for _, item in ipairs(items) do
        local uri = item.uri or item.targetUri
        if uri then
          local fname = vim.uri_to_fname(uri)
          if fname:lower():find('%.inc') then
            return fname
          end
        end
      end
    end
  end

  return nil
end

-- Best-effort resolution purely on the filesystem when no LSP answer is found.
local function fs_resolve(bufnr, inc_path)
  if not inc_path or inc_path == '' then
    return nil
  end

  local cur = vim.api.nvim_buf_get_name(bufnr)
  local dir = cur ~= '' and vim.fn.fnamemodify(cur, ':h') or vim.fn.getcwd()

  -- 1) Relative to the current file directory.
  local cand = readable(dir .. '/' .. inc_path)
  if cand then
    return cand
  end

  -- 2) Search upward from the current file using the include path.
  local found = vim.fn.findfile(inc_path, dir .. ';')
  if found ~= '' then
    local p = readable(vim.fn.fnamemodify(found, ':p'))
    if p then
      return p
    end
  end

  -- 3) Search using &path.
  found = vim.fn.findfile(inc_path, '.;')
  if found ~= '' then
    local p = readable(vim.fn.fnamemodify(found, ':p'))
    if p then
      return p
    end
  end

  -- 4) Last resort: bounded recursive search of the project tree by basename,
  -- preferring a result whose full path ends with the requested include path.
  if cfg.options.deep_search then
    local base = vim.fn.fnamemodify(inc_path, ':t')
    local matches = vim.fs.find(base, {
      path = vim.fn.getcwd(),
      type = 'file',
      limit = 25,
    })
    if matches and #matches > 0 then
      for _, r in ipairs(matches) do
        if r:sub(-#inc_path) == inc_path then
          return readable(r)
        end
      end
      return readable(matches[1])
    end
  end

  return nil
end

-- Resolve the on-disk path of the .inc file referenced by `include_text`.
function M.resolve(bufnr, line0, include_text)
  local inc_path = util.parse_include_path(include_text)

  if cfg.options.use_lsp then
    local ok, p = pcall(lsp_resolve, bufnr, line0)
    if ok and p then
      return p
    end
  end

  return fs_resolve(bufnr, inc_path)
end

return M
