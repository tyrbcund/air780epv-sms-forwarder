-- util_lib.lua · 库访问兼容层
--
-- 这版固件里，LuatOS 的库大多不是 table 而是 userdata
-- （sms、gpio 都已实测）。所以任何 `type(x) == "table"` 的判断都是错的，
-- 会把明明可用的库判成"不存在"。
--
-- 统一用这两个函数访问，兼容 table / userdata / 甚至函数式库。

local util_lib = {}

--- 安全取字段，取不到返回 nil（不抛错）
function util_lib.field(t, name)
    if t == nil then return nil end
    local ok, v = pcall(function() return t[name] end)
    if ok then return v end
    return nil
end

--- 该字段是不是可调用函数
function util_lib.hasFn(t, name)
    return type(util_lib.field(t, name)) == "function"
end

--- 带 pcall 的调用：ok, 返回值
function util_lib.call(t, name, ...)
    local f = util_lib.field(t, name)
    if type(f) ~= "function" then return false, nil end
    return pcall(f, ...)
end

return util_lib
