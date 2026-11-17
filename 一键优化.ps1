#Requires -Version 5.1
<#
.SYNOPSIS
    引望客户系统优化一键脚本（仅适用于 IMB-C47）v3.1
.DESCRIPTION
    默认全量执行；通过参数可单独运行某个模块；支持回退 USB/睡眠设置。

      -Patch          仅执行系统补丁安装
      -USB            仅执行关闭 USB 节能、重定向及系统睡眠
      -Driver         仅执行驱动包下载与安装
      -Rollback       回退 USB 节能、USB 重定向及睡眠设置（恢复默认值）
      -Help / -h / -? 显示帮助信息
      （不传参数时全量执行 Patch + USB + Driver）

.NOTES
    需以管理员身份运行。
#>

param(
    [switch]$Patch,
    [switch]$USB,
    [switch]$Driver,
    [switch]$Rollback,
    [Alias('h','?')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LogFile    = Join-Path $ScriptDir 'optimize_log.txt'
$NeedReboot = $false

# ═══════════════════════════════════════════════════════════
# 通用工具
# ═══════════════════════════════════════════════════════════

function Write-Log {
    param(
        [ValidateSet('INFO','OK','WARN','ERROR')]
        [string]$Level = 'INFO',
        [string]$Message
    )
    $ts   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level]  $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        'OK'    { Write-Host $line -ForegroundColor Green  }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red    }
        default { Write-Host $line }
    }
}

function Write-Section {
    param([string]$Title)
    $sep = '=' * 60
    Write-Host "`n$sep" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "$sep`n" -ForegroundColor Cyan
    Write-Log -Level INFO -Message "===== $Title ====="
}

# ═══════════════════════════════════════════════════════════
# Registry.pol 操作（让 gpedit 正确显示策略状态）
#
# pol 格式：8 字节头（PReg v1）+ 若干记录
# 每条记录：[key\0 ; value\0 ; type(4B) ; size(4B) ; data ]
#   "已禁用"写法：valueName = **del.xxx，type=REG_SZ(1)，data=\0\0
# ═══════════════════════════════════════════════════════════

function Get-RegPolContent {
    $polFile = "$env:SystemRoot\System32\GroupPolicy\Machine\Registry.pol"
    $header  = [byte[]](0x50,0x52,0x65,0x67,0x01,0x00,0x00,0x00)
    if (Test-Path $polFile) { return [System.IO.File]::ReadAllBytes($polFile) }
    return $header
}

function Remove-RegPolRecord {
    param([byte[]]$Bytes, [string]$Key, [string]$ValueName)
    $hdr        = $Bytes[0..7]
    $body       = if ($Bytes.Length -gt 8) { $Bytes[8..($Bytes.Length - 1)] } else { [byte[]]@() }
    $unicode    = [System.Text.Encoding]::Unicode.GetString($body)
    $pattern    = '\[' + [regex]::Escape($Key + [char]0) + ';' + [regex]::Escape($ValueName + [char]0) + ';[^\]]*\]'
    $cleaned    = [regex]::Replace($unicode, $pattern, '')
    $cleanBytes = [System.Text.Encoding]::Unicode.GetBytes($cleaned)
    $result     = New-Object byte[] ($hdr.Length + $cleanBytes.Length)
    [Array]::Copy($hdr, $result, $hdr.Length)
    [Array]::Copy($cleanBytes, 0, $result, $hdr.Length, $cleanBytes.Length)
    return $result
}

