# http/ — 唯一网络栈

路径：[`book.koplugin/http/`](../../book.koplugin/http/)。禁止 `socket.http` / luasocket 超时路径。缓存表见 [`../db/http.md`](../db/http.md)。

## 设计

全部外部 HTTP 经 Turbo 非阻塞回调。可取消句柄统一 `{ cancel }`。GET 的 `cache_ttl>0` 走 `http` 表；业务层（含 `online/`）不自己判新鲜度。

请求入口只检查 `NetworkMgr:isConnected()`，不在 UI 线程调用会同步解析 DNS 的 `isOnline()`；已连 Wi-Fi 但无法访问互联网时，由异步 HTTP 返回错误。未缓存的主机名经 `workers.job` 的 `light` fork 任务解析，连接只接收解析后的 IP，原始 Host/SNI 不变。DNS 地址缓存十分钟，连接失败清除；关闭流同时取消 DNS 任务，迟到结果不再连接。

## 用法

```lua
local Request = require("http.request")

local h = Request.get(url, {
    headers = { Authorization = "…" },
    cache_ttl = 3600,
    timeout = 20,
}, function(body, err, res)
    -- 成功：body 为响应体字符串，err 为 nil；失败：body 为 nil，err 为原因
    -- 需要状态码 / 响应头时看第三参 res
    if not body then return end
end)

Request.post(url, body, { headers = … }, cb)  -- 回调同 get：cb(body, err, res)
Request.download({ url = url }, dest_path, cb)
Request.stream({ url = url }, {
    on_headers = function(code, headers) end,
    on_data = function(chunk) end,
    on_done = function(err) end,  -- err 为 nil 表示成功收完
})

h.cancel()
Request.clearCache("example.com")  -- 可选 substr
```

日志里的 URL 会剥 query/fragment/userinfo，别往日志塞带令牌的完整 URL。
