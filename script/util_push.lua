-- util_push.lua · pushplus 推送
--
-- 刻意不依赖 json 库：请求体是固定结构，手拼 JSON + 转义即可。
-- 少一个依赖，就少一个"固件没编进这个库"的坑。
--
-- 注意：接口返回 code=200 只代表"服务端收到请求"，投递是异步的，
--       所以这里只能确认"已受理"，最终是否到邮箱要看邮箱本身。

local config = require "config"
local util_http = require "util_http"

local util_push = {}

-- JSON 字符串转义
local function esc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    -- 剩下的控制字符
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

function util_push.send(item)
    local code, resp = util_http.post_json(config.PUSHPLUS_URL, buildBody(item))

    if code ~= 200 then
        log.warn("push", "HTTP 失败 code=" .. tostring(code))
        return false
    end
    if type(resp) ~= "string" then
        log.warn("push", "HTTP 200 但无响应体")
        return false
    end

    -- 不解析整段 JSON，只抠出 "code":xxx
    local c = resp:match('"code"%s*:%s*(%-?%d+)')
    if tonumber(c) == 200 then
        local id = resp:match('"data"%s*:%s*"([^"]*)"')
        log.info("push", "已受理 " .. tostring(id))
        return true
    end

    log.warn("push", "接口拒绝 " .. resp:sub(1, 120))
    return false
end

return util_push
