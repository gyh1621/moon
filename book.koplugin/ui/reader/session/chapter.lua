--[[--
连续章节阅读编排：跨 switchDocument 的章节会话。

@module koplugin.book.ui.reader.session.chapter
--]]

local Store = require("book.store")
local Snapshot = require("ui.reader.session.snapshot")
local _ = require("gettext")

---@class ReaderChapterSession
---@field identity BookIdentity|nil 书籍身份与属主源
---@field toc BookChapter[] 从 books.toc 恢复的目录快照
---@field request { cancel: fun() }|nil 在途章节打开任务
---@field target { path: string, within: number|nil, direction: "prev"|"next"|nil, xpointer: string|nil }|nil 已下载、等待 ReaderReady 的目标
---@field toc_job { cancel: fun() }|nil 目录恢复任务
---@field switching boolean|nil 已进入 switchDocument，同步 CloseDocument 应保留本书会话

local Chapter = {}

local PREFETCH_AHEAD = 3
local TRANSITION_NOTICE_DELAY = 0.25

---@type ReaderChapterSession|nil
local chapter_session
---@type { cancel: fun() }|nil
local prefetch_job
local transition_notice
local transition_notice_timer

local function cancelTransitionNoticeTimer()
    if transition_notice_timer then
        require("ui/uimanager"):unschedule(transition_notice_timer)
        transition_notice_timer = nil
    end
end

local function closeTransitionNotice()
    cancelTransitionNoticeTimer()
    if transition_notice then
        require("ui/uimanager"):close(transition_notice)
        transition_notice = nil
    end
end

local function showTransitionNotice()
    cancelTransitionNoticeTimer()
    if transition_notice then return end
    transition_notice = require("ui/widget/infomessage"):new{
        text = _("正在切换章节，请稍候…"),
    }
    require("ui/uimanager"):show(transition_notice)
end

local function scheduleTransitionNotice(chapter)
    closeTransitionNotice()
    local timer
    timer = function()
        if transition_notice_timer ~= timer or chapter_session ~= chapter then return end
        showTransitionNotice()
    end
    transition_notice_timer = timer
    require("ui/uimanager"):scheduleIn(TRANSITION_NOTICE_DELAY, timer)
end

--- 取消在途的后续章预取任务。
--- 先清模块状态再 cancel，避免 cancel 回调重入时又看到已废弃的 job。
local function cancelPrefetch()
    local job = prefetch_job
    prefetch_job = nil
    if job and job.cancel then job.cancel() end
end

---@param session ReaderSessionSnapshot|nil
function Chapter.clearActiveChapter(session)
    local chapter = chapter_session
    chapter_session = nil
    cancelPrefetch()
    if session then session.chapter = nil end
    if chapter and chapter.request and chapter.request.cancel then chapter.request.cancel() end
    if chapter and chapter.toc_job and chapter.toc_job.cancel then chapter.toc_job.cancel() end
    closeTransitionNotice()
end

---@param session ReaderSessionSnapshot|nil
---@return BookChapter[]|nil
function Chapter.toc(session)
    local chapter = session and session.chapter
    return chapter and chapter.toc or nil
end

---@param toc BookChapter[]|table
---@param chapter_idx number|string|nil
---@return BookChapter|nil
local function tocEntry(toc, chapter_idx)
    local idx = tonumber(chapter_idx)
    if not idx or type(toc) ~= "table" then
        return nil
    end
    local direct = toc[idx]
    if type(direct) == "table" then
        local entry_idx = tonumber(direct.idx)
        if entry_idx == nil or entry_idx == idx then
            return direct
        end
    end
    for _, entry in ipairs(toc) do
        if type(entry) == "table" and tonumber(entry.idx) == idx then
            return entry
        end
    end
    return type(direct) == "table" and direct or nil
end

