--[[--
主体：时钟。无衬线时间 + 细分隔线 + 英文星期、日期、农历。

@module koplugin.book.ui.desktop.home.views.clock
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Myrl = require("online.myrl")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local GAP = 4
local SUB_H = 18
local DOW = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local clock_font_registered = false

---@class BookHomeClock : BookHomeComponent
---@field desktop BookDesktop|nil
---@field region table|nil
---@field time_widget table|nil
---@field weekday table|nil
---@field content_group table|nil
---@field calendar_group table|nil
---@field detail table|nil
---@field extra table|nil
---@field _tick fun()|nil
local M = {
    id = "clock",
    label = _("时钟"),
    icon = "schedule",
}
setmetatable(M, require("ui.desktop.home.views.base"))
M.__index = M

--- 时间 + 两行辅文的内容高度。
---@return number
function M.contentHeight()
    return UI.sz(36) + UI.sz(GAP) * 2 + UI.sz(SUB_H) * 2
end

--- 返回时钟内容高度；不吃剩余空间。
---@return BookHomeHeightSpec
function M:heightRange()
    return { height = M.contentHeight() }
end

--- 当前日期。
---@return string
local function dateLine()
    return os.date("%Y.%m.%d")
end

local function weekdayLine()
    return DOW[(tonumber(os.date("%w")) or 0) + 1]
end

--- 显示农历日期；缺失时显示占位符。
---@param data table|nil 日报数据，含 lunar 文字
---@return string
local function lunarLine(data)
    local lunar = data and data.lunar
    if type(lunar) == "string" and lunar ~= "" then
        return lunar
    end
    return "--"
end

--- 取消本实例保存的定时回调并清除句柄。
---@param self BookHomeClock 当前视图或布局实例
local function stopTick(self)
    if self._tick then UIManager:unschedule(self._tick) end
    self._tick = nil
end

--- 居中主行 + 两行辅文的同构排版（时钟、天气共用）。
--- 两行辅文控件写回 view.detail / view.extra，供 paint 原地 setText。
---@param view BookHomeComponent 已保存 ctx / opts 的组件实例
---@param hero table 主行控件
---@param detail string 第一行辅文
---@param extra string 第二行辅文
---@return table
function M.stack(view, hero, detail, extra)
    local opts = view.opts
    local w = opts.width
    local total_h = opts.height
    local gap = UI.sz(GAP)
    local sub_h = math.min(UI.sz(SUB_H), math.max(1, math.floor((total_h - UI.sz(36) - gap * 2) / 2)))
    local hero_h = math.max(1, total_h - sub_h * 2 - gap * 2)
    view.detail = TextWidget:new{
        text = detail,
        face = UI.face("xx_smallinfofont", 13),
        max_width = w,
        fgcolor = UI.muted(),
    }
    view.extra = TextWidget:new{
        text = extra,
        face = UI.face("xx_smallinfofont", 12),
        max_width = w,
        fgcolor = UI.dim(),
    }
    view.desktop = view.ctx.desktop
    view.region = Geom:new{ x = 0, y = opts.y or 0, w = w, h = total_h }
    return FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            dimen = Geom:new{ w = w, h = total_h },
            VerticalGroup:new{
                align = "center",
                CenterContainer:new{
                    dimen = Geom:new{ w = w, h = hero_h },
                    hero,
                },
                VerticalSpan:new{ width = gap },
                CenterContainer:new{
                    dimen = Geom:new{ w = w, h = sub_h },
                    view.detail,
                },
                VerticalSpan:new{ width = gap },
                CenterContainer:new{
                    dimen = Geom:new{ w = w, h = sub_h },
                    view.extra,
                },
            },
        }
end

--- 按指定宽高构建左右排版；时间天气的窄栏缩小时间与间距。
---@return table
function M:createWidget()
    if not clock_font_registered then
        local FontList = require("fontlist")
        FontList:getFontList()
        table.insert(FontList.fontlist, 1, UI.pluginRoot() .. "fonts/NotoSans-Light.ttf")
        clock_font_registered = true
    end
    local w, h = self.opts.width, self.opts.height
    local compact = w < UI.sz(300)
    local gap = UI.sz(compact and 12 or 20)
    local rule_w = UI.line()
    self.time_widget = TextWidget:new{
        text = os.date("%H:%M"),
        face = UI.face("NotoSans-Light.ttf", compact and 30 or 48),
        padding = 0,
        max_width = math.floor(w * 0.55),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local calendar_w = math.max(1, math.min(UI.sz(140), w - self.time_widget:getSize().w - gap * 2 - rule_w))
    self.weekday = TextWidget:new{
        text = weekdayLine(),
        face = UI.face("cfont", compact and 14 or 16),
        padding = 0,
        max_width = calendar_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    self.detail = TextWidget:new{
        text = dateLine(),
        face = UI.face("xx_smallinfofont", compact and 11 or 13),
        padding = 0,
        max_width = calendar_w,
        fgcolor = UI.muted(),
    }
    self.extra = TextWidget:new{
        text = lunarLine(self.data),
        face = UI.face("xx_smallinfofont", compact and 10 or 12),
        padding = 0,
        max_width = calendar_w,
        fgcolor = UI.dim(),
    }
    local row_h = UI.sz(18)
    self.calendar_group = VerticalGroup:new{
        align = "left",
        LeftContainer:new{ dimen = Geom:new{ w = self.weekday:getSize().w, h = UI.sz(23) }, self.weekday },
        VerticalSpan:new{ width = UI.sz(7) },
        LeftContainer:new{ dimen = Geom:new{ w = self.detail:getSize().w, h = row_h }, self.detail },
        VerticalSpan:new{ width = UI.sz(3) },
        LeftContainer:new{ dimen = Geom:new{ w = self.extra:getSize().w, h = row_h }, self.extra },
    }
    self.content_group = HorizontalGroup:new{
        align = "center",
        self.time_widget,
        HorizontalSpan:new{ width = gap },
        LineWidget:new{ dimen = Geom:new{ w = rule_w, h = UI.sz(66) }, background = UI.dim() },
        HorizontalSpan:new{ width = gap },
        self.calendar_group,
    }
    self.desktop = self.ctx.desktop
    self.region = Geom:new{ x = 0, y = self.opts.y or 0, w = w, h = h }
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        self.content_group,
    }
end

--- 更新当前时间、日期及农历文字；文字全未变时不刷新，墨水屏每次 dirty 都是一次真实刷新。
function M:paint()
    if not self.time_widget then return end
    local time, weekday, date, lunar = os.date("%H:%M"), weekdayLine(), dateLine(), lunarLine(self.data)
    if self.time_widget.text == time and self.weekday.text == weekday
        and self.detail.text == date and self.extra.text == lunar then return end
    self.time_widget:setText(time)
    self.weekday:setText(weekday)
    self.detail:setText(date)
    self.extra:setText(lunar)
    for _, i in ipairs({ 1, 3, 5 }) do
        local row = self.calendar_group[i]
        row.dimen.w = row[1]:getSize().w
    end
    self.calendar_group:resetLayout()
    self.content_group:resetLayout()
    self:dirty("content")
end

--- 取消旧计时回调，立即绘制一次后按下一分钟边界继续调度。
function M:tick()
    if not self.time_widget then return end
    stopTick(self)
    self._tick = function()
        if not self.lifecycle:uiReady() then return end
        self:paint()
        UIManager:scheduleIn(61 - tonumber(os.date("%S")), self._tick)
    end
    self._tick()
end

--- 异步读取日报中的农历和节日数据，失败时保留原数据。
---@param done fun(data:any, err:any) 数据加载回调；失败回退旧数据时仍按成功交付
---@return table|nil request 在线接口返回的取消句柄；同步缓存命中可能无句柄
function M:loadData(done)
    return Myrl:fetch({}, function(data, err)
        done(not err and data or self.data)
    end)
end

--- 仅在 Resume 阶段发起数据加载；数据变化后更新内容，取消的旧回调不再改写视图。
function M:pull()
    if not self.lifecycle:uiReady() then return end
    local previous = self.data
    self:load(function(ok)
        if ok and self.data ~= previous then
            self:paint()
        end
    end)
end

--- 启动分钟计时器（立即绘制一次）并拉取农历。
function M:onResume()
    self:tick()
    self:pull()
end

--- 取消分钟计时器，保留已有显示数据。
function M:onPause()
    stopTick(self)
end

--- 取消计时器并清除文字控件及桌面引用。
function M:onDestroy()
    stopTick(self)
    self.time_widget = nil
    self.weekday = nil
    self.content_group = nil
    self.calendar_group = nil
    self.detail = nil
    self.extra = nil
    self.region = nil
    self.desktop = nil
end

return M
