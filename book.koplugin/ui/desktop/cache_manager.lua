local Cache = require("book.cache")
local Overlay = require("ui.desktop.settings.overlay")
local SettingRow = require("ui.components.settingrow")
local Tasks = require("tasks")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Manager = Overlay:extend{ name = "book_cache_manager" }

local function row(opts)
    return function(width) return SettingRow.build(width, opts) end
end

local function message(text)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = 3 })
end

function Manager.open(desktop)
    Overlay.close(desktop)
    local manager = Manager:new{
        desktop = desktop,
        close_callback = function()
            desktop.settings_overlay = nil
            if desktop.lifecycle.state ~= "Destroy" then UIManager:setDirty(desktop, "ui") end
        end,
    }
    desktop.settings_overlay = manager
    UIManager:show(manager)
end

function Manager:init()
    self.entries = {}
    self.spec = { title = _("缓存与下载"), sections = function() return self:sections() end }
    Overlay.init(self)
end

function Manager:onResume()
    self.lifecycle:addHttp(Tasks.watch(function()
        if self.lifecycle:uiReady() then self:updateView() end
    end))
    self:refresh()
end

function Manager:refresh()
    if self.scan then self.scan:cancel() end
    self.loading, self.error = true, nil
    self:updateView()
    self.scan = self.lifecycle:addHttp(Cache.inventoryAsync(function(entries, err)
        if not self.lifecycle:uiReady() then return end
        self.scan = nil
        self.loading, self.error = false, err
        if err then require("utils.log").warn("cache inventory failed", err) end
        if entries then
            self.entries = entries
            if self.selected then
                local selected
                for _, entry in ipairs(entries) do
                    if entry.source_id == self.selected.source_id and entry.stable_id == self.selected.stable_id then
                        selected = entry
                        break
                    end
                end
                self.selected = selected
                self.spec.title = selected and selected.title or _("缓存与下载")
            end
        end
        self:updateView()
    end))
end

function Manager:openBook(entry)
    self.selected = entry
    self.spec.title = entry.title
    self.page = 1
    self:updateView()
end

function Manager:showChapters(entry)
    local labels = { cached = _("已缓存"), images = _("正文可读，图片未完成"), missing = _("未缓存") }
    local items = {}
    for _, chapter in ipairs(entry.chapters) do
        items[#items + 1] = {
            text = tostring(chapter.idx) .. ". " .. chapter.title .. " · " .. labels[chapter.state],
        }
    end
    local menu
    menu = require("ui/widget/menu"):new{
        title = _("章节缓存"), item_table = items,
        width = require("device").screen:getWidth(),
        height = require("device").screen:getHeight(),
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function Manager:retry(entry)
    local source, err = require("source.registry").resolve(entry.source_id)
    if not source or type(source.cacheAllChaptersAsync) ~= "function" then
        message(err or _("此书源不支持章节缓存"))
        return
    end
    local job, queued = require("source.cache_queue").enqueue(source, {
        source_id = entry.source_id, stable_id = entry.stable_id, book = entry.book,
    })
    message(not job and _("后台任务队列已满")
        or (queued and _("已加入后台缓存队列") or _("全本缓存任务已在后台运行")))
end

function Manager:clear(entry)
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = T(_("清理《%1》的本地缓存？\n正文、章节与图片需重新下载。阅读进度保留。"), entry.title),
        ok_text = _("清理"),
        ok_callback = function()
            if require("source.cache_queue").has(entry.source_id, entry.stable_id) then
                message(_("本书正在后台缓存，请先取消任务"))
                return
            end
            local ok, leftover = require("book.store").clearCache(entry.source_id, entry.stable_id)
            message(not ok and _("清理缓存失败") or (leftover and _("部分缓存文件未能删除") or _("缓存已清理")))
            if self.lifecycle:uiReady() then
                self.selected = nil
                self.spec.title = _("缓存与下载")
                self:refresh()
            end
        end,
    })
end

function Manager:sections()
    local controls = { row{
        kind = "action", icon = "refresh", title = _("刷新缓存状态"),
        subtitle = _("仅检查本地文件，不下载内容"),
        status = self.loading and _("检查中…") or nil,
        callback = function() self:refresh() end,
    } }
    if self.error then
        controls[#controls + 1] = row{
            kind = "action", title = _("检查缓存失败"), subtitle = _("点击重试，缓存文件不会被修改"),
            callback = function() self:refresh() end,
        }
    end
    local entry = self.selected
    if entry then
        local details = {
            row{ kind = "action", title = _("书籍文件占用"), status = require("util").getFriendlySize(entry.bytes) },
        }
        if entry.total > 0 then
            details[#details + 1] = row{
                kind = "nav", title = _("查看章节缓存"),
                subtitle = T(_("%1 章完整，%2 章待补图片，%3 章缺失"), entry.complete, entry.pending_images, entry.missing),
                status = tostring(entry.available) .. "/" .. tostring(entry.total),
                callback = function() self:showChapters(entry) end,
            }
        end
        local meta = require("source.registry").meta(entry.source_id)
        if meta and meta.type == "chapter" and (entry.total == 0 or entry.complete < entry.total) then
            details[#details + 1] = row{
                kind = "action", icon = "download", title = _("补全章节与图片"),
                subtitle = _("保留完整章节，仅补下载缺失内容"),
                callback = function() self:retry(entry) end,
            }
        end
        details[#details + 1] = row{
            kind = "action", icon = "delete", title = _("清理本书缓存"),
            subtitle = _("保留书籍信息与阅读进度"), callback = function() self:clear(entry) end,
        }
        return { { title = _("操作"), rows = controls }, { title = _("本地缓存"), rows = details } }
    end
    local jobs = {}
    for task_index, task in ipairs(Tasks.tasks()) do
        local state = task.state == "waiting" and _("等待恢复")
            or task.state == "queued" and _("排队中")
            or task.state == "retry_wait" and _("稍后重试") or _("进行中")
        jobs[#jobs + 1] = row{
            kind = "action", icon = task.restartable and "cancel" or "download",
            title = task.title or task.label,
            subtitle = task.label .. " · " .. state .. (task.restartable and _(" · 点击取消") or ""),
            status = task.total > 0 and tostring(task.count) .. "/" .. tostring(task.total) or nil,
            callback = function()
                if task.restartable then require("ui.components.task_dialog"):confirmCancel(task) end
            end,
        }
    end
    if #jobs == 0 then jobs[1] = row{ kind = "action", title = _("当前没有后台任务") } end
    local books = {}
    for book_index, cached in ipairs(self.entries) do
        books[#books + 1] = row{
            kind = "nav", icon = "book", title = cached.title,
            subtitle = cached.total > 0
                and T(_("正文 %1/%2 章，%3 章待补图片"), cached.available, cached.total, cached.pending_images)
                or _("本地书籍缓存"),
            status = require("util").getFriendlySize(cached.bytes),
            callback = function() self:openBook(cached) end,
        }
    end
    if #books == 0 then books[1] = row{
        kind = "action", title = self.loading and _("正在检查缓存…") or _("当前没有书籍缓存"),
    } end
    return {
        { title = _("操作"), rows = controls },
        { title = _("后台任务"), rows = jobs },
        { title = _("书籍缓存"), rows = books },
    }
end

function Manager:onBack()
    if self.selected then
        self.selected = nil
        self.spec.title = _("缓存与下载")
        self.page = 1
        self:updateView()
        return true
    end
    return Overlay.onClose(self)
end

return Manager
