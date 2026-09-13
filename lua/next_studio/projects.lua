local M = {}
local store = require("next_studio.store")
local uv = vim.uv
local markers = { ".git", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Makefile", "AGENTS.md" }
local skip = { node_modules = true, vendor = true, dist = true, build = true, target = true,
  backups = true, archive = true, archived = true, __pycache__ = true }

function M.name(root)
  return vim.fs.basename(root):gsub("[%%\r\n]", "_")
end

function M.list()
  local result, seen = {}, {}
  local function add(path)
    local root = store.canonical(path)
    if not root or seen[root] or store.sensitive(root) then return end
    local stat = uv.fs_stat(root)
    if not stat or stat.type ~= "directory" then return end
    seen[root] = true
    result[#result + 1] = { root = root, name = M.name(root) }
  end
  for _, root in ipairs(store.bookmarks()) do if type(root) == "string" then add(root) end end
  for _, root in ipairs(store.terminal_bookmarks()) do add(root) end
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local ok, root = pcall(vim.api.nvim_tabpage_get_var, tab, "next_studio_root")
    if ok then add(root) end
  end
  local visited = 0
  local function scan(path, depth)
    visited = visited + 1
    if visited > 2500 or depth > 5 then return end
    if depth > 0 then
      for _, marker in ipairs(markers) do
        if uv.fs_lstat(path .. "/" .. marker) then add(path); return end
      end
    end
    local handle = uv.fs_scandir(path)
    if not handle then return end
    while true do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then break end
      if kind == "directory" and name:sub(1, 1) ~= "." and not skip[name] then scan(path .. "/" .. name, depth + 1) end
    end
  end
  for _, base in ipairs(vim.g.next_studio_project_roots or require("next_studio.config").options.project_roots) do
    local root = store.canonical(base)
    if root then scan(root, 0) end
  end
  add(vim.fn.getcwd())
  table.sort(result, function(a, b) return a.name:lower() == b.name:lower() and a.root < b.root or a.name:lower() < b.name:lower() end)
  return result
end

function M.pick(open)
  local items = M.list()
  for _, item in ipairs(items) do
    item.text = item.name .. "  " .. item.root
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      if vim.t[tab].next_studio_root == item.root then item.active = true end
    end
  end
  if _G.Snacks and Snacks.picker then
    Snacks.picker({
      title = "NEXT / PROJECTS", items = items, preview = "none",
      layout = { preset = "select", preview = false, layout = { width = 0.8, max_width = 110, height = 0.7 } },
      format = function(item)
        return { { item.active and "● " or "○ ", item.active and "DiagnosticOk" or "Comment" },
          { item.name .. "  ", "Directory" }, { vim.fn.fnamemodify(item.root, ":~"), "Comment" } }
      end,
      confirm = function(picker, item)
        picker:close()
        if item then vim.schedule(function() open(item.root) end) end
      end,
    })
  else
    vim.ui.select(items, { prompt = "NEXT / Projects", format_item = function(item) return item.name .. "  " .. item.root end },
      function(item) if item then open(item.root) end end)
  end
end

return M