function Write-RegPolRecord {
    # 写入一条 Registry.pol 记录（同名旧记录先删除）
    param([string]$Key, [string]$ValueName, [uint32]$Type, [byte[]]$Data)
    $polFile   = "$env:SystemRoot\System32\GroupPolicy\Machine\Registry.pol"
    $bytes     = Get-RegPolContent
    $bytes     = Remove-RegPolRecord -Bytes $bytes -Key $Key -ValueName $ValueName

    $keyBytes  = [System.Text.Encoding]::Unicode.GetBytes($Key       + [char]0)
    $valBytes  = [System.Text.Encoding]::Unicode.GetBytes($ValueName + [char]0)
    $typeBytes = [BitConverter]::GetBytes($Type)
    $sizeBytes = [BitConverter]::GetBytes([uint32]$Data.Length)
    $open      = [byte[]](0x5B,0x00)
    $semi      = [byte[]](0x3B,0x00)
    $close     = [byte[]](0x5D,0x00)
    $entry     = $open + $keyBytes + $semi + $valBytes + $semi + $typeBytes + $semi + $sizeBytes + $semi + $Data + $close

    $newBytes  = New-Object byte[] ($bytes.Length + $entry.Length)
    [Array]::Copy($bytes, $newBytes, $bytes.Length)
    [Array]::Copy($entry, 0, $newBytes, $bytes.Length, $entry.Length)
    [System.IO.File]::WriteAllBytes($polFile, $newBytes)
}

function Update-GptIni {
    # 模拟 gpedit 保存行为：递增计算机策略版本号，并登记所需的 CSE
    # 否则 gpupdate 不会调用对应的客户端扩展（如 RemoteFX USB 重定向 CSE）
    param([string[]]$CseGuids = @())
    $gptFile  = "$env:SystemRoot\System32\GroupPolicy\gpt.ini"
    $toolGuid = '{D02B1F72-3407-48AE-BA88-E8213C6761F1}'   # 管理模板(计算机) 管理单元
    $allCse   = @('{35378EAC-683F-11D2-A89A-00C04FBBCFA2}') + $CseGuids   # 注册表 CSE 必须存在

    $lines = if (Test-Path $gptFile) { @(Get-Content $gptFile) } else { @('[General]') }

    # 解析现有 gPCMachineExtensionNames → 哈希表 CSE -> 工具GUID 列表
    $extMap = @{}
    $extLine = $lines | Where-Object { $_ -match '^\s*gPCMachineExtensionNames\s*=' } | Select-Object -First 1
    if ($extLine) {
        foreach ($m in [regex]::Matches(($extLine -split '=',2)[1], '\[([^\]]*)\]')) {
            $guids = [regex]::Matches($m.Groups[1].Value, '\{[0-9A-Fa-f\-]{36}\}') | ForEach-Object { $_.Value.ToUpper() }
            if ($guids) { $extMap[$guids[0]] = @($guids | Select-Object -Skip 1) }
        }
    }
    foreach ($cse in $allCse) {
        $cse = $cse.ToUpper()
        if (-not $extMap.ContainsKey($cse)) { $extMap[$cse] = @() }
        if ($extMap[$cse] -notcontains $toolGuid) { $extMap[$cse] = @($extMap[$cse]) + $toolGuid }
    }
    $extStr = ($extMap.Keys | Sort-Object | ForEach-Object {
        '[' + $_ + ((@($extMap[$_]) | Sort-Object) -join '') + ']'
    }) -join ''

    # 递增计算机版本（低 16 位），保留用户版本（高 16 位）
    $verLine = $lines | Where-Object { $_ -match '^\s*Version\s*=' } | Select-Object -First 1
    $ver = 0
    if ($verLine) { [uint32]::TryParse((($verLine -split '=',2)[1]).Trim(), [ref]$ver) | Out-Null }
    $machine = (($ver -band 0xFFFF) + 1) -band 0xFFFF
    $newVer  = ($ver -band 0xFFFF0000) -bor $machine

    $out = @('[General]', "gPCMachineExtensionNames=$extStr", "Version=$newVer")
    $out += $lines | Where-Object { $_ -notmatch '^\s*(\[General\]|gPCMachineExtensionNames\s*=|Version\s*=)' -and $_.Trim() -ne '' }
    [System.IO.File]::WriteAllLines($gptFile, [string[]]$out, [System.Text.Encoding]::ASCII)
}

function Delete-RegPolRecord {
    param([string]$Key, [string]$ValueName)
    $polFile = "$env:SystemRoot\System32\GroupPolicy\Machine\Registry.pol"
    if (-not (Test-Path $polFile)) { return }
    $bytes    = [System.IO.File]::ReadAllBytes($polFile)
    $newBytes = Remove-RegPolRecord -Bytes $bytes -Key $Key -ValueName $ValueName
    [System.IO.File]::WriteAllBytes($polFile, $newBytes)
}

