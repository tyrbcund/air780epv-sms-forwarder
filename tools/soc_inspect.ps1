# soc_inspect.ps1 · 固件体检
# 用法： .\soc_inspect.ps1 -Soc "C:\path\to\LuatOS-SoC_V20XX_EC718PV.soc"
#
# 它会解出 info.json 和 luat_conf_bsp.h，然后回答四个问题：
#   1. 是不是 EC718PV（带 VoLTE）的固件？
#   2. 有没有编 TLS（能不能用 HTTPS）？
#   3. 有没有 FSKV（能不能持久化队列）？
#   4. 脚本区多大、Lua 堆多大？
#
# 只读，不碰设备。

param(
    [Parameter(Mandatory = $true)][string]$Soc
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Soc)) { Write-Host "文件不存在: $Soc" -ForegroundColor Red; exit 1 }
$socItem = Get-Item -LiteralPath $Soc

# ---------- 找 7z ----------
$sevenZip = $null
foreach ($p in @(
    'E:\EC730PV\_temp\uis_download\7zip\32\7z.exe',
    'C:\Program Files\7-Zip\7z.exe',
    'C:\Program Files (x86)\7-Zip\7z.exe'
)) {
    if (Test-Path -LiteralPath $p) { $sevenZip = $p; break }
}
if (-not $sevenZip) {
    $found = Get-ChildItem 'C:\','D:\','E:\' -Filter '7z.exe' -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $sevenZip = $found.FullName }
}
if (-not $sevenZip) { Write-Host "找不到 7z.exe，无法解包" -ForegroundColor Red; exit 1 }

# ---------- 是不是 7z ----------
$fs = [System.IO.File]::OpenRead($Soc)
$magic = New-Object byte[] 6
$null = $fs.Read($magic, 0, 6)
$fs.Close()
$is7z = ($magic[0] -eq 0x37 -and $magic[1] -eq 0x7A -and $magic[2] -eq 0xBC -and $magic[3] -eq 0xAF)

Write-Host ""
Write-Host "===== $($socItem.Name) =====" -ForegroundColor Cyan
Write-Host ("大小: {0:N2} MB    修改: {1}" -f ($socItem.Length / 1MB), $socItem.LastWriteTime)
if (-not $is7z) {
    Write-Host "不是 7z 包（可能是别的格式或已损坏）——停止" -ForegroundColor Red
    exit 1
}

