-- util_queue.lua · 待发消息队列
--
-- 设计两条路：
--   有 fskv → 存 Flash，断电不丢（首选）
--   没 fskv → 存内存，掉电会丢，但绝不崩（降级）
--
-- 序列化不用 json 库：三个字段用不可见分隔符拼，省掉一个依赖。

local config   = require "config"
local util_lib = require "util_lib"

local util_queue = {}

local KEY_HEAD  = "qh"
local KEY_COUNT = "qc"
local MAX       = tonumber(config.QUEUE_MAX) or 30
local SEP       = "\1"

-- 能力探测：fskv 在不在（用 util_lib，兼容 userdata 库）
local HAS_FSKV = util_lib.hasFn(fskv, "set") and util_lib.hasFn(fskv, "get")

-- 降级用的内存队列
local mem_q = {}

local function encode(item)
    return table.concat({
        tostring(item.title or ""),
        tostring(item.text or ""),
        tostring(item.retry or 0),
    }, SEP)
end

local function decode(s)
    local a, b, c = s:match("^(.-)\1(.-)\1(.*)$")
    if not a then return nil end
    return { title = a, text = b, retry = tonumber(c) or 0 }
end

local function slot(i)
    return "q" .. (i % MAX)
end

function util_queue.init()
    if HAS_FSKV then
        fskv.init()
        -- ⚠ fskv.get 缺键时返回"零个值"而不是 nil，必须先落局部变量
        local h = fskv.get(KEY_HEAD)
        if h == nil then fskv.set(KEY_HEAD, 0) end
        local c = fskv.get(KEY_COUNT)
        if c == nil then fskv.set(KEY_COUNT, 0) end
        log.info("queue", "fskv 可用，队列持久化")
    else
        log.warn("queue", "fskv 不可用！降级为内存队列（掉电会丢消息）")
    end
    log.info("queue", "ready, pending=" .. util_queue.count())
end

function util_queue.count()
    if not HAS_FSKV then return #mem_q end
    local c = fskv.get(KEY_COUNT)
    return tonumber(c) or 0
end

function util_queue.push(item)
    if not HAS_FSKV then
        if #mem_q >= MAX then table.remove(mem_q, 1); log.warn("queue", "满, 丢最旧") end
        mem_q[#mem_q + 1] = item
        return true
    end

    local h = fskv.get(KEY_HEAD)
    local head = tonumber(h) or 0
    local cnt = util_queue.count()

    if cnt >= MAX then
        fskv.del(slot(head))
        head = head + 1
        fskv.set(KEY_HEAD, head)
        cnt = cnt - 1
        log.warn("queue", "满, 丢最旧一条")
    end

    local ok = pcall(fskv.set, slot(head + cnt), encode(item))
    if not ok then
        log.error("queue", "写入失败")
        return false
    end
    fskv.set(KEY_COUNT, cnt + 1)
    return true
end

function util_queue.peek()
    if not HAS_FSKV then return mem_q[1] end
    local h = fskv.get(KEY_HEAD)
    local head = tonumber(h) or 0
    local s = fskv.get(slot(head))
    if not s then return nil end
    return decode(s)
end

function util_queue.pop()
    if not HAS_FSKV then
        table.remove(mem_q, 1)
        return
    end
    local h = fskv.get(KEY_HEAD)
    local head = tonumber(h) or 0
    fskv.del(slot(head))
    fskv.set(KEY_HEAD, head + 1)
    local cnt = util_queue.count()
    if cnt > 0 then fskv.set(KEY_COUNT, cnt - 1) end
end

return util_queue
