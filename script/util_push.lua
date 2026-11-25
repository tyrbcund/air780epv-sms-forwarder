-- util_push.lua · pushplus 推送
--
-- 不依赖 json 库：请求体固定结构，手拼 JSON + 转义。
--
-- 失败时做两件事：
--   ① 日志打细（HTTP code + 响应体片段 + 第几次尝试）
--   ② 设置 LED 故障码（没条件挂日志时，看灯就知道哪类错）

local config = require "config"
local util_http = require "util_http"
local util_lib  = require "util_lib"

local util_push = {}

-- 故障码（与 led.lua 的灯语对应）
local F_HTTP      = 1   -- 连不上
local F_TIMEOUT   = 2   -- 超时
local F_REJECT    = 3   -- pushplus 拒绝
local F_CONFIG    = 4   -- 配置问题
local F_EXCEPTION = 6   -- 调用异常（代码/库的问题，不是网络）

local function ledFault(n)
    if led and util_lib.hasFn(led, "setFault") then
        util_lib.call(led, "setFault", n)
    end
end

-- JSON 字符串转义
local function esc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    s = s:gsub("[%c]", function(c)
        return string.format("\\u%04x", string.byte(c))
    end)
    return s
end

local function buildBody(item)
    local parts = {
        '"token":"'    .. esc(config.PUSHPLUS_TOKEN)   .. '"',
        '"title":"'    .. esc(item.title or "短信")     .. '"',
        '"content":"'  .. esc(item.text or "")          .. '"',
        '"template":"' .. esc(config.PUSHPLUS_TEMPLATE) .. '"',
        '"channel":"'  .. esc(config.PUSHPLUS_CHANNEL)  .. '"',
    }
    local opt = config.PUSHPLUS_OPTION
    if type(opt) == "string" and opt ~= "" then
        parts[#parts + 1] = '"option":"' .. esc(opt) .. '"'
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- HTTP code 归类
local function classify(code)
    if code == -8 then return F_TIMEOUT end
    if code == -1 or code == -4 or code == -5 or code == -6 or code == -7 then
        return F_HTTP
    end
    return F_HTTP
end

function util_push.send(item, attempt)
    local token = config.PUSHPLUS_TOKEN
    if type(token) ~= "string" or token == "" then
        log.error("push", "token 为空，无法推送")
        ledFault(F_CONFIG)
        return false
    end

    local body = buildBody(item)

    -- pcall 包住：http 库抛异常和"返回错误码"是两回事，必须分开
    local okCall, code, resp = pcall(util_http.post_json, config.PUSHPLUS_URL, body)
    if not okCall then
        log.error("push", "调用异常(非网络问题): " .. tostring(code))
        ledFault(F_EXCEPTION)
        return false
    end

    -- 失败日志：把 HTTP code 和响应体都打出来（原来只打 code，看不出原因）
    local brief = ""
    if type(resp) == "string" and #resp > 0 then
        brief = " resp=" .. resp:sub(1, 120)
    end

    if code ~= 200 then
        log.warn("push", "HTTP 失败 code=" .. tostring(code) ..
                 " 第" .. tostring(attempt or 1) .. "次" .. brief)
        ledFault(classify(code))
        return false
    end

    if type(resp) ~= "string" then
        log.warn("push", "HTTP 200 但响应体为空")
        ledFault(F_REJECT)
        return false
    end

    local c = resp:match('"code"%s*:%s*(%-?%d+)')
    if tonumber(c) == 200 then
        local id = resp:match('"data"%s*:%s*"([^"]*)"')
        log.info("push", "已受理 " .. tostring(id))
        ledFault(0)          -- 成功即清除故障码
        return true
    end

    log.warn("push", "接口拒绝 code=" .. tostring(c) .. brief)
    ledFault(F_REJECT)
    return false
end

return util_push