# ═══════════════════════════════════════════════════════════
# Module 0a：权限检测
# ═══════════════════════════════════════════════════════════

function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Warning '需要管理员权限，正在以管理员身份重新启动脚本...'
        $fwdArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f `
            $MyInvocation.MyCommand.Definition, ($MyInvocation.Line -replace '^[^-]*','')
        Start-Process powershell -ArgumentList $fwdArgs -Verb RunAs
        exit
    }
    Write-Log -Level OK -Message '管理员权限验证通过'
}

# ═══════════════════════════════════════════════════════════
# Module 0b：产品型号检测（仅 IMB-C47 继续执行）
# ═══════════════════════════════════════════════════════════

function Test-ProductModel {
    Write-Section '产品型号检测'
    $product = $null
    try {
        $product = (Get-WmiObject -Class Win32_ComputerSystemProduct -ErrorAction Stop).Name
    } catch {
        try {
            $product = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).Name
        } catch {
            Write-Log -Level ERROR -Message "无法读取产品型号：$($_.Exception.Message)"
            exit 1
        }
    }
    Write-Log -Level INFO -Message "当前产品型号：$product"
    if ($product -notlike '*IMB-C47*') {
        Write-Log -Level ERROR -Message "产品型号不匹配（期望 IMB-C47，实际 $product），脚本退出。"
        Write-Host "`n[错误] 本脚本仅适用于 IMB-C47，当前型号为：$product" -ForegroundColor Red
        Write-Host "       脚本已退出，不做任何修改。`n" -ForegroundColor Red
        exit 1
    }
    Write-Log -Level OK -Message "型号验证通过：$product"
}

# ═══════════════════════════════════════════════════════════
# Module 1：系统补丁一键安装
# ═══════════════════════════════════════════════════════════

function Install-WindowsPatches {
    Write-Section '系统补丁安装'
    $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        try {
            Set-Service -Name wuauserv -StartupType Manual -ErrorAction Stop
            Start-Service -Name wuauserv -ErrorAction Stop
            Write-Log -Level OK -Message 'Windows Update 服务已启动'
        } catch {
            Write-Log -Level WARN -Message "启动 Windows Update 服务失败：$($_.Exception.Message)"
        }
    }
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        Write-Log -Level INFO -Message '正在搜索可用更新（可能需要几分钟）...'
        $result  = $searcher.Search("IsInstalled=0 and Type='Software'")
        $updates = $result.Updates
        if ($updates.Count -eq 0) {
            Write-Log -Level OK -Message '系统已是最新，无需安装补丁'
            return
        }
        Write-Log -Level INFO -Message "找到 $($updates.Count) 个可用更新，开始下载..."
        $downloader         = $session.CreateUpdateDownloader()
        $downloader.Updates = $updates
        $dlResult           = $downloader.Download()
        Write-Log -Level OK -Message "下载完成，结果码：$($dlResult.ResultCode)"
        Write-Log -Level INFO -Message '开始安装更新...'
        $installer         = $session.CreateUpdateInstaller()
        $installer.Updates = $updates
        $instResult        = $installer.Install()
        for ($i = 0; $i -lt $updates.Count; $i++) {
            $u   = $updates.Item($i)
            $rc  = $instResult.GetUpdateResult($i).ResultCode
            $lvl = if ($rc -eq 2) { 'OK' } else { 'WARN' }
            Write-Log -Level $lvl -Message "[$rc] $($u.Title)"
        }
        if ($instResult.RebootRequired) {
            Write-Log -Level WARN -Message '补丁安装完成，需要重启才能完全生效'
            $script:NeedReboot = $true
        } else {
            Write-Log -Level OK -Message '所有补丁安装完成，无需重启'
        }
    } catch {
        Write-Log -Level ERROR -Message "补丁安装失败：$($_.Exception.Message)"
    }
}

