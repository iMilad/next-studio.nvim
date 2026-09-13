local api = vim.api
local studio = require("next_studio")
local layout = require("next_studio.layout")
local store = require("next_studio.store")
local root = store.canonical(assert(vim.env.NEXT_STUDIO_TEST_ROOT) .. "/projects/LEGACY")
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function leaf(kind, title)
  return { kind = kind, width = 60, height = 15, title = title }
end
local function branch(kind, children) return { kind = kind, width = 120, height = 32, children = children } end
local function count(node)
  if not node.children then return 1 end
  local n = 0; for _, child in ipairs(node.children) do n = n + count(child) end
  return n
end
local function role(kind)
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do if layout.kind(win) == kind then return win end end
end
local path = store.directory() .. "/" .. vim.fn.sha256(root) .. ".json"
if vim.env.NEXT_STUDIO_PHASE == "migration" then
  local editor = leaf("editor", "API")
  editor.file, editor.line = "example.txt", 1
  local files = leaf("tree", "Old Files")
  files.focused = true
  local old = branch("row", { files, branch("col", {
    branch("row", { editor, leaf("agent") }), branch("row", { leaf("terminal", "Build"), leaf("notes") }),
  }) })
  local data = { version = 1, root = root, revision = "legacy-fixture", selected = "Coding", layouts = {
    Coding = old, OnlyFiles = files, NestedFiles = branch("row", { branch("col", { files, files }), editor }),
  } }
  vim.fn.mkdir(store.directory(), "p")
  vim.fn.writefile({ vim.json.encode(data) }, path)
  local bytes = table.concat(vim.fn.readfile(path), "\n")
  local loaded = assert(store.load(root))
  check(count(loaded.layouts.Coding) == 4 and loaded.layouts.Coding.kind == "col", "Migration removes the sidebar and collapses its parent split")
  check(loaded.layouts.OnlyFiles.kind == "editor", "A Files-only layout becomes a usable empty editor")
  check(loaded.layouts.NestedFiles.kind == "editor" and loaded.layouts.NestedFiles.title == "API", "Nested Files-only branches collapse without losing the remaining pane")
  check(table.concat(vim.fn.readfile(path), "\n") == bytes, "Loading old layouts does not rewrite the saved file")
  check(old.children[1].kind == "tree", "Migration leaves the source tree unchanged")
end

check(studio.open(root), "Migrated layout opens")
check(#api.nvim_tabpage_list_wins(0) == 4 and count(layout.capture(root)) == 4, "Only the four retained panes restore")
check(api.nvim_buf_get_name(api.nvim_win_get_buf(role("editor"))) == root .. "/example.txt", "Editor file survives migration and restart")
check(vim.w[role("terminal")].next_studio_title == "Build", "Pane names survive migration and restart")

local colors = {}
for _, kind in ipairs({ "editor", "terminal", "agent", "notes" }) do
  local win = role(kind)
  api.nvim_set_current_win(win)
  layout.refresh()
  local group = vim.wo[win].winhighlight:match("Normal:([^,]+)")
  local active = api.nvim_get_hl(0, { name = group, link = false }).bg
  colors[active] = true
  check(vim.wo[win].winbar == "" and group:find("Active", 1, true), kind .. " uses background focus without a winbar")
  api.nvim_set_current_win(role(kind == "editor" and "agent" or "editor"))
  layout.refresh()
  local inactive = vim.wo[win].winhighlight:match("Normal:([^,]+)")
  check(api.nvim_get_hl(0, { name = inactive, link = false }).bg ~= active, kind .. " dims when focus moves away")
end
check(vim.tbl_count(colors) == 4, "Each pane role has a distinct background")

api.nvim_set_current_win(role("editor"))
local editor = api.nvim_get_current_buf()
vim.wo.winhighlight = "Search:IncSearch,Normal:ErrorMsg"
layout.refresh()
check(vim.wo.winhighlight:find("Search:IncSearch", 1, true), "Unrelated window highlights are preserved")
studio.pane("terminal")
check(vim.wo.winhighlight:find("Normal:NextStudioterminalActiveNormal", 1, true), "Changing role immediately updates the background")
studio.pane("editor")
check(api.nvim_get_current_buf() == editor and vim.wo.winbar == "", "Changing back preserves the editor buffer and header-free layout")

-- Model a native file-browser buffer, without installing a browser dependency.
vim.cmd("belowright new")
vim.bo.filetype = "netrw"
layout.refresh()
check(not vim.wo.winhighlight:find("NextStudio", 1, true), "Native browser windows keep their own appearance")
check(count(layout.capture(root)) == 4, "Native browser windows are excluded from saved Studio layouts")
studio.pane("agent")
check(vim.bo.filetype == "netrw", "Studio does not replace a native file-browser buffer")
vim.cmd.close()

check(studio.save("Coding"), "Migrated workspace saves")
local saved = table.concat(vim.fn.readfile(path), "\n")
check(not saved:find('"kind":"tree"', 1, true), "Saved layouts contain no obsolete Files role")
print("PASS standalone " .. vim.env.NEXT_STUDIO_PHASE .. ": " .. checks .. " checks")
vim.cmd("qa!")
