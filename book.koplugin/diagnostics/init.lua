local DataStorage = require("datastorage")
local Device = require("device")
local JSON = require("json")
local Job = require("workers.job")
local Log = require("utils.log")
local Paths = require("utils.paths")
local Request = require("http.request")
local Settings = require("utils.settings")
local Text = require("utils.text")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Diagnostics = { repository = "gyh1621/moon-diagnostics" }
local API = "https://api.github.com/repos/" .. Diagnostics.repository
local LOG_LIMIT = 12 * 1024
local BATTERY_LIMIT = 4 * 1024

local function scrub(value, token)
    return (value:gsub(token:gsub("(%W)", "%%%1"), "[REDACTED]")
        :gsub("github_pat_[%w_]+", "[REDACTED]"):gsub("gh[pousr]_[%w]+", "[REDACTED]"))
end

local function fileSection(path, title, limit, token, tail)
    local file = io.open(path, "rb")
    if not file then return "## " .. title .. "\nUnavailable (missing or unreadable).", false end
    local size = file:seek("end")
    file:seek("set", tail and math.max(0, size - limit) or 0)
    local content = file:read(limit) or ""
    file:close()
    if content == "" then return "## " .. title .. "\nEmpty.", false end
    content = scrub(content, token)
    -- A byte-bounded tail may start inside a UTF-8 character.
    if tail and size > limit then content = content:gsub("^[\128-\191]+", "") end
    local encoding = "text"
    if not Text.isValidUtf8(content) then
        content = Text.base64Encode(content)
        encoding = "base64 (original bytes)"
    end
    local fence = "```"
    for run in content:gmatch("`+") do
        if #run >= #fence then fence = string.rep("`", #run + 1) end
    end
    local note = size > limit and (tail and "Latest " or "First ") .. limit .. " bytes; truncated.\n" or ""
    return "## " .. title .. "\n" .. note .. "Encoding: " .. encoding .. "\n\n"
        .. fence .. "\n" .. content .. "\n" .. fence, true
end

local function batteryReport()
    local plugin = require("pluginloader"):getPluginInstance("batterystat")
    if not plugin or type(plugin.stat) ~= "function" then
        return "## Battery Statistics\nLive report unavailable: KOReader's battery statistics plugin is disabled or unavailable.", false
    end
    -- Use the already-loaded singleton; loading main.lua again would restart its counters.
    local stat = plugin:stat()
    stat:accumulate()
    local rows = stat:dump()
    plugin:onFlushSettings()
    local lines = { "## Battery Statistics" }
    for _, row in ipairs(rows) do
        lines[#lines + 1] = row[2] == "" and ("\n### " .. row[1]) or (row[1] .. " " .. tostring(row[2]) .. "  ")
    end
    return table.concat(lines, "\n"), true
end

local function decode(response)
    if not response or type(response.body) ~= "string" then return nil end
    local ok, value = pcall(JSON.decode, response.body)
    return ok and type(value) == "table" and value or nil
end

local function requestError(response, posting)
    if response and (response.code == 401 or response.code == 403 or response.code == 404) then
        return _("GitHub 拒绝访问。请检查令牌有效期和私有仓库的 Issues 写入权限。")
    end
    return posting and _("上传未确认，请先检查私有仓库，避免重复创建问题。")
        or _("无法确认私有仓库，请检查网络后重试。")
end

function Diagnostics.upload(callback)
    local token = Text.stripWhitespace(Settings.get("diagnostics").github_issue_token)
    local finished, active = false, nil
    local function finish(issue, err)
        if finished then return end
        finished = true
        callback(issue, err)
    end
    local handle = { cancel = function()
        if finished then return end
        finished = true
        if active then active:cancel() end
        callback(nil, _("上传已取消。"))
    end }
    if token == "" then
        finish(nil, _("请先设置 GitHub 令牌。"))
        return handle
    end
    local headers = {
        Authorization = "Bearer " .. token,
        Accept = "application/vnd.github+json",
        ["X-GitHub-Api-Version"] = "2026-03-10",
    }
    active = Request.request({ url = API, headers = headers }, function(response)
        if finished then return end
        local repo = decode(response)
        if not response or response.code ~= 200 then
            finish(nil, requestError(response, false))
            return
        end
        if not repo or repo.full_name ~= Diagnostics.repository or repo.private ~= true or repo.has_issues ~= true then
            finish(nil, _("目标仓库必须为私有且启用 Issues，已停止上传。"))
            return
        end
        Log.flush()
        -- Two ticks also allow an already-pending flush to drain its queued batch.
        UIManager:nextTick(function() UIManager:nextTick(function()
            if finished then return end
            local ok, battery, live = pcall(batteryReport)
            if not ok then battery, live = "## Battery Statistics\nLive report could not be captured; saved counters follow.", false end
            local power = Device:getPowerDevice()
            local metadata = string.format("Moon: %s\nKOReader: %s\nDevice: %s\nUTC: %s\nBattery: %s%%; charging: %s\n",
                require("bookversion"), require("version"):getCurrentRevision() or "unknown", Device.model or "unknown",
                os.date("!%Y-%m-%dT%H:%M:%SZ"), tostring(power:getCapacityHW()), tostring(power:isCharging()))
            active = Job.run(function()
                local crash, has_crash = fileSection(DataStorage:getFullDataDir() .. "/crash.log", "crash.log", LOG_LIMIT, token, true)
                local moon, has_moon = fileSection(Paths.logPath(), ".moon/book.log", LOG_LIMIT, token, true)
                local saved, has_saved = fileSection(DataStorage:getSettingsDir() .. "/battery_stats.lua", "settings/battery_stats.lua", BATTERY_LIMIT, token, false)
                return { available = live or has_crash or has_moon or has_saved,
                    body = scrub(table.concat({ "# Moon diagnostic report", metadata, battery, saved, crash, moon }, "\n\n"), token) }
            end, {
                name = "diagnostic-snapshot", kind = "light", timeout = 30,
                on_failed = function() finish(nil, _("无法读取诊断报告，请重试。")) end,
                on_done = function(report)
                    UIManager:nextTick(function()
                        if finished then return end
                        if not report.available then finish(nil, _("没有可上传的日志或电池统计。")); return end
                        local post_headers = {}
                        for key, value in pairs(headers) do post_headers[key] = value end
                        post_headers["Content-Type"] = "application/json"
                        active = Request.request({ url = API .. "/issues", method = "POST", headers = post_headers,
                            body = JSON.encode({ title = "Moon diagnostics " .. os.date("!%Y-%m-%d %H:%M:%S UTC"), body = report.body }),
                        }, function(created)
                            if finished then return end
                            local issue = decode(created)
                            if created and created.code == 201 and issue and type(issue.number) == "number"
                                and issue.html_url == "https://github.com/" .. Diagnostics.repository .. "/issues/" .. issue.number then
                                finish(issue)
                            else
                                finish(nil, requestError(created, true))
                            end
                        end)
                    end)
                end,
            })
        end) end)
    end)
    return handle
end

return Diagnostics
