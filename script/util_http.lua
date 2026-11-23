-- util_http.lua · HTTP 封装
--
-- ⚠ 唯一的铁律：超时必须小于硬件看门狗（main.lua 里 wdt.init(10000)）。
--   如果超时比看门狗长，网络一卡就轮不到"超时"这个正常错误码——
--   设备会在超时之前被看门狗硬复位，日志里只会看到"又重启了"。
--   所以这里固定 6 秒，给看门狗留 4 秒余量。

local util_http = {}

local DEFAULT_TIMEOUT = 6000

--- POST 一段 JSON，返回 http 状态码和响应体
function util_http.post_json(url, body, timeout)
    local code, headers, resp = http.request("POST", url,
        { ["Content-Type"] = "application/json" }, body,
        { timeout = timeout or DEFAULT_TIMEOUT }).wait()
    return code, resp
end

return util_http