---@param entry BookChapter|table|nil
---@return string|nil
local function tocTitle(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local title = entry.title or entry.name
    if type(title) ~= "string" then
        return nil
    end
    title = require("utils.text").trim(title)
    if title == "" then
        return nil
    end
    return title
end

---@param snapshot ReaderSessionSnapshot|nil
---@return string|nil
function Chapter.chapterTitle(snapshot)
    if not snapshot then
        return nil
    end
    local id = snapshot.identity
    local toc = snapshot.chapter and snapshot.chapter.toc
    if toc and id and id.chapter_idx then
        return tocTitle(tocEntry(toc, id.chapter_idx))
    end
    return nil
end

---@param chapter ReaderChapterSession
---@param ui table
local function applyChapterTarget(chapter, ui)
    local target = chapter.target
    chapter.target = nil
    chapter.switching = false
    if not target then return end
    if target.within == nil and target.direction == nil and target.xpointer == nil then return end
    local within, direction = target.within, target.direction

    if chapter_session ~= chapter or ui.document.file ~= target.path then return end
    if target.xpointer then
        ui:handleEvent(require("ui/event"):new("GotoXPointer", target.xpointer, target.xpointer))
        return
    end
    local page
    if within ~= nil then
        within = require("book.progress").clampFraction(within)
        if ui.document.getXPointerFromProportion then
            local xptr = ui.document:getXPointerFromProportion(within)
            if xptr and ui.rolling then
                ui.rolling:onGotoXPointer(xptr)
                return
            elseif xptr and ui.link then
                ui.link:onGotoXPointer(xptr)
                return
            end
        end
        if ui.document.getPageCount then
            local total = ui.document:getPageCount() or 1
            page = math.max(1, math.min(total, math.floor(within * total + 0.5)))
        end
    elseif direction == "prev" then
        local total
        if ui.document.getPageCount then
            total = ui.document:getPageCount()
        end
        if total and total > 1 then
            page = total
        end
    elseif direction == "next" then
        page = 1
    end
    if not page then return end
    if ui.view and ui.view.view_mode == "page" and ui:getCurrentPage() == page then return end
    if ui.link then
        ui.link:addCurrentLocationToStack()
    end
    ui:handleEvent(require("ui/event"):new("GotoPage", page))
end

---@param view table|nil
---@param position fun(view: table): number
---@param atStart fun(before: number, after: number): boolean
---@param atBoundary fun(view: table, diff: number): boolean|nil
local function wrapBoundary(view, position, atStart, atBoundary)
    if not view then return end
    local original = view.onGotoViewRel
    if type(original) ~= "function" then return end
    view.onGotoViewRel = function(self, diff, ...)
        if not chapter_session then return original(self, diff, ...) end
        local reader_ui = self.ui
        if atBoundary and diff ~= 0 and atBoundary(self, diff)
            and Chapter.onChapterBoundary(reader_ui._book_chapter_session, diff < 0 and -1 or 1) then
            return true
        end
        local before = position(self)
        local result = original(self, diff, ...)
        if diff < 0 and atStart(before, position(self)) then
            local reader_ui = self.ui
            if reader_ui then
                reader_ui:handleEvent(require("ui/event"):new("StartOfBook"))
            end
        end
        return result
    end
end

---@param ui table
local function wrapChapterReaderUi(ui, session)
    if not ui or ui.name ~= "ReaderUI" then return end
    ui._book_chapter_session = session
    if ui._book_chapters_wrapped then return end
    ui._book_chapters_wrapped = true
    wrapBoundary(ui.rolling, function(view)
        if view.view and view.view.view_mode == "scroll" then
            return view.current_pos
        end
        return view.current_page
    end, function(before, after)
        return before == after
    end, function(view, diff)
        local document = view.ui.document
        if view.view.view_mode == "scroll" then
            if diff < 0 then return view.current_pos <= 0 end
            local max_pos = document.info.doc_height - view.ui.dimen.h + view.view.footer:getHeight()
            return view.current_pos >= max_pos
        end
        if document:hasHiddenFlows() then
            if diff < 0 then return document:getPrevPage(view.current_page) <= 0 end
            local page = view.current_page
            for _ = 1, document:getVisiblePageNumberCount() do
                page = document:getNextPage(page)
                if page <= 0 then return true end
            end
            return false
        end
        return diff < 0 and view.current_page <= 1
            or diff > 0 and view.current_page + document:getVisiblePageNumberCount() > document:getPageCount()
    end)
    wrapBoundary(ui.paging, function(view)
        return view.getTopPage and view:getTopPage() or view.current_page
    end, function(before, after)
        return before == 1 and after == before
    end)
end

---@param chapter ReaderChapterSession
local function schedulePrefetch(chapter)
    cancelPrefetch()
    if not chapter or chapter.request or chapter.target or chapter.switching then return end
    local identity = chapter.identity
    local source = identity and identity.source
    if not source or not identity.chapter_idx
        or type(chapter.toc) ~= "table" or type(source.prefetchChaptersAsync) ~= "function" then
        return
    end
    prefetch_job = source:prefetchChaptersAsync(identity, chapter.toc, identity.chapter_idx, PREFETCH_AHEAD)
end

---@param plugin table
---@param session ReaderSessionSnapshot
---@return boolean nav_target 切章导航目标已指定，跳过 pending 本地进度
function Chapter.onReaderReady(plugin, session)
    local ui = plugin.ui
    local identity = session.identity
    local previous = chapter_session
    local same_book = previous
        and previous.identity
        and previous.identity.source_id == identity.source_id
        and previous.identity.stable_id == identity.stable_id
    local chapter
    if same_book then
        ---@cast previous ReaderChapterSession
        chapter = previous
        cancelPrefetch()
        if chapter.request and chapter.request.cancel then chapter.request.cancel() end
        chapter.request = nil
        chapter.identity = identity
    else
        Chapter.clearActiveChapter(nil)
        chapter = {
            identity = identity,
            toc = Store.toc(identity, Store.TOC_MAX_AGE),
            switching = false,
        }
        chapter_session = chapter
    end

    local target = chapter.target
    local nav_target = target ~= nil and target.path == ui.document.file
    if target and not nav_target then
        chapter.target = nil
        chapter.switching = false
    end
    session.chapter = chapter
    closeTransitionNotice()
    applyChapterTarget(chapter, ui)
    wrapChapterReaderUi(ui, session)
    Snapshot.refresh(session)
    if not nav_target then
        require("book.progress").applyLocalPending(session)
        Snapshot.refresh(session)
    end
    return nav_target
end

---@param plugin table
---@param session ReaderSessionSnapshot
function Chapter.afterBootstrap(plugin, session)
    local chapter = session.chapter
    if not chapter then return end
    plugin:emitToSource("chapter_changed", {
        identity = session.identity,
        position = require("book.progress").position(session),
    }, session.identity.source)
    local identity = chapter.identity
    if not identity then return end
    local source = identity.source
    if not source then return end
    local toc_current = type(source.isTocCurrent) ~= "function" or source:isTocCurrent(chapter.toc)
    if toc_current and type(chapter.toc) == "table" and #chapter.toc > 0 then
        schedulePrefetch(chapter)
        return
    end
    local load_toc = toc_current and source.loadTocAsync or source.refreshTocAsync
    if type(load_toc) ~= "function" then return end
    chapter.toc_job = load_toc(source, identity, function(toc)
        chapter.toc_job = nil
        if chapter_session ~= chapter or session.chapter ~= chapter
            or type(toc) ~= "table" or #toc == 0 then
            return
        end
        chapter.toc = toc
        Snapshot.refresh(session)
        require("ui.reader").refresh(plugin)
        schedulePrefetch(chapter)
    end)
end

---@param session ReaderSessionSnapshot|nil
---@return boolean clear_conflicts 是否清除进度冲突记忆
function Chapter.onCloseDocument(session)
    if not (chapter_session and chapter_session.switching) then
        Chapter.clearActiveChapter(session)
        return true
    end
    return false
end

--- 切章失败：收起提示、报错并恢复预取。
---@param chapter ReaderChapterSession
---@param text string
local function failRequest(chapter, text)
    closeTransitionNotice()
    require("ui/uimanager"):show(require("ui/widget/infomessage"):new{ text = text })
    schedulePrefetch(chapter)
end

---@param chapter ReaderChapterSession
---@param idx integer
---@param opts { within: number|nil, direction: "prev"|"next"|nil, xpointer: string|nil }
local function requestChapter(chapter, idx, opts)
    cancelPrefetch()
    scheduleTransitionNotice(chapter)
    local identity = chapter.identity
    if not identity then return end
    local source = identity.source
    if not source then return end
    chapter.request = source:openBookAsync(identity, { chapter_idx = idx }, function(path, err)
        chapter.request = nil
        if chapter_session ~= chapter then return end
        if not path then
            failRequest(chapter, err or _("章节打开失败"))
            return
        end

        -- 目录跳转不带方向：一律落到章首；只有翻页越界（显式 prev）才回上一章尾部
        local within = opts.within
        local direction = within == nil and (opts.direction or "next") or nil
        chapter.target = {
            path = path,
            within = within,
            direction = direction,
            xpointer = opts.xpointer,
        }

        local ReaderUI = require("apps/reader/readerui")
        local UIManager = require("ui/uimanager")
        -- 原生打开会阻塞 UI；先绘制提示，不能指望计时器在渲染中执行。
        showTransitionNotice()
        UIManager:tickAfterNext(function()
            if chapter_session ~= chapter then return end
            chapter.switching = true
            local ok, switch_err = pcall(function()
                if ReaderUI.instance then
                    ReaderUI.instance:switchDocument(path, true)
                else
                    ReaderUI:showReader(path, nil, true)
                end
            end)
            if not ok and chapter_session == chapter then
                chapter.switching = false
                chapter.target = nil
                failRequest(chapter, tostring(switch_err or _("章节打开失败")))
            end
        end)
    end)
end

---@param session ReaderSessionSnapshot|nil
---@param idx integer
---@param opts { within: number|nil, direction: "prev"|"next"|nil, xpointer: string|nil }|nil
---@return boolean
function Chapter.gotoChapter(session, idx, opts)
    if not session then return false end
    local chapter = session.chapter
    local current_idx = session.identity.chapter_idx
    if not chapter or type(chapter.toc) ~= "table"
        or chapter.request or chapter.target or chapter.switching
        or idx < 1 or idx > #chapter.toc then
        return false
    end
    if current_idx and idx == current_idx then
        return false
    end
    requestChapter(chapter, idx, opts or {})
    return true
end

---@param session ReaderSessionSnapshot|nil
---@param delta integer
---@return boolean
function Chapter.onChapterBoundary(session, delta)
    if not session then return false end
    local chapter = session.chapter
    if not chapter or type(chapter.toc) ~= "table" then
        return false
    end
    if chapter.request or chapter.target or chapter.switching then
        return true
    end
    local current = tonumber(session.identity.chapter_idx)
    if not current then return false end
    local target = current + delta
    if target < 1 or target > #chapter.toc then return false end
    requestChapter(chapter, target, {
        direction = delta < 0 and "prev" or "next",
    })
    return true
end

return Chapter
