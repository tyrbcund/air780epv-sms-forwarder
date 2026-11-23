# 变更记录

每一次改动都写清"为什么"，下次排错时能直接对上日志里的现象。

---

## v3.5.3 · 2026-11-23

**修：邮件内容挤成一行**

- 现象：邮件里 `🔑 验证码：902123 📨 发件人：…` 全在一行
- 原因：`template = "txt"`，但 pushplus 邮件按 HTML 渲染，`\n` 被折叠
- 改动：`PUSHPLUS_TEMPLATE = "html"`，换行改用 `<br/>`，正文做 HTML 转义（`& < >`）
- 依据：pushplus 文档「消息内容中如何换行」—— html 模板用 `<br/>`

## v3.5.2 · 2026-11-23

**修：`gpio` 被误判成"不存在"**

- 现象：`[led] 无 gpio 库，LED 不可用`，但 `[caps]` 显示 gpio 可用
- 原因：`gpio` 是 **userdata 不是 table**，`type(gpio) ~= "table"` 误判
- 改动：新增 `util_lib.lua`（`field` / `hasFn` / `call`），`led` / `util_net` / `util_queue` 全部改用它
- 顺带修：`util_queue` 里 `type(fskv)=="table"` 的同类问题

## v3.5.1 · 2026-11-23

**加：短信排版 + 验证码提取**

- 版式改成 emoji 标签分行（对齐旧程序的观感）
- 命中「验证码/校验码/动态码/口令」等关键字时，把验证码提到正文最上方
- 邮件标题统一为「短信转发」（原来带完整号码，通知栏会被截断）

## v3.5.0 · 2026-11-23

**加：状态指示灯**

- `led.lua`：慢闪=正常 / 快闪=无网 / 双闪=队列积压 / 灭=死了
- 收到短信插播 1 下，发送成功插播 2 下
- GPIO 27，与旧程序一致

## v3.4.0 · 2026-11-23

**修：`sms` 被误判成"不存在"**

- 现象：`[caps]` 显示 sms 在，但代码报"固件里没有 sms 库"
- 原因：`sms` 是 **userdata**，`type(sms) ~= "table"` 误判
- 改动：改用 `pcall` 取字段；新增 `[dump]` 打印库暴露的所有方法

## v3.3.0 · 2026-11-23

**加：sms API 自适应**

- 候选名单逐个尝试 `setNewSmsCb` / `set_new_sms_cb` / `setSmsCb` / `setCallback` / `onsms`
- 全不中时打印 `[dump] sms: ...` 暴露真实函数名

## v3.2.0 · 2026-11-23

**修：`socket.isReady` 为 nil 导致崩溃循环**

- 现象：`main.lua:141: attempt to call a nil value (field 'isReady')` → `Lua VM exit` → 每 16.2 秒重启
- 改动：新增 `util_net.lua`，依次探测 `socket.isReady` / `socket.ready` / `mobile.status`，全无则乐观放行
- 同时：所有任务体包 `pcall`（未捕获错误 = 整机重启）

## v3.1.0 · 2026-11-23

**修：能力探测全部误报**

- 现象：`[caps] 可用:` 为空，13 个库全报缺失，但 `rtos.version()` 明明能用
- 原因：`_G[name]` 在 LuatOS 里不反映真实环境
- 改动：改成直接读全局变量

## v3.0.0 · 2026-11-23

**重写**（原程序为一份基于 Air780EPV 的旧版转发器，源码已丢失）

- 只保留必要功能：收短信 → pushplus → 邮箱
- 去掉：cc 来电通知、定时重启、低功耗休眠、告警音频、定位、串口转发
- 新增：fskv 队列（可降级）、失败重试轮转、每小时 GC、内存日志
- 铁律：HTTP 超时 6 秒 < 看门狗 10 秒
