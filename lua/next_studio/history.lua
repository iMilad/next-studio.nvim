local M = { tabs = {} }
local api = vim.api
local layout = require("next_studio.layout")

local function stacks()
  local tab = api.nvim_get_current_tabpage()
  M.tabs[tab] = M.tabs[tab] or { undo = {}, redo = {} }
  return M.tabs[tab]
end

function M.push(root, label)
  local h = stacks()
  h.undo[#h.undo + 1] = { tree = layout.capture(root, true), label = label }
  while #h.undo > require("next_studio.config").options.history_limit do table.remove(h.undo, 1) end
  h.redo = {}
end

function M.restore(root, redo)
  local h = stacks()
  local from, to = redo and h.redo or h.undo, redo and h.undo or h.redo
  local entry = from[#from]
  if not entry then vim.notify("NEXT: No layout changes to " .. (redo and "redo" or "undo")); return false end
  local current = layout.capture(root, true)
  local studio = require("next_studio")
  studio.busy = true
  local ok = pcall(layout.apply, root, entry.tree)
  studio.busy = false
  if not ok then
    studio.busy = true
    pcall(layout.apply, root, current)
    studio.busy = false
    vim.notify("NEXT: Could not restore this arrangement; buffers are retained", vim.log.levels.WARN)
    return false
  end
  table.remove(from)
  to[#to + 1] = { tree = current, label = entry.label }
  vim.notify("NEXT: " .. (redo and "Redid " or "Undid ") .. entry.label)
  return true
end

return M
