-- Headless test suite for the Neovim plugin.
-- Run from the plugin root:
--   nvim --headless -u NONE -c "set noswapfile" -c "set rtp+=." \
--        -c "luafile scripts/nvim_smoketest.lua"

--------------------------------------------------------------------------------
-- Tiny test framework (collects all results, never aborts on first failure)
--------------------------------------------------------------------------------
local passed, failed = 0, 0
local failures = {}
local current = '<root>'

local function record(ok, msg)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    table.insert(failures, string.format('[%s] %s', current, msg))
  end
end

local function ok_(cond, msg)
  record(cond and true or false, msg)
end

local function eq(a, b, msg)
  record(a == b, string.format('%s (got %s, want %s)', msg, vim.inspect(a), vim.inspect(b)))
end

local function has(haystack, needle, msg)
  record(haystack:find(needle, 1, true) ~= nil, msg .. ' (missing: ' .. needle .. ')')
end

local function no(haystack, needle, msg)
  record(haystack:find(needle, 1, true) == nil, msg .. ' (unexpected: ' .. needle .. ')')
end

local function describe(name, fn)
  current = name
  local good, err = pcall(fn)
  if not good then
    failed = failed + 1
    table.insert(failures, string.format('[%s] threw error: %s', name, err))
  end
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------
vim.cmd('set noswapfile')

local ok_req, m = pcall(require, 'mlir-inc-previewer')
if not ok_req then
  io.stderr:write('FATAL: cannot require mlir-inc-previewer: ' .. tostring(m) .. '\n')
  vim.cmd('cquit 1')
end

local cfg = require('mlir-inc-previewer.config')
local util = require('mlir-inc-previewer.util')
local preview = require('mlir-inc-previewer.preview')
local MacroState = require('mlir-inc-previewer.macros')

-- With `-u NONE`, plugin/ scripts are not auto-sourced; load it so the user
-- commands get registered for the command-existence test below.
vim.cmd('runtime! plugin/mlir-inc-previewer.lua')

cfg.options.use_lsp = false -- force deterministic filesystem resolution

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')

local function write_inc(name, lines)
  local p = tmp .. '/' .. name
  vim.fn.writefile(lines, p)
  return p
end

-- Create a scratch buffer whose on-disk dir is `tmp`, so that relative include
-- resolution (`#include "X.inc"` -> tmp/X.inc) works.
local buf_seq = 0
local function make_buf(lines)
  buf_seq = buf_seq + 1
  vim.cmd('enew!')
  local b = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(b, tmp .. '/host_' .. buf_seq .. '.cpp')
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = 'cpp'
  return b
end

local function buf_lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

local function buf_str(b)
  return table.concat(buf_lines(b), '\n')
end

--------------------------------------------------------------------------------
-- 1. Include-line detection
--------------------------------------------------------------------------------
describe('detection: is_inc_include_line', function()
  ok_(util.is_inc_include_line('#include "a/b.inc"'), 'quotes')
  ok_(util.is_inc_include_line('   #include "x.inc"'), 'indented')
  ok_(util.is_inc_include_line('#include <dir/x.inc>'), 'angle brackets')
  ok_(util.is_inc_include_line('#include "x.inc" // trailing comment'), 'trailing comment')
  ok_(util.is_inc_include_line('#include "Foo.h.inc"'), 'h.inc suffix')
  ok_(util.is_inc_include_line('#include "Bar.INC"'), 'uppercase ext')
  ok_(not util.is_inc_include_line('#include "a/b.h"'), 'reject .h')
  ok_(not util.is_inc_include_line('#include "a/b.hpp"'), 'reject .hpp')
  ok_(not util.is_inc_include_line('int x = 0;'), 'reject plain code')
  ok_(not util.is_inc_include_line('// #include "x.inc"'), 'reject fully commented include')
  ok_(not util.is_inc_include_line(''), 'reject empty')
end)

describe('detection: commented include round-trip', function()
  local original = '    #include "mlir/Foo.inc"'
  local commented = util.comment(original)
  ok_(util.is_commented_inc_include_line(commented), 'detect commented include')
  eq(util.uncomment(commented), original, 'uncomment preserves indentation')
  ok_(not util.is_commented_inc_include_line('/// just a comment'), 'reject random /// line')
  ok_(not util.is_commented_inc_include_line(original), 'plain include is not "commented"')
end)

