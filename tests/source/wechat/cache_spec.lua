local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Paths = require("utils.paths")
local Text = require("utils.text")

package.preload["json"] = function() return require("support.json_stub") end

local image_requests, text_requests = 0, 0
local image_fails = true
local hold_images, pending_image
local png = "\137PNG\r\n\026\n" .. string.rep("x", 32)
package.preload["source.wechat.auth"] = function()
    return {
        hasSession = function() return true end,
        webGetAsync = function(url, _, cb)
            image_requests = image_requests + 1
            Assert.eq(url, "https://cdn/missing.png")
            if hold_images then pending_image = cb
            elseif image_fails then cb(nil, "image unavailable") else cb(png) end
            return { cancel = function() end }
        end,
        webPostAsync = function(_, _, _, cb)
            text_requests = text_requests + 1
            cb(nil, "unexpected text download")
            return { cancel = function() end }
        end,
    }
end
package.preload["book.store"] = function()
    return { touch = function() return true end }
end
package.preload["ui/network/manager"] = function()
    return {
        runWhenConnected = function(_, cb) cb() end,
        isOnline = function() return false end,
        isConnected = function() return true end,
    }
end

local Chapter = require("source.chapter")
local WeRead = require("source.wechat.chapter")
local identity = { source_id = "wechat", stable_id = "cache-repair-regression" }
local toc = { { idx = 1, uid = "u1", title = "一", tar = "/unexpected-tar" } }
local path = Paths.chapterPath(identity.stable_id, 1, identity.source_id)
local html = '<!DOCTYPE html><html><body><p>Saved text</p><img src="images/existing.png"/>'
    .. '<img src="https://cdn/missing.png"/></body></html>'
local f = assert(io.open(path, "wb"))
f:write(html)
f:close()
local source = { loadTocAsync = function(_, _, cb) cb(toc) end }
local function fetch(identity_arg, chapter, cb)
    return WeRead.fetchContentAsync(identity_arg.stable_id, chapter, cb)
end
local result
local function cacheAll()
    result = nil
    Chapter.cacheAllAsync(source, identity, fetch, nil, function(ok, cached, err, total, failed)
        result = { ok = ok, cached = cached, err = err, total = total, failed = failed }
    end, 0)
    Stubs.flush()
    Assert.not_nil(result)
end

-- Image failure is partial, while the already saved text remains readable offline.
cacheAll()
Assert.is_false(result.ok)
Assert.eq(result.cached, 0)
Assert.eq(result.failed, 1)
Assert.eq(result.total, 1)
Assert.not_nil(result.err)
Assert.eq(text_requests, 0)
Assert.eq(image_requests, 1)
local opened
Chapter.openWithUi({}, identity, {}, { chapter_idx = 1 }, {}, function(p) opened = p end)
Stubs.flush()
Assert.eq(opened, path)
Assert.eq(image_requests, 1)

-- Retry localizes only missing images, without fetching text or the tar again.
image_fails = false
cacheAll()
Assert.is_true(result.ok)
Assert.eq(result.cached, 1)
Assert.eq(result.failed, 0)
Assert.eq(text_requests, 0)
Assert.eq(image_requests, 2)
f = assert(io.open(path, "rb"))
local repaired = f:read("*a")
f:close()
Assert.is_false(Text.hasRemoteImageSrc(repaired))
Assert.matches(repaired, "Saved text")
Assert.matches(repaired, 'src="images/existing%.png"')
Assert.matches(repaired, 'src="images/[0-9a-f]+%.png"')
local _, body_count = repaired:gsub("<body>", "")
Assert.eq(body_count, 1)
cacheAll()
Assert.eq(text_requests, 0)
Assert.eq(image_requests, 2)
-- Cached cleanup must not overwrite the image repair's in-progress .part file.
f = assert(io.open(path, "wb"))
f:write(html:gsub("<body>", "<head><title>Saved</title></head><body>"))
f:close()
hold_images = true
local overlapping_cache
Chapter.cacheAllAsync(source, identity, fetch, nil, function(ok) overlapping_cache = ok end, 0)
Assert.not_nil(pending_image)
pending_image(png)
local overlapping_reader
Chapter.openAsync({}, identity, {}, { chapter_idx = 1 }, {
    loadToc = function(_, cb) cb(toc) end,
    fetchContent = fetch,
    refreshCached = function(_, _, cached_path, cb) WeRead.refreshCached(cached_path, cb) end,
}, function(p) overlapping_reader = p end)
Stubs.flush()
Assert.eq(overlapping_reader, path)
Assert.is_true(overlapping_cache)
f = assert(io.open(path, "rb"))
Assert.is_false(Text.hasRemoteImageSrc(f:read("*a")))
f:close()
Assert.eq(text_requests, 0)
os.remove(path)
