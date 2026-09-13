-- Layout data only: no Vimscript sessions, buffer contents, or shell commands.
local M = {}
local uv = vim.uv
local config = require("next_studio.config")

function M.directory()
  return vim.g.next_studio_state_dir or config.options.state_dir or (vim.fn.stdpath("state") .. "/next-workspaces")
end

function M.canonical(path)
  if type(path) ~= "string" or path:find("[%z\1-\31]") then return nil end
  if path == "~" or path:sub(1, 2) == "~/" then path = vim.fn.expand("~") .. path:sub(2) end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  return uv.fs_realpath(path)
end

function M.sensitive(path)
  local lower = path:lower()
  for part in lower:gmatch("[^/]+") do
    if part:match("^%.env") or part:match("^id_[a-z0-9]+$")
      or vim.tbl_contains({ ".aws", ".ssh", ".kube", ".gnupg", ".netrc", ".npmrc", ".pypirc",
        ".git-credentials", "keychains", "certificates", "sso" }, part) then return true end
  end
  return lower:match("%.pem$") ~= nil or lower:match("%.key$") ~= nil
    or lower:match("%.p12$") ~= nil or lower:match("%.pfx$") ~= nil
    or lower:match("%.crt$") ~= nil or lower:match("%.cer$") ~= nil
    or lower:match("/gh/hosts%.yml$") ~= nil or lower:match("/%.docker/config%.json$") ~= nil
    or lower:match("/auth%.json$") ~= nil or lower:match("/credentials[^/]*$") ~= nil
    or lower:match("/tokens?%.json$") ~= nil or lower:match("/cookies[^/]*$") ~= nil
end