# ═══════════════════════════════════════════════════════════
# Module 2：关闭 USB 重定向（RemoteFX）
# 参照 关闭USB重定向.docx：gpedit → 计算机配置 → 管理模板 →
#   Windows 组件 → 远程桌面服务 → 远程桌面会话客户端
#   → RemoteFX USB 设备重定向 → 已禁用
#
# 实现：向 Registry.pol 写入 **del.fUsbRedirectionEnableMode
# 让 gpedit 显示"已禁用"，同时删除注册表里的普通键值
# ═══════════════════════════════════════════════════════════

function Disable-UsbRedirection {
    Write-Section '关闭 USB 重定向（RemoteFX）'

    $polKey = 'SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client'
    $valName = 'fUsbRedirectionEnableMode'
    $regPath = "HKLM:\$polKey"

    try {
        # 确保注册表路径存在但不设普通值（已禁用时注册表里不应有此键值）
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        Remove-ItemProperty -Path $regPath -Name $valName -Force -ErrorAction SilentlyContinue

        # 向 Registry.pol 写入 **del.valueName → gpedit 显示"已禁用"
        Write-RegPolRecord `
            -Key      $polKey `
            -ValueName "**del.$valName" `
            -Type     1 `
            -Data     ([byte[]](0x00,0x00))

        # 更新 gpt.ini：版本号 +1，并登记 RemoteFX USB 重定向 CSE（ADMX clientExtension）
        Update-GptIni -CseGuids @('{4BCD6CDE-777B-48B6-9804-43568E23545D}')

        # 刷新计算机组策略（后台静默）
        & gpupdate /target:computer /force | Out-Null

        Write-Log -Level OK -Message 'USB 重定向（RemoteFX）已禁用（gpedit 显示"已禁用"，需重启生效）'
        $script:NeedReboot = $true
    } catch {
        Write-Log -Level ERROR -Message "关闭 USB 重定向失败：$($_.Exception.Message)"
    }
}

# ═══════════════════════════════════════════════════════════
# Module 3：关闭 USB 节能（USB 选择性挂起）
# ═══════════════════════════════════════════════════════════

