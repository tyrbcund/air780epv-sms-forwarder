-- led.lua · 单个 LED 的状态码
--
-- 站在设备前看一眼就知道它在干什么。优先级从高到低：
--   ⚡ 快闪 (200ms)        → 网络未就绪
--   ⚡ 双闪 (亮-灭-亮-停)   → 队列积压，有消息发不出去
--   ⚡ 慢闪 (100ms/1900ms) → 正常运行（2 秒 1 次）
--   ⚡ 瞬闪 1~2 下          → 收到短信 / 发送成功（插播）
--   ✗  常灭                → 程序没在跑（最强的故障信号）
--
-- 注意：gpio 库是 userdata 不是 table，必须用 util_lib 访问。

local config    = require "config"
local util_lib  = require "util_lib"
local util_queue = require "util_queue"
local util_net  = require "util_net"

local led = {}

local PIN    = tonumber(config.LED_PIN) or 27
local ACTIVE = tonumber(config.LED_ACTIVE) or 1

local ready = false
local pending = 0     -- 待插播的闪烁次数

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
    util_lib.call(gpio, "set", PIN, 1 - ACTIVE)   -- 先熄灭
    log.info("led", "GPIO" .. PIN .. " 就绪, 亮电平=" .. ACTIVE)
end

--- 插播闪烁（收到短信、发送成功）
function led.blink(n)
    pending = pending + (n or 1)
    if pending > 9 then pending = 9 end
end

function led.start()
    if not ready then return end

    sys.taskInit(function()
        while true do
            local ok, err = pcall(function()
                if pending > 0 then
                    pending = pending - 1
                    on();  sys.wait(120)
                    off(); sys.wait(120)
                else
                    local up = util_net.isReady()
                    local q  = util_queue.count()

                    if not up then
                        on();  sys.wait(200)
                        off(); sys.wait(200)
                    elseif q > 0 then
                        on();  sys.wait(120)
                        off(); sys.wait(120)
                        on();  sys.wait(120)
                        off(); sys.wait(1200)
                    else
                        on();  sys.wait(100)
                        off(); sys.wait(1900)
                    end
                end
            end)
            -- LED 出任何错都不许影响业务，也不许把任务打死
            if not ok then
                log.warn("led", "闪烁任务异常: " .. tostring(err))
                sys.wait(1000)
            end
        end
    end)
end

return led
