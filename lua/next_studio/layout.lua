local M = { buffers = {}, panes = {}, appearance = {}, sequence = 0 }
local store = require("next_studio.store")
local api = vim.api
M.labels = { terminal = "TERMINAL", agent = "AGENT", editor = "EDITOR", notes = "PROJECT NOTES" }

function M.external(win)
  local buf = api.nvim_win_get_buf(win)
  local ft, bt = vim.bo[buf].filetype, vim.bo[buf].buftype
  return vim.tbl_contains({ "NvimTree", "neo-tree", "netrw", "oil" }, ft)
    or (bt ~= "" and bt ~= "terminal" and not vim.b[buf].next_studio_kind)
end

function M.kind(win)
  local buf = api.nvim_win_get_buf(win)
  if vim.b[buf].next_studio_kind == "agent" then return "agent" end
  if vim.b[buf].next_studio_kind == "notes" then return "notes" end
  return vim.bo[buf].buftype == "terminal" and "terminal" or "editor"
end

-- Restore each pane's editor options when returning from another role.
local option_names = { "number", "relativenumber", "list", "foldenable", "winfixwidth", "winfixheight",
  "spell", "signcolumn", "foldmethod", "foldcolumn", "cursorcolumn", "cursorline", "cursorlineopt",
  "colorcolumn", "wrap", "winhighlight", "statuscolumn" }
local function window_options(win, global)
  local options = {}
  for _, name in ipairs(option_names) do
    options[name] = api.nvim_get_option_value(name, global and { scope = "global" } or { win = win })
  end
  return options
end

local function pane(root, win)
  local state = M.panes[win]
  if not state or state.root ~= root then
    state = { root = root, roles = {}, defaults = window_options(win, M.kind(win) ~= "editor") }
    M.panes[win] = state
  end
  return state
end

local function restore_options(win, options)
  for name, value in pairs(options) do api.nvim_set_option_value(name, value, { win = win }) end
end

local function slot(buf)
  if not vim.b[buf].next_studio_slot then
    M.sequence = M.sequence + 1
    vim.b[buf].next_studio_slot = M.sequence
  end
  return vim.b[buf].next_studio_slot
end

local function remember(root, buf, id)
  id = id or slot(buf)
  M.sequence = math.max(M.sequence, id)
  vim.b[buf].next_studio_slot = id
  M.buffers[root] = M.buffers[root] or {}
  M.buffers[root][id] = buf
  return id
end

