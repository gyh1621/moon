local Assert = require("support.assert")
require("util").getFriendlySize = function(bytes) return tostring(bytes) .. " B" end
package.preload["ui.desktop.settings.overlay"] = function()
    return { extend = function(_, opts) return opts end }
end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, opts) return opts end }
end
local Tasks = require("tasks")
local Manager = require("ui.desktop.cache_manager")
local queued = Tasks.enqueue{
    key = "manager-spec", lane = "cache", label = "Cache", title = "Downloading book",
    restartable = true,
    run = function(report) report(nil, 2, 10); return { cancel = function() end } end,
}
local sections = Manager.sections({ entries = {
    { title = "Partial book", total = 10, available = 4, pending_images = 1, bytes = 100 },
} })
local job = sections[2].rows[1](600)
Assert.eq(job.title, "Downloading book")
Assert.eq(job.status, "2/10")
local book = sections[3].rows[1](600)
Assert.eq(book.title, "Partial book")
Assert.is_true(book.subtitle:find("4/10", 1, true) ~= nil)
Assert.is_true(book.subtitle:find("1", 1, true) ~= nil)
queued.cancel()
sections = Manager.sections({ entries = {} })
Assert.eq(sections[2].rows[1](600).title, "当前没有后台任务")
Assert.eq(sections[3].rows[1](600).title, "当前没有书籍缓存")
sections = Manager.sections({ entries = {}, error = "internal Lua traceback" })
Assert.eq(sections[1].rows[2](600).subtitle, "点击重试，缓存文件不会被修改")
