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
# 电源方案工具（powercfg 为外部命令，失败不会抛异常，需检查退出码）
# ═══════════════════════════════════════════════════════════

# 文档 关闭USB节能及系统睡眠优化设置.docx 中"电源选项 → 高级设置"涉及的项
$PowerSettings = @(
    @{ Desc = '硬盘 → 在此时间后关闭硬盘';            Sub = 'SUB_DISK';                             Set = 'DISKIDLE';                             Off = 0; Default = @{ AC = 1200; DC = 600 } }
    @{ Desc = '睡眠 → 在此时间后睡眠';                Sub = 'SUB_SLEEP';                            Set = 'STANDBYIDLE';                          Off = 0; Default = @{ AC = 1800; DC = 900 } }
    @{ Desc = '睡眠 → 允许混合睡眠';                  Sub = 'SUB_SLEEP';                            Set = 'HYBRIDSLEEP';                          Off = 0; Default = @{ AC = 1;    DC = 1   } }
    @{ Desc = '睡眠 → 在此时间后休眠';                Sub = 'SUB_SLEEP';                            Set = 'HIBERNATEIDLE';                        Off = 0; Default = @{ AC = 0;    DC = 0   } }
    @{ Desc = 'USB 设置 → USB 选择性暂停设置';         Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Set = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Off = 0; Default = @{ AC = 1;    DC = 1   } }
    @{ Desc = 'PCI Express → 链接状态电源管理';        Sub = 'SUB_PCIEXPRESS';                       Set = 'ASPM';                                 Off = 0; Default = @{ AC = 1;    DC = 2   } }
)

function Invoke-PowerCfg {
    # 用 $args 透传参数；不重定向 stderr（PS 5.1 + EAP=Stop 下 2>&1 会误抛异常）
    $out = & powercfg @args
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg $($args -join ' ') 失败（退出码 $LASTEXITCODE）：$($out -join ' ')"
    }
    return $out
}

function Get-PowerSettingValue {
    # 返回 @{ AC = int; DC = int }（当前活动方案）
    param([string]$Sub, [string]$Set)
    $out  = Invoke-PowerCfg /q SCHEME_CURRENT $Sub $Set
    # 输出中最后两个 0x 值依次为"当前交流/直流电源设置索引"（中英文系统通用）
    $hexs = [regex]::Matches(($out -join "`n"), '0x([0-9a-fA-F]{8})') | ForEach-Object { [Convert]::ToInt64($_.Groups[1].Value, 16) }
    $hexs = @($hexs)
    if ($hexs.Count -lt 2) { throw "无法解析 powercfg /q 输出：$Sub $Set" }
    return @{ AC = $hexs[-2]; DC = $hexs[-1] }
}

function Set-PowerSettingValue {
    param([string]$Sub, [string]$Set, [int]$AC, [int]$DC)
    Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT $Sub $Set $AC | Out-Null
    Invoke-PowerCfg /setdcvalueindex SCHEME_CURRENT $Sub $Set $DC | Out-Null
}

# ═══════════════════════════════════════════════════════════
# Module 3：关闭 USB 节能
# 参照 关闭USB节能及系统睡眠优化设置.docx：
#   设备管理器 → 通用串行总线控制器 → 所有 USB 设备 → 电源管理
#   → 取消勾选"允许计算机关闭此设备以节约电源"
# 实现：该勾选框对应 WMI root\wmi:MSPower_DeviceEnable.Enable（与设备管理器 UI 同一接口）
# ═══════════════════════════════════════════════════════════

function Set-UsbDevicePowerManagement {
    # $Enable = $false → 取消勾选；$true → 恢复勾选
    param([bool]$Enable, [string]$Prefix = '')
    # 设备管理器"通用串行总线控制器"= 设备类 USB
    $ids = @(Get-PnpDevice -Class USB -ErrorAction Stop | ForEach-Object { $_.InstanceId.ToUpper() })
    $pm  = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Stop)
    $ok = 0; $fail = 0
    foreach ($inst in $pm) {
        # InstanceName = <设备实例ID>_<序号>
        $devId = ($inst.InstanceName -replace '_\d+$', '').ToUpper()
        if ($ids -notcontains $devId) { continue }
        try {
            if ($inst.Enable -ne $Enable) {
                Set-CimInstance -InputObject $inst -Property @{ Enable = $Enable } -ErrorAction Stop
            }
            $ok++
        } catch {
            $fail++
            Write-Log -Level ERROR -Message "${Prefix}设置设备电源管理失败：${devId}（$($_.Exception.Message)）"
        }
    }
    return @{ OK = $ok; Fail = $fail }
}

