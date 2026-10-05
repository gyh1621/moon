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
Assert.eq(entry.has_content, true, "partial chapters are managed even with pending images")

local cover_only = { source_id = "wechat", stable_id = "inventory-cover-only", toc = book.toc }
local cover_dir = Paths.bookWorkDir(cover_only.stable_id, cover_only.source_id)
write(Paths.coverPath(cover_only.stable_id, cover_only.source_id), "cover")
write(cover_dir .. "/metadata.json", "{}")
write(cover_dir .. "/1.html.part", "unfinished")
write(cover_dir .. "/images/asset.png", "image")
write(cover_dir .. "/2.html", "")
Assert.eq(Cache.inspect(cover_only).has_content, false, "covers, assets, metadata and temporary files are not book content")
Assert.eq(Cache.inspect(cover_only).bytes, 22, "hidden artifacts still have their actual byte count")
require("ffi/util").purgeDir(cover_dir)
os.remove(Paths.coverPath(cover_only.stable_id, cover_only.source_id))

local whole = { source_id = "moon", stable_id = "inventory-whole", toc = "[]" }
local whole_dir = Paths.bookWorkDir(whole.stable_id, whole.source_id)
whole.path = whole_dir .. "/book.epub"
write(whole.path, "downloaded document")
Assert.eq(Cache.inspect(whole).has_content, true, "registered whole-book downloads remain visible")
Assert.eq(Cache.inspect(whole).bytes, 19)
write(whole.path, "")
Assert.eq(Cache.inspect(whole).has_content, false, "an empty document is not cached content")
whole.path = whole_dir .. "/book.epub.part"
write(whole.path, "unfinished")
Assert.eq(Cache.inspect(whole).has_content, false, "a temporary document is not cached content")
whole.path = Paths.coverPath(whole.stable_id, whole.source_id)
write(whole.path, "cover")
Assert.eq(Cache.inspect(whole).has_content, false, "a cover path is not a downloaded document")
require("ffi/util").purgeDir(whole_dir)
os.remove(whole.path)

local manga = { source_id = "copymanga", stable_id = "inventory-manga", toc = book.toc }
local manga_dir = Paths.bookWorkDir(manga.stable_id, manga.source_id)
manga.path = manga_dir .. "/1.cbz"
write(manga.path, "downloaded archive")
Assert.eq(Cache.inspect(manga).has_content, true, "registered comic chapter archives remain visible")
require("ffi/util").purgeDir(manga_dir)

local no_toc = { source_id = "wechat", stable_id = "inventory-no-toc" }
local no_toc_dir = Paths.bookWorkDir(no_toc.stable_id, no_toc.source_id)
no_toc.path = no_toc_dir .. "/1.html"
write(no_toc.path, "readable chapter")
Assert.eq(Cache.inspect(no_toc).has_content, true, "registered readable chapters do not require TOC metadata")
require("ffi/util").purgeDir(no_toc_dir)

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
Assert.eq(Cache.inspect(empty).has_content, false)
Assert.is_nil(lfs.attributes(empty_dir), "inspection must not recreate a deleted book cache directory")

-- Model the filesystem's lstat result for a linked root; its children still resolve as files.
local linked = { source_id = "wechat", stable_id = "inventory-linked", toc = '[{"title":"One"}]' }
local linked_dir = Paths.bookWorkDir(linked.stable_id, linked.source_id)
write(linked_dir .. "/1.html", "external text")
linked.path = linked_dir .. "/book.epub"
write(linked.path, "external document")
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
Assert.eq(linked_entry.has_content, false, "a document through a linked root is not managed content")
require("ffi/util").purgeDir(linked_dir)
os.remove(Paths.coverPath(linked.stable_id, linked.source_id))

local linked_child = { source_id = "moon", stable_id = "inventory-linked-child", toc = "[]" }
local child_dir = Paths.bookWorkDir(linked_child.stable_id, linked_child.source_id)
linked_child.path = child_dir .. "/linked/book.epub"
write(linked_child.path, "external document")
lfs.symlinkattributes = function(path)
    if path == child_dir .. "/linked" then return { mode = "link" } end
    return symlinkattributes(path)
end
local child_entry = Cache.inspect(linked_child)
lfs.symlinkattributes = symlinkattributes
Assert.eq(child_entry.bytes, 0, "a linked child directory is excluded from owned bytes")
Assert.eq(child_entry.has_content, false, "never count a registered document through a linked child directory")
require("ffi/util").purgeDir(child_dir)
