require("l10n").apply()

local Diagnostics = require("diagnostics")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local SettingRow = require("ui.components.settingrow")
local Settings = require("utils.settings")
local Text = require("utils.text")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local DiagnosticsUI = {}

function DiagnosticsUI:rows(desktop)
    return {
        function(width)
            local configured = Settings.get("diagnostics").github_issue_token ~= ""
            return SettingRow.build(width, {
                kind = "nav", icon = "key", title = _("GitHub 令牌"),
                status = configured and "******" or _("未设置"), status_on = configured,
                subtitle = _("仅私有诊断仓库：Issues 写入权限"),
                callback = function()
                    local cfg = Settings.get("diagnostics")
                    local dialog
                    dialog = InputDialog:new{
                        title = _("GitHub 令牌"), input = cfg.github_issue_token,
                        input_hint = "github_pat_…", text_type = "password",
                        buttons = {{
                            { text = _("取消"), id = "close", callback = function() UIManager:close(dialog) end },
                            { text = _("保存"), is_enter_default = true, callback = function()
                                cfg.github_issue_token = Text.stripWhitespace(dialog:getInputText())
                                Settings.saveSection("diagnostics", cfg)
                                UIManager:close(dialog)
                                desktop:updateView()
                            end },
                        }},
                    }
                    UIManager:show(dialog)
                    dialog:onShowKeyboard()
                end,
            })
        end,
        function(width)
            return SettingRow.build(width, {
                kind = "action", icon = "upload", title = _("上传诊断报告"),
                subtitle = _("日志与电池统计 → 私有 GitHub Issue"),
                callback = function()
                    if desktop._diagnostics_sending then return end
                    desktop._diagnostics_sending = true
                    local loading = InfoMessage:new{ text = _("正在上传诊断报告…") }
                    UIManager:show(loading)
                    Diagnostics.upload(function(issue, err)
                        desktop._diagnostics_sending = false
                        UIManager:close(loading)
                        if desktop.lifecycle.state == "Destroy" then return end
                        UIManager:show(InfoMessage:new{
                            text = issue and T(_("已上传到私有问题 #%1"), issue.number) .. "\n\n" .. issue.html_url or err,
                        })
                    end)
                end,
            })
        end,
    }
end

return DiagnosticsUI