function Disable-UsbSelectiveSuspend {
    Write-Section '关闭 USB 节能（USB 选择性挂起）'

    # 层A：全局注册表
    try {
        $usbSvc = 'HKLM:\SYSTEM\CurrentControlSet\Services\USB'
        if (-not (Test-Path $usbSvc)) { New-Item -Path $usbSvc -Force | Out-Null }
        Set-ItemProperty -Path $usbSvc -Name 'DisableSelectiveSuspend' -Value 1 -Type DWord -Force
        Write-Log -Level OK -Message '[层A] USB 选择性挂起全局注册表已禁用'
    } catch {
        Write-Log -Level ERROR -Message "[层A] 注册表写入失败：$($_.Exception.Message)"
    }

    # 层B：当前电源方案 (powercfg)
    try {
        $schemeRaw = & powercfg /getactivescheme
        if ($schemeRaw -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
            $scheme = $Matches[1]
            & powercfg /setacvalueindex $scheme 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
            & powercfg /setdcvalueindex $scheme 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
            & powercfg /setactive $scheme
            Write-Log -Level OK -Message '[层B] 电源方案中 USB 选择性挂起已禁用（交流+直流）'
        } else {
            Write-Log -Level WARN -Message '[层B] 无法解析当前电源方案 GUID，跳过'
        }
    } catch {
        Write-Log -Level ERROR -Message "[层B] powercfg 执行失败：$($_.Exception.Message)"
    }

    # 层C：遍历 USB Root Hub 实例
    try {
        $enumPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB'
        $count    = 0
        if (Test-Path $enumPath) {
            Get-ChildItem $enumPath -ErrorAction SilentlyContinue | ForEach-Object {
                Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($_.PSChildName -match 'Root_Hub|RootHub|root_hub') {
                        $dpPath = Join-Path $_.PSPath 'Device Parameters'
                        if (Test-Path $dpPath) {
                            try {
                                Set-ItemProperty -Path $dpPath -Name 'AllowIdleIrpInD3' -Value 0 -Type DWord -Force
                                $count++
                            } catch {}
                        }
                    }
                }
            }
        }
        $msg = if ($count -gt 0) { "[层C] 已对 $count 个 USB Root Hub 实例关闭节能唤醒" } `
                                 else { '[层C] 未找到 Root Hub 设备实例，跳过' }
        Write-Log -Level INFO -Message $msg
    } catch {
        Write-Log -Level ERROR -Message "[层C] 遍历设备管理器注册表失败：$($_.Exception.Message)"
    }
}

# ═══════════════════════════════════════════════════════════
# Module 4：关闭系统睡眠 / 休眠
# ═══════════════════════════════════════════════════════════

function Disable-SleepAndHibernate {
    Write-Section '关闭系统睡眠与休眠'

    $cmds = @(
        @{ Desc = '关闭显示器(AC)'; Cmd = { powercfg /change monitor-timeout-ac 0 } }
        @{ Desc = '关闭显示器(DC)'; Cmd = { powercfg /change monitor-timeout-dc 0 } }
        @{ Desc = '关闭硬盘(AC)';   Cmd = { powercfg /change disk-timeout-ac 0 } }
        @{ Desc = '关闭硬盘(DC)';   Cmd = { powercfg /change disk-timeout-dc 0 } }
        @{ Desc = '睡眠(AC)';       Cmd = { powercfg /change standby-timeout-ac 0 } }
        @{ Desc = '睡眠(DC)';       Cmd = { powercfg /change standby-timeout-dc 0 } }
        @{ Desc = '休眠(AC)';       Cmd = { powercfg /change hibernate-timeout-ac 0 } }
        @{ Desc = '休眠(DC)';       Cmd = { powercfg /change hibernate-timeout-dc 0 } }
        @{ Desc = '禁用休眠';       Cmd = { powercfg /h off } }
    )
    foreach ($item in $cmds) {
        try {
            & $item.Cmd
            Write-Log -Level OK -Message "已设置：$($item.Desc)"
        } catch {
            Write-Log -Level ERROR -Message "设置失败 [$($item.Desc)]：$($_.Exception.Message)"
        }
    }
}

# USB + 睡眠组合
function Invoke-UsbSleepDisable {
    Disable-UsbRedirection
    Disable-UsbSelectiveSuspend
    Disable-SleepAndHibernate
}

# ═══════════════════════════════════════════════════════════
# Module Rollback：回退 USB 节能、重定向及睡眠设置
# ═══════════════════════════════════════════════════════════

function Invoke-Rollback {
    Write-Section '回退 USB / 睡眠设置（恢复默认）'

    $polKey  = 'SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client'
    $valName = 'fUsbRedirectionEnableMode'
    $regPath = "HKLM:\$polKey"

    # --- 回退 USB 重定向：移除 Registry.pol 中的禁用记录，gpedit 恢复"未配置" ---
    try {
        Delete-RegPolRecord -Key $polKey -ValueName "**del.$valName"
        Update-GptIni -CseGuids @('{4BCD6CDE-777B-48B6-9804-43568E23545D}')
        Remove-ItemProperty -Path $regPath -Name $valName -Force -ErrorAction SilentlyContinue
        & gpupdate /target:computer /force | Out-Null
        Write-Log -Level OK -Message '[回退] USB 重定向策略已恢复"未配置"'
        $script:NeedReboot = $true
    } catch {
        Write-Log -Level ERROR -Message "[回退] USB 重定向恢复失败：$($_.Exception.Message)"
    }

    # --- 回退 USB 节能（层A）---
    try {
        $usbSvc = 'HKLM:\SYSTEM\CurrentControlSet\Services\USB'
        Remove-ItemProperty -Path $usbSvc -Name 'DisableSelectiveSuspend' -Force -ErrorAction SilentlyContinue
        Write-Log -Level OK -Message '[回退] USB 选择性挂起全局注册表值已移除'
    } catch {
        Write-Log -Level ERROR -Message "[回退] USB 节能注册表恢复失败：$($_.Exception.Message)"
    }

    # --- 回退 USB 节能（层B：电源方案恢复默认值 1=启用）---
    try {
        $schemeRaw = & powercfg /getactivescheme
        if ($schemeRaw -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
            $scheme = $Matches[1]
            & powercfg /setacvalueindex $scheme 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 1
            & powercfg /setdcvalueindex $scheme 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 1
            & powercfg /setactive $scheme
            Write-Log -Level OK -Message '[回退] 电源方案 USB 选择性挂起已恢复（交流+直流 = 启用）'
        }
    } catch {
        Write-Log -Level ERROR -Message "[回退] powercfg USB 恢复失败：$($_.Exception.Message)"
    }

    # --- 回退 USB Root Hub AllowIdleIrpInD3（层C）---
    try {
        $enumPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB'
        $count    = 0
        if (Test-Path $enumPath) {
            Get-ChildItem $enumPath -ErrorAction SilentlyContinue | ForEach-Object {
                Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($_.PSChildName -match 'Root_Hub|RootHub|root_hub') {
                        $dpPath = Join-Path $_.PSPath 'Device Parameters'
                        if (Test-Path $dpPath) {
                            try {
                                Set-ItemProperty -Path $dpPath -Name 'AllowIdleIrpInD3' -Value 1 -Type DWord -Force
                                $count++
                            } catch {}
                        }
                    }
                }
            }
        }
        if ($count -gt 0) { Write-Log -Level OK -Message "[回退] 已对 $count 个 USB Root Hub 恢复节能唤醒" }
    } catch {
        Write-Log -Level ERROR -Message "[回退] USB Root Hub 注册表恢复失败：$($_.Exception.Message)"
    }

    # --- 回退睡眠：恢复 Windows 默认值 ---
    $defaults = @(
        @{ Desc = '显示器超时(AC) 恢复 10 分钟'; Cmd = { powercfg /change monitor-timeout-ac 10 } }
        @{ Desc = '显示器超时(DC) 恢复 5 分钟';  Cmd = { powercfg /change monitor-timeout-dc 5  } }
        @{ Desc = '硬盘超时(AC)   恢复 20 分钟'; Cmd = { powercfg /change disk-timeout-ac 20 } }
        @{ Desc = '硬盘超时(DC)   恢复 10 分钟'; Cmd = { powercfg /change disk-timeout-dc 10 } }
        @{ Desc = '睡眠超时(AC)   恢复 30 分钟'; Cmd = { powercfg /change standby-timeout-ac 30 } }
        @{ Desc = '睡眠超时(DC)   恢复 15 分钟'; Cmd = { powercfg /change standby-timeout-dc 15 } }
        @{ Desc = '休眠超时 恢复 0（从不）';      Cmd = { powercfg /change hibernate-timeout-ac 0; powercfg /change hibernate-timeout-dc 0 } }
        @{ Desc = '重新启用休眠';                   Cmd = { powercfg /h on } }
    )
    foreach ($item in $defaults) {
        try {
            & $item.Cmd
            Write-Log -Level OK -Message "[回退] $($item.Desc)"
        } catch {
            Write-Log -Level ERROR -Message "[回退] 失败 [$($item.Desc)]：$($_.Exception.Message)"
        }
    }

    Write-Log -Level OK -Message '回退完成，建议重启以使所有策略生效'
    $script:NeedReboot = $true
}

# ═══════════════════════════════════════════════════════════
# Module 5：IMB-C47 驱动包自动下载并安装
# ═══════════════════════════════════════════════════════════

function Install-ImbC47Drivers {
    Write-Section 'IMB-C47 驱动包下载与安装'

    $driverDir = Join-Path $ScriptDir '_drivers'
    if (-not (Test-Path $driverDir)) {
        New-Item -ItemType Directory -Path $driverDir -Force | Out-Null
    }

    $pageUrl = 'https://www.adlinktech.com.cn/Products/DownloadSoftwareDriver.aspx?lang=zh_cn&pdNo=2184&kind=DR'
    Write-Log -Level INFO -Message "正在解析驱动下载页面：$pageUrl"

    $links = @()
    try {
        $resp  = Invoke-WebRequest -Uri $pageUrl -UseBasicParsing -TimeoutSec 60
        $hrefs = ($resp.Links | Where-Object { $_.href -match '\.(zip|exe|msi)(\?.*)?$' }).href
        foreach ($h in $hrefs) {
            if ($h -match '^http')  { $links += $h }
            elseif ($h -match '^/') { $links += "https://www.adlinktech.com.cn$h" }
        }
        if ($links.Count -eq 0) {
            $m2 = [regex]::Matches($resp.Content, 'href="([^"]+\.(zip|exe|msi)[^"]*)"')
            foreach ($m in $m2) {
                $href = $m.Groups[1].Value
                if ($href -match '^http')  { $links += $href }
                elseif ($href -match '^/') { $links += "https://www.adlinktech.com.cn$href" }
            }
        }
        Write-Log -Level INFO -Message "解析到 $($links.Count) 个驱动下载链接"
    } catch {
        Write-Log -Level ERROR -Message "页面解析失败：$($_.Exception.Message)"
        Write-Log -Level WARN  -Message "驱动模块已跳过，请手动前往官网下载：$pageUrl"
        return
    }

    if ($links.Count -eq 0) {
        Write-Log -Level WARN -Message '未解析到驱动链接（页面可能使用 JS 动态加载），请手动下载。'
        Write-Log -Level INFO -Message "官网地址：$pageUrl"
        return
    }

    foreach ($url in ($links | Select-Object -Unique)) {
        $fileName = [System.IO.Path]::GetFileName(($url -split '\?')[0])
        $destFile = Join-Path $driverDir $fileName
        Write-Log -Level INFO -Message "下载：$fileName"
        try {
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($url, $destFile)
            Write-Log -Level OK -Message "下载完成：$fileName"
        } catch {
            Write-Log -Level ERROR -Message "下载失败 [$fileName]：$($_.Exception.Message)"
            continue
        }
        Invoke-DriverInstall -FilePath $destFile -DriverDir $driverDir
    }

    Write-Log -Level OK -Message '驱动模块执行完毕'
}

function Invoke-DriverInstall {
    param([string]$FilePath, [string]$DriverDir)
    $ext  = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $name = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    try {
        if ($ext -eq '.zip') {
            $extractDir = Join-Path $DriverDir $name
            New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($FilePath, $extractDir)
            Write-Log -Level INFO -Message "解压：$name"
            $inner = Get-ChildItem $extractDir -Recurse -Include '*.exe','*.msi' |
                     Sort-Object { if ($_.Name -match 'setup|install') { 0 } else { 1 } } |
                     Select-Object -First 1
            if ($inner) {
                Invoke-DriverInstall -FilePath $inner.FullName -DriverDir $DriverDir
            } else {
                Get-ChildItem $extractDir -Recurse -Filter '*.inf' | ForEach-Object {
                    Write-Log -Level INFO -Message "pnputil 安装：$($_.Name)"
                    & pnputil /add-driver $_.FullName /install | Out-Null
                    Write-Log -Level OK -Message "pnputil 完成：$($_.Name)"
                }
            }
        } elseif ($ext -eq '.exe') {
            Write-Log -Level INFO -Message "静默安装(EXE)：$name"
            $proc = Start-Process -FilePath $FilePath -ArgumentList '/s /norestart' -Wait -PassThru
            if ($proc.ExitCode -notin @(0, 3010)) {
                $proc = Start-Process -FilePath $FilePath -ArgumentList '/silent /norestart' -Wait -PassThru
            }
            $lvl = if ($proc.ExitCode -in @(0, 3010)) { 'OK' } else { 'WARN' }
            Write-Log -Level $lvl -Message "安装结果(EXE) $name ExitCode=$($proc.ExitCode)"
            if ($proc.ExitCode -eq 3010) { $script:NeedReboot = $true }
        } elseif ($ext -eq '.msi') {
            Write-Log -Level INFO -Message "静默安装(MSI)：$name"
            $proc = Start-Process -FilePath 'msiexec.exe' `
                        -ArgumentList "/i `"$FilePath`" /quiet /norestart" -Wait -PassThru
            $lvl = if ($proc.ExitCode -in @(0, 3010)) { 'OK' } else { 'WARN' }
            Write-Log -Level $lvl -Message "安装结果(MSI) $name ExitCode=$($proc.ExitCode)"
            if ($proc.ExitCode -eq 3010) { $script:NeedReboot = $true }
        } else {
            Write-Log -Level WARN -Message "未知扩展名，跳过：$FilePath"
        }
    } catch {
        Write-Log -Level ERROR -Message "安装异常 [$name]：$($_.Exception.Message)"
    }
}

# ═══════════════════════════════════════════════════════════
# 重启提示
# ═══════════════════════════════════════════════════════════

function Prompt-Reboot {
    Write-Section '完成'
    if ($script:NeedReboot) {
        Write-Host '操作完成，需要重启才能完全生效。' -ForegroundColor Yellow
        $choice = Read-Host '是否立即重启？(Y/N)'
        if ($choice -match '^[Yy]') {
            Write-Log -Level INFO -Message '用户确认重启'
            Restart-Computer -Force
        } else {
            Write-Log -Level INFO -Message '用户选择稍后重启'
            Write-Host '请稍后手动重启以使所有设置生效。' -ForegroundColor Yellow
        }
    } else {
        Write-Host '所有设置已生效，无需重启。' -ForegroundColor Green
    }
    Write-Host "`n日志已保存至：$LogFile" -ForegroundColor Cyan
}

