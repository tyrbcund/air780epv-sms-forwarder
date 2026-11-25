-- led.lua · 单个 LED 的状态码 + 故障码
--
-- 设计目标：不接电脑、不看日志，站在设备前就能判断"哪里坏了"。
--
-- 基础状态（互斥，按优先级）：
--   慢闪  100ms亮/1900ms灭   → 正常（有网、队列空）
--   快闪  200ms亮/200ms灭    → 网络未就绪，正在重连
--   帧闪  见下               → 队列积压（有消息发不出去）
--   常灭                     → 程序没在跑（最强故障信号）
--
-- 积压帧（每 5 秒重复一次）：
--   [2 下]  停 1.2s  [N 下]  停 2.5s
--     ↑第一组固定 2 下 = "有积压"      ↑第二组 N 下 = 故障码
--
-- 故障码 N：
--   1 = 网络层失败（HTTP code -1/-4/-5/-6/-7，连不上）
--   2 = 超时（HTTP code -8）
--   3 = pushplus 拒绝（接口返回非 200）
--   4 = 配置问题（token 空 / 渠道无效）
--   5 = 消息被丢弃（重试超限放弃，或队列满丢最旧）← 唯一不可逆损失
--   6 = 调用异常（http 库抛错/卡住，是代码或库的问题，不是网络）
--   0 = 原因未知（只闪第一组 2 下）

local config     = require "config"
local util_lib   = require "util_lib"
local util_queue = require "util_queue"
local util_net   = require "util_net"

local led = {}

local PIN    = tonumber(config.LED_PIN) or 27
local ACTIVE = tonumber(config.LED_ACTIVE) or 1

local ready   = false
local pending = 0    -- 插播次数（收到短信 / 发送成功）
local fault   = 0    -- 当前故障码

local function on()
    if ready then util_lib.call(gpio, "set", PIN, ACTIVE) end
end

local function off()
    if ready then util_lib.call(gpio, "set", PIN, 1 - ACTIVE) end
end

function led.init()
    if gpio == nil then
        log.warn("led", "没有 gpio 库，LED 不可用（不影响其它功能）")
        return
    end
    if not util_lib.hasFn(gpio, "setup") then
        log.warn("led", "gpio.setup 不可用，跳过 LED")
        return
    end

    local ok = util_lib.call(gpio, "setup", PIN, 1 - ACTIVE)
    if not ok then
        log.warn("led", "GPIO" .. PIN .. " 初始化失败，跳过 LED")
        return
    end

    ready = true
    util_lib.call(gpio, "set", PIN, 1 - ACTIVE)
    log.info("led", "GPIO" .. PIN .. " 就绪, 亮电平=" .. ACTIVE)
end

--- 插播闪烁（收到短信 1 下 / 发送成功 2 下）
function led.blink(n)
    pending = pending + (n or 1)
    if pending > 9 then pending = 9 end
end

--- 设置故障码（0 = 清除）
function led.setFault(n)
    n = tonumber(n) or 0
    if n ~= fault then
        fault = n
        log.warn("led", "故障码=" .. n)
    end
end

function led.getFault()
    return fault
end

-- 闪 n 下（120ms 节奏）
local function burst(n)
    for _ = 1, n do
        on();  sys.wait(120)
        off(); sys.wait(120)
    end
end

function led.start()
    if not ready then return end

    sys.taskInit(function()
        while true do
            local ok, err = pcall(function()
                if pending > 0 then
                    pending = pending - 1
                    burst(1)
                    sys.wait(120)
                    return
                end

                local up = util_net.isReady()
                local q  = util_queue.count()

                if not up then
                    -- 无网：快闪
                    on();  sys.wait(200)
                    off(); sys.wait(200)
                elseif q > 0 then
                    -- 积压：2 下 + 原因码
                    burst(2)
                    sys.wait(1200)
                    if fault > 0 then
                        burst(fault)
                        sys.wait(2500)
                    else
                        sys.wait(1500)
                    end
                else
                    -- 正常：2 秒 1 次
                    on();  sys.wait(100)
                    off(); sys.wait(1900)
                end
            end)

            if not ok then
                log.warn("led", "闪烁任务异常: " .. tostring(err))
                sys.wait(1000)
            end
        end
    end)
end

return led
