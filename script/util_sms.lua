-- util_sms.lua · 收短信（API 自适应版）
--
-- 踩过的两个坑：
-- ① LuatOS 有些库不是 table 而是 userdata（方法通过 __index 暴露），
--    所以不能用 type(sms) == "table" 来判断库是否可用 —— 会误判成"没有 sms"。
-- ② 云编译固件里 sms 的函数名可能和文档不同，必须逐个探测。
--
-- 兜底原则不变：回调体 pcall（未捕获错误 = VM 退出 = 15 秒后重启）。

local config = require "config"
local util_queue = require "util_queue"

local util_sms = {}

local last_key, last_ts = "", 0

-- 安全取字段：兼容 table 和 userdata
local function getField(t, name)
    if t == nil then return nil end
    local ok, v = pcall(function() return t[name] end)
    if ok then return v end
    return nil
end

-- 打印库暴露了哪些东西（userdata 时 pairs 会失败，用探测代替）
local function dumpApi(name, t)
    if type(t) == "table" then
        local ok, ks = pcall(function()
            local a = {}
            for k, v in pairs(t) do a[#a + 1] = tostring(k) .. "(" .. type(v) .. ")" end
            table.sort(a)
            return a
        end)
        if ok and ks then
            log.info("dump", name .. " 类型=table: " .. table.concat(ks, " "))
            return
        end
    end

    -- userdata / 其它：逐个探常用名字
    local probes = { "setNewSmsCb", "set_new_sms_cb", "setSmsCb", "setCallback",
                     "onsms", "send", "autoLong", "clearLong", "unpack", "debug" }
    local marks = {}
    for _, n in ipairs(probes) do
        marks[#marks + 1] = n .. (type(getField(t, n)) == "function" and "✓" or "✗")
    end
    log.info("dump", name .. " 类型=" .. type(t) .. ": " .. table.concat(marks, " "))
end

local function in_list(str, list)
    if type(list) ~= "table" then return false end
    for _, v in ipairs(list) do
        if v ~= "" and str:find(tostring(v), 1, true) then return true end
    end
    return false
end

local function time_from_meta(m)
    if type(m) == "table" and m.year and m.mon and m.day then
        local y = m.year
        if y < 2000 then y = y + 2000 end
        return string.format("%d-%02d-%02d %02d:%02d:%02d",
            y, m.mon, m.day, m.hour or 0, m.min or 0, m.sec or 0)
    end
    if os.time() < 1700000000 then return "未对时" end
    return os.date("%Y-%m-%d %H:%M:%S")
end

-- 从短信里抠验证码：命中关键字后，取紧随其后的 4~8 位数字
local CODE_KEYS = { "验证码", "校验码", "动态码", "动态密码", "识别码", "口令", "code" }

local function extractCode(txt)
    for _, k in ipairs(CODE_KEYS) do
        local s = txt:find(k, 1, true)
        if s then
            local seg = txt:sub(s, s + 40)
            local d = seg:match("(%d%d%d%d%d?%d?%d?%d?)")
            if d and #d >= 4 then return d end
        end
    end
    return nil
end

-- 排版：手机上看得更清楚
-- pushplus 的邮件按 HTML 渲染，所以：
--   html 模板 → 用 <br> 换行，正文要做 HTML 转义
--   txt 模板  → 用 \n，但实际会被折叠成一整行（pushplus 的行为）
local function fmtBody(num, txt, t)
    local html = (config.PUSHPLUS_TEMPLATE == "html")
    local BR = html and "<br/>" or "\n"

    -- HTML 转义：短信里可能有 & < > 引号，不转义会把版面搞乱
    local function E(s)
        if not html then return tostring(s) end
        s = tostring(s)
        s = s:gsub("&", "&amp;")
        s = s:gsub("<", "&lt;")
        s = s:gsub(">", "&gt;")
        return s
    end

    if config.BEAUTIFY == false then
        return E(txt) .. BR .. BR .. E("发件号码: " .. num) .. BR .. E("收件时间: " .. t)
    end

    local lines = {}

    if config.CODE_HIGHLIGHT ~= false then
        local code = extractCode(txt)
        if code then
            lines[#lines + 1] = "🔑 验证码：" .. E(code)
            lines[#lines + 1] = ""
        end
    end

    lines[#lines + 1] = "📨 发件人：" .. E(num)
    lines[#lines + 1] = "⏰ 时间：" .. E(t)
    lines[#lines + 1] = "📝 内容："
    lines[#lines + 1] = E(txt)

    return table.concat(lines, BR)
end

local function handle(num, txt, m)
    num = tostring(num or "")
    txt = tostring(txt or "")

    if txt == "" then
        log.info("sms", "空内容，忽略")
        return
    end

    log.info("sms", "from=" .. num, "len=" .. #txt)

    if in_list(num, config.BLACKLIST) then
        log.info("sms", "号码命中黑名单，丢弃")
        return
    end
    if in_list(txt, config.BLOCK_WORDS) then
        log.info("sms", "内容命中关键字，丢弃")
        return
    end

    local key = num .. "|" .. txt
    local now = os.time()
    local gap = tonumber(config.DEDUP_SECONDS) or 60
    if key == last_key and (now - last_ts) < gap then
        log.info("sms", "重复内容，忽略")
        return
    end
    last_key, last_ts = key, now

    local ok = util_queue.push({
        title = config.SMS_TITLE or "短信转发",
        text  = fmtBody(num, txt, time_from_meta(m)),
        retry = 0,
    })

    if ok then
        log.info("sms", "已入队, pending=" .. util_queue.count())
        sys.publish("NEW_MSG")
    end
end

local function onSms(num, txt, m)
    local ok, err = pcall(handle, num, txt, m)
    if not ok then
        log.error("sms", "回调异常已捕获: " .. tostring(err))
    end
    if #last_key > 512 then last_key = "" end
end

local CANDS = { "setNewSmsCb", "set_new_sms_cb", "setSmsCb", "setCallback", "onsms" }

function util_sms.start()
    if sms == nil then
        log.error("sms", "sms 全局不存在，无法收短信")
        return
    end

    dumpApi("sms", sms)

    for _, name in ipairs(CANDS) do
        local f = getField(sms, name)
        if type(f) == "function" then
            local ok, err = pcall(f, onSms)
            if ok then
                log.info("sms", "监听已启动, API = sms." .. name)
                local al = getField(sms, "autoLong")
                if type(al) == "function" then pcall(al, true) end
                return
            end
            log.warn("sms", "sms." .. name .. " 调用失败: " .. tostring(err))
        end
    end

    log.error("sms", "候选 API 全部不可用（见上面 [dump] 行）")
end

return util_sms