# ---------- 解包关键文件 ----------
$tmp = Join-Path $env:TEMP ("soc_inspect_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    & $sevenZip x $Soc -o"$tmp" 'info.json' 'luat_conf_bsp.h' -y 2>&1 | Out-Null

    $infoPath = Join-Path $tmp 'info.json'
    $hdrPath  = Join-Path $tmp 'luat_conf_bsp.h'

    # ---------- info.json ----------
    if (Test-Path $infoPath) {
        $info = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json

        # info.json 里尺寸有两种写法：
        #   数字   -> 单位已经是 KB（如 script.size = 128）
        #   字符串 -> 十六进制字节数（如 filesystem.size = "20000" = 0x20000 = 128KB）
        function ConvertTo-Kb($v) {
            if ($null -eq $v) { return '?' }
            if ($v -is [string]) {
                if ($v -match '^[0-9A-Fa-f]+$') {
                    return [string][math]::Round(([Convert]::ToInt64($v, 16)) / 1KB, 0)
                }
                return $v
            }
            return [string]$v
        }

        $scriptKb = ConvertTo-Kb $info.rom.fs.script.size
        $fsKb     = ConvertTo-Kb $info.rom.fs.filesystem.size
        $logBr    = $info.user.log_br
        $luaKb    = $info.chip.ram.lua
        $sysKb    = $info.chip.ram.sys
        $useLuac  = $info.script.'use-luac'
        $coreVer  = $info.rom.'version-core'
        $bspVer   = $info.rom.'version-bsp'
        $chipType = $info.chip.type

        Write-Host ""
        Write-Host "[分区 / 内存]" -ForegroundColor Yellow
        Write-Host ("  芯片类型      : {0}" -f $chipType)
        Write-Host ("  版本          : core={0}  bsp={1}" -f $coreVer, $bspVer)
        Write-Host ("  脚本区        : {0} KB（luadb）" -f $scriptKb)
        Write-Host ("  文件系统      : {0} KB（lfs）" -f $fsKb)
        Write-Host ("  Lua 堆        : {0} KB / 系统 {1} KB" -f $luaKb, $sysKb)
        Write-Host ("  日志波特率    : {0}" -f $logBr)
        Write-Host ("  脚本编译      : use-luac={0}" -f $useLuac)
    }
    else {
        Write-Host "没有 info.json" -ForegroundColor Red
    }

    # ---------- luat_conf_bsp.h ----------
    if (Test-Path $hdrPath) {
        $hdr = Get-Content -LiteralPath $hdrPath -Raw -Encoding UTF8

        $flags = [ordered]@{
            'TLS (HTTPS 能力)' = 'LUAT_USE_TLS'
            'FSKV (持久化)'    = 'LUAT_USE_FSKV'
            'SMS (短信)'       = 'LUAT_USE_SMS'
            'NETWORK (含 http)'= 'LUAT_USE_NETWORK'
            'DNS'              = 'LUAT_USE_DNS'
            'MOBILE'           = 'LUAT_USE_MOBILE'
            'VoLTE (EPV 标志)' = 'LUAT_USE_VOLTE'
            'UART'             = 'LUAT_USE_UART'
        }

        Write-Host ""
        Write-Host "[编译开关]" -ForegroundColor Yellow
        $hasVolte = $false
        $hasTls   = $false
        $hasFskv  = $false
        foreach ($k in $flags.Keys) {
            $macro = $flags[$k]
            # 注意：宏可能写成 #define X 1，也可能只有 #define X（无值）
            $on = [regex]::IsMatch($hdr, "(?m)^\s*#define\s+$macro\b")
            $commented = [regex]::IsMatch($hdr, "(?m)^\s*//\s*#define\s+$macro\b")
            $state = if ($on) { '✅ 有' } elseif ($commented) { '❌ 被注释掉' } else { '❌ 未出现' }
            Write-Host ("  {0,-20}: {1}" -f $k, $state)
            if ($macro -eq 'LUAT_USE_VOLTE'  -and $on) { $hasVolte = $true }
            if ($macro -eq 'LUAT_USE_TLS'    -and $on) { $hasTls = $true }
            if ($macro -eq 'LUAT_USE_FSKV'   -and $on) { $hasFskv = $true }
        }

        # ---------- 结论 ----------
        Write-Host ""
        Write-Host "[结论]" -ForegroundColor Yellow
        if ($hasVolte) {
            Write-Host "  机型匹配 : ✅ 带 VoLTE，是 EC718PV 系（可用）" -ForegroundColor Green
        } else {
            Write-Host "  机型匹配 : ⚠️ 没有 VoLTE —— 可能是 EC718P（非 V），刷到 EPV 上有风险" -ForegroundColor Yellow
        }
        if ($hasTls) {
            Write-Host "  HTTPS    : ✅ 可以试 https" -ForegroundColor Green
        } else {
            Write-Host "  HTTPS    : ❌ 没编 TLS，只能用 http" -ForegroundColor Yellow
        }
        if ($hasFskv) {
            Write-Host "  持久化   : ✅ 有 FSKV，队列可以掉电不丢" -ForegroundColor Green
        } else {
            Write-Host "  持久化   : ❌ 没 FSKV，重启会丢队列" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "没有 luat_conf_bsp.h（可能是纯 CSDK 包，不是完整固件）" -ForegroundColor Yellow
    }
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