--------------------------------------------------------------------------------
-- 2. Macro state machine
--------------------------------------------------------------------------------
describe('macros: #ifdef / #ifndef / #endif', function()
  local ms = MacroState.new()
  ms:process_line('#define A')
  ms:process_line('#ifdef A')
  ok_(ms:is_active(), 'ifdef A active when A defined')
  ms:process_line('#endif')
  ms:process_line('#ifdef B')
  ok_(not ms:is_active(), 'ifdef B inactive when B undefined')
  ms:process_line('#endif')
  ms:process_line('#ifndef B')
  ok_(ms:is_active(), 'ifndef B active when B undefined')
  ms:process_line('#endif')
  ms:process_line('#ifndef A')
  ok_(not ms:is_active(), 'ifndef A inactive when A defined')
  ms:process_line('#endif')
  ok_(ms:is_active(), 'active after all blocks balanced')
end)

describe('macros: #if defined / #if !defined', function()
  local ms = MacroState.new()
  ms:process_line('#define X')
  ms:process_line('#if defined(X)')
  ok_(ms:is_active(), 'if defined(X) active')
  ms:process_line('#endif')
  ms:process_line('#if !defined(X)')
  ok_(not ms:is_active(), 'if !defined(X) inactive')
  ms:process_line('#endif')
end)

describe('macros: #else flips, #undef, nesting', function()
  local ms = MacroState.new()
  ms:process_line('#ifdef NOPE') -- inactive
  ok_(not ms:is_active(), 'before else inactive')
  ms:process_line('#else')
  ok_(ms:is_active(), 'after else active')
  ms:process_line('#endif')

  -- nesting: outer active, inner inactive
  ms:process_line('#define OUT')
  ms:process_line('#ifdef OUT')
  ms:process_line('#ifdef INNER')
  ok_(not ms:is_active(), 'nested inactive inner deactivates')
  ms:process_line('#endif')
  ok_(ms:is_active(), 'back to active outer')
  ms:process_line('#endif')

  -- undef removes a definition
  ms:process_line('#undef OUT')
  ms:process_line('#ifdef OUT')
  ok_(not ms:is_active(), 'undef makes ifdef inactive')
  ms:process_line('#endif')
end)

describe('macros: generic #if stays balanced', function()
  local ms = MacroState.new()
  ms:process_line('#if SOME_EXPR > 1')
  ok_(ms:is_active(), 'generic #if treated as active')
  ms:process_line('#endif')
  ok_(ms:is_active(), 'generic #if/#endif balanced')
end)

--------------------------------------------------------------------------------
-- 3. Expand (macro-aware vs macro-unaware)
--------------------------------------------------------------------------------
write_inc('Ops.cpp.inc', {
  '#ifdef GET_OP_LIST',
  'OpA, OpB',
  '#endif // GET_OP_LIST',
  '#ifdef GET_OP_CLASSES',
  'class Hidden {};',
  '#endif // GET_OP_CLASSES',
})

describe('expand: macro-aware filters inactive blocks', function()
  local b = make_buf({
    'void f() {',
    '#define GET_OP_LIST',
    '#include "Ops.cpp.inc"',
    '}',
  })
  ok_(preview.expand_at(b, 2, true), 'expand_at returns true')
  local s = buf_str(b)
  has(s, cfg.BEGIN_TAG, 'has begin tag')
  has(s, cfg.END_TAG, 'has end tag')
  has(s, 'OpA, OpB', 'keeps active content')
  no(s, 'class Hidden', 'drops inactive content')
  has(s, '/// MLIR Inc File:', 'has file header')
  eq(util.count_preview_blocks(buf_lines(b)), 1, 'exactly one block')
end)

describe('expand: macro-unaware keeps everything', function()
  local b = make_buf({
    'void f() {',
    '#define GET_OP_LIST',
    '#include "Ops.cpp.inc"',
    '}',
  })
  ok_(preview.expand_at(b, 2, false), 'expand_at returns true')
  local s = buf_str(b)
  has(s, 'OpA, OpB', 'keeps list content')
  has(s, 'class Hidden', 'keeps classes content too')
end)

describe('expand: unresolved include is a no-op', function()
  local b = make_buf({ '#include "definitely_missing_zzz.inc"' })
  local before = buf_str(b)
  ok_(not preview.expand_at(b, 0, true), 'returns false on unresolved')
  eq(buf_str(b), before, 'buffer unchanged on unresolved')
end)

--------------------------------------------------------------------------------
-- 4. Toggle (cursor positions) + collapse
--------------------------------------------------------------------------------
write_inc('Simple.inc', { 'line_one', 'line_two' })

