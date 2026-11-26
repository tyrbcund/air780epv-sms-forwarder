-- main.lua · 短信转发器（v3.2.0 加固版）
--
-- 只做一件事：收短信 → 推到 pushplus → 由它转邮件。
--
-- 三条设计铁律（都是实测踩出来的）：
--   ① 可选库一律先探测再用，缺库只降级，不崩
--   ② 每个任务体、每个回调体都 pcall 包住 —— 未捕获错误会让 VM 退出、15 秒后重启
--   ③ 网络超时 < 看门狗，且绝不自己切飞行模式

PROJECT = "sms-forwarder"
VERSION = "4.1.0"

log.setLevel("INFO")

sys = require "sys"
pcall(require, "sysplus")   -- http 的 .wait() 需要它

--============================================================
-- 能力探测
--   ⚠ 不能用 _G[name]：LuatOS 的 _G 不反映真实运行环境，
--     实测会把确实存在的库全读成 nil（第一版就栽在这里）。
--     下面直接读全局变量，缺库时读到 nil，这是可靠的。
--============================================================
local function capsReport()
    local names = { "http", "sms", "socket", "mobile", "fskv", "json",
                    "pm", "wdt", "gpio", "uart", "mcu", "rtos", "io" }
    local vals  = { http, sms, socket, mobile, fskv, json,
                    pm, wdt, gpio, uart, mcu, rtos, io }
    local ok, miss = {}, {}
    for i = 1, #names do
        if vals[i] ~= nil then ok[#ok + 1] = names[i] else miss[#miss + 1] = names[i] end
    end
    log.info("caps", "可用: " .. table.concat(ok, " "))
    if #miss > 0 then
        log.warn("caps", "缺失: " .. table.concat(miss, " "))
    end
    return miss
end

local function fwVersion()
    if rtos and rtos.version then
        local ok, v = pcall(rtos.version)
        if ok then return tostring(v) end
    end
    return "?"
end

local function uptimeMin()
    if mcu and mcu.ticks then
        local ok, t = pcall(mcu.ticks)
        if ok and t then return math.floor(t / 60000) end
    end
    return -1
end

local function uptimeMs()
    if mcu and mcu.ticks then
        local ok, t = pcall(mcu.ticks)
        if ok and t then return t end
    end
    return 0
end

-- 重启：优先 rtos.restart，退而求其次 rtos.reboot
local function doRestart(reason)
    log.error("main", "===== 重启设备: " .. tostring(reason) .. " =====")
    sys.wait(500)
    local done = false
    if rtos and rtos.restart then done = pcall(rtos.restart) end
    if not done and rtos and rtos.reboot then pcall(rtos.reboot) end
end

-- 重建网络（轻量）：重置协议栈 + 开关飞行模式，几秒就好，队列不丢
-- 这是自愈的主力手段，参考 lageev/air780e-forwarder
local lastNetReset = 0
local function doNetReset(reason)
    if mobile == nil or mobile.flymode == nil then return end

    local now = uptimeMs()
    local gap = tonumber(config.FLYMODE_MIN_GAP_MS) or 60000
    if now > 0 and lastNetReset > 0 and (now - lastNetReset) < gap then
        log.warn("net", "距上次重建不足 " .. math.floor(gap / 1000) .. " 秒，跳过")
        return
    end
    lastNetReset = now

    log.warn("net", "===== 重建网络: " .. tostring(reason) .. " =====")
    pcall(function() mobile.reset() end)
    sys.wait(1000)
    pcall(function() mobile.flymode(0, true) end)
    sys.wait(1500)
    pcall(function() mobile.flymode(0, false) end)
    log.info("net", "网络重建完成")
end

log.info("main", PROJECT, VERSION, fwVersion())
local missing = capsReport()

--============================================================
-- 看门狗（可选）
--============================================================
if wdt and wdt.init then
    pcall(wdt.init, 10000)
    sys.timerLoopStart(function()
        if wdt.feed then pcall(wdt.feed) end
    end, 2000)
    log.info("main", "看门狗 10 秒")
else
    log.warn("main", "无 wdt 库，跳过看门狗")
end

--============================================================
-- DNS（可选）
--============================================================
if socket and socket.setDNS then
    pcall(socket.setDNS, nil, 1, "223.5.5.5")
    pcall(socket.setDNS, nil, 2, "119.29.29.29")
end

--============================================================
-- 网络自愈交给固件（可选）
-- 参数参考 lageev/air780e-forwarder：检测周期 30 秒（比原来的 300 秒积极 10 倍）
--============================================================
if mobile and mobile.setAuto then
    pcall(mobile.setAuto, 10000, 30000, 8, true, 60000)
    log.info("main", "网络自愈参数: 30 秒检测")
else
    log.warn("main", "无 mobile.setAuto，网络自愈依赖固件默认")
end

--============================================================
-- 持久化（可选，util_queue 内部会降级）
--============================================================
if fskv and fskv.init then
    pcall(fskv.init)
end

--============================================================
-- 重启诊断（可选）
--============================================================
BOOT_REASON, BOOT_COUNT = "unknown", 0
do
    if pm and pm.lastReson then
        local okp, pk, chg, hw = pcall(pm.lastReson)
        if okp then
            local r = (pk == 1 and "pwrkey" or "") ..
                      (chg == 1 and "/charge" or "") ..
                      (hw == 1 and "/hw" or "")
            if r == "" then r = "soft" end
            BOOT_REASON = r
        end
    end

    if fskv and fskv.get then
        local v = fskv.get("boot_count")
        BOOT_COUNT = (tonumber(v) or 0) + 1
        if fskv.set then fskv.set("boot_count", tostring(BOOT_COUNT)) end
    end

    log.info("main", "重启原因=" .. BOOT_REASON, "累计=" .. BOOT_COUNT .. "次")
end

--============================================================
-- 加载模块
--============================================================
config     = require "config"
util_queue = require "util_queue"
util_net   = require "util_net"
util_http  = require "util_http"
util_push  = require "util_push"
util_sms   = require "util_sms"
led        = require "led"

util_queue.init()

--============================================================
-- 小区重选门限：弱信号时更愿意换小区（ageev 项目验证过的做法）
-- 必须在飞行模式下改，否则不生效；放在 config 加载之后
--============================================================
sys.taskInit(function()
    sys.wait(60000)
    local weak = tonumber(config.RESEL_WEAK_CELL) or 0
    if weak <= 0 then return end
    if not (mobile and mobile.flymode and mobile.config) then
        log.warn("net", "无 mobile.config/flymode，跳过小区重选调整")
        return
    end
    local ok, err = pcall(function()
        log.info("net", "调整小区重选门限: " .. weak)
        mobile.flymode(0, true)
        sys.wait(800)
        pcall(function() mobile.config(mobile.CONF_RESELTOWEAKNCELL, weak) end)
        pcall(function() mobile.config(mobile.CONF_STATICCONFIG, 1) end)
        sys.wait(200)
        mobile.flymode(0, false)
        log.info("net", "小区重选门限已设置")
    end)
    if not ok then log.warn("net", "小区调整失败: " .. tostring(err)) end
end)

local failStreak = 0          -- 连续推送失败次数（成功即清零）
local rebootWindowStart = 0   -- 自愈重启的 24 小时窗口起点
local rebootInWindow = 0      -- 本窗口内已自愈重启次数

--============================================================
-- 定时切飞行模式重建网络
--   比整机重启温和：几秒就好、队列不丢。
--   队列里有待发消息时先延后，避免打断正在重试的发送。
--============================================================
local flyIv = tonumber(config.FLYMODE_INTERVAL) or 0
if flyIv > 0 and mobile and mobile.flymode then
    log.info("net", "定时切飞行模式: 每 " .. math.floor(flyIv / 3600000) .. " 小时")
    sys.timerLoopStart(function()
        sys.taskInit(function()
            local deferMs = tonumber(config.FLYMODE_DEFER_MS) or 600000
            local deferMax = tonumber(config.FLYMODE_DEFER_MAX) or 3
            local waited = 0
            while util_queue.count() > 0 and waited < deferMax do
                log.warn("net", "有待发消息，延后切飞行模式")
                sys.wait(deferMs)
                waited = waited + 1
            end
            log.info("net", "切飞行模式重建网络")
            pcall(function() mobile.reset() end)
            sys.wait(1000)
            pcall(function() mobile.flymode(0, true) end)
            sys.wait(1500)
            pcall(function() mobile.flymode(0, false) end)
            log.info("net", "飞行模式切换完成")
        end)
    end, flyIv)
else
    log.info("net", "定时切飞行模式: 已关闭")
end

-- 状态灯：慢闪=正常 / 快闪=没网 / 双闪=有积压 / 灭=死了
led.init()
led.start()

-- 收到短信，插播 1 下
sys.subscribe("NEW_MSG", function()
    led.blink(1)
end)

-- 队列满丢消息：闪故障码 5 + 开启告警窗口
sys.subscribe("Q_DROP", function()
    led.setFault(5)
    led.setAlert(tonumber(config.LOST_ALERT_MINUTES) or 0)
end)

util_sms.start()

--============================================================
-- 发送主循环
--   整体 pcall：任何异常都只打一条日志，不许杀死任务
--============================================================
sys.taskInit(function()
    while true do
        local ok, err = pcall(function()
            if not util_net.isReady() then
                log.warn("net", "未就绪，等待 IP_READY")
                sys.waitUntil("IP_READY", 120000)
            end

            local item = util_queue.peek()

            if not item then
                sys.waitUntil("NEW_MSG", 60000)
            elseif not util_net.isReady() then
                sys.wait(5000)
            else
                if util_push.send(item, (tonumber(item.retry) or 0) + 1) then
                    util_queue.pop()
                    log.info("push", "成功, 剩余=" .. util_queue.count())
                    led.blink(2)    -- 发送成功，插播 2 下
                    failStreak = 0
                else
                    util_queue.pop()
                    item.retry = (tonumber(item.retry) or 0) + 1
                    failStreak = failStreak + 1
                    if item.retry > (tonumber(config.RETRY_MAX) or 5) then
                        log.error("push", "重试超限，放弃这条（消息已丢）")
                        led.setFault(5)
                        led.setAlert(tonumber(config.LOST_ALERT_MINUTES) or 0)
                    else
                        util_queue.push(item)
                        log.warn("push", "失败, 第 " .. item.retry .. " 次重试",
                                 "连续失败=" .. failStreak)
                    end

                    -- 第一道：连续失败 2 次 → 切飞行模式重建网络（几秒，队列不丢）
                    local flyN = tonumber(config.FAIL_FLYMODE_COUNT) or 0
                    if flyN > 0 and failStreak % flyN == 0 then
                        doNetReset("连续失败 " .. failStreak .. " 次")
                        sys.wait(5000)
                    end

                    -- 第二道：连续失败够多 → 重启整机（最后手段）
                    local need = tonumber(config.FAIL_REBOOT_COUNT) or 0
                    if need > 0 and failStreak >= need then
                        local maxDaily = tonumber(config.FAIL_REBOOT_DAILY_MAX) or 3
                        local now = uptimeMs()
                        if rebootWindowStart == 0 or (now - rebootWindowStart) > 86400000 then
                            rebootWindowStart = now
                            rebootInWindow = 0
                        end
                        if rebootInWindow < maxDaily then
                            rebootInWindow = rebootInWindow + 1
                            doRestart("连续推送失败 " .. failStreak .. " 次")
                        else
                            log.error("main", "24 小时内已重启 " .. rebootInWindow ..
                                      " 次，不再自动重启（等人工处理）")
                        end
                    end

                    sys.wait(tonumber(config.RETRY_GAP_MS) or 30000)
                end
            end
        end)

        if not ok then
            log.error("main", "发送循环异常已捕获: " .. tostring(err))
            sys.wait(5000)
        end
    end
end)

--============================================================
-- 定时重启：按"运行时长"算，不依赖 NTP
-- 依据：实测这台设备运行 23~24 小时后数据面和 SMS 接收会同时劣化，
--       重启是唯一已知有效的恢复手段。这不是遮羞布，是针对固件缺陷的妥协。
--============================================================
sys.timerLoopStart(function()
    local ok, err = pcall(function()
        local h = tonumber(config.REBOOT_AFTER_HOURS) or 0
        if h <= 0 then return end
        local ms = uptimeMs()
        if ms > 0 and ms >= h * 3600000 then
            doRestart("运行已满 " .. h .. " 小时")
        end
    end)
    if not ok then log.error("main", "定时重启任务异常: " .. tostring(err)) end
end, 600000)   -- 每 10 分钟检查一次

--============================================================
-- 每小时回收一次堆
--============================================================
sys.timerLoopStart(function()
    local ok, err = pcall(function()
        log.info("mem", math.floor(collectgarbage("count")) .. "KB",
                 "队列=" .. util_queue.count(),
                 "运行=" .. uptimeMin() .. "分钟")
        collectgarbage("collect")
    end)
    if not ok then log.error("main", "内存任务异常: " .. tostring(err)) end
end, 3600000)

--============================================================
-- 开机通知（可选）
--============================================================
sys.taskInit(function()
    if not config.BOOT_NOTIFY then return end
    local ok, err = pcall(function()
        sys.waitUntil("IP_READY", 180000)
        sys.wait(3000)
        util_queue.push({
            title = "设备上线",
            text  = "原因: " .. tostring(BOOT_REASON) ..
                    "\n累计重启: " .. tostring(BOOT_COUNT) .. " 次",
            retry = 0,
        })
        sys.publish("NEW_MSG")
    end)
    if not ok then log.error("main", "开机通知异常: " .. tostring(err)) end
end)

log.info("main", "启动完成，缺库=" .. tostring(#missing))

sys.run()
