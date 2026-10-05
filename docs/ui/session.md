# ui.reader.session — 阅读会话

代码：[`ui/reader/session.lua`](../../book.koplugin/ui/reader/session.lua) 及 `session/{chapter,snapshot,mode,toc,document_toc}.lua`。

## 设计

书籍级会话门面：身份自举、统计/注解/进度、切章、关书结清、向属主源发事件。  
是否按章**只看** `identity.chapter_idx`（`Mode.isChapter`）。

| 对象 | 寿命 |
|---|---|
| `ReaderSessionSnapshot` | 单个文档 ReaderReady → CloseDocument |
| `ReaderChapterSession` | 跨 `switchDocument` 保留，直到真关书 |

```mermaid
sequenceDiagram
  participant KO as KOReader
  participant S as Session
  participant Store as book.store
  participant Dom as progress/note/stats
  participant Src as identity.source

  KO->>S: onReaderReady
  S->>Store: ensureIdentity
  Store-->>S: BookIdentity(+source)
  S->>Dom: start / applyLocal / pull
  S->>S: attach reader UI
  KO->>S: page / annotations / close
  S->>Dom: save
  Dom->>Src: dirty_only push
```

关书路径（`document_close` / `suspend`）对 progress、notes、stats **一律只推不拉**——远端收敛延迟会用旧值盖掉刚上传的新值。完整 pull 留给下次开书。

切章导航带 `skip_pull`，避免每章都拉云端。

章节下载超过 250 ms 时显示切换提示；缓存准备完成后也会先绘制提示，再进入阻塞 UI 的原生打开，提示保留到 `ReaderReady` 或失败/退出。目标章在 `ReaderReady` 内同步定位，目录跳转/向后翻章到章首，向前翻章到上一章末页；分页模式已经在目标页时不重复跳转。连续章节在原生滚动阅读器翻页越界前直接切换，避免 page 0/末页之后重新绘制旧页；保留 KOReader 原有的图片与定期全刷策略。锁屏仅在本进程首次初始化时生成，切章重建插件不再重复生成，休眠和设置刷新仍更新锁屏。

已读：`fraction>=1` 或 EndOfBook → `markReadComplete`；可选设置 `auto_mark_read_at_99` 在 99% 且 `read_state==0` 时自动已读。安装自定义 EndOfBook，屏蔽 KOReader 默认结束菜单。

`.moon` 内无法识别的文件：ConfirmBox「关闭文档 / 仍要阅读」。

---

## 用法

`main.lua` 接线（不要在 main 里写业务）：

```lua
function BookPlugin:onReaderReady()
    require("ui.reader.session").onReaderReady(self)
end
function BookPlugin:onCloseDocument()
    require("ui.reader.session").onCloseDocument(self)
end
function BookPlugin:onPageUpdate(page)
    require("ui.reader.session").onPageChanged(self, page)
end
function BookPlugin:onAnnotationsModified(items)
    require("ui.reader.session").onAnnotationsModified(self, items)
end
function BookPlugin:onSuspend()
    require("ui.reader.session").onPause(self)
end
function BookPlugin:onResume()
    require("ui.reader.session").onResume(self)
end
```

会话内查询与切章：

```lua
local Session = require("ui.reader.session")

local snap = Session.current()          -- 只读，别改字段
Session.isChapterMode(identity)
Session.toc()
Session.chapterIndex(snap)
Session.chapterTitle(snap)
Session.remainingSeconds()

Session.gotoChapter(idx, { within = 0.0 })
Session.onChapterBoundary(1)           -- 页尾下一章；-1 上一章
```

开书 bootstrap（内部）：

```text
Stats.start
ui.reader.onCreate
Note.applyLocal          -- 同步，首绘前
若非 skip_pull:
  Progress.pull
  Note.pull
章模式: ChapterMode.afterBootstrap（预取等）
```

关书结清（内部 `syncReading`）：

```text
Progress.save → source:syncProgressAsync(dirty_only)
Note.save → source:syncNotesAsync(dirty_only)
Stats.stop → source:syncStatsAsync(dirty_only)
emitToSource(event, nil, identity.source)
真关书: Progress.clearConflicts()；清章节会话
```

阅读 UI：[`ui/reader.lua`](../../book.koplugin/ui/reader.lua)（panel / bars，仅会话活跃时注册触控区）。

### 注意

- 所有源事件第三参传 `identity.source`。
- 切章不是真关书：快照会重建，章会话与冲突记忆策略不同。
- 异步回调用 `Store.isCurrentDocument` 丢弃旧结果。