function M.file(root, relative)
  if type(relative) ~= "string" or relative:sub(1, 1) == "/" or relative:find("[%z\1-\31]") or M.sensitive(relative) then return nil end
  local path = M.canonical(root .. "/" .. relative)
  if not path or path:sub(1, #root + 1) ~= root .. "/" or M.sensitive(path) then return nil end
  local stat = uv.fs_stat(path)
  return stat and stat.type == "file" and path or nil
end

local function read(path)
  local stat = uv.fs_lstat(path)
  if not stat then return nil end
  if stat.type ~= "file" or stat.size > 1024 * 1024 then return nil, "Invalid layout data" end
  local fd = uv.fs_open(path, "r", 384)
  if not fd then return nil, "Cannot read layout data" end
  local bytes = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  local ok, data = pcall(vim.json.decode, bytes or "")
  if not ok or type(data) ~= "table" then return nil, "Invalid layout data" end
  return data
end

local function write(path, data)
  local tmp = path .. ".tmp-" .. uv.os_getpid()
  local fd = uv.fs_open(tmp, "wx", 384)
  if not fd then return false, "Cannot create layout file" end
  local bytes = vim.json.encode(data)
  local count = uv.fs_write(fd, bytes, 0)
  uv.fs_fsync(fd)
  uv.fs_close(fd)
  if count ~= #bytes then uv.fs_unlink(tmp); return false, "Cannot write layout file" end
  local ok = uv.fs_rename(tmp, path)
  if not ok then uv.fs_unlink(tmp); return false, "Cannot replace layout file" end
  return true
end

local function locked(name, callback)
  local dir = M.directory()
  vim.fn.mkdir(dir, "p", 448)
  local stat = uv.fs_lstat(dir)
  if not stat or stat.type ~= "directory" then return false, "Invalid layout directory" end
  local path = dir .. "/" .. name .. ".json"
  local lock = path .. ".lock"
  local fd = uv.fs_open(lock, "wx", 384)
  if not fd then return false, "Layout is busy in another Neovim; try again" end
  local ok, result, detail = pcall(callback, path)
  uv.fs_close(fd)
  uv.fs_unlink(lock)
  if not ok then return false, "Layout update failed" end
  return result, detail
end

function M.valid_tree(tree)
  local count = 0
  local function valid(node, depth)
    if type(node) ~= "table" or depth > 12 then return false end
    for _, key in ipairs({ "width", "height" }) do
      if type(node[key]) ~= "number" or node[key] < 1 or node[key] > 10000 then return false end
    end
    if node.kind == "row" or node.kind == "col" then
      if type(node.children) ~= "table" or #node.children < 2 or #node.children > 32 then return false end
      for _, child in ipairs(node.children) do if not valid(child, depth + 1) then return false end end
      return true
    end
    count = count + 1
    return count <= 32 and vim.tbl_contains({ "editor", "tree", "terminal", "agent", "notes" }, node.kind)
      and (node.title == nil or (type(node.title) == "string" and #node.title <= 80 and not node.title:find("[%z\1-\31\127]")))
      and (node.file == nil or type(node.file) == "string")
      and (node.slot == nil or (type(node.slot) == "number" and node.slot >= 1 and node.slot <= 1000000))
      and (node.line == nil or (type(node.line) == "number" and node.line >= 1 and node.line < 100000000))
  end
  return valid(tree, 0)
end

-- Accept v0.1 layouts, but discard the removed Files role and collapse its split.
-- Loading is read-only; a normal save writes the migrated layout later.
function M.migrate(tree)
  local function visit(node)
    if node.kind == "tree" then return nil end
    local result = vim.deepcopy(node)
    if not node.children then return result end
    result.children = {}
    for _, child in ipairs(node.children) do
      local value = visit(child)
      if value then result.children[#result.children + 1] = value end
    end
    if #result.children == 0 then return nil end
    if #result.children == 1 then return result.children[1] end
    return result
  end
  return visit(tree) or { kind = "editor", width = tree.width, height = tree.height, focused = true }
end

function M.load(root)
  local data, err = read(M.directory() .. "/" .. vim.fn.sha256(root) .. ".json")
  if err then return nil, err end
  if not data then return { version = 1, root = root, revision = "", layouts = {}, selected = "Last" } end
  if data.version ~= 1 or data.root ~= root or type(data.revision) ~= "string"
    or type(data.layouts) ~= "table" or type(data.selected) ~= "string" then return nil, "Invalid project layout" end
  for name, tree in pairs(data.layouts) do
    if type(name) ~= "string" or not name:match("^[%w _-]+$") or #name > 40 or not M.valid_tree(tree) then return nil, "Invalid saved layout" end
    data.layouts[name] = M.migrate(tree)
  end
  return data
end

function M.save(root, name, tree, expected, force)
  if not name:match("^[%w _-]+$") or #name > 40 or not M.valid_tree(tree) then return false, "Use a short layout name: letters, numbers, spaces, - or _" end
  return locked(vim.fn.sha256(root), function(path)
    local data, err = M.load(root)
    if not data then return false, err end
    if not force and data.revision ~= expected then
      return false, "Layout changed in another Neovim. :StudioSave! explicitly replaces it."
    end
    data.layouts[name] = M.migrate(tree)
    data.selected = name
    data.revision = tostring(uv.hrtime()) .. "-" .. uv.os_getpid()
    data.updated = os.time()
    local ok, why = write(path, data)
    return ok, ok and data.revision or why
  end)
end

function M.bookmarks()
  local data = read(M.directory() .. "/projects.json")
  return data and type(data.projects) == "table" and data.projects or {}
end

function M.add(root)
  return locked("projects", function(path)
    local data, err = read(path)
    if err then return false, err end
    data = data or { version = 1, projects = {} }
    if type(data.projects) ~= "table" then return false, "Invalid project list" end
    for _, item in ipairs(data.projects) do if item == root then return true end end
    data.projects[#data.projects + 1] = root
    return write(path, data)
  end)
end

-- Read only the path field of the existing NEXT Studio bookmark registry.
function M.terminal_bookmarks()
  local path = vim.g.next_studio_registry or config.options.legacy_registry
  if not path then return {} end
  local data = read(path)
  local result = {}
  for _, item in ipairs(data and type(data.projects) == "table" and data.projects or {}) do
    if type(item) == "table" and type(item.path) == "string" and item.path:sub(1, 1) == "/"
      and not item.path:find("[%z\1-\31]") then result[#result + 1] = item.path end
  end
  return result
end

return M
