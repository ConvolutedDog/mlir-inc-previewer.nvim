-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

if vim.g.loaded_mlir_inc_previewer then
  return
end
vim.g.loaded_mlir_inc_previewer = true

local function preview()
  return require('mlir-inc-previewer.preview')
end

local function api()
  return require('mlir-inc-previewer')
end

local cmd = vim.api.nvim_create_user_command

cmd('MlirIncToggle', function() preview().toggle(true) end,
  { desc = 'MLIR Inc: Expand/Collapse preview (macro-aware)' })

cmd('MlirIncToggleFull', function() preview().toggle(false) end,
  { desc = 'MLIR Inc: Expand/Collapse preview (macro-unaware)' })

cmd('MlirIncExpandAll', function() preview().expand_all(true) end,
  { desc = 'MLIR Inc: Expand all previews (macro-aware)' })

cmd('MlirIncExpandAllFull', function() preview().expand_all(false) end,
  { desc = 'MLIR Inc: Expand all previews (macro-unaware)' })

cmd('MlirIncClean', function() api().clean() end,
  { desc = 'MLIR Inc: Clean all preview blocks' })

cmd('MlirIncCleanAndSave', function() preview().clean_and_save() end,
  { desc = 'MLIR Inc: Clean all preview blocks and save' })

cmd('MlirIncNext', function() preview().navigate_next() end,
  { desc = 'MLIR Inc: Navigate to next preview block' })

cmd('MlirIncHelp', function()
  vim.cmd('help mlir-inc-previewer')
end, { desc = 'MLIR Inc: Open plugin help' })

cmd('MlirIncRestart', function() api().restart() end,
  { desc = 'MLIR Inc: Restart (clean all previews, refresh hooks)' })

-- Generate helptags for this plugin's doc/ on load. Lazy-loaded plugins are not
-- in &rtp until loaded, so :help mlir-inc-previewer fails until tags exist.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h')
local doc = root .. '/doc'
if vim.fn.isdirectory(doc) == 1 then
  vim.cmd('silent! helptags ' .. vim.fn.fnameescape(doc))
end
