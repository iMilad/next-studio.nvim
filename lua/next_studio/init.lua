local M = { tabs = {}, busy = false }
local api = vim.api
local store = require("next_studio.store")
local layout = require("next_studio.layout")
local projects = require("next_studio.projects")
local screensaver = require("next_studio.screensaver")
local config = require("next_studio.config")
local controls = require("next_studio.controls")
local history = require("next_studio.history")

local function notify(message, level)
  vim.notify("NEXT: " .. message, level or vim.log.levels.INFO)
end

function M.current()
  return M.tabs[api.nvim_get_current_tabpage()]
end

function M.save(name, quiet, force)
  local state = M.current()
  if not state or M.busy or state.blocked then return false end
  local cover, zoom = screensaver.state, controls.zoomed
  local source = zoom and zoom.source or (cover and cover.source)
  if zoom and api.nvim_win_is_valid(zoom.win) and api.nvim_win_is_valid(zoom.source) then
    local view = api.nvim_win_call(zoom.win, vim.fn.winsaveview)
    api.nvim_win_call(zoom.source, function() vim.fn.winrestview(view) end)
  end
  local tree = source and api.nvim_win_is_valid(source)
    and api.nvim_win_call(source, function() return layout.capture(state.root) end) or layout.capture(state.root)
  local ok, revision = store.save(state.root, name or "Last", tree, state.revision, force)
  if ok then
    state.revision = revision
    state.snapshot = tree
    state.label = name or "Last"
    state.warned = false
    if not quiet then notify("Layout saved: " .. state.label) end
  elseif not quiet or not state.warned then
    state.warned = true
    notify(revision, vim.log.levels.WARN)
  end
  return ok
end

local function apply(state, tree)
  M.busy = true
  local ok = pcall(layout.apply, state.root, tree)
  M.busy = false
  if not ok then
    state.blocked = true
    notify("Could not restore the complete layout. Existing buffers remain open; use :StudioReset to arrange again.", vim.log.levels.ERROR)
    return false
  end
  state.blocked = false
  return true
end

function M.open(path)
  if not M.ready then M.setup() end
  controls.prepare()
  local root = store.canonical(path or vim.fn.getcwd())
  local stat = root and vim.uv.fs_stat(root)
  if not stat or stat.type ~= "directory" or store.sensitive(root) then
    notify("Choose an existing project folder", vim.log.levels.WARN)
    return false
  end
  for tab, state in pairs(M.tabs) do
    if api.nvim_tabpage_is_valid(tab) and state.root == root then
      api.nvim_set_current_tabpage(tab)
      return true
    end
  end
  local data, err = store.load(root)
  if not data then notify(err, vim.log.levels.ERROR); return false end
  local current = M.current()
  if current then M.save(nil, true) end
  local ft, bt = vim.bo.filetype, vim.bo.buftype
  local name = api.nvim_buf_get_name(0)
  -- A directory argument may have been claimed by nvim-tree before VimEnter.
  -- Retire only that untouched launch tab after the workspace restores safely.
  local args = M.launch and M.launch.args or {}
  local launch_dir = #args == 1 and args[1] or nil
  if launch_dir and launch_dir:sub(1, 1) ~= "/" and launch_dir:sub(1, 1) ~= "~" then
    launch_dir = M.launch.cwd .. "/" .. launch_dir
  end
  local browser_launch = not current and ft == "NvimTree" and not vim.bo.modified
    and #api.nvim_tabpage_list_wins(0) == 1 and launch_dir
    and vim.fn.isdirectory(launch_dir) == 1 and api.nvim_get_current_tabpage() or nil
  local reusable = not current and not vim.bo.modified and #api.nvim_tabpage_list_wins(0) == 1
    and (ft == "snacks_dashboard" or (name == "" and (bt == "" or bt == "nofile")) or vim.fn.isdirectory(name) == 1)
  if not reusable then vim.cmd.tabnew() end
  local tab = api.nvim_get_current_tabpage()
  local state = { root = root, revision = data.revision, label = data.selected }
  M.tabs[tab] = state
  vim.t.next_studio_root = root
  vim.t.name = projects.name(root)
  vim.cmd.tcd(vim.fn.fnameescape(root))
  -- Prevent a second, global Vimscript session from competing with project layouts.
  local ok, persistence = pcall(require, "persistence")
  if ok then persistence.stop() end
  local registered, why = store.add(root)
  if not registered then notify(why, vim.log.levels.WARN) end
  local tree = data.layouts[data.selected] or data.layouts.Last or layout.default()
  local restored = apply(state, tree)
  if restored and browser_launch and browser_launch ~= tab and api.nvim_tabpage_is_valid(browser_launch) then
    pcall(vim.cmd, "tabclose " .. api.nvim_tabpage_get_number(browser_launch))
  end
  if restored then vim.cmd.redrawtabline() end
  return restored