describe('toggle: expand then collapse with cursor inside block', function()
  local b = make_buf({ 'before', '#include "Simple.inc"', 'after' })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  preview.toggle(true)
  eq(util.count_preview_blocks(buf_lines(b)), 1, 'expanded one block')
  -- move cursor into the expanded content and collapse
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  preview.toggle(true)
  local s = buf_str(b)
  eq(util.count_preview_blocks(buf_lines(b)), 0, 'collapsed')
  has(s, '#include "Simple.inc"', 'include restored')
  no(s, 'clang-format', 'clang-format lines removed')
  no(s, 'line_one', 'expanded content removed')
end)

describe('toggle: cursor within +/-3 lines of include still works', function()
  local b = make_buf({ '#include "Simple.inc"', 'a', 'b', 'c' })
  vim.api.nvim_win_set_cursor(0, { 4, 0 }) -- 3 lines below the include
  preview.toggle(false)
  eq(util.count_preview_blocks(buf_lines(b)), 1, 'expanded from nearby cursor')
end)

describe('toggle: collapse preserves include indentation', function()
  local b = make_buf({ 'void f() {', '    #include "Simple.inc"', '}' })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  preview.toggle(false)
  vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- on the commented include line
  preview.toggle(false)
  local lines = buf_lines(b)
  local found = false
  for _, l in ipairs(lines) do
    if l == '    #include "Simple.inc"' then found = true end
  end
  ok_(found, 'indentation preserved after collapse')
end)

--------------------------------------------------------------------------------
-- 5. expand_all
--------------------------------------------------------------------------------
describe('expand_all: multiple includes, leaves non-.inc alone', function()
  local b = make_buf({
    '#include "vector"',
    '#include "Simple.inc"',
    'int x;',
    '#include "Ops.cpp.inc"',
    '#include "other.h"',
  })
  preview.expand_all(false)
  local s = buf_str(b)
  eq(util.count_preview_blocks(buf_lines(b)), 2, 'expanded two .inc includes')
  has(s, '#include "vector"', 'left std include untouched')
  has(s, '#include "other.h"', 'left .h include untouched')
end)

describe('expand_all: does not recurse into preview blocks / unresolved skipped', function()
  local b = make_buf({
    '#include "Simple.inc"',
    '#include "missing_aaa.inc"',
    '#include "Simple.inc"',
  })
  preview.expand_all(true)
  -- two resolvable includes -> two blocks, the missing one stays as include
  eq(util.count_preview_blocks(buf_lines(b)), 2, 'two blocks from resolvable includes')
  has(buf_str(b), '#include "missing_aaa.inc"', 'unresolved include left in place')
end)

describe('expand_all: macro-aware carries context across includes', function()
  write_inc('ma.inc', { '#define CROSS', 'from_a' })
  write_inc('mb.inc', {
    '#ifdef CROSS', 'cross_visible', '#endif',
    '#ifdef NOPE', 'should_hide', '#endif',
  })
  local b = make_buf({
    '#include "ma.inc"',
    '#include "mb.inc"',
  })
  preview.expand_all(true)
  local s = buf_str(b)
  has(s, 'from_a', 'first include expanded')
  has(s, 'cross_visible', 'macro defined in earlier .inc affects later one')
  no(s, 'should_hide', 'undefined macro block still dropped')
  eq(util.count_preview_blocks(buf_lines(b)), 2, 'two blocks created')
end)

--------------------------------------------------------------------------------
-- 6. clean_all
--------------------------------------------------------------------------------
describe('clean_all: removes all blocks and restores includes', function()
  local b = make_buf({
    '#include "Simple.inc"',
    'mid',
    '#include "Ops.cpp.inc"',
  })
  preview.expand_all(false)
  eq(util.count_preview_blocks(buf_lines(b)), 2, 'precondition: two blocks')
  local removed = preview.clean_all(b)
  eq(removed, 2, 'clean_all reports two removed')
  local s = buf_str(b)
  eq(util.count_preview_blocks(buf_lines(b)), 0, 'no blocks left')
  has(s, '#include "Simple.inc"', 'first include restored')
  has(s, '#include "Ops.cpp.inc"', 'second include restored')
  no(s, 'clang-format', 'no clang-format leftovers')
  no(s, 'MLIR Inc File', 'no header leftovers')
end)

