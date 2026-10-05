local Assert = require("support.assert")
local Config = require("support.config")
local Paths = require("utils.paths")
package.preload["json"] = function() return require("support.json_stub") end
local lfs = require("libs/libkoreader-lfs")
local Cache = require("book.cache")

local function write(path, content)
    Paths.ensureDir(path:match("(.+)/[^/]+$"))
    local file = assert(io.open(path, "wb"))
    file:write(content)
    file:close()
end

local book = {
    source_id = "wechat", stable_id = "inventory-spec", title = "Partial book",
    toc = '[{"title":"One"},{"title":"Two"},{"title":"Three"},{"title":"Four"}]',
}
local dir = Paths.bookWorkDir(book.stable_id, book.source_id)
require("ffi/util").purgeDir(dir)
write(Paths.chapterPath(book.stable_id, 1, book.source_id), "one")
write(Paths.chapterPath(book.stable_id, 2, book.source_id), '<img src="https://x">')
write(Paths.chapterPath(book.stable_id, 4, book.source_id), "")
write(dir .. "/assets/image.png", "1234567")
write(dir .. "/3.html.part", "12345")
write(Paths.coverPath(book.stable_id, book.source_id), "12")

local entry = Cache.inspect(book)
Assert.eq(entry.title, "Partial book")
Assert.eq(entry.total, 4)
Assert.eq(entry.available, 2, "readable text includes chapters awaiting images")
Assert.eq(entry.complete, 1)
Assert.eq(entry.pending_images, 1)
Assert.eq(entry.missing, 2, "missing and empty files are not cached chapters")
Assert.eq(entry.bytes, 38, "owned files include partial downloads and the book cover")
Assert.eq(entry.chapters[1].state, "cached")
Assert.eq(entry.chapters[2].state, "images")
Assert.eq(entry.chapters[3].state, "missing")
Assert.eq(entry.chapters[4].state, "missing")
Assert.eq(entry.chapters[3].title, "Three")

-- A local source points at the user's original file, which is never a managed cache.
local original = Config.dir() .. "/inventory-original.epub"
write(original, "original")
Assert.is_nil(Cache.inspect({ source_id = "local", stable_id = original, path = original }))
Assert.eq(lfs.attributes(original, "size"), 8)

require("ffi/util").purgeDir(dir)
os.remove(Paths.coverPath(book.stable_id, book.source_id))
os.remove(original)

local empty = { source_id = "wechat", stable_id = "inventory-missing", toc = book.toc }
local empty_dir = Paths.bookWorkDir(empty.stable_id, empty.source_id)
require("ffi/util").purgeDir(empty_dir)
Assert.eq(Cache.inspect(empty).available, 0)
Assert.is_nil(lfs.attributes(empty_dir), "inspection must not recreate a deleted book cache directory")

-- Model the filesystem's lstat result for a linked root; its children still resolve as files.
local linked = { source_id = "wechat", stable_id = "inventory-linked", toc = '[{"title":"One"}]' }
local linked_dir = Paths.bookWorkDir(linked.stable_id, linked.source_id)
write(linked_dir .. "/1.html", "external text")
write(Paths.coverPath(linked.stable_id, linked.source_id), "12")
local symlinkattributes = lfs.symlinkattributes
lfs.symlinkattributes = function(path)
    if path == linked_dir then return { mode = "link" } end
    return symlinkattributes(path)
end
local linked_entry = Cache.inspect(linked)
lfs.symlinkattributes = symlinkattributes
Assert.eq(linked_entry.bytes, 2, "linked work directory is excluded; dedicated cover is owned")
Assert.eq(linked_entry.available, 0, "never inspect external chapters through a linked root")
Assert.eq(linked_entry.missing, 1)
require("ffi/util").purgeDir(linked_dir)
os.remove(Paths.coverPath(linked.stable_id, linked.source_id))