end

function M.prepare(label)
  controls.prepare()
  local state = M.current()
  if state and label then history.push(state.root, label) end
  return state
end

function M.zoom()
  if not M.current() and not M.open() then return end
  controls.zoom()
end

function M.resize()
  if not M.current() and not M.open() then return end
  controls.resize(M.current().root)
end

function M.undo(redo)
  local state = M.prepare()
  if state then return history.restore(state.root, redo) end
end

function M.rename(title)
  local state = M.prepare()
  if not state then return end
  local win = api.nvim_get_current_win()
  local function rename(value)
    if not value or M.current() ~= state or not api.nvim_win_is_valid(win) then return end
    if #value > 80 or value:find("[%z\1-\31\127]") then notify("Use a short pane title", vim.log.levels.WARN); return end
    M.prepare("rename pane")
    layout.title(win, value)
  end
  if title ~= nil then rename(title)
  else vim.ui.input({ prompt = "Pane name (empty resets): ", default = vim.w[win].next_studio_title or "" }, function(value)
    vim.schedule(function() rename(value) end)
  end) end
end

function M.exchange(target)
  local state = M.prepare()
  if not state then return end
  local source, tab = api.nvim_get_current_win(), api.nvim_get_current_tabpage()
  local function swap(win)
    if not win or M.current() ~= state or api.nvim_get_current_tabpage() ~= tab
      or not api.nvim_win_is_valid(source) or not api.nvim_win_is_valid(win) or win == source then return end
    M.prepare("swap panes")
    layout.exchange(state.root, source, win)
  end
  if target then swap(target); return end
  local windows = vim.tbl_filter(function(win) return win ~= source and api.nvim_win_get_config(win).relative == "" and not layout.external(win) end, api.nvim_tabpage_list_wins(0))
  vim.ui.select(windows, { prompt = "NEXT / Swap this pane with", format_item = function(win)
    local pos = api.nvim_win_get_position(win)
    return (vim.w[win].next_studio_title or layout.labels[layout.kind(win)]) .. " · row " .. (pos[1] + 1) .. ", column " .. (pos[2] + 1)
  end }, function(win) if win then vim.schedule(function() swap(win) end) end end)
end

function M.notes()
  M.toggle("notes")
end

function M.tasks()
  if not M.current() and not M.open() then return end
  require("next_studio.tasks").pick(M.current().root)
end

function M.pick()
  projects.pick(M.open)
end

function M.folder()
  vim.ui.input({ prompt = "Project folder: ", default = vim.fn.getcwd(), completion = "dir" }, function(path)
    if path and path ~= "" then M.open(path) end
  end)
end

function M.named()
  if not M.current() then M.open(); return end
  local state = M.current()
  vim.ui.input({ prompt = "Save layout as: ", default = "Coding" }, function(name)
    if name and name ~= "" and M.current() == state then M.save(name) end
  end)
end

