--[[--
拷贝漫画离线打开：已有 CBZ 时不触发目录/详情/下载。

@module tests.source.copymanga.open_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local calls = 0
local touched
local detail_callback
local cancelled = 0
local progress_shown, progress_closed = 0, 0

local function stub(name, factory)
    package.preload[name] = factory
    package.loaded[name] = nil
end

stub("gettext", function()
    return function(value) return value end
end)
stub("source.base", function() return {} end)
stub("source.copymanga.mapper", function() return {} end)
stub("source.copymanga.toc", function() return { read = function() return nil end } end)
stub("utils.settings", function()
    return { getSource = function() return {} end }
end)
stub("source.copymanga.client", function()
    return {
        new = function()
            return setmetatable({ detailAsync = function(_, _, cb)
                calls = calls + 1
                detail_callback = cb
                return { cancel = function() cancelled = cancelled + 1 end }
            end }, {
                __index = function()
                    return function()
                        calls = calls + 1
                        error("network path reached")
                    end
                end,
            })
        end,
    }
end)
stub("ui/network/manager", function()
    return {
        isOnline = function() error("blocking availability DNS reached") end,
        runWhenOnline = function() error("blocking availability DNS reached") end,
        runWhenConnected = function(_, cb) cb() end,
    }
end)
stub("ui/widget/progressbardialog", function()
    return { new = function()
        return {
            show = function() progress_shown = progress_shown + 1 end,
            close = function() progress_closed = progress_closed + 1 end,
        }
    end }
end)
stub("utils.paths", function()
    return {
        bookWorkDir = function() return "/offline-cache/comic" end,
    }
end)
stub("libs/libkoreader-lfs", function()
    return {
        attributes = function(path)
            if path == "/offline-cache/comic/2.cbz" then
                return { mode = "file", size = 42 }
            end
            return nil
        end,
    }
end)
stub("db.book", function()
    return { get = function() return nil end }
end)
stub("db.progress", function()
    return { get = function() return nil end }
end)
stub("ui/uimanager", function()
    return {
        nextTick = function(_, fn) Stubs.flush(); fn() end,
    }
end)
stub("book.store", function()
    return {
        touch = function(path, identity, opts)
            touched = { path = path, identity = identity, opts = opts }
            return true
        end,
    }
end)

package.loaded["source.copymanga"] = nil
local Copymanga = require("source.copymanga")
local source = Copymanga.new()
local identity = {
    source_id = "copymanga",
    stable_id = "comic",
    book = {},
}

local result, err
source:openBookAsync(identity, { chapter_idx = 2 }, function(path, open_err)
    result, err = path, open_err
end)

Assert.eq(calls, 0)
Assert.eq(result, "/offline-cache/comic/2.cbz")
Assert.is_nil(err)
Assert.eq(touched.path, result)
Assert.eq(touched.opts.chapter_idx, 2)

-- 未缓存章节直接进入异步请求；网络失败仍关闭准备框并交付原错误。
result, err = nil, nil
source:openBookAsync(identity, { chapter_idx = 1 }, function(path, open_err)
    result, err = path, open_err
end)
Assert.eq(calls, 1)
Assert.eq(progress_shown, 1)
Assert.is_nil(err)
detail_callback(nil, "DNS lookup failed")
Assert.is_nil(result)
Assert.eq(err, "DNS lookup failed")
Assert.eq(progress_closed, 1)

-- 取消保留当前请求取消能力，迟到失败不能再次交付结果。
local delivered = false
local job = source:openBookAsync(identity, { chapter_idx = 1 }, function() delivered = true end)
job.cancel()
Assert.eq(cancelled, 1)
detail_callback(nil, "late error")
Assert.is_false(delivered)
Assert.eq(progress_closed, 2)
