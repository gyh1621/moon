# source.chapter — 按章 materialization

代码：[`source/chapter.lua`](../../book.koplugin/source/chapter.lua)。

## 设计

这里的逻辑属于**源侧落地**：目录缓存、章节正文落盘、本地进度选章、预取。  
阅读会话（`ui/reader/session`）只编排切章与生命周期，不下载文件。

起始章（未指定 `chapter_idx` 时）：

1. 读 `pending_progress`（有 `chapter_idx`，或仅有 `fraction>0` 时用 fraction×toc 折算）
2. 否则第 1 章  
夹到 `[1, #toc]`。远端进度不参与选章，由开书后 `Progress.pull` 收敛（不一致时弹冲突框，可跳章）。已无 `books.last_chapter_idx`。

目录：优先 `books.toc` / `toc_fetched_at`；TTL 由调用方解释（如 wechat ~6h）。wechat 拉进度时若 `chapter_uid` 不在缓存目录里，会走一次 `loadTocAsync`，但缓存仍在 TTL 内时直接复用缓存，不强制重拉。

落盘：写 `.part` 再 rename；**`Store.touch` 成功**才把 path 交给调用方。  
阅读可用 = 非空章节文件已落盘，图片失败不阻止离线阅读，也不触发重新下载正文。
完整缓存 = 文件存在且远程 `img src` 已内联；按 size+mtime 签名缓存，上限 512 条。图片未完成的章节保留正文，但计入全本缓存的失败统计。wechat 重试使用已保存的正文，只补下载剩余远程图片。

前台打开、阅读预取与全本缓存按章节文件路径共享正文请求及原子写入，避免重复下载或争用 `.part`。取消只移除当前调用方；最后一个调用方取消才终止任务。已取消任务的迟到回调不能影响后续重试。

本地缓存命中快开时仍须 `touch`——旧文件可能早于 chapters 表。切章快开不做后台重复 `openAsync`，避免 UI 线程扫 HTML。

章节打开和预取不使用同步 DNS 探测的 `isOnline` / `runWhenOnline`。预取逐章先检查完整缓存，命中时离线也能完成；只有需要下载时才经 `runWhenConnected` 检查连接并保留 KOReader 的 Wi-Fi 连接提示。未缓存章节打开（含拷贝漫画的独立入口）也只走连接检查；已连接但 DNS/WAN 不可用时，由异步 HTTP 返回错误，关闭准备框并交付失败。取消后连接完成或请求迟到回调不能交付结果。

工作目录：`Paths.bookWorkDir(stable_id, source_id)`（`md5(stable_id)`，因 id 可能含斜杠）。

---

## 用法

具体源一般包一层再调公共逻辑，例如：

```lua
function Source:openBookAsync(identity, opts, cb)
    return require("source.chapter").openWithUi(self, identity, identity.book, opts, {
        -- 注入：loadToc / downloadChapter / progress 等
    }, cb)
end

function Source:loadTocAsync(identity, cb)
    local cached = Store.toc(identity)  -- 或源自己的 Toc.read + TTL
    if cached then
        UIManager:nextTick(function() cb(cached) end)
        return nil
    end
    return self._client:tocAsync(…, function(chapters, err)
        -- setToc 后 cb(chapters)
    end)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    -- 会话侧通常预取后续 3 章
end
```

Session 切章：

```lua
Session.gotoChapter(idx, opts)
Session.onChapterBoundary(1)  -- 页尾 → 下一章
-- 内部：源打开邻章 path → switchDocument → 新 ReaderReady（skip_pull）
```

### 注意

- `touch` 失败 = 打开失败，不要把未登记 path 交给 Reader。
- 预取失败应静默可恢复，不能留下半写 `.part` 当正文。
- 会话与 chapter 模块边界：会话不 require 源 client。
