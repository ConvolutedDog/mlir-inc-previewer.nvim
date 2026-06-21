-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

local cfg = require('mlir-inc-previewer.config')
local util = require('mlir-inc-previewer.util')
local resolver = require('mlir-inc-previewer.resolver')
local MacroState = require('mlir-inc-previewer.macros')

local M = {}

local function notify(msg, level)
  vim.notify('[mlir-inc-previewer] ' .. msg, level or vim.log.levels.INFO)
end

local function get_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function set_lines(bufnr, lines)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

-- Filter .inc lines through a (running) macro state, keeping only active lines.
-- The state is advanced in place, so callers can reuse it across includes to
-- get correct sequential macro context. When `omit_marker` is enabled, each
-- contiguous run of omitted body lines gets one summary /// comment.
local function is_directive(trimmed)
  return trimmed:match('^#if') or trimmed:match('^#elif')
      or trimmed:match('^#else') or trimmed:match('^#endif')
end

local function omit_marker_line(count, context)
  local noun = count == 1 and 'line' or 'lines'
  return string.format('/// [MLIR_INC_PREVIEW: %d %s omitted — %s]', count, noun, context)
end

local function filter_with_state(ms, inc_lines)
  local show_markers = cfg.options.omit_marker
  local out = {}
  local omit_count = 0
  local omit_context = nil

  local function flush_omit()
    if omit_count > 0 then
      if show_markers then
        table.insert(out, omit_marker_line(omit_count, omit_context or 'inactive conditional block'))
      end
      omit_count = 0
      omit_context = nil
    end
  end

  for _, line in ipairs(inc_lines) do
    local trimmed = vim.trim(line)
    ms:process_line(trimmed)
    if is_directive(trimmed) then
      flush_omit()
      table.insert(out, line)
    elseif ms:is_active() then
      flush_omit()
      table.insert(out, line)
    else
      omit_count = omit_count + 1
      if not omit_context then
        omit_context = ms:inactive_context()
      end
    end
  end
  flush_omit()
  return out
end

-- Build the full preview block (commented include + tags + content) for a
-- single include line.
local function build_block(include_text, path, content)
  local block = {
    '// clang-format off',
    util.comment(include_text),
    '// clang-format on',
    cfg.BEGIN_TAG,
    '// clang-format off',
    '/// MLIR Inc File: ' .. path,
    '// clang-format on',
  }
  vim.list_extend(block, content)
  table.insert(block, cfg.END_TAG)
  return block
end

-- Read an .inc file's lines, or nil on failure.
local function read_inc(path)
  local ok, inc_lines = pcall(vim.fn.readfile, path)
  if not ok or type(inc_lines) ~= 'table' then
    return nil
  end
  return inc_lines
end

-- Expand the include at 0-based line `inc0`. Returns true on success.
function M.expand_at(bufnr, inc0, macro_aware)
  local lines = get_lines(bufnr)
  local inc1 = inc0 + 1
  local include_text = lines[inc1]
  if not include_text or not util.is_inc_include_line(include_text) then
    return false
  end

  local path = resolver.resolve(bufnr, inc0, include_text)
  if not path then
    notify('Cannot resolve .inc file for: ' .. vim.trim(include_text), vim.log.levels.WARN)
    return false
  end

  local inc_lines = read_inc(path)
  if not inc_lines then
    notify('Cannot read file: ' .. path, vim.log.levels.ERROR)
    return false
  end

  local content
  if macro_aware and cfg.REMOVE_UNRELATED_PREVIEW_BLOCKS then
    local ms = MacroState.new()
    -- Seed with every host line before the include (1-based 1..inc0).
    for i = 1, inc0 do
      ms:process_line(lines[i])
    end
    content = filter_with_state(ms, inc_lines)
  else
    content = inc_lines
  end

  -- Replace just the single include line: keeps everything else intact and
  -- avoids the stale-index editing bugs of the original implementation.
  vim.api.nvim_buf_set_lines(bufnr, inc0, inc0 + 1, false, build_block(include_text, path, content))
  return true
end

-- Collapse the preview block belonging to the commented include at 0-based
-- line `commented0`. Returns true on success.
function M.collapse_at(bufnr, commented0)
  local lines = get_lines(bufnr)
  local commented1 = commented0 + 1

  local begin1
  for i = commented1 + 1, #lines do
    if lines[i]:find(cfg.BEGIN_TAG, 1, true) then
      begin1 = i
      break
    end
  end
  if not begin1 then
    return false
  end

  local end1
  for i = begin1, #lines do
    if lines[i]:find(cfg.END_TAG, 1, true) then
      end1 = i
      break
    end
  end
  if not end1 then
    return false
  end

  local del = {}
  for i = begin1, end1 do
    del[i] = true
  end
  if commented1 - 1 >= 1 and util.is_clang_format(lines[commented1 - 1], 'off') then
    del[commented1 - 1] = true
  end
  if commented1 + 1 < begin1 and util.is_clang_format(lines[commented1 + 1], 'on') then
    del[commented1 + 1] = true
  end

  local out = {}
  for i = 1, #lines do
    if del[i] then
      -- removed
    elseif i == commented1 then
      table.insert(out, util.uncomment(lines[i]))
    else
      table.insert(out, lines[i])
    end
  end

  set_lines(bufnr, out)
  return true
