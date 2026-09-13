local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("NextStudioScreensaver")
local keys = api.nvim_replace_termcodes

local function highlights()
  for name, color in pairs({ Background = "#25344e", Stars = "#334766", Cyan = "#58e6ff", Pink = "#ff70c6" }) do
    api.nvim_set_hl(0, "NextSaver" .. name, { fg = color, bg = "#080d19" })
  end
end

local function draw(state)
  if M.state ~= state or not api.nvim_win_is_valid(state.win) then return end
  local width, height = vim.o.columns, vim.o.lines
  if width ~= state.width or height ~= state.height then
    api.nvim_win_set_config(state.win, { relative = "editor", row = 0, col = 0, width = width, height = height })
    state.width, state.height = width, height
  end
  local cells, colors, depth = {}, {}, {}
  for row = 1, height do
    cells[row], colors[row], depth[row] = {}, {}, {}
    for col = 1, width do cells[row][col] = " " end
  end
  local function point(x, y, char, color, z)
    x, y = math.floor(x), math.floor(y)
    if x < 1 or x > width or y < 1 or y > height then return end
    if z and depth[y][x] and depth[y][x] > z then return end
    cells[y][x], colors[y][x], depth[y][x] = char, color, z
  end
  local function label(y, value, color)
    local x = math.floor((width - #value) / 2) + 1
    for i = 1, #value do point(x + i - 1, y, value:sub(i, i), color) end
  end
  local t = (vim.uv.hrtime() - state.started) / 1e9
  for i = 1, math.min(90, math.floor(width * height / 65)) do
    point((i * 79.31 - t * (1 + i % 3)) % width + 1, (i * 37.19) % height + 1,
      i % 7 == 0 and "+" or ".", "NextSaverStars")
  end
  -- Project a slowly rotating torus into terminal cells, with a small depth buffer.
  local a, b = t * 0.35 + 0.6, t * 0.18
  local ca, sa, cb, sb = math.cos(a), math.sin(a), math.cos(b), math.sin(b)
  local scale, shades = math.min(width * 0.24, height * 0.85), ".:-=+*#%@"
  for theta = 0, 2 * math.pi, 0.10 do
    for phi = 0, 2 * math.pi, 0.10 do
      local ct, st, cp, sp = math.cos(theta), math.sin(theta), math.cos(phi), math.sin(phi)
      local r = 1.6 + 0.65 * ct
      local x, y, z = r * cp, r * sp, 0.65 * st
      local nx, ny, nz = ct * cp, ct * sp, st
      y, z, ny, nz = y * ca - z * sa, y * sa + z * ca, ny * ca - nz * sa, ny * sa + nz * ca
      x, y, nx, ny = x * cb - y * sb, x * sb + y * cb, nx * cb - ny * sb, nx * sb + ny * cb
      local light = math.max(0, -0.3 * nx - 0.5 * ny - 0.8 * nz)
      local shade = math.min(#shades, 1 + math.floor(light * (#shades - 1)))
      point(width / 2 + 2 * scale * x / (z + 6), height / 2 + scale * y / (z + 6),
        shades:sub(shade, shade), light > 0.65 and "NextSaverPink" or "NextSaverCyan", 1 / (z + 6))
    end
  end
  if width >= 36 and height >= 12 then label(4, "N E X T   /   D E E P   S P A C E", "NextSaverCyan") end
  local options = require("next_studio.config").options
  if width >= 30 then label(height - 2, (options.screensaver.key or "") .. " / " .. require("next_studio.config").hint("z") .. " - BACK", "NextSaverStars") end
  local lines = {}
  for row = 1, height do lines[row] = table.concat(cells[row]) end
  vim.bo[state.buf].modifiable = true
  api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for row = 1, height do
    local col = 1
    while col <= width do
      local color, first = colors[row][col], col
      repeat col = col + 1 until col > width or colors[row][col] ~= color
      if color then
        api.nvim_buf_set_extmark(state.buf, ns, row - 1, first - 1,
          { end_col = col - 1, hl_group = color, priority = 200 })
      end
    end
  end
  -- Command-line mode does not repaint buffer changes automatically.
  vim.cmd.redraw()
end

function M.hide(resume)
  local state = M.state
  if not state then return end
  M.state = nil
  vim.on_key(nil, ns)
  if state.timer then state.timer:stop(); state.timer:close() end
  if api.nvim_win_is_valid(state.win) then api.nvim_win_close(state.win, true) end
  if api.nvim_buf_is_valid(state.buf) then api.nvim_buf_delete(state.buf, { force = true }) end
  if not api.nvim_win_is_valid(state.source) then return end
  api.nvim_set_current_win(state.source)
  if api.nvim_win_get_buf(state.source) ~= state.source_buf then return end
  if vim.bo[state.source_buf].buftype ~= "terminal" then
    api.nvim_win_set_cursor(state.source, state.cursor)
    vim.fn.winrestview(state.view)
  end
  if resume == false then return end
  if state.mode:match("^[it]") then vim.cmd.startinsert()
  elseif state.mode:match("^R") then vim.cmd.startreplace()
  elseif state.visual then
    vim.fn.setpos(".", state.visual)
    vim.cmd.normal({ args = { state.visual_mode }, bang = true })
    api.nvim_win_set_cursor(state.source, state.cursor)
    if state.select then vim.cmd.normal({ args = { "\7" }, bang = true }) end
  end
  vim.cmd.redraw()
end

function M.show()
  if M.state then return end
  local mode = api.nvim_get_mode().mode
  local state = { source = api.nvim_get_current_win(), source_buf = api.nvim_get_current_buf(),
    cursor = api.nvim_win_get_cursor(0), view = vim.fn.winsaveview(), mode = mode, started = vim.uv.hrtime() }
  local visual_modes = { v = "v", V = "V", ["\22"] = "\22", s = "v", S = "V", ["\19"] = "\22" }
  if visual_modes[mode] then
    state.visual = vim.fn.getpos("v")
    state.visual_mode, state.select = visual_modes[mode], visual_modes[mode] ~= mode
    vim.cmd.normal({ args = { keys("<Esc>", true, false, true) }, bang = true })
  end
  vim.cmd.stopinsert()
  state.buf = api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].filetype = "next_screensaver"
  vim.bo[state.buf].undolevels = -1
  M.state = state
  state.win = api.nvim_open_win(state.buf, true, { relative = "editor", row = 0, col = 0,
    width = vim.o.columns, height = vim.o.lines, style = "minimal", border = "none",
    zindex = 1000000, noautocmd = true })
  vim.wo[state.win].winbar = ""
  vim.wo[state.win].winblend = 0
  vim.wo[state.win].wrap = false
  vim.wo[state.win].winhighlight = "Normal:NextSaverBackground,NormalFloat:NextSaverBackground,EndOfBuffer:NextSaverBackground"
  highlights()
  draw(state)
  -- Discard input after mapping resolution, including window commands and mouse
  -- clicks. Only the two explicit return keys can uncover the workspace.
  local options = require("next_studio.config").options
  local leader = keys(options.key_prefix:gsub("<leader>", function() return vim.g.mapleader or "\\" end) .. "z", true, false, true)
  local toggle = options.screensaver.key and keys(options.screensaver.key, true, false, true)
  local recent = ""
  vim.on_key(function(_, typed)
    if M.state ~= state then return end
    recent = (recent .. typed):sub(-#leader)
    if typed == toggle or recent == leader then vim.schedule(function() if M.state == state then M.hide() end end) end
    return ""
  end, ns)
  state.timer = vim.uv.new_timer()
  state.timer:start(120, 120, vim.schedule_wrap(function()
    if M.state == state then draw(state) end
  end))
end

function M.toggle()
  if M.state then M.hide() else M.show() end
end

function M.setup()
  local group = api.nvim_create_augroup("NextStudioScreensaver", { clear = true })
  -- Registered before Studio's exit hook, so the real layout/focus is saved.
  api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function() M.hide(false) end })
  api.nvim_create_autocmd("VimResized", { group = group, callback = function() if M.state then draw(M.state) end end })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  api.nvim_create_autocmd("WinEnter", { group = group, callback = function()
    local state = M.state
    if state and api.nvim_get_current_win() ~= state.win then
      vim.schedule(function()
        if M.state == state and api.nvim_win_is_valid(state.win) then api.nvim_set_current_win(state.win) end
      end)
    end
  end })
  local options = require("next_studio.config").options
  if options.keymaps and options.screensaver.enabled and options.screensaver.key then
    vim.keymap.set({ "n", "i", "x", "s", "t", "c" }, options.screensaver.key, M.toggle, { desc = "ASCII screensaver / return", silent = true })
  end
end

return M
