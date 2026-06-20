-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

local cfg = require('mlir-inc-previewer.config')

local M = {}

-- Strip an inline `// ...` comment from a line.
local function strip_inline_comment(text)
  local without = text:gsub('//.*$', '')
  return vim.trim(without)
end

-- Is the line an `#include "...inc"` / `#include <...inc>` directive?
function M.is_inc_include_line(text)
  if not text or not text:find('#', 1, true) then
    return false
  end
  local body = strip_inline_comment(text)
  local path = body:match('^#include%s+["<](.-)[">]')
  if not path then
    return false
  end
  return path:lower():find('%.inc') ~= nil
end

-- Is the line a previously commented-out .inc include produced by this plugin?
function M.is_commented_inc_include_line(text)
  if not text then
    return false
  end
  if text:sub(1, #cfg.BEGIN_COMMENT_LINE) ~= cfg.BEGIN_COMMENT_LINE then
    return false
  end
  if text:sub(-#cfg.END_COMMENT_LINE) ~= cfg.END_COMMENT_LINE then
    return false
  end
  return M.is_inc_include_line(M.uncomment(text))
end

-- Comment out an original include line.
function M.comment(text)
  return cfg.BEGIN_COMMENT_LINE .. text .. cfg.END_COMMENT_LINE
end

-- Restore the original include line from a commented one (preserves indentation).
function M.uncomment(text)
  return text:sub(#cfg.BEGIN_COMMENT_LINE + 1, #text - #cfg.END_COMMENT_LINE)
end

-- True if a trimmed line is a clang-format directive of the given kind.
function M.is_clang_format(line, kind)
  return vim.trim(line):match('^// clang%-format ' .. kind) ~= nil
end

-- Extract the included path string from an include directive line.
function M.parse_include_path(text)
  local body = strip_inline_comment(text)
  return body:match('^#include%s+["<](.-)[">]')
end

-- `lines` is the 1-based array returned by nvim_buf_get_lines.
-- `cur1` is the 1-based current line. Returns the 1-based index or nil.
local function search_around(lines, cur1, predicate)
  if lines[cur1] and predicate(lines[cur1]) then
    return cur1
  end
  local range = (cfg.options and cfg.options.search_range) or cfg.SEARCH_INC_LINE_RANGE
  for off = 1, range do
    local up = cur1 - off
    if up >= 1 and predicate(lines[up]) then
      return up
    end
  end
  for off = 1, range do
    local down = cur1 + off
    if down <= #lines and predicate(lines[down]) then
      return down
    end
  end
  return nil
end

function M.find_inc_include_line(lines, cur1)
  return search_around(lines, cur1, M.is_inc_include_line)
end

function M.find_commented_inc_include_line(lines, cur1)
  local found = search_around(lines, cur1, M.is_commented_inc_include_line)
  if found then
    return found
  end

  -- If the cursor sits inside an expanded preview block, walk up to the BEGIN
  -- tag and then find the commented include just above it.
  for i = cur1, 1, -1 do
    local t = lines[i]
    if t == cfg.END_TAG then
      break
    end
    if t == cfg.BEGIN_TAG then
      for j = i, 1, -1 do
        local tj = lines[j]
        if tj == cfg.END_TAG then
          break
        end
        if M.is_commented_inc_include_line(tj) then
          return j
        end
      end
      break
    end
  end

  return nil
end

-- Returns a list of { begin1, end1 } (1-based, inclusive) preview block ranges.
function M.find_all_preview_blocks(lines)
  local blocks = {}
  local inside = false
  local start1 = -1
  for i = 1, #lines do
    local t = lines[i]
    if t:find(cfg.BEGIN_TAG, 1, true) then
      inside = true
      start1 = i
    elseif inside and t:find(cfg.END_TAG, 1, true) then
      table.insert(blocks, { start1, i })
      inside = false
    end
  end
  return blocks
end

function M.count_preview_blocks(lines)
  local n = 0
  for i = 1, #lines do
    if lines[i]:find(cfg.BEGIN_TAG, 1, true) then
      n = n + 1
    end
  end
  return n
end

return M
