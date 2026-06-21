-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- Tracks preprocessor macro state (#define/#undef and conditional blocks) so we
-- can decide which lines of an .inc file are active for the current host file.
--
-- Matches real preprocessor behaviour: lines inside an inactive #if branch are
-- not processed at all (#define inside them does not leak out; nested #ifdef
-- cannot become active while an outer block is inactive).
local MacroState = {}
MacroState.__index = MacroState

function MacroState.new()
  return setmetatable({
    defined = {}, -- set of defined macro names
    -- stack entries: { name, type, active, parent_active }
    -- active:        this branch is currently taken
    -- parent_active: all enclosing branches were reachable (#else only flips
    --                when parent_active is true)
    stack = {},
  }, MacroState)
end

local function push_block(self, name, type, cond)
  local parent_active = self:is_active()
  table.insert(self.stack, {
    name = name,
    type = type,
    active = parent_active and cond,
    parent_active = parent_active,
  })
end

-- Feed a single line and update the macro state.
function MacroState:process_line(line)
  local trimmed = vim.trim(line)

  -- #ifdef
  local m = trimmed:match('^#ifdef%s+([%w_]+)')
  if m then
    push_block(self, m, 'ifdef', self.defined[m] ~= nil)
    return
  end

  -- #ifndef
  m = trimmed:match('^#ifndef%s+([%w_]+)')
  if m then
    push_block(self, m, 'ifndef', self.defined[m] == nil)
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
    push_block(self, m, 'if', self.defined[m] ~= nil)
    return
  end

  -- #if !defined(X)
  m = trimmed:match('^#if%s*!%s*defined%s*%(%s*([%w_]+)%s*%)')
  if m then
    push_block(self, m, 'if!', self.defined[m] == nil)
    return
  end

  -- Any other #if* form: keep the stack balanced; treat as active only when the
  -- parent chain is active (we cannot evaluate the expression).
  if trimmed:match('^#if') then
    push_block(self, '', 'if?', true)
    return
  end

  -- #else — flip only when this conditional was reachable (parent was active).
  if trimmed:match('^#else') then
    if #self.stack > 0 then
      local last = self.stack[#self.stack]
      if last.parent_active then
        last.active = not last.active
      end
    end
    return
  end

  -- #elif — deactivate current branch; a later #else may still flip.
  if trimmed:match('^#elif') then
    if #self.stack > 0 then
      local last = self.stack[#self.stack]
      if last.parent_active then
        last.active = false
      end
    end
    return
  end

  -- #define / #undef only take effect in active code (not inside skipped #if).
  if not self:is_active() then
    return
  end

  m = trimmed:match('^#define%s+([%w_]+)')
  if m then
    self.defined[m] = true
    return
  end

  m = trimmed:match('^#undef%s+([%w_]+)')
  if m then
    self.defined[m] = nil
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
