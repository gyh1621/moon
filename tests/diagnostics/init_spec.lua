local Assert = require("support.assert")
local root = require("support.config").dir()
local token = "github_pat_testfixture"
local ticks, requests, snapshots, callbacks = {}, {}, 0, {}
local flushed, accumulated, live, fail_worker = 0, 0, true, false
local decoded = {}
local cfg = { github_issue_token = token }
package.preload["datastorage"] = function() return {
    getFullDataDir = function() return root end,
    getSettingsDir = function() return root .. "/settings" end,
} end
local function write(path, value)
    local file = assert(io.open(path, "wb")); file:write(value); file:close()
end
local function drain()
    while #ticks > 0 do local fn = table.remove(ticks, 1); fn() end
end
local function reply(index, code, value)
    local key = "response-" .. index
    decoded[key] = value
    requests[index].cb({ code = code, body = key })
    drain()
end
package.preload["utils.settings"] = function() return { get = function() return cfg end } end
package.preload["utils.paths"] = function() return { logPath = function() return root .. "/.moon/book.log" end } end
package.preload["utils.log"] = function() return { flush = function() flushed = flushed + 1 end } end
package.preload["ui/uimanager"] = function() return { nextTick = function(_, fn) ticks[#ticks + 1] = fn end } end
package.preload["json"] = function() return {
    decode = function(value) if not decoded[value] then error("malformed JSON") end; return decoded[value] end,
    encode = function(value) return value end,
} end
package.preload["http.request"] = function() return { request = function(opts, cb)
    local request = { opts = opts, cb = cb }
    requests[#requests + 1] = request
    return { cancel = function() request.cancelled = true end }
end } end
package.preload["workers.job"] = function() return { run = function(worker, opts)
    snapshots = snapshots + 1
    Assert.eq(opts.kind, "light")
    if fail_worker then opts.on_failed("sensitive worker exception") else opts.on_done(worker()) end
    return { cancel = function() end }
end } end
package.preload["bookversion"] = function() return "0.0.0-dev" end
package.preload["version"] = function() return { getCurrentRevision = function() return "v2026.07.1" end } end
package.preload["device"] = function() return { model = "fixture", getPowerDevice = function() return {
    getCapacityHW = function() return 63 end, isCharging = function() return false end,
} end } end
package.preload["pluginloader"] = function() return { getPluginInstance = function()
    if not live then return nil end
    return {
        stat = function() return {
            accumulate = function() accumulated = accumulated + 1 end,
            dump = function() return { { "Awake since last charge", "" }, { "Change per hour:", "2.00%" },
                { "Sleeping since last charge", "" }, { "Estimated remaining time:", "80:00" } } end,
        } end,
        onFlushSettings = function() write(root .. "/settings/battery_stats.lua", "return { awake = { percentage = 8, time = 14400000000 } }") end,
    }
end } end
local Diagnostics = require("diagnostics")
local function upload()
    return Diagnostics.upload(function(issue, err) callbacks[#callbacks + 1] = { issue = issue, err = err } end)
end
local private = { full_name = Diagnostics.repository, private = true, has_issues = true }

-- No token, no request. Public/unknown/disabled repositories are rejected before collection.
cfg.github_issue_token = ""
upload()
Assert.len(requests, 0)
Assert.matches(callbacks[1].err, "GitHub")
cfg.github_issue_token = token
for _, repo in ipairs({
    { full_name = Diagnostics.repository, private = false, has_issues = true },
    { full_name = "other/repo", private = true, has_issues = true },
    { full_name = Diagnostics.repository, has_issues = true },
    { full_name = Diagnostics.repository, private = true, has_issues = false },
}) do upload(); reply(#requests, 200, repo); Assert.eq(snapshots, 0) end
upload(); reply(#requests, 401, {})
Assert.eq(snapshots, 0)
Assert.matches(callbacks[#callbacks].err, "GitHub")
upload(); reply(#requests, 200, "not an object")
Assert.eq(snapshots, 0)

-- Actual bounded files, redaction and the loaded Battery Statistics report.
write(root .. "/crash.log", "OLD-MARKER" .. string.rep("月", 6000) .. "\n" .. token .. " ghp_secretfixture ```\nTAIL-MARKER")
write(root .. "/.moon/book.log", "moon fixture github_pat_anotherfixture")
upload()
local get_index = #requests
Assert.eq(requests[get_index].opts.url, "https://api.github.com/repos/gyh1621/moon-diagnostics")
Assert.eq(requests[get_index].opts.headers.Authorization, "Bearer " .. token)
Assert.is_nil(requests[get_index].opts.cache_ttl)
reply(get_index, 200, private)
Assert.eq(accumulated, 1)
Assert.eq(flushed, 1)
local post = requests[#requests].opts
Assert.eq(post.method, "POST")
Assert.eq(post.headers["Content-Type"], "application/json")
local body = post.body.body
Assert.matches(body, "Battery Statistics")
Assert.matches(body, "Sleeping since last charge")
Assert.matches(body, "2%.00%%")
Assert.matches(body, "14400000000")
Assert.matches(body, "63%%; charging: false")
Assert.matches(body, "TAIL%-MARKER")
Assert.is_false(body:find("OLD-MARKER", 1, true))
Assert.is_false(body:find(token, 1, true))
Assert.is_false(body:find("ghp_secretfixture", 1, true))
Assert.is_false(body:find("github_pat_anotherfixture", 1, true))
Assert.matches(body, "%[REDACTED%]")
Assert.is_true(require("utils.text").isValidUtf8(body))
Assert.is_true(#body < 50000)
local issue = { number = 42, html_url = "https://github.com/gyh1621/moon-diagnostics/issues/42" }
reply(#requests, 201, issue)
Assert.eq(callbacks[#callbacks].issue, issue)

-- Battery-only reports work; no logs/counters prevents POST when the plugin is disabled.
os.remove(root .. "/crash.log"); os.remove(root .. "/.moon/book.log")
upload(); reply(#requests, 200, private)
Assert.eq(requests[#requests].opts.method, "POST")
Assert.matches(requests[#requests].opts.body.body, "Unavailable")
reply(#requests, 500, {})
Assert.matches(callbacks[#callbacks].err, "重复")
live = false
os.remove(root .. "/settings/battery_stats.lua")
upload(); local missing_index = #requests; reply(missing_index, 200, private)
Assert.len(requests, missing_index)
Assert.matches(callbacks[#callbacks].err, "电池统计")

-- Saved counters survive a disabled plugin; invalid bytes are represented losslessly.
write(root .. "/settings/battery_stats.lua", "return { sleeping = { percentage = 3 } }")
write(root .. "/crash.log", "\255\254failure")
upload(); reply(#requests, 200, private)
Assert.matches(requests[#requests].opts.body.body, "disabled or unavailable")
Assert.matches(requests[#requests].opts.body.body, "base64")
reply(#requests, 201, { number = 42, html_url = "https://evil.example/42" })
Assert.is_nil(callbacks[#callbacks].issue)

-- Cancellation discards late callbacks and never proceeds to snapshot/POST.
local before = snapshots
local handle = upload()
local cancelled_index = #requests
handle:cancel(); handle:cancel()
local count = #callbacks
reply(cancelled_index, 200, private)
Assert.eq(snapshots, before)
Assert.len(callbacks, count)
Assert.is_true(requests[cancelled_index].cancelled)
fail_worker = true
upload(); reply(#requests, 200, private)
Assert.is_false(callbacks[#callbacks].err:find("sensitive", 1, true))
os.remove(root .. "/crash.log"); os.remove(root .. "/settings/battery_stats.lua")
return true