# ═══════════════════════════════════════════════════════════
# 主入口
# ═══════════════════════════════════════════════════════════

function Main {
    # -Help 显示帮助后退出
    if ($Help) {
        Write-Host @'

用法：
  .\一键优化.ps1                不带参数，全量执行所有模块
  .\一键优化.ps1 -Patch         仅安装 Windows 系统补丁
  .\一键优化.ps1 -USB           仅关闭 USB 节能、USB 重定向及系统睡眠/休眠
  .\一键优化.ps1 -Driver        仅下载并安装 IMB-C47 驱动包
  .\一键优化.ps1 -Rollback      回退 USB 节能、USB 重定向及睡眠设置（恢复默认值）
  .\一键优化.ps1 -Help          显示此帮助信息（也可用 -h 或 -?）

参数可组合，例如：
  .\一键优化.ps1 -Patch -Driver  只打补丁 + 装驱动，跳过 USB/睡眠设置

注意：
  - 本脚本仅适用于 IMB-C47 产品型号
  - 需以管理员身份运行
  - 日志输出至脚本同级目录 optimize_log.txt

'@
        exit 0
    }

    Write-Host ''
    Write-Host '==================================================' -ForegroundColor White
    Write-Host '   引望客户系统优化脚本  v3.1' -ForegroundColor White
    Write-Host '   仅适用于 IMB-C47 · 纯 PowerShell · 零第三方依赖' -ForegroundColor DarkGray
    Write-Host '==================================================' -ForegroundColor White

    if (-not (Test-Path $LogFile)) {
        New-Item -Path $LogFile -ItemType File -Force | Out-Null
    }

    $runAll      = -not ($Patch -or $USB -or $Driver -or $Rollback)
    $modeDisplay = if ($runAll)       { '全量执行' }
                   elseif ($Rollback) { '回退模式' }
                   else {
                       $parts = @()
                       if ($Patch)  { $parts += '补丁安装' }
                       if ($USB)    { $parts += 'USB/睡眠关闭' }
                       if ($Driver) { $parts += '驱动安装' }
                       $parts -join ' + '
                   }

    Write-Log -Level INFO -Message "========== 脚本启动 [$modeDisplay] =========="

    Assert-Admin
    # Test-ProductModel  # 本机测试时暂时关闭产品校验

    if ($Rollback) {
        Invoke-Rollback
    } else {
        if ($runAll -or $Patch)  { Install-WindowsPatches  }
        if ($runAll -or $USB)    { Invoke-UsbSleepDisable  }
        if ($runAll -or $Driver) { Install-ImbC47Drivers   }
    }

    Prompt-Reboot
    Write-Log -Level INFO -Message '========== 脚本结束 =========='
}

Main
