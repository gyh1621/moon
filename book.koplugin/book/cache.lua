--[[--
缓存文件管理：扫盘统计、整库清空。

  只管 `.moon/cache/` 下的落盘文件与对应 books/chapters 路径登记；
  书籍身份与元数据门面在 book.store。

@module koplugin.book.book.cache
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("utils.log")
local UIManager = require("ui/uimanager")
local Paths = require("utils.paths")
local BookDB = require("db.book")
local ChapterDB = require("db.chapter")

local Cache = {}

local BUDGET = 32

--- Inspect owned book files in a worker; original local documents are excluded.
function Cache.inspect(book)
    if book.source_id == "local" then return nil end
    local Text = require("utils.text")
    local entry = {
        source_id = book.source_id, stable_id = book.stable_id,
        title = book.title or book.stable_id, book = book,
        bytes = 0, total = 0, available = 0, complete = 0, pending_images = 0,
        chapters = {},
    }
    local dir = Paths.bookWorkDir(book.stable_id, book.source_id)
    local work_attr = lfs.symlinkattributes(dir)
    local stack = { dir }
    while #stack > 0 do
        local path = table.remove(stack)
        local attr = lfs.symlinkattributes(path)
        if attr and attr.mode == "directory" then
            for name in lfs.dir(path) do
                if name ~= "." and name ~= ".." then stack[#stack + 1] = path .. "/" .. name end
            end
        elseif attr and attr.mode == "file" then
            entry.bytes = entry.bytes + attr.size
        end
    end
    local cover = lfs.symlinkattributes(Paths.coverPath(book.stable_id, book.source_id))
    if cover and cover.mode == "file" then entry.bytes = entry.bytes + cover.size end
    local path = book.path
    local root = Paths.cacheDir() .. "/"
    if type(path) == "string" and path:sub(1, #root) == root
        and path:sub(1, #dir + 1) ~= dir .. "/" then
        local attr = lfs.symlinkattributes(path)
        if attr and attr.mode == "file" then entry.bytes = entry.bytes + attr.size end
    end
    local ok, toc = pcall(require("json").decode, book.toc or "")
    if ok and type(toc) == "table" then
        entry.total = #toc
        for idx, chapter in ipairs(toc) do
            -- chapterPath creates the work directory; inspection must remain read-only.
            local chapter_path = dir .. "/" .. tostring(idx) .. ".html"
            local attr = work_attr and work_attr.mode == "directory" and lfs.symlinkattributes(chapter_path)
            local remote = attr and attr.mode == "file" and attr.size > 0
                and Text.hasRemoteImageSrcInFile(chapter_path)
            local state = "missing"
            if remote ~= nil and attr and attr.mode == "file" and attr.size > 0 then
                entry.available = entry.available + 1
                if remote then
                    entry.pending_images = entry.pending_images + 1
                    state = "images"
                else
                    entry.complete = entry.complete + 1
                    state = "cached"
                end
            end
            entry.chapters[idx] = { idx = idx, title = chapter.title or chapter.name or tostring(idx), state = state }
        end
    end
    entry.missing = entry.total - entry.available
    return entry
end

--- Read metadata in the main process, then scan files without opening SQLite in the worker.
function Cache.inventoryAsync(cb)
    local books = BookDB.cacheBooks()
    return require("workers.job").run(function()
        local entries = {}
        for _, book in ipairs(books) do
            local entry = Cache.inspect(book)
            if entry and entry.bytes > 0 then entries[#entries + 1] = entry end
        end
        return entries
    end, {
        name = "cache.inventory", kind = "light",
        on_done = function(entries) cb(entries) end,
        on_failed = function(err) cb(nil, err) end,
    })
end

--- 协作式递归遍历：一个 UI 周期最多处理 BUDGET 个目录项，剩余排到下一 tick。
--- 文件在遇到时回调，目录在其子项全部处理完后回调（自底向上，便于删除）。
--- visit 返回 false/nil 时立即终止，done(false, err)。
---@param root string
---@param visit fun(path: string, attr: table): boolean|nil, string|nil
---@param done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
local function walkAsync(root, visit, done)
    local cancelled = false
    local stack = {}
    --- lfs.dir 返回 (iter, dir_obj)；必须成对保存，调用 iter(dir_obj)。
    local function push(path, attr)
        local iter, state = lfs.dir(path)
        if type(iter) == "function" and state ~= nil then
            stack[#stack + 1] = { path = path, attr = attr, iter = iter, state = state }
        end
    end
    local root_attr = lfs.attributes(root)
    if root_attr and root_attr.mode == "directory" then push(root, root_attr) end

    local function step()
        if cancelled then return end
        for _ = 1, BUDGET do
            local top = stack[#stack]
            if not top then break end
            local name = top.iter(top.state)
            local ok, err = true, nil
            if not name then
                table.remove(stack)
                ok, err = visit(top.path, top.attr)
            elseif name ~= "." and name ~= ".." then
                local path = top.path .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    push(path, attr)
                elseif attr then
                    ok, err = visit(path, attr)
                end
            end
            if not ok then
                done(false, err)
                return
            end
        end
        if #stack == 0 then
            done(true)
        else
            UIManager:nextTick(step)
        end
    end
    UIManager:nextTick(step)
    return { cancel = function() cancelled = true end }
end

--- Cooperative cache size scan. Never walk the cache tree during widget build.
--- 缓存目录字节数之外再计入 sqlite 库文件本身；无法 stat 的项直接跳过。
---@param cb fun(bytes: number)
---@return { cancel: fun() }
function Cache.sizeBytesAsync(cb)
    local total = 0
    return walkAsync(Paths.cacheDir(), function(_, attr)
        if attr.mode == "file" then total = total + (tonumber(attr.size) or 0) end
        return true
    end, function()
        local db_attr = lfs.attributes(Paths.dbPath())
        if db_attr and db_attr.mode == "file" then
            total = total + (tonumber(db_attr.size) or 0)
        end
        cb(total)
    end)
end

--- 清空文件缓存及其路径登记，不动书籍元数据。
---@param cb fun(ok: boolean, err: any)|nil
---@return { cancel: fun() }
function Cache.clearAsync(cb)
    cb = cb or function() end
    local dir = Paths.cacheDir()
    local cancelled = false
    local purge_job
    -- 只清 cache 目录下的路径登记；本地源外部文件路径与书籍元数据必须保留。
    -- 先清 DB 再删文件：即使文件删除失败，DB 记录已干净，不会产生孤立引用。
    -- db.* 不抛错，失败只体现在返回值上。
    if not (ChapterDB.deleteUnder(dir) and BookDB.clearPathsUnder(dir)) then
        logger.warn("book cache db clear failed, skipping file purge")
        cb(false, "db clear failed")
        return { cancel = function() end }
    end
    -- DB 清理成功后再删文件
    -- 任一 remove 失败立即终止整次删除。
    purge_job = walkAsync(dir, function(path) return os.remove(path) end, function(ok, err)
        if cancelled then return end
        if not ok then
            -- 文件删除失败但 DB 已清：重建 cache 目录即可
            Paths.ensureCacheRoot()
            logger.warn("book cache file purge failed (db already cleared)", dir, err)
            cb(false, err)
            return
        end
        Paths.ensureCacheRoot()
        logger.info("book cache cleared", dir)
        cb(true)
    end)
    return { cancel = function()
            cancelled = true
            if purge_job then
                purge_job:cancel()
            end
        end }
end

return Cache
