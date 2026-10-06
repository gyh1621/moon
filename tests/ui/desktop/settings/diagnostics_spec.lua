local Assert = require("support.assert")
local shown, closed, calls, updated, saved = {}, {}, {}, 0, nil
local cfg = { github_issue_token = "" }
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["ui/widget/infomessage"] = function() return { new = function(_, opts) return opts end } end
package.preload["ui/widget/inputdialog"] = function() return { new = function(_, opts)
    opts.onShowKeyboard = function() end
    opts.getInputText = function() return "  github_pat_ fixture\n" end
    return opts
end } end
package.preload["ui/uimanager"] = function() return {
    show = function(_, widget) shown[#shown + 1] = widget end,
    close = function(_, widget) closed[#closed + 1] = widget end,
} end
package.preload["ui.components.settingrow"] = function() return { build = function(_, opts) return opts end } end
package.preload["utils.settings"] = function() return {
    get = function() return cfg end, saveSection = function(section) saved = section end,
} end
package.preload["diagnostics.init"] = function() return { upload = function(cb) calls[#calls + 1] = cb end } end
local desktop = { lifecycle = { state = "Resume" }, updateView = function() updated = updated + 1 end }
local UI = require("ui.desktop.settings.diagnostics")
local rows = UI:rows(desktop)
Assert.len(rows, 2)
local key = rows[1](600)
Assert.eq(key.status, "未设置")
key.callback()
local dialog = shown[#shown]
Assert.eq(dialog.text_type, "password")
dialog.buttons[1][2].callback()
Assert.eq(cfg.github_issue_token, "github_pat_fixture")
Assert.eq(saved, "diagnostics")
Assert.eq(updated, 1)
Assert.eq(rows[1](600).status, "******")
local upload = rows[2](600)
upload.callback()
Assert.len(calls, 1)
Assert.eq(shown[#shown].text, "正在上传诊断报告…")
Assert.is_nil(shown[#shown].timeout)
UI:rows(desktop)[2](600).callback()
Assert.len(calls, 1)
calls[1]({ number = 42, html_url = "https://github.com/gyh1621/moon-diagnostics/issues/42" })
Assert.matches(shown[#shown].text, "#42")
Assert.len(closed, 2)
Assert.is_false(desktop._diagnostics_sending)
upload.callback(); calls[2](nil, "fixture error")
Assert.eq(shown[#shown].text, "fixture error")
desktop.lifecycle.state = "Destroy"
upload.callback(); local count = #shown; calls[3](nil, "late error")
Assert.len(shown, count)
return true
