local M = {}
local api = vim.api

function M.diagram(tree, width, height)
  local grid = {}
  for y = 1, height do grid[y] = {}; for x = 1, width do grid[y][x] = " " end end
  local function put(x, y, char)
    if grid[y] and x >= 1 and x <= width then grid[y][x] = char end
  end
  local function minimum(node, horizontal)
    if not node.children then return horizontal and 4 or 3 end
    local size = 0
    for _, child in ipairs(node.children) do
      local child_size = minimum(child, horizontal)
      if (node.kind == "row") == horizontal then size = size + child_size else size = math.max(size, child_size) end
    end
    return size
  end
  local function box(node, x, y, w, h)
    if node.children then
      local horizontal = node.kind == "row"
      local field, total, reserved = horizontal and "width" or "height", 0, 0
      for _, child in ipairs(node.children) do
        total = total + child[field]
        reserved = reserved + minimum(child, horizontal)
      end
      local offset, available = 0, horizontal and w or h
      for i, child in ipairs(node.children) do
        local amount = reserved <= available
          and minimum(child, horizontal) + math.floor((available - reserved) * child[field] / total)
          or math.floor(available * child[field] / total)
        if i == #node.children then amount = available - offset end
        if amount > 0 then box(child, x + (horizontal and offset or 0), y + (horizontal and 0 or offset), horizontal and amount or w, horizontal and h or amount) end
        offset = offset + amount
      end
      return
    end
    for col = x, x + w - 1 do put(col, y, "-"); put(col, y + h - 1, "-") end
    for row = y, y + h - 1 do put(x, row, "|"); put(x + w - 1, row, "|") end
    for _, corner in ipairs({ { x, y }, { x + w - 1, y }, { x, y + h - 1 }, { x + w - 1, y + h - 1 } }) do put(corner[1], corner[2], "+") end
    if h < 3 or w < 4 then return end
    local label = node.title or require("next_studio.layout").labels[node.kind]
    label = vim.fn.strcharpart(label, 0, math.max(1, w - 3))
    local start = x + math.max(1, math.floor((w - vim.fn.strdisplaywidth(label)) / 2))
    for i = 1, vim.fn.strchars(label) do put(start + i - 1, y + math.floor(h / 2), vim.fn.strcharpart(label, i - 1, 1)) end
  end
  box(tree, 1, 1, width, height)
  return vim.tbl_map(table.concat, grid)
end

function M.open(layouts, selected, callback)
  local names = vim.tbl_keys(layouts)
  table.sort(names)
  if #names == 0 then vim.notify("NEXT: Save an arrangement first"); return end
  local index = 1
  for i, name in ipairs(names) do if name == selected then index = i end end
  local width, height = math.max(24, math.min(100, vim.o.columns - 6)), math.max(10, math.min(30, vim.o.lines - 6))
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden, vim.bo[buf].filetype = "wipe", "next-layouts"
  local win = api.nvim_open_win(buf, true, { relative = "editor", row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2), width = width, height = height, style = "minimal", border = "rounded",
    title = " NEXT / LAYOUTS ", title_pos = "center", footer = " j/k choose   Enter apply   Esc cancel ", footer_pos = "center" })
  M.active = { win = win, buf = buf }
  api.nvim_create_autocmd("WinClosed", { pattern = tostring(win), once = true, callback = function()
    if M.active and M.active.win == win then M.active = nil end
  end })
  local function close()
    M.active = nil
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  end
  local function render()
    local lines = { "  " .. index .. " / " .. #names .. "   " .. names[index], "" }
    vim.list_extend(lines, M.diagram(layouts[names[index]], width - 4, height - 4))
    for i = 3, #lines do lines[i] = "  " .. lines[i] end
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    api.nvim_win_set_cursor(win, { 1, 2 })
  end
  local function move(step) index = (index - 1 + step) % #names + 1; render() end
  for key, fn in pairs({ j = function() move(1) end, k = function() move(-1) end,
    ["<Down>"] = function() move(1) end, ["<Up>"] = function() move(-1) end,
    q = close, ["<Esc>"] = close, ["<CR>"] = function() local name = names[index]; close(); vim.schedule(function() callback(name) end) end }) do
    vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true })
  end
  render()
end

return M
