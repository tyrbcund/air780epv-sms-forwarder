-- util_net.lua · 网络状态判断（兼容 userdata 库）
--
-- 踩过的坑：
-- ① 某些固件里 socket 表存在但没有 isReady —— 直接调用会抛错，
--    未捕获错误 = VM 退出 = 15 秒后重启。
-- ② 库可能是 userdata 而不是 table，所以 type(x)=="table" 判断不可靠。
--    统一走 util_lib.hasFn / field。

local util_lib = require "util_lib"

local util_net = {}

function util_net.isReady()
    if util_lib.hasFn(socket, "isReady") then
        local ok, r = util_lib.call(socket, "isReady")
        if ok then return r and true or false end
    end

    if util_lib.hasFn(socket, "ready") then
        local ok, r = util_lib.call(socket, "ready")
        if ok then return r and true or false end
    end

    if util_lib.hasFn(mobile, "status") then
        local ok, s = util_lib.call(mobile, "status")
        if ok then return s == 1 end
    end

    -- 判断不了就别拦着，发失败会走重试
    return true
end

return util_net