function Disable-UsbSelectiveSuspend {
    Write-Section '关闭 USB 节能'

    # 层A：全局注册表禁用 USB 选择性挂起
    try {
        $usbSvc = 'HKLM:\SYSTEM\CurrentControlSet\Services\USB'
        if (-not (Test-Path $usbSvc)) { New-Item -Path $usbSvc -Force | Out-Null }
        Set-ItemProperty -Path $usbSvc -Name 'DisableSelectiveSuspend' -Value 1 -Type DWord -Force
        Write-Log -Level OK -Message '[层A] USB 选择性挂起全局注册表已禁用'
    } catch {
        Write-Log -Level ERROR -Message "[层A] 注册表写入失败：$($_.Exception.Message)"
    }

    # 层B：设备管理器 → 通用串行总线控制器 → 所有设备 → 取消"允许计算机关闭此设备以节约电源"
    try {
        $r = Set-UsbDevicePowerManagement -Enable $false -Prefix '[层B] '
        if ($r.OK -eq 0 -and $r.Fail -eq 0) {
            Write-Log -Level INFO -Message '[层B] 未找到带"电源管理"选项的 USB 设备，跳过'
        } elseif ($r.Fail -eq 0) {
            Write-Log -Level OK -Message "[层B] 已对 $($r.OK) 个 USB 设备取消勾选`"允许计算机关闭此设备以节约电源`""
        } else {
            Write-Log -Level WARN -Message "[层B] 成功 $($r.OK) 个，失败 $($r.Fail) 个"
        }
    } catch {
        Write-Log -Level ERROR -Message "[层B] 设置 USB 设备电源管理失败：$($_.Exception.Message)"
    }
    # USB 选择性暂停（电源选项）在 Module 4 中与其他电源项统一设置并校验
}

# ═══════════════════════════════════════════════════════════
# Module 4：电源选项（当前活动方案）
# 参照 关闭USB节能及系统睡眠优化设置.docx → 电源选项 → 高级设置：
#   关闭硬盘=从不、睡眠=从不、混合睡眠=关闭、休眠=从不、
#   USB 选择性暂停=已禁用、PCI Express 链接状态电源管理=关闭
# 注意：不执行 powercfg /h off —— 关闭休眠后"允许混合睡眠/在此时间后休眠"
#       会从电源选项界面消失，与文档截图不一致；休眠超时已设为"从不"。
# ═══════════════════════════════════════════════════════════

function Disable-SleepAndHibernate {
    Write-Section '电源选项：关闭睡眠 / 休眠 / 硬盘 / USB / PCIe 节能'

    try {
        $scheme = (Invoke-PowerCfg /getactivescheme) -join ' '
        Write-Log -Level INFO -Message "当前活动电源方案：$($scheme.Trim())"
    } catch {
        Write-Log -Level ERROR -Message "无法获取当前电源方案：$($_.Exception.Message)"
        return
    }

    # 显示器关闭（文档未要求，保持原脚本行为）
    try {
        Invoke-PowerCfg /change monitor-timeout-ac 0 | Out-Null
        Invoke-PowerCfg /change monitor-timeout-dc 0 | Out-Null
        Write-Log -Level OK -Message '已设置：关闭显示器 = 从不（交流+直流）'
    } catch {
        Write-Log -Level ERROR -Message "设置失败 [关闭显示器]：$($_.Exception.Message)"
    }

    foreach ($s in $PowerSettings) {
        try {
            Set-PowerSettingValue -Sub $s.Sub -Set $s.Set -AC $s.Off -DC $s.Off
        } catch {
            Write-Log -Level ERROR -Message "设置失败 [$($s.Desc)]：$($_.Exception.Message)"
        }
    }

    try {
        Invoke-PowerCfg /setactive SCHEME_CURRENT | Out-Null
    } catch {
        Write-Log -Level ERROR -Message "重新激活电源方案失败：$($_.Exception.Message)"
    }

    # 回读校验
    foreach ($s in $PowerSettings) {
        try {
            $v = Get-PowerSettingValue -Sub $s.Sub -Set $s.Set
            if ($v.AC -eq $s.Off -and $v.DC -eq $s.Off) {
                Write-Log -Level OK -Message "已生效：$($s.Desc)（交流=$($v.AC) 直流=$($v.DC)）"
            } else {
                Write-Log -Level ERROR -Message "未生效：$($s.Desc)（交流=$($v.AC) 直流=$($v.DC)，期望 $($s.Off)）"
            }
        } catch {
            Write-Log -Level WARN -Message "无法校验 [$($s.Desc)]：$($_.Exception.Message)"
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

    # --- 回退 USB 设备电源管理：恢复勾选"允许计算机关闭此设备以节约电源" ---
    try {
        $r = Set-UsbDevicePowerManagement -Enable $true -Prefix '[回退] '
        Write-Log -Level OK -Message "[回退] 已对 $($r.OK) 个 USB 设备恢复勾选`"允许计算机关闭此设备以节约电源`"（失败 $($r.Fail) 个）"
    } catch {
        Write-Log -Level ERROR -Message "[回退] USB 设备电源管理恢复失败：$($_.Exception.Message)"
    }

    # --- 回退电源选项：恢复 Windows"平衡"方案默认值 ---
    foreach ($s in $PowerSettings) {
        try {
            Set-PowerSettingValue -Sub $s.Sub -Set $s.Set -AC $s.Default.AC -DC $s.Default.DC
            Write-Log -Level OK -Message "[回退] $($s.Desc) 恢复默认（交流=$($s.Default.AC) 直流=$($s.Default.DC)）"
        } catch {
            Write-Log -Level ERROR -Message "[回退] 失败 [$($s.Desc)]：$($_.Exception.Message)"
        }
    }
    try {
        Invoke-PowerCfg /change monitor-timeout-ac 10 | Out-Null
        Invoke-PowerCfg /change monitor-timeout-dc 5  | Out-Null
        Write-Log -Level OK -Message '[回退] 关闭显示器 恢复默认（交流 10 分钟 / 直流 5 分钟）'
    } catch {
        Write-Log -Level ERROR -Message "[回退] 失败 [关闭显示器]：$($_.Exception.Message)"
    }
    try {
        Invoke-PowerCfg /h on | Out-Null   # 兼容旧版脚本曾执行过 powercfg /h off
        Write-Log -Level OK -Message '[回退] 休眠功能已启用'
    } catch {
        Write-Log -Level WARN -Message "[回退] 启用休眠失败（部分设备/虚拟机不支持休眠）：$($_.Exception.Message)"
    }
    try {
        Invoke-PowerCfg /setactive SCHEME_CURRENT | Out-Null
    } catch {
        Write-Log -Level ERROR -Message "[回退] 重新激活电源方案失败：$($_.Exception.Message)"
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