describe('clean_all: no-op when nothing to clean', function()
  local b = make_buf({ 'int main() { return 0; }' })
  eq(preview.clean_all(b), 0, 'returns 0 when clean')
end)

--------------------------------------------------------------------------------
-- 7. navigate_next
--------------------------------------------------------------------------------
describe('navigate_next: jumps and wraps', function()
  local b = make_buf({ '#include "Simple.inc"', 'x', '#include "Ops.cpp.inc"' })
  preview.expand_all(false)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  preview.navigate_next()
  local first = vim.api.nvim_win_get_cursor(0)[1]
  ok_(first > 1, 'jumped to first block')
  preview.navigate_next()
  local second = vim.api.nvim_win_get_cursor(0)[1]
  ok_(second > first, 'jumped to second block')
  preview.navigate_next()
  local wrapped = vim.api.nvim_win_get_cursor(0)[1]
  eq(wrapped, first, 'wrapped back to first block')
end)

--------------------------------------------------------------------------------
-- 8. statusline
--------------------------------------------------------------------------------
describe('statusline reflects block count', function()
  local b = make_buf({ '#include "Simple.inc"' })
  eq(m.statusline(), '', 'empty when clean')
  preview.expand_all(false)
  has(m.statusline(), 'MLIR Inc: 1 preview', 'shows singular count')
end)

--------------------------------------------------------------------------------
-- 9. user commands registered (plugin/ loaded via rtp)
--------------------------------------------------------------------------------
describe('user commands exist', function()
  for _, c in ipairs({
    'MlirIncToggle', 'MlirIncToggleFull', 'MlirIncExpandAll',
    'MlirIncExpandAllFull', 'MlirIncClean', 'MlirIncCleanAndSave', 'MlirIncNext', 'MlirIncHelp',
  }) do
    eq(vim.fn.exists(':' .. c), 2, c .. ' is defined')
  end
end)

--------------------------------------------------------------------------------
-- 10. clean-on-save: expanded blocks are never written to disk
--------------------------------------------------------------------------------
describe('clean_on_save autocmd strips blocks before :write', function()
  m.setup({ clean_on_save = true })
  local path = tmp .. '/save_target.cpp'
  vim.fn.writefile({ '#include "Simple.inc"' }, path)
  vim.cmd('edit ' .. path)
  vim.bo.filetype = 'cpp'
  preview.expand_all(false)
  ok_(util.count_preview_blocks(buf_lines(0)) == 1, 'precondition: expanded in buffer')
  vim.cmd('silent write')
  local on_disk = table.concat(vim.fn.readfile(path), '\n')
  no(on_disk, cfg.BEGIN_TAG, 'no begin tag on disk')
  no(on_disk, 'line_one', 'no expanded content on disk')
  has(on_disk, '#include "Simple.inc"', 'include restored on disk')
end)

describe('clean_and_save cleans buffer and writes', function()
  local path = tmp .. '/cas_target.cpp'
  vim.fn.writefile({ '#include "Simple.inc"' }, path)
  vim.cmd('edit ' .. path)
  vim.bo.filetype = 'cpp'
  preview.expand_at(0, 0, false)
  preview.clean_and_save()
  eq(util.count_preview_blocks(buf_lines(0)), 0, 'buffer cleaned')
  local on_disk = table.concat(vim.fn.readfile(path), '\n')
  no(on_disk, cfg.BEGIN_TAG, 'disk has no preview block')
end)

describe('extension-based attach: keymaps for the full extension family', function()
  local function has_keymap(bufnr, desc)
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
      if km.desc == desc then
        return true
      end
    end
    return false
  end
  for _, ext in ipairs({ 'inc', 'def', 'tcc', 'tpp', 'inl', 'ipp', 'hpp', 'cxx', 'cuh' }) do
    local p = tmp .. '/attach_test.' .. ext
    vim.fn.writefile({ 'int x;' }, p)
    vim.cmd('edit ' .. p)
    ok_(has_keymap(0, 'MLIR Inc: toggle preview (macro-aware)'), 'keymap attached for .' .. ext)
  end
end)

--------------------------------------------------------------------------------
-- Report
--------------------------------------------------------------------------------
print(string.format('\n==== %d passed, %d failed ====', passed, failed))
if failed > 0 then
  for _, f in ipairs(failures) do
    io.stderr:write('FAIL ' .. f .. '\n')
  end
  vim.cmd('cquit 1')
else
  print('ALL TESTS PASSED')
  vim.cmd('qall!')
end
