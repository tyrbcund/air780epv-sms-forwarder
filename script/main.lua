-- main.lua · 短信转发器（v3.2.0 加固版）
--
-- 只做一件事：收短信 → 推到 pushplus → 由它转邮件。
--
-- 三条设计铁律（都是实测踩出来的）：
--   ① 可选库一律先探测再用，缺库只降级，不崩
--   ② 每个任务体、每个回调体都 pcall 包住 —— 未捕获错误会让 VM 退出、15 秒后重启
--   ③ 网络超时 < 看门狗，且绝不自己切飞行模式

PROJECT = "sms-forwarder"
VERSION = "3.5.3"

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
--============================================================
if mobile and mobile.setAuto then
    pcall(mobile.setAuto, 10000, 300000, 8, true, 120000)
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

-- 状态灯：慢闪=正常 / 快闪=没网 / 双闪=有积压 / 灭=死了
led.init()
led.start()

-- 收到短信，插播 1 下
sys.subscribe("NEW_MSG", function()
    led.blink(1)
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
                if util_push.send(item) then
                    util_queue.pop()
                    log.info("push", "成功, 剩余=" .. util_queue.count())
                    led.blink(2)    -- 发送成功，插播 2 下
                else
                    util_queue.pop()
                    item.retry = (tonumber(item.retry) or 0) + 1
                    if item.retry > (tonumber(config.RETRY_MAX) or 5) then
                        log.error("push", "重试超限，放弃这条")
                    else
                        util_queue.push(item)
                        log.warn("push", "失败, 第 " .. item.retry .. " 次重试")
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