function M.layouts()
  M.prepare()
  local state = M.current()
  if not state then M.open(); return end
  local data, err = store.load(state.root)
  if not data then notify(err, vim.log.levels.ERROR); return end
  local names = vim.tbl_keys(data.layouts)
  table.sort(names)
  if #names == 0 then notify("Arrange the panes, then Space p s to save"); return end
  require("next_studio.layout_picker").open(data.layouts, data.selected, function(name)
    if not name or M.current() ~= state then return end
    -- Keep current buffers and jobs in memory even when selecting another geometry.
    M.prepare("apply layout " .. name)
    if apply(state, data.layouts[name]) then
      state.revision, state.label = data.revision, name
      M.save("Last", true)
      state.label = name
    end
  end)
end

function M.reset()
  local state = M.current()
  if not state then M.open(); return end
  M.prepare("reset layout")
  M.save("Before reset", true)
  if apply(state, layout.default(layout.capture(state.root))) then state.label = "Studio" end
end

function M.toggle(kind)
  if not M.current() and not M.open() then return end
  M.prepare("toggle " .. layout.labels[kind])
  layout.toggle(M.current().root, kind)
end

function M.split(direction)
  if not M.current() and not M.open() then return end
  M.prepare("split " .. direction)
  layout.new(M.current().root, direction)
end

function M.close()
  local state = M.current()
  if not state then return end
  controls.prepare()
  if layout.external(0) or api.nvim_win_get_config(0).relative ~= "" then return end
  local windows = vim.tbl_filter(function(win) return api.nvim_win_get_config(win).relative == "" end, api.nvim_tabpage_list_wins(0))
  if #windows == 1 then notify("This is the last pane in this project"); return end
  history.push(state.root, "close pane")
  layout.capture(state.root)
  api.nvim_win_hide(0)
  layout.refresh()
end

