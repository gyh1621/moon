--[[--
首页时钟：大时间 + 日期 + 农历；自己拉 myrl。

@module tests.ui.desktop.home.clock_spec
--]]

local Assert = require("support.assert")
local scheduled = {}
local paints = 0
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, delay, fn) scheduled[fn] = delay end,
        unschedule = function(_, fn) scheduled[fn] = nil end,
        setDirty = function() paints = paints + 1 end,
    }
end

package.preload["gettext"] = function()
    return function(s) return s end
end
package.preload["fontlist"] = function()
    return { fontlist = {}, getFontList = function() end }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0 }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts)
        opts.getSize = function(self) return self.dimen or { w = self.width or 0, h = self.height or 0 } end
        return opts
    end }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        face = function() end,
        line = function() return 1 end,
        pluginRoot = function() return "book.koplugin/" end,
        muted = function() return 1 end,
        dim = function() return 2 end,
    }
end
local function containerStub()
    return { new = function(_, opts)
        opts.getSize = function(self) return self.dimen or { w = self.width or 0, h = self.height or 0 } end
        opts.resetLayout = function() end
        return opts
    end }
end
package.preload["ui/widget/container/centercontainer"] = containerStub
package.preload["ui/widget/container/framecontainer"] = containerStub
package.preload["ui/widget/verticalgroup"] = containerStub
package.preload["ui/widget/verticalspan"] = containerStub
package.preload["ui/widget/horizontalgroup"] = containerStub
package.preload["ui/widget/horizontalspan"] = containerStub
package.preload["ui/widget/container/leftcontainer"] = containerStub
package.preload["ui/widget/linewidget"] = containerStub

local text_widgets = {}
package.preload["ui/widget/textwidget"] = function()
    return {
        new = function(_, opts)
            local widget = { text = opts.text }
            function widget:setText(text) self.text = text end
            function widget:getSize() return { w = 100, h = 40 } end
            text_widgets[#text_widgets + 1] = widget
            return widget
        end,
    }
end

local myrl_cb
package.preload["online.myrl"] = function()
    return {
        fetch = function(_, _, cb)
            myrl_cb = cb
            return { cancel = function() end }
        end,
    }
end

local old_date = os.date
local now = { time = "10:20", sec = "20", day = "2026-09-10", w = "4" }
os.date = function(format)
    if format == "%H:%M" then return now.time end
    if format == "%S" then return now.sec end
    if format == "%Y.%m.%d" then return (now.day:gsub("-", ".")) end
    if format == "%w" then return now.w end
    return old_date(format)
end

local Clock = require("ui.desktop.home.views.clock")
local clock = Clock:new()
clock.lifecycle.state = "Resume"
clock:build({ desktop = {} }, { width = 320, height = 96, y = 10 })
Assert.eq(text_widgets[1].text, "10:20")
Assert.eq(text_widgets[2].text, "Thursday")
Assert.eq(text_widgets[3].text, "2026.09.10")
Assert.eq(text_widgets[4].text, "--")
Assert.is_nil(myrl_cb, "build must not fetch")
clock:onResume()
Assert.not_nil(myrl_cb)
myrl_cb({ lunar = "农历七月廿八", holiday = "中秋" })
Assert.eq(text_widgets[4].text, "农历七月廿八")
Assert.is_true(paints >= 1)

-- 同一分钟再次 Resume、缓存返回同内容新表：都不得重复刷新。
local same = paints
clock:onResume()
myrl_cb({ lunar = "农历七月廿八", holiday = "中秋" })
Assert.eq(paints, same)
myrl_cb({ lunar = "农历七月廿八", holiday = "今天是国庆节" })
Assert.eq(paints, same, "holiday changes must not refresh the clock")

now.time = "10:21"
local before = paints
clock:onResume()
Assert.eq(text_widgets[1].text, "10:21")
Assert.is_true(paints > before)
now.time, now.day, now.w = "00:00", "2026-09-11", "5"
clock:paint()
Assert.eq(text_widgets[1].text, "00:00")
Assert.eq(text_widgets[2].text, "Friday")
Assert.eq(text_widgets[3].text, "2026.09.11")
for day, name in ipairs({ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }) do
    now.w = tostring(day - 1)
    clock:paint()
    Assert.eq(clock.weekday.text, name, "weekdays must use full English names")
end
for _, data in ipairs({ {}, { holiday = "今天是国庆节" }, { lunar = "" }, { lunar = false } }) do
    clock.data = data
    clock:paint()
    Assert.eq(clock.extra.text, "--", "missing lunar date must not fall back to a holiday")
end
Assert.not_nil(scheduled[clock._tick])
local tick = clock._tick
clock:onResume()
Assert.is_nil(scheduled[tick])
tick = clock._tick
clock:onPause()
Assert.is_nil(scheduled[tick])
clock:onResume()
Assert.not_nil(clock._tick, "暂停后可以直接恢复")
tick = clock._tick
clock:onPause()
clock:onDestroy()
Assert.is_nil(scheduled[tick])
Assert.is_nil(clock.time_widget)

os.date = old_date
return true
