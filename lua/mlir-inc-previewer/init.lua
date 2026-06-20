-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

local cfg = require('mlir-inc-previewer.config')
local preview = require('mlir-inc-previewer.preview')
local util = require('mlir-inc-previewer.util')

local M = {}

-- Convenient re-exports.
M.toggle = preview.toggle
M.expand_all = preview.expand_all
M.navigate_next = preview.navigate_next
M.clean_and_save = preview.clean_and_save

-- Clean all preview blocks in the current buffer and report the result.
function M.clean()
  local n = preview.clean_all()
  if n > 0 then
    vim.notify(string.format('[mlir-inc-previewer] Cleaned %d preview%s', n, n == 1 and '' or 's'))
  else
    vim.notify('[mlir-inc-previewer] No preview blocks found')
  end
end

-- Statusline component: returns e.g. "MLIR Inc: 2 previews" or "".
function M.statusline()
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return ''
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local n = util.count_preview_blocks(lines)
  if n > 0 then
    return string.format('MLIR Inc: %d preview%s', n, n == 1 and '' or 's')
  end
  return ''
end

-- Build autocmd file patterns ("*.cpp", "*.inc", ...) from the configured
-- extension list.
local function ext_patterns()
  local pats = {}
  for _, e in ipairs(cfg.options.extensions or {}) do
    table.insert(pats, '*.' .. e)
  end
  return pats
end

-- Does the buffer's filename end with one of the configured extensions?
local function buf_matches(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then
    return false
  end
  local ext = name:match('%.([%w%+]+)$')
  if not ext then
    return false
  end
  ext = ext:lower()
  for _, e in ipairs(cfg.options.extensions or {}) do
    if e:lower() == ext then
      return true
    end
  end
  return false
end

local function set_buffer_keymaps(bufnr)
  local k = cfg.options.keymaps or {}
  local function map(lhs, fn, desc)
    if lhs and lhs ~= '' then
      vim.keymap.set('n', lhs, fn, { buffer = bufnr, silent = true, desc = desc })
    end
  end
  map(k.toggle, function() preview.toggle(true) end, 'MLIR Inc: toggle preview (macro-aware)')
  map(k.toggle_full, function() preview.toggle(false) end, 'MLIR Inc: toggle preview (macro-unaware)')
  map(k.expand_all, function() preview.expand_all(true) end, 'MLIR Inc: expand all (macro-aware)')
  map(k.expand_all_full, function() preview.expand_all(false) end, 'MLIR Inc: expand all (macro-unaware)')
  map(k.clean, M.clean, 'MLIR Inc: clean all preview blocks')
  map(k.next, preview.navigate_next, 'MLIR Inc: navigate to next preview')
end

function M.setup(opts)
  cfg.options = vim.tbl_deep_extend('force', vim.deepcopy(cfg.defaults), opts or {})

  local group = vim.api.nvim_create_augroup('MlirIncPreviewer', { clear = true })
  local patterns = ext_patterns()

  -- Attach buffer-local keymaps for the configured file extensions.
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
    group = group,
    pattern = patterns,
    callback = function(args)
      set_buffer_keymaps(args.buf)
    end,
  })

  -- Also handle buffers that are already open at setup time.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and buf_matches(buf) then
      set_buffer_keymaps(buf)
    end
  end

  -- Never write expanded preview blocks to disk: clean before saving.
  if cfg.options.clean_on_save then
    vim.api.nvim_create_autocmd('BufWritePre', {
      group = group,
      pattern = patterns,
      callback = function(args)
        preview.clean_all(args.buf)
      end,
    })
  end
end

return M