local function capture_leaf(root, win, memory)
  if M.external(win) then return nil end
  local buf = api.nvim_win_get_buf(win)
  local kind, bt = M.kind(win), vim.bo[buf].buftype
  local leaf = { kind = kind, width = api.nvim_win_get_width(win), height = api.nvim_win_get_height(win),
    slot = remember(root, buf), focused = win == api.nvim_get_current_win(), title = vim.w[win].next_studio_title }
  if memory then
    leaf._options = window_options(win)
    leaf._view = api.nvim_win_call(win, vim.fn.winsaveview)
    leaf._roles = vim.deepcopy(pane(root, win).roles)
  end
  if kind == "editor" and bt == "" then
    local name = api.nvim_buf_get_name(buf)
    local path = name ~= "" and store.canonical(name) or nil
    if path and path:sub(1, #root + 1) == root .. "/" and not store.sensitive(path) and not store.sensitive(name) then
      leaf.file = path:sub(#root + 2)
      leaf.line = api.nvim_win_get_cursor(win)[1]
    end
  end
  return leaf
end

function M.capture(root, memory)
  local function capture(node)
    if node[1] == "leaf" then return capture_leaf(root, node[2], memory) end
    local result = { kind = node[1], children = {}, width = 0, height = 0 }
    for _, child in ipairs(node[2]) do
      local value = capture(child)
      if value then
        result.children[#result.children + 1] = value
        if result.kind == "row" then
          result.width = result.width + value.width + 1
          result.height = math.max(result.height, value.height)
        else
          result.height = result.height + value.height + 1
          result.width = math.max(result.width, value.width)
        end
      end
    end
    if #result.children == 0 then return nil end
    if #result.children == 1 then return result.children[1] end
    if result.kind == "row" then result.width = result.width - 1 else result.height = result.height - 1 end
    return result
  end
  return capture(vim.fn.winlayout()) or { kind = "editor", width = vim.o.columns, height = math.max(1, vim.o.lines - 2), focused = true }
end

function M.default(previous)
  local editor = { kind = "editor", width = 80, height = 28, focused = true }
  local agent = { kind = "agent", width = 38, height = 28 }
  local terminal = { kind = "terminal", width = 119, height = 10 }
  local retained = {}
  local function collect(node)
    if node.children then for _, child in ipairs(node.children) do collect(child) end
    elseif not retained[node.kind] or node.focused then retained[node.kind] = node end
  end
  if previous then collect(previous) end
  for _, node in ipairs({ editor, agent, terminal }) do
    for _, key in ipairs({ "slot", "file", "line" }) do node[key] = retained[node.kind] and retained[node.kind][key] end
  end
  local upper = { kind = vim.o.columns >= 100 and "row" or "col", width = 119, height = 28, children = { editor, agent } }
  if upper.kind == "col" then editor.height = 20; agent.height = 8 end
  return { kind = "col", width = 119, height = 39, children = { upper, terminal } }
end

-- Role colors replace persistent title rows. The focused pane is lighter.
local palette = {
  editor = { "#142337", "#0c1523" }, terminal = { "#163329", "#0d201a" },
  agent = { "#342039", "#201525" }, notes = { "#36301c", "#221f13" },
}
local surfaces = { "Normal", "NormalNC", "EndOfBuffer", "SignColumn", "FoldColumn", "LineNr", "CursorLineNr", "CursorLine" }

function M.highlights()
  local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
  for kind, colors in pairs(palette) do
    for index, bg in ipairs(colors) do
      local prefix = "NextStudio" .. kind .. (index == 1 and "Active" or "Inactive")
      for _, surface in ipairs(surfaces) do
        local value = api.nvim_get_hl(0, { name = surface, link = false })
        if surface == "Normal" or surface == "NormalNC" then value = { fg = normal.fg or 0xc0caf5 } end
        value.bg = bg
        value.ctermbg = nil
        value.blend = nil
        api.nvim_set_hl(0, prefix .. surface, value)
      end
    end
  end
  api.nvim_set_hl(0, "NextStudioBorderActive", { fg = "#58e6ff", bold = true })
  api.nvim_set_hl(0, "NextStudioBorderInactive", { fg = "#283a55" })
end

local function appearance(win, kind, active)
  local previous = M.appearance[win] or {}
  local mappings = {}
  for _, mapping in ipairs(vim.split(vim.wo[win].winhighlight, ",", { trimempty = true })) do
    local from, to = mapping:match("^([^:]+):(.+)$")
    local owned = to and (to:match("^NextStudioBorder") or to:match("^NextStudioeditor")
      or to:match("^NextStudioterminal") or to:match("^NextStudioagent") or to:match("^NextStudionotes"))
    if from and not owned then mappings[from] = to end
  end
  -- Preserve third-party mappings underneath Studio's temporary role colors.
  for from, to in pairs(previous) do if not mappings[from] then mappings[from] = to end end
  M.appearance[win] = kind and vim.deepcopy(mappings) or nil
  if kind then
    local prefix = "NextStudio" .. kind .. (active and "Active" or "Inactive")
    for _, surface in ipairs(surfaces) do mappings[surface] = prefix .. surface end
    mappings.WinSeparator = active and "NextStudioBorderActive" or "NextStudioBorderInactive"
  end
  local values = {}
  for from, to in pairs(mappings) do values[#values + 1] = from .. ":" .. to end
  table.sort(values)
  vim.wo[win].winhighlight = table.concat(values, ",")
end

function M.decorate(win, kind)
  if not api.nvim_win_is_valid(win) then return end
  if M.external(win) or (api.nvim_win_get_config(win).relative ~= "" and not vim.w[win].next_studio_zoom) then
    appearance(win)
    return
  end
  kind = kind or M.kind(win)
  local active = win == api.nvim_get_current_win()
  vim.wo[win].winbar = ""
  appearance(win, kind, active)
  if kind ~= "editor" and vim.w[win].next_studio_decorated ~= kind then
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
  end
  vim.w[win].next_studio_decorated = kind
end

function M.refresh()
  for win in pairs(M.panes) do if not api.nvim_win_is_valid(win) then M.panes[win] = nil end end
  for win in pairs(M.appearance) do if not api.nvim_win_is_valid(win) then M.appearance[win] = nil end end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do M.decorate(win) end
end

local function terminal_keys(buf)
  local opts = { buffer = buf, silent = true }
  for _, key in ipairs({ "h", "j", "k", "l" }) do
    vim.keymap.set("t", "<C-" .. key .. ">", "<C-\\><C-n><C-w>" .. key, opts)
  end
  vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", opts)
end

function M.shell(buf, root, kind)
  local command = vim.g.next_studio_shell or require("next_studio.config").options.shell
  if not command then
    local shell = vim.o.shell
    local name = vim.fs.basename(shell)
    command = name == "zsh" and { shell, "-f" }
      or name == "bash" and { shell, "--noprofile", "--norc" }
      or name == "fish" and { shell, "--no-config" } or { shell }
  end
  vim.bo[buf].buftype = ""
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.bo[buf].modified = false
  local job = api.nvim_buf_call(buf, function()
    return vim.fn.jobstart(command, { term = true, cwd = root })
  end)
  vim.b[buf].next_studio_kind = kind
  vim.b[buf].next_studio_root = root
  terminal_keys(buf)
  require("next_studio").bind_terminal_keys(buf)
  if job <= 0 then vim.notify("NEXT: shell could not start", vim.log.levels.WARN) end
  return buf
end

local function placeholder(buf, lines, kind)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  for i, line in ipairs(lines) do lines[i] = line:gsub("Space p ", function() return require("next_studio.config").hint("") end) end
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "next-studio"
  vim.b[buf].next_studio_kind = kind
end

local function agent(buf, root)
  placeholder(buf, { "", "  NEXT / AGENT", "",
    "  i   Open agent shell", "", "  Run your chosen CLI:", "    claude   or   codex", "",
    "  Space p c   Pane type", "  Space p s   Save layout", "",
    "  Sessions stay live", "  between project tabs.", "",
    "  After a full restart,", "  start/resume the agent." }, "agent")
  for _, key in ipairs({ "i", "<CR>" }) do
    vim.keymap.set("n", key, function()
      -- Remove the launcher maps before this buffer becomes a terminal.
      pcall(vim.keymap.del, "n", "i", { buffer = buf })
      pcall(vim.keymap.del, "n", "<CR>", { buffer = buf })
      M.shell(buf, root, "agent")
      vim.cmd.startinsert()
    end, { buffer = buf, desc = "Start agent shell" })
  end
end

local function editor(buf)
  placeholder(buf, { "", "  NEXT / WORKSPACE", "", "  i           Start a new file", "  Space p p   Switch project", "  :edit path  Open a file",
    "  Space p s   Save this layout", "  Space p n   Save a named layout", "  Space p l   Choose a layout",
    "", "  Space p v   New empty pane on the right", "  Space p b   New empty pane below",
    "  Space p x   Close this pane",
    "  Ctrl-w h/j/k/l   Move between panes", "  Drag a border to resize", "",
    "  Space p c   Change this pane's type", "  Space p t   Toggle terminal", "  Space p a   Toggle agent pane", "  Space p h   Quick guide" }, "editor")
  vim.keymap.set("n", "i", function()
    api.nvim_win_set_buf(0, api.nvim_create_buf(true, false))
    vim.cmd.startinsert()
  end, { buffer = buf, desc = "Start a new file" })
end

local function cached(root, node)
  local buf = node.slot and (M.buffers[root] or {})[node.slot]
  if not buf or not api.nvim_buf_is_valid(buf) then return nil end
  if vim.bo[buf].buftype == "terminal" and not vim.b[buf].next_studio_task
    and vim.fn.jobwait({ vim.b[buf].terminal_job_id }, 0)[1] ~= -1 then return nil end
  return buf
end

local function fill(root, node, win, options)
  api.nvim_set_current_win(win)
  local state = pane(root, win)
  local buf = cached(root, node)
  if node.kind == "notes" and not buf then buf = require("next_studio.notes").buffer(root) end
  if not buf and node.kind == "editor" and node.file then
    local path = store.file(root, node.file)
    if path then
      buf = vim.fn.bufadd(path)
      vim.fn.bufload(buf)
    end
  end
  if not buf then
    buf = api.nvim_create_buf(node.kind == "editor", true)
    if node.kind == "terminal" then M.shell(buf, root, "terminal")
    elseif node.kind == "agent" then agent(buf, root)
    else editor(buf) end
  end
  remember(root, buf, node.slot)
  api.nvim_win_set_buf(win, buf)
  restore_options(win, options or node._options or state.defaults)
  vim.w[win].next_studio_title = node.title
  if node._roles then state.roles = vim.deepcopy(node._roles) end
  vim.w[win].next_studio_decorated = nil
  if node.kind == "editor" and node.line then
    pcall(api.nvim_win_set_cursor, win, { math.min(node.line, api.nvim_buf_line_count(buf)), 0 })
  end
  if node._view and vim.bo[buf].buftype ~= "terminal" then vim.fn.winrestview(node._view) end
  M.decorate(win, node.kind)
end

function M.apply(root, tree)
  assert(store.valid_tree(tree), "Invalid layout")
  tree = store.migrate(tree)
  local current = api.nvim_get_current_win()
  if api.nvim_win_get_config(current).relative ~= "" or M.external(current) then
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_config(win).relative == "" and not M.external(win) then api.nvim_set_current_win(win); break end
    end
  end
  -- :only hides buffers; it never deletes them or stops their terminal jobs.
  vim.cmd("silent only")
  local first = api.nvim_get_current_win()
  api.nvim_win_set_buf(first, api.nvim_create_buf(false, true))
  local leaves = {}
  local function build(node, win)
    if node.kind ~= "row" and node.kind ~= "col" then
      leaves[#leaves + 1] = { node = node, win = win }
      return
    end
    local windows = { win }
    for i = 2, #node.children do
      api.nvim_set_current_win(windows[i - 1])
      vim.cmd(node.kind == "row" and "belowright vsplit" or "belowright split")
      windows[i] = api.nvim_get_current_win()
    end
    local field = node.kind == "row" and "width" or "height"
    local getter = node.kind == "row" and api.nvim_win_get_width or api.nvim_win_get_height
    local setter = node.kind == "row" and api.nvim_win_set_width or api.nvim_win_set_height
    local total, weight = 0, 0
    for i, child in ipairs(node.children) do total = total + getter(windows[i]); weight = weight + child[field] end
    for i = 1, #windows - 1 do pcall(setter, windows[i], math.max(1, math.floor(total * node.children[i][field] / weight))) end
    for i, child in ipairs(node.children) do build(child, windows[i]) end
  end
  local equalalways = vim.o.equalalways
  vim.o.equalalways = false
  local ok, err = pcall(function()
    build(tree, first)
    for _, leaf in ipairs(leaves) do fill(root, leaf.node, leaf.win) end
    local focus
    for _, leaf in ipairs(leaves) do if leaf.node.focused then focus = leaf.win end end
    if not focus then
      for _, leaf in ipairs(leaves) do if leaf.node.kind == "editor" then focus = leaf.win; break end end
    end
    api.nvim_set_current_win(focus or first)
  end)
  vim.o.equalalways = equalalways
  if not ok then error(err) end
  M.refresh()
end

function M.change(root, win, kind)
  assert(M.labels[kind], "Unknown pane type")
  assert(api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative == "" and not M.external(win), "Choose a workspace pane")
  api.nvim_set_current_win(win)
  local old = M.kind(win)
  if old == kind then M.refresh(); return end
  local state = pane(root, win)
  local previous = capture_leaf(root, win)
  state.roles[old] = { node = previous, options = window_options(win) }

  local retained = state.roles[kind]
  local node = (retained and vim.deepcopy(retained.node)) or { kind = kind }
  -- A new type gets its own buffer. Returning to a type reuses this pane's
  -- earlier buffer/job instead of borrowing another pane's hidden session.
  if not cached(root, node) then node.slot = nil end
  fill(root, node, win, retained and retained.options or nil)
  M.refresh()
end

function M.new(root, direction)
  assert(direction == "vertical" or direction == "horizontal", "Choose split direction")
  local source = api.nvim_get_current_win()
  assert(api.nvim_win_get_config(source).relative == "" and not M.external(source), "Choose a workspace pane")
  local options = M.kind(source) == "editor" and window_options(source) or pane(root, source).defaults
  vim.cmd(direction == "vertical" and "belowright vnew" or "belowright new")
  local win = api.nvim_get_current_win()
  vim.w[win].next_studio_title = nil
  restore_options(win, options)
  M.panes[win] = { root = root, roles = {}, defaults = vim.deepcopy(options) }
  remember(root, api.nvim_get_current_buf())
  M.refresh()
  return win
end

function M.toggle(root, kind)
  assert(M.labels[kind], "Unknown pane type")
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local buf = api.nvim_win_get_buf(win)
    if vim.b[buf].next_studio_kind == kind then
      api.nvim_win_hide(win)
      M.refresh()
      return
    end
  end
  local node = { kind = kind, width = 35, height = 10 }
  for id, buf in pairs(M.buffers[root] or {}) do
    if api.nvim_buf_is_valid(buf) and vim.b[buf].next_studio_kind == kind then node.slot = id; break end
  end
  vim.cmd((kind == "terminal" or kind == "notes") and "botright 10split" or "botright 38vsplit")
  fill(root, node, api.nvim_get_current_win())
  M.refresh()
end

function M.exchange(root, first, second)
  assert(first ~= second and api.nvim_win_is_valid(first) and api.nvim_win_is_valid(second), "Choose two panes")
  assert(api.nvim_win_get_tabpage(first) == api.nvim_win_get_tabpage(second), "Choose panes in this project")
  assert(api.nvim_win_get_config(first).relative == "" and api.nvim_win_get_config(second).relative == "", "Choose workspace panes")
  local a, b = capture_leaf(root, first, true), capture_leaf(root, second, true)
  fill(root, b, first)
  fill(root, a, second)
  api.nvim_set_current_win(second)
  M.refresh()
end

function M.title(win, title)
  assert(type(title) == "string" and #title <= 80 and not title:find("[%z\1-\31\127]"), "Use a short pane title")
  vim.w[win].next_studio_title = title ~= "" and title or nil
  M.refresh()
end

return M
