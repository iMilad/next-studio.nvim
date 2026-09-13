local M = {}
local api = vim.api
local layout = require("next_studio.layout")

local function size()
  return { relative = "editor", row = vim.o.showtabline == 2 and 1 or 0, col = 0,
    width = vim.o.columns, height = math.max(1, vim.o.lines - vim.o.cmdheight - 2) }
end

function M.unzoom(resume)
  local state = M.zoomed
  if not state then return end
  M.zoomed = nil
  local buf = api.nvim_win_is_valid(state.win) and api.nvim_win_get_buf(state.win) or nil
  local view = buf and api.nvim_win_call(state.win, vim.fn.winsaveview) or nil
  vim.cmd.stopinsert()
  if api.nvim_win_is_valid(state.win) then api.nvim_win_close(state.win, true) end
  if api.nvim_win_is_valid(state.source) then
    api.nvim_set_current_win(state.source)
    if buf and api.nvim_buf_is_valid(buf) then api.nvim_win_set_buf(state.source, buf) end
    if view then vim.fn.winrestview(view) end
    if resume and state.mode:match("^[it]") then vim.cmd.startinsert() end
  end
  layout.refresh()
end

function M.zoom()
  if M.zoomed then M.unzoom(true); return end
  M.finish_resize()
  local source = api.nvim_get_current_win()
  if api.nvim_win_get_config(source).relative ~= "" then return end
  local state = { source = source, mode = api.nvim_get_mode().mode }
  local buf, view = api.nvim_get_current_buf(), vim.fn.winsaveview()
  local options = {}
  for _, option in ipairs({ "number", "relativenumber", "signcolumn", "cursorline", "wrap", "foldenable", "foldmethod", "foldcolumn", "list" }) do
    options[option] = vim.wo[source][option]
  end
  vim.cmd.stopinsert()
  state.win = api.nvim_open_win(buf, true, vim.tbl_extend("force", size(), { border = "none", zindex = 90, noautocmd = true }))
  M.zoomed = state
  vim.w[state.win].next_studio_zoom = true
  vim.w[state.win].next_studio_title = vim.w[source].next_studio_title
  for name, value in pairs(options) do vim.wo[state.win][name] = value end
  vim.fn.winrestview(view)
  layout.refresh()
  if state.mode:match("^[it]") then vim.cmd.startinsert() end
end

local function restore_maps(state)
  for key, previous in pairs(state.maps) do
    pcall(vim.keymap.del, "n", key, { buffer = state.buf })
    if previous and previous.buffer == 1 and api.nvim_buf_is_valid(state.buf) then
      api.nvim_buf_call(state.buf, function() vim.fn.mapset("n", false, previous) end)
    end
  end
end

function M.finish_resize(cancel)
  local state = M.resizing
  if not state then return end
  M.resizing = nil
  restore_maps(state)
  if api.nvim_win_is_valid(state.hint) then api.nvim_win_close(state.hint, true) end
  if api.nvim_buf_is_valid(state.hintbuf) then api.nvim_buf_delete(state.hintbuf, { force = true }) end
  if cancel and api.nvim_win_is_valid(state.win) then
    api.nvim_win_call(state.win, function() vim.cmd(state.restore) end)
  elseif state.changed then
    local history = require("next_studio.history")
    local tab = api.nvim_win_is_valid(state.win) and api.nvim_win_get_tabpage(state.win)
    if tab then
      history.tabs[tab] = history.tabs[tab] or { undo = {}, redo = {} }
      local h = history.tabs[tab]
      h.undo[#h.undo + 1] = { tree = state.before, label = "resize panes" }
      while #h.undo > require("next_studio.config").options.history_limit do table.remove(h.undo, 1) end
      h.redo = {}
    end
  end
  layout.refresh()
  if api.nvim_get_current_win() == state.win and state.mode:match("^[it]") then vim.cmd.startinsert() end
end

function M.resize(root)
  if M.resizing then M.finish_resize(); return end
  M.unzoom(false)
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_config(win).relative ~= "" then return end
  local state = { win = win, buf = api.nvim_get_current_buf(), mode = api.nvim_get_mode().mode,
    restore = vim.fn.winrestcmd(), before = layout.capture(root, true), maps = {} }
  vim.cmd.stopinsert()
  local hint = " RESIZE   h/l width   j/k height   = equalize   Enter keep   Esc cancel "
  state.hintbuf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(state.hintbuf, 0, -1, false, { hint })
  state.hint = api.nvim_open_win(state.hintbuf, false, { relative = "editor", row = vim.o.lines - vim.o.cmdheight - 2,
    col = 0, width = math.min(#hint, vim.o.columns), height = 1, style = "minimal", border = "none", zindex = 120, focusable = false })
  vim.wo[state.hint].winhighlight = "Normal:NextStudioActive,NormalFloat:NextStudioActive"
  M.resizing = state
  local function map(key, fn)
    state.maps[key] = vim.fn.maparg(key, "n", false, true)
    vim.keymap.set("n", key, fn, { buffer = state.buf, silent = true, nowait = true })
  end
  for key, command in pairs({ h = "vertical resize -2", l = "vertical resize +2", j = "resize +1", k = "resize -1",
    ["<Left>"] = "vertical resize -2", ["<Right>"] = "vertical resize +2", ["<Down>"] = "resize +1", ["<Up>"] = "resize -1", ["="] = "wincmd =" }) do
    map(key, function()
      if M.resizing ~= state or not api.nvim_win_is_valid(win) then return end
      local before = vim.fn.winrestcmd()
      api.nvim_win_call(win, function() pcall(vim.cmd, command) end)
      state.changed = state.changed or before ~= vim.fn.winrestcmd()
    end)
  end
  map("<CR>", function() M.finish_resize() end)
  map("<Esc>", function() M.finish_resize(true) end)
end

function M.prepare()
  M.finish_resize()
  M.unzoom(false)
end

function M.setup()
  local group = api.nvim_create_augroup("NextStudioControls", { clear = true })
  api.nvim_create_autocmd("VimResized", { group = group, callback = function()
    if M.zoomed and api.nvim_win_is_valid(M.zoomed.win) then api.nvim_win_set_config(M.zoomed.win, size()) end
    M.finish_resize()
  end })
  api.nvim_create_autocmd({ "TabLeave", "VimLeavePre" }, { group = group, callback = function() M.prepare() end })
  api.nvim_create_autocmd("WinEnter", { group = group, callback = function()
    local state = M.resizing
    if state and api.nvim_get_current_win() ~= state.win and not require("next_studio.screensaver").state then M.finish_resize() end
  end })
end

return M