end

-- Toggle (expand or collapse) the nearest .inc preview around the cursor.
function M.toggle(macro_aware)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = get_lines(bufnr)
  local cur1 = vim.api.nvim_win_get_cursor(0)[1]

  local commented1 = util.find_commented_inc_include_line(lines, cur1)
  if commented1 then
    if not M.collapse_at(bufnr, commented1 - 1) then
      notify('Found commented include line but failed to collapse', vim.log.levels.ERROR)
    end
    return
  end

  local inc1 = util.find_inc_include_line(lines, cur1)
  if inc1 then
    if M.expand_at(bufnr, inc1 - 1, macro_aware) then
      notify('Expanded preview')
    end
  else
    notify('No .inc include statement found near cursor', vim.log.levels.WARN)
  end
end

-- Expand every .inc include in the buffer.
--
-- Done in a single pass that builds the whole new buffer in memory and writes
-- it back exactly once. This avoids the O(n^2) re-reads, the per-include redraw,
-- and the per-include LSP `didChange` storm that made large files (10k+ lines)
-- very slow. Resolution results are cached per include path.
function M.expand_all(macro_aware)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = get_lines(bufnr)
  local use_macros = macro_aware and cfg.REMOVE_UNRELATED_PREVIEW_BLOCKS
  local ms = use_macros and MacroState.new() or nil
  local cache = {}
  local out = {}
  local inside = false
  local count = 0

  local function passthrough(line)
    if ms then
      ms:process_line(line)
    end
    table.insert(out, line)
  end

  for i = 1, #lines do
    local line = lines[i]
    if not inside and line:find(cfg.BEGIN_TAG, 1, true) then
      inside = true
      passthrough(line)
    elseif inside and line:find(cfg.END_TAG, 1, true) then
      inside = false
      passthrough(line)
    elseif not inside and util.is_inc_include_line(line) then
      local key = util.parse_include_path(line) or line
      local path = cache[key]
      if path == nil then
        path = resolver.resolve(bufnr, i - 1, line) or false
        cache[key] = path
      end

      local inc_lines = path and read_inc(path) or nil
      if inc_lines then
        local content = ms and filter_with_state(ms, inc_lines) or inc_lines
        vim.list_extend(out, build_block(line, path, content))
        count = count + 1
      else
        passthrough(line) -- unresolved/unreadable: leave the include as-is
      end
    else
      passthrough(line)
    end
  end

  if count > 0 then
    set_lines(bufnr, out)
  end
  notify(string.format('Expanded %d preview%s', count, count == 1 and '' or 's'))
end

-- Remove all preview blocks and restore the original include lines.
-- Returns the number of preview blocks removed.
function M.clean_all(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = get_lines(bufnr)

  local del = {}
  local replace = {}

  for i = 1, #lines do
    if util.is_commented_inc_include_line(lines[i]) then
      replace[i] = util.uncomment(lines[i])
      if i - 1 >= 1 and util.is_clang_format(lines[i - 1], 'off') then
        del[i - 1] = true
      end
      if i + 1 <= #lines and util.is_clang_format(lines[i + 1], 'on') then
        del[i + 1] = true
      end
    end
  end

  local blocks = util.find_all_preview_blocks(lines)
  for _, b in ipairs(blocks) do
    for i = b[1], b[2] do
      del[i] = true
    end
  end

  if next(del) == nil and next(replace) == nil then
    return 0
  end

  local out = {}
  for i = 1, #lines do
    if del[i] then
      -- removed
    elseif replace[i] then
      table.insert(out, replace[i])
    else
      table.insert(out, lines[i])
    end
  end

  set_lines(bufnr, out)
  return #blocks
end

-- Clean previews then write the file (expanded blocks are never persisted).
function M.clean_and_save()
  local bufnr = vim.api.nvim_get_current_buf()
  local n = M.clean_all(bufnr)
  vim.cmd('silent write')
  if n > 0 then
    notify(string.format('Cleaned %d preview%s and saved', n, n == 1 and '' or 's'))
  else
    notify('No preview blocks found, file saved')
  end
end

-- Jump to the next preview block (wraps around to the top).
function M.navigate_next()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = get_lines(bufnr)
  local cur1 = vim.api.nvim_win_get_cursor(0)[1]

  local target
  for i = cur1 + 1, #lines do
    if lines[i]:find(cfg.BEGIN_TAG, 1, true) then
      target = i
      break
    end
  end
  if not target then
    for i = 1, cur1 - 1 do
      if lines[i]:find(cfg.BEGIN_TAG, 1, true) then
        target = i
        break
      end
    end
  end

  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    notify(string.format('Jumped to preview (line %d)', target))
  else
    notify('No more preview blocks found')
  end
end

return M
