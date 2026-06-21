-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- Tracks preprocessor macro state (#define/#undef and conditional blocks) so we
-- can decide which lines of an .inc file are active for the current host file.
local MacroState = {}
MacroState.__index = MacroState

function MacroState.new()
  return setmetatable({
    defined = {}, -- set of defined macro names
    stack = {},   -- stack of { name, type, active }
  }, MacroState)
end

-- Feed a single line and update the macro state.
function MacroState:process_line(line)
  local trimmed = vim.trim(line)

  -- #define
  local m = trimmed:match('^#define%s+([%w_]+)')
  if m then
    self.defined[m] = true
    return
  end

  -- #undef
  m = trimmed:match('^#undef%s+([%w_]+)')
  if m then
    self.defined[m] = nil
    return
  end

  -- #ifdef
  m = trimmed:match('^#ifdef%s+([%w_]+)')
  if m then
    table.insert(self.stack, { name = m, type = 'ifdef', active = self.defined[m] ~= nil })
    return
  end

  -- #ifndef
  m = trimmed:match('^#ifndef%s+([%w_]+)')
  if m then
    table.insert(self.stack, { name = m, type = 'ifndef', active = self.defined[m] == nil })
    return
  end

  -- #endif
  if trimmed:match('^#endif') then
    if #self.stack > 0 then
      table.remove(self.stack)
    end
    return
  end

  -- #if defined(X)
  m = trimmed:match('^#if%s+defined%s*%(%s*([%w_]+)%s*%)')
  if m then
    table.insert(self.stack, { name = m, type = 'if', active = self.defined[m] ~= nil })
    return
  end

  -- #if !defined(X)
  m = trimmed:match('^#if%s*!%s*defined%s*%(%s*([%w_]+)%s*%)')
  if m then
    table.insert(self.stack, { name = m, type = 'if!', active = self.defined[m] == nil })
    return
  end

  -- Any other #if* form (e.g. `#if 1`, `#if defined X`) is treated as active so
  -- the conditional stack stays balanced with its matching #endif.
  if trimmed:match('^#if') then
    table.insert(self.stack, { name = '', type = 'if?', active = true })
    return
  end

  -- #else - flip the current block's status.
  if trimmed:match('^#else') then
    if #self.stack > 0 then
      local last = self.stack[#self.stack]
      last.active = not last.active
    end
    return
  end

  -- #elif - we cannot evaluate the expression, so deactivate the current branch.
  if trimmed:match('^#elif') then
    if #self.stack > 0 then
      self.stack[#self.stack].active = false
    end
    return
  end
end

-- Is the current line within an active conditional context?
function MacroState:is_active()
  for _, block in ipairs(self.stack) do
    if not block.active then
      return false
    end
  end
  return true
end

-- Human-readable label for the innermost inactive conditional block (for omit
-- markers in macro-aware preview).
function MacroState:inactive_context()
  for i = #self.stack, 1, -1 do
    local block = self.stack[i]
    if not block.active then
      if block.name ~= '' then
        return string.format('inactive #%s %s', block.type, block.name)
      end
      return string.format('inactive #%s', block.type)
    end
  end
  return 'inactive conditional block'
end

return MacroState