function M.windows()
  if not M.current() then return end
  local tab = api.nvim_get_current_tabpage()
  local windows = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if api.nvim_win_get_config(win).relative == "" and not layout.external(win) then windows[#windows + 1] = win end
  end
  vim.ui.select(windows, { prompt = "NEXT / Go to pane", format_item = function(win)
    local pos = api.nvim_win_get_position(win)
    return (vim.w[win].next_studio_title or layout.labels[layout.kind(win)]) .. "  · row " .. (pos[1] + 1) .. ", column " .. (pos[2] + 1)
  end }, function(win)
    if win then vim.schedule(function()
      if api.nvim_get_current_tabpage() == tab and api.nvim_win_is_valid(win) then api.nvim_set_current_win(win) end
    end) end
  end)
end

function M.bind_terminal_keys(buf)
  if not config.options.keymaps then return end
  for key, mapping in pairs(M.keys or {}) do
    vim.keymap.set("t", config.options.key_prefix .. key, function()
      if key == "z" or key == "m" or key == "r" then mapping[1](); return end
      vim.cmd.stopinsert()
      vim.schedule(mapping[1])
    end, { buffer = buf, desc = mapping[2], silent = true })
  end
end

function M.pane(kind)
  if not M.current() and not M.open() then return end
  controls.prepare()
  local state, win, tab = M.current(), api.nvim_get_current_win(), api.nvim_get_current_tabpage()
  if api.nvim_win_get_config(win).relative ~= "" or layout.external(win) then notify("Select a workspace pane first"); return end
  local function change(value)
    if not api.nvim_win_is_valid(win) or M.current() ~= state or api.nvim_get_current_tabpage() ~= tab then return end
    value = value:lower()
    if not layout.labels[value] then notify("Pane types: editor, agent, terminal, notes", vim.log.levels.WARN); return end
    if layout.kind(win) == value then return end
    history.push(state.root, "change pane type")
    M.busy = true
    local ok = pcall(layout.change, state.root, win, value)
    M.busy = false
    if not ok then notify("Could not change this pane. Existing buffers remain available.", vim.log.levels.WARN) end
    layout.refresh()
  end
  if kind and kind ~= "" then change(kind); return end
  local current = layout.kind(win)
  local choices = {
    { kind = "editor", detail = "Edit a file" },
    { kind = "agent", detail = "Agent shell / launcher" },
    { kind = "terminal", detail = "Project shell" },
    { kind = "notes", detail = "Project notes and checklist" },
  }
  vim.ui.select(choices, { prompt = "NEXT / Change this pane: " .. layout.labels[current],
    format_item = function(item)
      return layout.labels[item.kind] .. (item.kind == current and " (current)" or "") .. "  —  " .. item.detail
    end }, function(item)
    -- Let the picker close before replacing the original pane's buffer.
    if item then vim.schedule(function() change(item.kind) end) end
  end)
end

function M.status()
  local state = M.current()
  return state and (projects.name(state.root) .. " / " .. (state.label or "Studio")) or "NEXT PAGE"
end

function M.help()
  local lines = {
    "NEXT / PROJECT STUDIO", "",
    "PROJECTS", "  Space p p    Choose / switch a project", "  Space p o    Open any folder",
    "  :StudioAdd   Bookmark the current folder", "  gt / gT      Next / previous project tab", "",
    "LAYOUTS", "  Space p s    Save this layout", "  Space p n    Save a named layout",
    "  Space p l    Choose a saved layout", "  Space p d    Reset to the Studio layout", "",
    "PANES", "  Lighter background = selected pane",
    "  Editor: blue · Terminal: green · Agent: purple · Notes: gold",
    "  Space p c    Change THIS pane: Editor / Agent / Terminal / Notes",
    "  :StudioPane agent   Change directly (also editor/terminal/notes)",
    "  Space p t    Toggle project terminal", "  Space p a    Toggle agent pane",
    "  Space p v    New EMPTY pane on the right (vertical)",
    "  Space p b    New EMPTY pane below (horizontal)",
    "  Space p x    Close this pane", "  Space p w    Choose a pane to focus",
    "  Ctrl-w v/s   Duplicate split right / below",
    "  Space p m    Zoom this pane / restore", "  Space p r    Resize with h/j/k/l; Enter keep, Esc cancel",
    "  Space p e    Exchange two panes", "  Space p u/U  Undo / redo layout changes",
    "  Space p N    Name this pane (shown in pickers)", "  Space p q    Project Notes",
    "  Space p k    Toggle a Notes checkbox", "  Space p j    Project commands / task output",
    "  Ctrl-w h/j/k/l   Move between panes", "  Ctrl-w c     Close this pane", "  Drag borders to resize", "",
    "Changing type keeps files and jobs available in this Neovim.",
    "Use your existing file manager and file-finder shortcuts.", "",
    "SCREENSAVER", "  F12          Cover Neovim / return (also while typing)",
    "  Space p z    Same ASCII screensaver", "  Other keys keep the workspace covered", "",
    "TERMINAL", "  i            Enter terminal input", "  Esc Esc      Leave terminal input",
    "  Ctrl-h/j/k/l Move directly to another pane", "",
    "Layouts save on project switch and normal exit.",
    "Open project tabs keep their buffers and terminal jobs alive.",
    "After a full restart, shells start fresh in the project folder.",
    "Agent panes wait for you to start or resume your chosen CLI.",
    "Layouts save roles, titles, file paths, cursor lines and geometry.",
    "Notes save separately; task commands do not restart from a layout.",
    "Unsaved text stays in memory; save your files before quitting.",
    "If another Neovim changed a layout, :StudioSave! opts into replacing it.",
    "", "Press q or Esc to close this guide.",
  }
  for i, line in ipairs(lines) do lines[i] = line:gsub("Space p ", function() return config.hint("") end) end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = math.min(76, vim.o.columns - 6)
  local height = math.min(#lines, vim.o.lines - 6)
  local win = api.nvim_open_win(buf, true, { relative = "editor", width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1, col = math.floor((vim.o.columns - width) / 2),
    style = "minimal", border = "single", title = " NEXT / QUICK GUIDE ", title_pos = "center" })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function() if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end end,
      { buffer = buf, silent = true })
  end
end

function M.startup()
  local launch = M.launch or { args = vim.fn.argv(), cwd = vim.fn.getcwd() }
  if not config.options.auto_open or vim.g.next_studio_no_startup or #api.nvim_list_uis() == 0 or #launch.args > 1 or vim.bo.modified then return end
  local arg = #launch.args == 1 and launch.args[1] or nil
  if arg and arg:sub(1, 1) ~= "/" and arg:sub(1, 1) ~= "~" then arg = launch.cwd .. "/" .. arg end
  if arg and vim.fn.isdirectory(arg) == 0 then return end
  local root = store.canonical(arg or launch.cwd)
  if not root then return end
  local containers = { store.canonical(vim.fn.expand("~")), store.canonical(vim.fn.expand("~/workspace")) }
  if not arg and vim.tbl_contains(containers, root) then return end
  M.open(root)
end

function M.setup(opts)
  if M.ready then return end
  assert(vim.fn.has("nvim-0.12") == 1, "NEXT Studio requires Neovim 0.12 or newer")
  config.setup(opts)
  M.options = config.options
  M.launch = { args = vim.fn.argv(), cwd = vim.fn.getcwd() }
  vim.o.hidden = true
  vim.o.mouse = "a"
  -- The preferred size cannot be below the configured hard minimum.
  -- LazyVim sets winminwidth=5; preserve it instead of assuming Neovim defaults.
  vim.o.winheight = math.max(1, vim.o.winminheight)
  vim.o.winwidth = math.max(1, vim.o.winminwidth)
  vim.o.equalalways = false
  screensaver.setup()
  controls.setup()
  require("next_studio.notes").setup()
  local commands = {
    Studio = function() M.open() end,
    StudioProjects = M.pick, StudioOpen = function(opts) if opts.args == "" then M.folder() else M.open(opts.args) end end,
    StudioAdd = function(opts)
      local root = store.canonical(opts.args ~= "" and opts.args or vim.fn.getcwd())
      if not root or store.sensitive(root) or vim.fn.isdirectory(root) == 0 then notify("Choose a project folder", vim.log.levels.WARN); return end
      local ok, err = store.add(root)
      notify(ok and "Project added" or err, ok and vim.log.levels.INFO or vim.log.levels.WARN)
    end,
    StudioSave = function(opts) if not M.current() then M.open() end; M.save(opts.args ~= "" and opts.args or nil, false, opts.bang) end,
    StudioLayouts = M.layouts, StudioReset = M.reset,
    StudioTerminal = function() M.toggle("terminal") end, StudioAgent = function() M.toggle("agent") end,
    StudioPane = function(opts) M.pane(opts.args) end,
    StudioVertical = function() M.split("vertical") end, StudioHorizontal = function() M.split("horizontal") end,
    StudioClose = M.close, StudioWindows = M.windows,
    StudioHelp = M.help, StudioScreensaver = screensaver.toggle,
    StudioZoom = M.zoom, StudioResize = M.resize, StudioSwap = function() M.exchange() end,
    StudioUndo = function() M.undo() end, StudioRedo = function() M.undo(true) end,
    StudioRename = function(opts) M.rename(opts.args ~= "" and opts.args or nil) end,
    StudioNotes = M.notes, StudioCheck = function() require("next_studio.notes").check() end, StudioTasks = M.tasks,
  }
  for name, callback in pairs(commands) do
    local complete = (name == "StudioOpen" or name == "StudioAdd") and "dir" or nil
    if name == "StudioPane" then
      complete = function(lead)
        return vim.tbl_filter(function(value) return value:sub(1, #lead) == lead end, { "editor", "agent", "terminal", "notes" })
      end
    end
    api.nvim_create_user_command(name, callback, { nargs = "?", bang = true,
      complete = complete })
  end
  M.keys = {
    p = { M.pick, "Projects" }, o = { M.folder, "Open project folder" }, s = { M.save, "Save layout" },
    n = { M.named, "Save named layout" }, l = { M.layouts, "Choose layout" }, d = { M.reset, "Default Studio layout" },
    c = { M.pane, "Change this pane's type" },
    v = { function() M.split("vertical") end, "New empty pane (right)" },
    b = { function() M.split("horizontal") end, "New empty pane (below)" },
    x = { M.close, "Close this pane" }, w = { M.windows, "Go to pane" },
    z = { screensaver.toggle, "ASCII screensaver / return" },
    m = { M.zoom, "Zoom pane / restore" }, r = { M.resize, "Resize panes" }, e = { function() M.exchange() end, "Swap panes" },
    u = { function() M.undo() end, "Undo layout change" }, U = { function() M.undo(true) end, "Redo layout change" },
    N = { function() M.rename() end, "Name this pane" }, q = { M.notes, "Project Notes" },
    k = { function() require("next_studio.notes").check() end, "Toggle Notes checkbox" }, j = { M.tasks, "Project commands" },
    t = { function() M.toggle("terminal") end, "Project terminal" },
    a = { function() M.toggle("agent") end, "Agent pane" }, h = { M.help, "Studio quick guide" },
  }
  if not config.options.screensaver.enabled then M.keys.z = nil end
  if config.options.keymaps then
    for key, mapping in pairs(M.keys) do vim.keymap.set("n", config.options.key_prefix .. key, mapping[1], { desc = mapping[2] }) end
    for _, direction in ipairs({ "h", "j", "k", "l" }) do
      if vim.fn.maparg("<C-" .. direction .. ">", "n") == "" then
        vim.keymap.set("n", "<C-" .. direction .. ">", "<C-w>" .. direction, { desc = "Move to pane" })
      end
    end
  end
  local group = api.nvim_create_augroup("NextProjectStudio", { clear = true })
  local function highlights()
    api.nvim_set_hl(0, "NextStudioPanel", { fg = "#58e6ff", bold = true })
    api.nvim_set_hl(0, "NextStudioAgent", { fg = "#ff70c6", bold = true })
    api.nvim_set_hl(0, "NextStudioActive", { fg = "#0b1020", bg = "#58e6ff", bold = true })
    layout.highlights()
  end
  highlights()
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = function()
    highlights()
    vim.schedule(function() if M.current() then layout.refresh() end end)
  end })
  api.nvim_create_autocmd("TabLeave", { group = group, callback = function()
    local state = M.current()
    if state and not state.blocked then M.save(nil, true) end
  end })
  api.nvim_create_autocmd("TabEnter", { group = group, callback = function()
    local state = M.current()
    if state and not M.busy then
      vim.schedule(function()
        if M.current() ~= state then return end
        vim.cmd.tcd(vim.fn.fnameescape(state.root))
        layout.refresh()
      end)
    end
  end })
  api.nvim_create_autocmd("TabClosed", { group = group, callback = function()
    for tab in pairs(M.tabs) do if not api.nvim_tabpage_is_valid(tab) then M.tabs[tab] = nil end end
    for tab in pairs(history.tabs) do if not api.nvim_tabpage_is_valid(tab) then history.tabs[tab] = nil end end
  end })
  api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function()
    local state = M.current()
    if state and not state.blocked then M.save(nil, true) end
  end })
  api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "WinResized", "FileType" }, { group = group, callback = function()
    if M.current() and not M.busy then layout.refresh() end
  end })
  api.nvim_create_autocmd("WinClosed", { group = group, callback = function()
    vim.schedule(function() if M.current() and not M.busy then layout.refresh() end end)
  end })
  if not vim.g.next_studio_no_startup then
    if vim.v.vim_did_enter == 1 then vim.schedule(M.startup)
    else api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = function() vim.schedule(M.startup) end }) end
  end
  M.ready = true
end

return M
