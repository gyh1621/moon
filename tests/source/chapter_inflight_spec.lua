local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Paths = require("utils.paths")

package.preload["book.store"] = function()
    return { touch = function() return true end }
end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, cb) cb() end }
end
local Chapter = require("source.chapter")
local identity = { source_id = "wechat", stable_id = "inflight-regression" }
local toc = { { idx = 1, title = "One" } }
local path = Paths.chapterPath(identity.stable_id, 1, identity.source_id)
os.remove(path)
local calls, cancellations, callbacks = 0, 0, {}
local function fetch(_, _, cb)
    calls = calls + 1
    callbacks[calls] = cb
    return { cancel = function() cancellations = cancellations + 1 end }
end
local ops = { loadToc = function(_, cb) cb(toc) end, fetchContent = fetch }
local source = { loadTocAsync = function(_, _, cb) cb(toc) end }
local cache_ok, opened
local cache = Chapter.cacheAllAsync(source, identity, fetch, nil, function(ok) cache_ok = ok end, 0)
Chapter.openAsync({}, identity, {}, { chapter_idx = 1 }, ops, function(p) opened = p end)
Assert.eq(calls, 1, "full cache and reading share the chapter request")
callbacks[1]({ title = "One", text = "Shared text" })
Stubs.flush()
Assert.eq(opened, path)
Assert.is_true(cache_ok)
local file = assert(io.open(path, "rb"))
Assert.matches(file:read("*a"), "Shared text")
file:close()
os.remove(path)

-- Stopping a whole-book cache cancels its request even if the TOC completed synchronously.
cache = Chapter.cacheAllAsync(source, identity, fetch, nil, function()
    error("cancelled cache delivered a result")
end, 0)
Assert.eq(calls, 2)
cache.cancel()
Assert.eq(cancellations, 1)
callbacks[2]({ text = "Late cancelled text" })
Stubs.flush()
Assert.is_nil(io.open(path, "rb"))

-- Cancelling either subscriber leaves the other one's download alive.
for _, cancel_reader in ipairs({ false, true }) do
    os.remove(path)
    local base_calls, base_cancellations = calls, cancellations
    local cache_result, reader_result
    cache = Chapter.cacheAllAsync(source, identity, fetch, nil, function(ok) cache_result = ok end, 0)
    local reader = Chapter.openAsync({}, identity, {}, { chapter_idx = 1 }, ops,
        function(p) reader_result = p end)
    Assert.eq(calls, base_calls + 1)
    if cancel_reader then reader.cancel() else cache.cancel() end
    Assert.eq(cancellations, base_cancellations)
    callbacks[calls]({ text = "Remaining subscriber" })
    Stubs.flush()
    if cancel_reader then
        Assert.is_true(cache_result)
        Assert.is_nil(reader_result)
    else
        Assert.eq(reader_result, path)
        Assert.is_nil(cache_result)
    end
end
os.remove(path)

-- Last cancellation frees the slot; an old callback cannot overwrite a later generation.
local first_result, second_result
local first = Chapter.prefetchAsync(identity, {}, toc, 0, 1, ops,
    function() first_result = true end)
local old_callback = callbacks[calls]
local base_cancellations = cancellations
first.cancel()
Assert.eq(cancellations, base_cancellations + 1)
Chapter.openAsync({}, identity, {}, { chapter_idx = 1 }, ops, function(p) second_result = p end)
old_callback({ text = "Obsolete text" })
Assert.is_nil(second_result)
callbacks[calls]({ text = "Current text" })
Stubs.flush()
Assert.is_nil(first_result)
Assert.eq(second_result, path)
local file = assert(io.open(path, "rb"))
Assert.matches(file:read("*a"), "Current text")
file:close()
os.remove(path)

-- A reader joining during the yielded file write shares that write too.
local prefetch_result, write_join_result
Chapter.prefetchAsync(identity, {}, toc, 0, 1, ops, function(cached) prefetch_result = cached end)
callbacks[calls]({ text = "Writing text" })
local base_calls = calls
Chapter.openAsync({}, identity, {}, { chapter_idx = 1 }, ops, function(p) write_join_result = p end)
Assert.eq(calls, base_calls)
Assert.is_nil(write_join_result)
Stubs.flush()
Assert.eq(write_join_result, path)
Assert.eq(prefetch_result, 1)
os.remove(path)

-- Synchronous fetch callbacks must leave the yielded writer cancellable.
local synchronous_ops = { fetchContent = function(_, _, cb) cb({ text = "Cancelled write" }) end }
local writing = Chapter.prefetchAsync(identity, {}, toc, 0, 1, synchronous_ops,
    function() error("cancelled writer delivered a result") end)
writing.cancel()
Stubs.flush()
Assert.is_nil(io.open(path, "rb"))
Assert.is_nil(io.open(path .. ".part", "rb"))

-- Failure fans out once and does not prevent retrying the same chapter.
local cache_error, reader_error
Chapter.prefetchAsync(identity, {}, toc, 0, 1, ops, function(cached, _, failed, err)
    Assert.eq(cached, 0)
    Assert.eq(failed, 1)
    cache_error = err
end)
Chapter.openAsync({}, identity, {}, { chapter_idx = 1 }, ops, function(_, err) reader_error = err end)
callbacks[calls](nil, "download failed")
Stubs.flush()
Assert.eq(cache_error, "download failed")
Assert.eq(reader_error, "download failed")
local retried
Chapter.openAsync({}, identity, {}, { chapter_idx = 1 }, ops, function(p) retried = p end)
callbacks[calls]({ text = "Retried text" })
Assert.eq(retried, path)
os.remove(path)

-- Source, book, and chapter identity must keep unrelated downloads separate.
local identities = {
    identity,
    { source_id = "jdread", stable_id = identity.stable_id },
    { source_id = "wechat", stable_id = "another-inflight-book" },
}
base_calls = calls
local paths = {}
for i, ref in ipairs(identities) do
    local p = Paths.chapterPath(ref.stable_id, 1, ref.source_id)
    os.remove(p)
    Chapter.openAsync({}, ref, {}, { chapter_idx = 1 }, ops, function(saved) paths[i] = saved end)
end
local two_toc = { toc[1], { idx = 2, title = "Two" } }
local second_path = Paths.chapterPath(identity.stable_id, 2, identity.source_id)
os.remove(second_path)
Chapter.openAsync({}, identity, {}, { chapter_idx = 2 }, {
    loadToc = function(_, cb) cb(two_toc) end, fetchContent = fetch,
}, function(p) paths[4] = p end)
Assert.eq(calls, base_calls + 4)
for i = 1, 4 do callbacks[base_calls + i]({ text = "Separate text " .. i }) end
Assert.len(paths, 4)
Assert.eq(paths[4], second_path)
for _, saved in ipairs(paths) do os.remove(saved) end
