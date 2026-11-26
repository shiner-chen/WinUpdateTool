#Requires -Version 5.1
<#
.SYNOPSIS
    WinUpdateTool v3.1
.DESCRIPTION
    默认全量执行；通过参数可单独运行某个模块；支持回退 USB/睡眠设置。

      -Patch          仅执行系统补丁安装
      -USB            仅执行关闭 USB 节能、重定向及系统睡眠
      -Driver         导入驱动备份或安装离线驱动及软件包
      -Online         补丁使用 Windows Update，驱动使用 ADLINK 官网
      -PatchPath      指定离线补丁目录，默认为脚本同级 WinPatches
      -DriverPath     指定驱动导出或离线安装的目录
      -ExportDrivers  导出第三方驱动，默认为脚本同级 ExportedDrivers
      -SelectDrivers  导出时在终端按设备勾选驱动
      -AdlinkLogin    提示输入已登录的 ADLINK 浏览器会话 Cookie
      -AdlinkPassword 在查询驱动目录前打开 ADLINK 登录窗口
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
    [switch]$Online,
    [ValidateNotNullOrEmpty()]
    [string]$PatchPath,
    [ValidateNotNullOrEmpty()]
    [string]$DriverPath,
    [switch]$AdlinkLogin,
    [switch]$AdlinkPassword,
    [switch]$Rollback,
    [Alias('h','?')]
    [switch]$Help,
    [switch]$ExportDrivers,
    [switch]$SelectDrivers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LogFile    = Join-Path $ScriptDir 'optimize_log.txt'
$NeedReboot = $false
$DriverBackupMarker = '.WinUpdateTool.DriverBackup'
$DriverExportPending = "$DriverBackupMarker.pending"

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
    if ($Bytes.Length -eq 8) { return $Bytes }
    $hdr        = $Bytes[0..7]
    $unicode    = [System.Text.Encoding]::Unicode.GetString($Bytes, 8, $Bytes.Length - 8)
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
        $forwardedArgs = foreach ($name in $script:PSBoundParameters.Keys) {
            $value = $script:PSBoundParameters[$name]
            if ($value) {
                "-$name"
                if ($name -in 'PatchPath', 'DriverPath') {
                    # Windows 命令行中的结束引号之前需要将路径末尾的反斜杠加倍。
                    '"{0}"' -f ($value -replace '(\\+)$', '$1$1')
                }
            }
        }
        $fwdArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f `
            $PSCommandPath, ($forwardedArgs -join ' ')
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $process = Start-Process -FilePath $powershell -ArgumentList $fwdArgs -Verb RunAs -Wait -PassThru
        exit $process.ExitCode
    }
}

# ═══════════════════════════════════════════════════════════
# Module 0b：产品型号检测
# ═══════════════════════════════════════════════════════════

function Test-ProductModel {
    param([hashtable]$Products)
    Write-Section '产品型号检测'
    try {
        $biosVersion = Get-CimInstance -ClassName Win32_BIOS -Property SMBIOSBIOSVersion -ErrorAction Stop |
                       Select-Object -ExpandProperty SMBIOSBIOSVersion
    } catch {
        Write-Log -Level ERROR -Message "无法读取 SMBIOSBIOSVersion，脚本退出。$($_.Exception.Message)"
        exit 1
    }

    $biosVersion = "$biosVersion".Trim()
    Write-Log -Level INFO -Message "SMBIOSBIOSVersion：'$biosVersion'"
    if ($biosVersion -notmatch '\A(?<Product>[^_\s]+)_\S+\z') {
        Write-Log -Level ERROR -Message 'BIOS 版本格式应为“产品型号_版本号”，无法解析产品型号，脚本退出。'
        exit 1
    }

    $product = $Matches.Product
    Write-Log -Level INFO -Message "当前产品型号：$product"
    if (-not $Products.ContainsKey($product)) {
        Write-Log -Level ERROR -Message "型号 $product 未列在支持产品.psd1 中，脚本退出。"
        exit 1
    }
    Write-Log -Level OK -Message "型号验证通过：$product"
    return $product
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
            return $true
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
        return ($instResult.ResultCode -eq 2)
    } catch {
        Write-Log -Level ERROR -Message "补丁安装失败：$($_.Exception.Message)"
        return $false
    }
}

function Get-OfflinePatchIdentity {
    param([IO.FileInfo]$File, [string]$MetadataDir)

    # MSU 的外层 XML 可提供程序集标识。CAB 的标识及前置项在 update.mum 中。
    $expand = Join-Path $env:SystemRoot 'System32\expand.exe'
    $documents = @()
    if ($File.Extension -eq '.msu') {
        & $expand $File.FullName '-F:*.xml' $MetadataDir | Out-Null
        $documents = @(Get-ChildItem -LiteralPath $MetadataDir -File -Filter '*.xml')
    } else {
        & $expand $File.FullName '-F:update.mum' $MetadataDir | Out-Null
        $documents = @(Get-ChildItem -LiteralPath $MetadataDir -File -Filter 'update.mum')
    }

    $identities = @()
    $parents = @()
    foreach ($document in $documents) {
        try {
            [xml]$xml = Get-Content -LiteralPath $document.FullName -Raw
        } catch {
            Write-Log -Level INFO -Message "由 Windows 安装服务检查无法读取的包元数据。$($File.Name)"
            continue
        }
        $identities += $xml.SelectNodes("/*[local-name()='assembly']/*[local-name()='assemblyIdentity'] | //*[local-name()='servicing']/*[local-name()='package']/*[local-name()='assemblyIdentity']")
        $parents += $xml.SelectNodes("/*[local-name()='assembly']/*[local-name()='package']/*[local-name()='parent']/*[local-name()='assemblyIdentity']")
    }

    if ($File.Extension -eq '.msu' -and
        -not ($identities | Where-Object { $_.GetAttribute('name') -match 'RollupFix|ServicingStack' })) {
        # 外层 XML 缺少服务堆栈或累积更新标识时，从主 CAB 获取版本和依赖。
        & $expand $File.FullName '-F:Windows*-KB*.cab' $MetadataDir | Out-Null
        foreach ($payload in (Get-ChildItem -LiteralPath $MetadataDir -File -Filter '*.cab')) {
            $identity = Get-OfflinePatchIdentity -File $payload -MetadataDir $MetadataDir
            $identities += $identity.Identities
            $parents += $identity.Parents
            [IO.File]::Delete($payload.FullName)
            [IO.File]::Delete((Join-Path $MetadataDir 'update.mum'))
        }
    }
    return @{ Identities = $identities; Parents = $parents }
}

function Install-OfflineWindowsPatches {
    param([string]$Path)

    $activity = '离线 Windows 补丁安装'
    Write-Section $activity
    Write-Log -Level INFO -Message "补丁目录为 $Path"
    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse | Where-Object Extension -in '.msu', '.cab')
    if ($files.Count -eq 0) {
        Write-Log -Level INFO -Message '目录中没有 MSU 或 CAB 补丁。请将离线补丁包复制到该目录。'
        return $true
    }

    $environmentKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $architecture = (Get-ItemPropertyValue -LiteralPath $environmentKey -Name PROCESSOR_ARCHITECTURE).ToLowerInvariant()
    $build = [int](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber)
    $dependencies = @{}
    $manifestPath = Join-Path $Path 'Dependencies.psd1'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $dependencies = Import-PowerShellDataFile -LiteralPath $manifestPath
    }

    $root = $Path.TrimEnd('\') + '\'
    $metadataRoot = Join-Path ([IO.Path]::GetTempPath()) ('WinUpdateTool-patch-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $metadataRoot | Out-Null
    $packages = @(
        foreach ($file in $files) {
            $metadataDir = Join-Path $metadataRoot ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $metadataDir | Out-Null
            try {
                Write-Log -Level INFO -Message "读取补丁元数据。$($file.Name)"
                $metadata = Get-OfflinePatchIdentity -File $file -MetadataDir $metadataDir
                $architectures = @($metadata.Identities | ForEach-Object { $_.GetAttribute('processorArchitecture') } | Where-Object { $_ })
                if ($architectures.Count -eq 0 -and $file.BaseName -match '(?:^|[-_.])(x64|amd64|arm64|x86)(?:[-_.]|$)') {
                    $architectures = @(if ($Matches[1] -eq 'x64') { 'amd64' } else { $Matches[1] })
                }
                $key = $file.FullName.Substring($root.Length)
                if ($architectures.Count -gt 0 -and $architecture -notin $architectures -and 'neutral' -notin $architectures) {
                    Write-Log -Level INFO -Message "跳过与 $architecture 架构不匹配的补丁 $key"
                    continue
                }
                $identities = @($metadata.Identities | ForEach-Object { $_.GetAttribute('name') })
                $role = 1
                if ($identities -match 'RollupFix' -or $file.BaseName -match '(?:^|[-_.])LCU(?:[-_.]|$)') { $role = 2 }
                elseif ($identities -match 'ServicingStack' -or $file.BaseName -match '(?:^|[-_.])SSU(?:[-_.]|$)') { $role = 0 }
                $versions = @(
                    foreach ($identity in $metadata.Identities) {
                        $version = $null
                        if ([version]::TryParse($identity.GetAttribute('version'), [ref]$version)) { $version }
                    }
                )
                $requires = @()
                if ($dependencies.ContainsKey($key)) {
                    $requires = @($dependencies[$key] | ForEach-Object { ([string]$_).Replace('/', '\') })
                }
                [pscustomobject]@{
                    File = $file
                    Key = $key
                    Role = $role
                    Version = ($versions | Sort-Object -Descending | Select-Object -First 1)
                    Requires = $requires
                    Identities = $identities
                    Parents = @($metadata.Parents | ForEach-Object { $_.GetAttribute('name') })
                    Result = ''
                }
            } finally {
                try { [IO.Directory]::Delete($metadataDir, $true) }
                catch { Write-Log -Level WARN -Message "未能清理补丁元数据目录 $metadataDir。$($_.Exception.Message)" }
            }
        }
    )
    try { [IO.Directory]::Delete($metadataRoot) }
    catch { Write-Log -Level WARN -Message "补丁元数据目录已保留在 $metadataRoot。" }
    if ($packages.Count -eq 0) { return $true }

    $packages = @($packages | Sort-Object Role, Version, Key)
    $available = @{}
    foreach ($package in $packages) { $available[$package.Key] = $package }
    $pending = $packages
    $installed = $skipped = $failed = 0
    do {
        $remaining = [Collections.Generic.List[object]]::new()
        $progress = $false
        foreach ($package in $pending) {
            $blocked = @($package.Requires | Where-Object { -not $available.ContainsKey($_) -or $available[$_].Result -ne 'Ready' })
            if ($blocked.Count -gt 0) {
                $package.Result = "等待指定的前置补丁 $($blocked -join ', ')"
                $remaining.Add($package)
                continue
            }
            $parentPending = $pending | Where-Object {
                $_.Result -ne 'Ready' -and -not $_.Result -and $_.Key -ne $package.Key -and
                ($_.Identities | Where-Object { $_ -in $package.Parents })
            } | Select-Object -First 1
            if ($parentPending) {
                $package.Result = "等待候选前置补丁 $($parentPending.Key)"
                $remaining.Add($package)
                $progress = $true
                continue
            }
            try {
                $completed = $installed + $skipped + $failed
                $status = "已处理 $completed / $($packages.Count) 个补丁"
                Write-Log -Level INFO -Message "检查并安装 $($package.Key)（$status）"
                if ($package.File.Extension -eq '.cab' -or ($build -ge 26100 -and $package.Role -eq 2)) {
                    # 联机映像指正在运行的 Windows，补丁来源仍是本地文件。
                    $installer = Join-Path $env:SystemRoot 'System32\dism.exe'
                    $arguments = '/Online /Add-Package /NoRestart /PackagePath:"{0}"' -f $package.File.FullName
                    # DISM 在当前控制台显示自己的安装进度。
                    $process = Start-Process -FilePath $installer -ArgumentList $arguments -NoNewWindow -Wait -PassThru
                } else {
                    $installer = Join-Path $env:SystemRoot 'System32\wusa.exe'
                    $arguments = '"{0}" /quiet /norestart' -f $package.File.FullName
                    # WUSA 静默安装时，按批次完成数绘制进度，并显示当前补丁的等待时间。
                    $percent = [int][Math]::Floor(100 * $completed / $packages.Count)
                    $timer = [Diagnostics.Stopwatch]::StartNew()
                    try {
                        $process = Start-Process -FilePath $installer -ArgumentList $arguments -NoNewWindow -PassThru
                        do {
                            $elapsed = $timer.Elapsed.ToString('hh\:mm\:ss')
                            Write-Progress -Activity $activity -Status $status -PercentComplete $percent -CurrentOperation "正在检查或安装 $($package.Key)（已等待 $elapsed）"
                        } while (-not $process.WaitForExit(1000))
                    } finally {
                        Write-Progress -Activity $activity -Completed
                    }
                }
                $code = '{0:X8}' -f ([int]$process.ExitCode)
                switch ($code) {
                    { $_ -in '00000000','00000BC2','00000669','00240005' } {
                        if ($code -eq '00240005') {
                            $script:NeedReboot = $true
                        } elseif ($process.ExitCode -ne 0) {
                            Complete-DriverInstall -Name $package.Key -ExitCode $process.ExitCode
                        }
                        $package.Result = 'Ready'
                        $installed++
                        $progress = $true
                        Write-Log -Level OK -Message "补丁处理完成。$($package.Key)"
                    }
                    '00240006' {
                        $package.Result = 'Ready'
                        $skipped++
                        $progress = $true
                        Write-Log -Level INFO -Message "补丁已安装。$($package.Key)"
                    }
                    '80242014' {
                        $script:NeedReboot = $true
                        $package.Result = "Windows 要求重启后继续（0x$code）"
                        $remaining.Add($package)
                    }
                    { $_ -in '80240016','80240017','800F081E','800F0823','800F0831','80242017' } {
                        $package.Result = "0x$code"
                        $remaining.Add($package)
                    }
                    default { throw "Windows 安装服务返回 0x$code。" }
                }
            } catch {
                $package.Result = 'Failed'
                $failed++
                Write-Log -Level WARN -Message "补丁 $($package.Key) 安装失败。$($_.Exception.Message)"
            }
        }
        $pending = @($remaining.ToArray())
    } while ($progress -and $pending.Count -gt 0)

    foreach ($package in $pending) {
        if ($package.Result -in '0x80240017','0x800F081E') {
            $skipped++
            Write-Log -Level INFO -Message "Windows 判定补丁不适用或已被取代。$($package.Key)（$($package.Result)）"
        } else {
            $failed++
            Write-Log -Level WARN -Message "补丁 $($package.Key) 未完成。$($package.Result)"
        }
    }
    if ($failed -gt 0 -and $script:NeedReboot) {
        Write-Log -Level INFO -Message '重启后可重新运行相同命令，继续处理剩余补丁。'
    }
    Write-Log -Level INFO -Message "离线补丁结果：处理完成 $installed 个，跳过 $skipped 个，未完成 $failed 个。"
    return ($failed -eq 0)
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
# Module 5：ADLINK 驱动和软件包下载与安装
# ═══════════════════════════════════════════════════════════

function Connect-AdlinkAccount {
    param([uri]$Origin, [int]$ProductId, $Session)

    $catalog = [uri]::new($Origin, "/Products/DownloadSoftwareDriver.aspx?lang=zh_cn&pdNo=$ProductId&kind=DR")
    $loginPath = '/Member/SignInDriver.aspx'
    $loginPage = [uri]::new($Origin, "$($loginPath)?lang=zh_cn&referURL=$([uri]::EscapeDataString($catalog.AbsoluteUri))")
    $html = (Invoke-WebRequest -Uri $loginPage -WebSession $Session -UseBasicParsing -TimeoutSec 60).Content
    $form = [regex]::Match($html, '(?is)<form\b(?<attributes>[^>]*\bid\s*=\s*["'']form1["''][^>]*)>(?<inputs>.*?)</form>')
    $action = [regex]::Match($form.Groups['attributes'].Value, '(?i)\baction\s*=\s*["'']([^"'']+)["'']')
    if (-not $action.Success) { throw '无法识别 ADLINK 登录表单，请使用浏览器登录。' }
    $submitUrl = [uri]::new($loginPage, [Net.WebUtility]::HtmlDecode($action.Groups[1].Value))
    if ($submitUrl.Scheme -ne 'https' -or $submitUrl.Authority -ne $Origin.Authority -or $submitUrl.AbsolutePath -ne $loginPath) {
        throw 'ADLINK 登录表单地址已变更，请使用浏览器登录。'
    }

    $userField = 'ctl00$CPContens$loginBox$emailBoxId'
    $passwordField = 'ctl00$CPContens$loginBox$passwordBoxId'
    $submitField = 'ctl00$CPContens$loginBox$loginBtn'
    $body = @{}
    $fields = @{}
    foreach ($inputTag in [regex]::Matches($form.Groups['inputs'].Value, '(?is)<input\b[^>]*>')) {
        $attribute = @{}
        foreach ($match in [regex]::Matches($inputTag.Value, '(?i)\b(name|type|value)\s*=\s*(?:"([^"]*)"|''([^'']*)'')')) {
            $value = if ($match.Groups[2].Success) { $match.Groups[2].Value } else { $match.Groups[3].Value }
            $attribute[$match.Groups[1].Value] = [Net.WebUtility]::HtmlDecode($value)
        }
        $name = $attribute['name']
        if (-not $name) { continue }
        $fields[$name] = $attribute['type']
        if ($attribute['type'] -eq 'hidden' -or $name -eq $submitField) { $body[$name] = [string]$attribute['value'] }
    }
    if (-not $body.ContainsKey('__VIEWSTATE') -or $fields[$userField] -ne 'text' -or
        $fields[$passwordField] -ne 'password' -or $fields[$submitField] -ne 'submit') {
        throw 'ADLINK 登录表单字段已变更，请使用浏览器登录。'
    }

    $credential = Get-Credential -Message '登录 ADLINK 官网下载驱动。请输入 ADLINK 账号邮箱和密码。'
    if ($null -eq $credential) { throw '已取消 ADLINK 登录。' }

    $email = $credential.UserName.Trim()
    $password = $credential.Password
    $payload = $null
    try {
        if (-not $email -or $password.Length -eq 0) { throw '请输入 ADLINK 登录邮箱和密码。' }
        $body[$userField] = $email
        $body[$passwordField] = [Net.NetworkCredential]::new($email, $password).Password
        $encodedFields = foreach ($field in $body.GetEnumerator()) {
            '{0}={1}' -f [Net.WebUtility]::UrlEncode([string]$field.Key), [Net.WebUtility]::UrlEncode([string]$field.Value)
        }
        $payload = [Text.Encoding]::UTF8.GetBytes(($encodedFields -join '&'))
        try {
            $request = [Net.HttpWebRequest][Net.WebRequest]::Create($submitUrl)
            $request.Method = 'POST'
            $request.AllowAutoRedirect = $false
            $request.ContentType = 'application/x-www-form-urlencoded'
            $request.ContentLength = $payload.Length
            $request.CookieContainer = $Session.Cookies
            $request.UserAgent = $Session.UserAgent
            $request.Referer = $loginPage.AbsoluteUri
            $request.Timeout = 60000
            $request.ReadWriteTimeout = 60000
            $stream = $request.GetRequestStream()
            try { $stream.Write($payload, 0, $payload.Length) } finally { $stream.Dispose() }
            $response = $request.GetResponse()
            $response.Dispose()
        } catch {
            throw '无法提交 ADLINK 登录表单，请检查网络或在浏览器登录。'
        }
    } finally {
        $body.Clear()
        $encodedFields = $null
        if ($payload) { [Array]::Clear($payload, 0, $payload.Length) }
        $password.Dispose()
    }
}

function Get-AdlinkPackages {
    param([int]$ProductId, [string]$Windows, [uri]$Origin, $Session, [switch]$RequireLogin)

    $endpoint = [uri]::new($Origin, '/Products/DownloadSoftData.ashx')
    $compatibleCategories = @($Windows, 'Windows 10\11')
    foreach ($kind in 'DR', 'SW') {
        $page = [uri]::new($Origin, "/Products/DownloadSoftwareDriver.aspx?lang=zh_cn&pdNo=$ProductId&kind=$kind")
        $html = (Invoke-WebRequest -Uri $page -WebSession $Session -UseBasicParsing -TimeoutSec 60).Content
        $osSelect = [regex]::Match($html, '(?is)<select\b[^>]*\bid\s*=\s*["'']CPContens_DropDownList1["''][^>]*>(.*?)</select>')
        if (-not $osSelect.Success) { throw "官网 $kind 目录缺少操作系统分类。$page" }

        $loginField = [regex]::Match($html, '(?is)<input\b[^>]*\bid\s*=\s*["'']CPContens_hf_IsLogin["''][^>]*>')
        $login = if ($loginField.Value -match '\bvalue\s*=\s*["'']Y["'']') { 'Y' } else { 'N' }
        if ($kind -eq 'DR' -and $RequireLogin) {
            if ($login -ne 'Y') {
                throw [System.Security.Authentication.AuthenticationException]::new('ADLINK 未确认登录成功。请核对邮箱和密码，或在浏览器完成验证后使用 -AdlinkLogin。')
            }
            Write-Log -Level OK -Message 'ADLINK 官网登录成功'
        }
        $categories = @(
            foreach ($option in [regex]::Matches($osSelect.Groups[1].Value, '(?i)<option\b[^>]*\bvalue\s*=\s*["'']([^"'']+)["'']')) {
                $category = [Net.WebUtility]::HtmlDecode($option.Groups[1].Value).Trim()
                if ($category -in $compatibleCategories -or $category -eq 'All') { $category }
            }
        )
        foreach ($category in ($categories | Select-Object -Unique)) {
            $encodedCategory = [uri]::EscapeDataString($category)
            $query = "$($endpoint.AbsoluteUri)?pdNo=$ProductId&kind=$kind&OS=$encodedCategory&lang=zh_cn&MainCategory="
            Write-Log -Level INFO -Message "查询 ADLINK $kind 分类：$category"
            $response = Invoke-WebRequest -Uri $query -WebSession $Session -UseBasicParsing -TimeoutSec 60
            if ([string]::IsNullOrWhiteSpace($response.Content)) { continue }
            $items = ConvertFrom-Json -InputObject $response.Content
            foreach ($item in $items) {
                $spec = if ($item.PSObject.Properties['Spec']) { "$($item.Spec)".Trim() }
                if ($spec -and $spec -notin $compatibleCategories -and $spec -notin @('All', 'Windows')) { continue }

                $id = [int]$item.ID
                $size = [long]$item.FileSize
                $fileName = [IO.Path]::GetFileName([string]$item.FileName)
                $driverType = if ($item.PSObject.Properties['DriverType']) { [string]$item.DriverType }
                if ($id -le 0 -or $size -le 0 -or -not $fileName -or $fileName -in @('.', '..') -or
                    $fileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                    throw "官网 $kind 分类 $category 包含无效的文件信息。"
                }
                [pscustomobject]@{
                    Kind       = $kind
                    Id         = $id
                    Name       = [Net.WebUtility]::HtmlDecode([string]$item.Description).Trim()
                    Category   = $category
                    DriverType = $driverType
                    FileName   = $fileName
                    Size       = $size
                    CatalogUrl = $page
                    Url        = [uri]"$($endpoint.AbsoluteUri)?pdNo=$ProductId&type=$kind&id=$id&isLogin=$login&lang=zh_cn&MainCategory="
                }
            }
        }
    }
}

function Save-AdlinkPackage {
    param(
        $Package,
        [string]$Destination,
        [string[]]$LocalDirectories,
        $Session,
        [int]$PackageNumber,
        [int]$PackageCount
    )

    $localPaths = @($Destination) + @(foreach ($directory in $LocalDirectories) { Join-Path $directory $Package.FileName })
    foreach ($path in $localPaths) {
        $file = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($file -isnot [IO.FileInfo]) { continue }
        if ($file.Length -eq $Package.Size) {
            Write-Log -Level INFO -Message "[$PackageNumber/$PackageCount] 使用本地安装包：$path"
            return $file.FullName
        }
        Write-Log -Level INFO -Message "本地安装包大小与目录不符：$path"
    }
    Write-Log -Level INFO -Message "[$PackageNumber/$PackageCount] 本地无匹配安装包，开始下载 $($Package.Name)。"

    $partial = "$Destination.$([guid]::NewGuid().ToString('N')).partial"
    $url = $Package.Url
    $activity = '下载驱动及软件包'
    $status = "[$PackageNumber/$PackageCount] $($Package.Name)"
    try {
        Write-Progress -Activity $activity -Status $status -CurrentOperation '正在连接下载服务器' -PercentComplete 0
        for ($redirect = 0; $redirect -le 8; $redirect++) {
            if ($url.Scheme -ne 'https') { throw "官网返回了非 HTTPS 下载地址。" }
            if ($url.AbsolutePath -match '/Member/(DialogLogin|SignIn)') {
                throw [System.Security.Authentication.AuthenticationException]::new('ADLINK 下载仍要求登录。可在浏览器登录后使用 -AdlinkLogin，或将下载的文件放到上述本地路径。')
            }
            $request = [Net.HttpWebRequest][Net.WebRequest]::Create($url)
            $request.AllowAutoRedirect = $false
            $request.CookieContainer = $Session.Cookies
            $request.UserAgent = $Session.UserAgent
            $request.Referer = $Package.CatalogUrl.AbsoluteUri
            $request.Timeout = 60000
            $request.ReadWriteTimeout = 60000
            $response = $request.GetResponse()
            try {
                if ([int]$response.StatusCode -in @(301, 302, 303, 307, 308)) {
                    $url = [uri]::new($url, $response.Headers['Location'])
                    continue
                }
                if ($response.ContentType -match '^(text/|application/(json|xhtml))') {
                    throw "官网下载接口返回页面，无法取得 $($Package.FileName)。"
                }
                $inputStream = $response.GetResponseStream()
                try {
                    $outputStream = [IO.File]::Open($partial, [IO.FileMode]::CreateNew)
                    try {
                        $buffer = [byte[]]::new(128KB)
                        $downloaded = 0L
                        $updateTimer = [Diagnostics.Stopwatch]::StartNew()
                        while (($bytesRead = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                            $outputStream.Write($buffer, 0, $bytesRead)
                            $downloaded += $bytesRead
                            if ($updateTimer.ElapsedMilliseconds -ge 250) {
                                $percent = [Math]::Min(99, [Math]::Floor(100.0 * $downloaded / $Package.Size))
                                $transferred = '已下载 {0:N1} / {1:N1} MiB' -f ($downloaded / 1MB), ($Package.Size / 1MB)
                                Write-Progress -Activity $activity -Status $status -CurrentOperation $transferred -PercentComplete $percent
                                $updateTimer.Restart()
                            }
                        }
                    } finally { $outputStream.Dispose() }
                } finally { $inputStream.Dispose() }
                break
            } finally { $response.Dispose() }
        }
        if (-not (Test-Path -LiteralPath $partial -PathType Leaf)) { throw '官网下载地址重定向次数过多。' }
        if ((Get-Item -LiteralPath $partial).Length -ne $Package.Size) {
            throw "下载文件大小与目录不符，期望 $($Package.Size) 字节。"
        }
        Move-Item -LiteralPath $partial -Destination $Destination -Force
        Write-Progress -Activity $activity -Status $status -CurrentOperation '下载完成' -PercentComplete 100
        Write-Log -Level OK -Message "[$PackageNumber/$PackageCount] 下载完成：$($Package.Name)"
        return $Destination
    } finally {
        Write-Progress -Activity $activity -Completed
        [IO.File]::Delete($partial)
    }
}

function Install-AdlinkPackages {
    param([string]$Product, [int]$ProductId)

    Write-Section "$Product 驱动及软件包下载与安装"
    $origin = [uri]'https://www.adlinktech.com.cn/'
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $useAccountLogin = [bool]$AdlinkPassword
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -Property Version,BuildNumber,ProductType -ErrorAction Stop
        if ($os.ProductType -ne 1 -or [version]$os.Version -lt [version]'10.0' -or [int]$os.BuildNumber -lt 10240) {
            throw "驱动目录支持 Windows 10 和 Windows 11 客户端。当前系统版本为 $($os.Version)。"
        }
        $windows = if ([int]$os.BuildNumber -ge 22000) { 'Windows 11' } else { 'Windows 10' }
        Write-Log -Level INFO -Message "本机系统：$windows（Build $($os.BuildNumber)），产品目录 pdNo=$ProductId"

        if ($AdlinkLogin -and $AdlinkPassword) { throw '请只选择一种 ADLINK 登录方式。' }
        if ($useAccountLogin) {
            Connect-AdlinkAccount -Origin $origin -ProductId $ProductId -Session $session
        } elseif ($AdlinkLogin) {
            $secureCookie = Read-Host '在 ADLINK 官网登录后，粘贴该站请求的 Cookie 值' -AsSecureString
            $cookiePtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureCookie)
            try {
                $cookieHeader = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($cookiePtr)
                foreach ($pair in ($cookieHeader -split ';\s*')) {
                    if ($pair -notmatch '\A([^=\s]+)=(.*)\z') { continue }
                    $cookie = [Net.Cookie]::new($Matches[1], $Matches[2], '/')
                    $cookie.Secure = $true
                    $session.Cookies.Add($origin, $cookie)
                }
            } catch {
                throw '无法读取 ADLINK 会话 Cookie，请粘贴该站请求的 Cookie 值。'
            } finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($cookiePtr)
                $cookieHeader = $null
                $secureCookie.Dispose()
            }
        }
    } catch {
        Write-Log -Level WARN -Message "无法开始 ADLINK 驱动任务：$($_.Exception.Message)"
        return $false
    }

    $driverDirectory = Join-Path $ScriptDir '_drivers'
    $productDirectory = Join-Path $driverDirectory $ProductId
    $packageResults = @{}
    :catalog while ($true) {
        try {
            $packages = @(Get-AdlinkPackages -ProductId $ProductId -Windows $windows -Origin $origin -Session $session -RequireLogin:$useAccountLogin |
                          Sort-Object Kind, Id -Unique)
            if ($packages.Count -eq 0) {
                Write-Log -Level INFO -Message "官网目录没有适用于 $windows 的驱动或软件包。"
                return $true
            }
            $packages = @($packages | Sort-Object Kind, @{ Expression = { $_.DriverType -ne 'Chipset' } }, Id)
            Write-Log -Level INFO -Message "共找到 $($packages.Count) 个匹配包"
        } catch [System.Security.Authentication.AuthenticationException] {
            Write-Log -Level WARN -Message $_.Exception.Message
            return $false
        } catch {
            Write-Log -Level ERROR -Message "读取 ADLINK 目录失败：$($_.Exception.Message)"
            return $false
        }
        foreach ($package in $packages) {
            Write-Log -Level INFO -Message "[$($package.Kind) / $($package.Category)] $($package.Name)"
        }

        $processed = 0
        $packageNumber = 0
        foreach ($package in $packages) {
            $packageNumber++
            $packageKey = "$($package.Kind)-$($package.Id)"
            if ($packageResults.ContainsKey($packageKey)) {
                if ($packageResults[$packageKey]) { $processed++ }
                continue
            }

            $packageDir = Join-Path $productDirectory $packageKey
            $destination = Join-Path $packageDir $package.FileName
            try {
                New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
                Write-Log -Level INFO -Message "准备安装 [$packageNumber/$($packages.Count)] $($package.Name)：$destination"
                $packageFile = Save-AdlinkPackage -Package $package -Destination $destination -LocalDirectories @($productDirectory, $driverDirectory) -Session $session -PackageNumber $packageNumber -PackageCount $packages.Count
            } catch {
                if ($_.Exception -is [System.Security.Authentication.AuthenticationException] -and
                    -not ($useAccountLogin -or $AdlinkLogin)) {
                    try {
                        Write-Log -Level INFO -Message 'ADLINK 要求登录，正在打开登录窗口。'
                        Connect-AdlinkAccount -Origin $origin -ProductId $ProductId -Session $session
                    } catch {
                        Write-Log -Level WARN -Message "ADLINK 登录未完成：$($_.Exception.Message)"
                        return $false
                    }
                    $useAccountLogin = $true
                    continue catalog
                }
                $packageResults[$packageKey] = $false
                Write-Log -Level ERROR -Message "无法获取 $($package.Name) 的安装包：$($_.Exception.Message) 官网：$($package.CatalogUrl)"
                continue
            }

            try {
                Write-Log -Level INFO -Message "正在安装 [$packageNumber/$($packages.Count)] $($package.Name)"
                $installStatus = Invoke-DriverInstall -FilePath $packageFile -DriverDir $packageDir
                $packageResults[$packageKey] = $true
                $processed++
                if ($installStatus -notin 'PnPProcessed', 'Skipped') {
                    Write-Log -Level OK -Message "安装完成：$($package.Name)"
                }
            } catch {
                $packageResults[$packageKey] = $false
                Write-Log -Level WARN -Message "安装 $($package.Name) 未完成：$($_.Exception.Message)"
            }
        }

        $failed = $packages.Count - $processed
        $level = if ($failed -eq 0) { 'OK' } else { 'WARN' }
        Write-Log -Level $level -Message "驱动及软件包结果：已处理 $processed 个，未完成 $failed 个。"
        return ($failed -eq 0)
    }
}

function Complete-DriverInstall {
    param([string]$Name, [int]$ExitCode)

    switch ($ExitCode) {
        0 { return }
        3010 {
            $script:NeedReboot = $true
            Write-Log -Level INFO -Message "$Name 需要重启，已推迟到本次任务结束。"
        }
        1641 {
            $script:NeedReboot = $true
            # 1641 表示安装程序已发起重启。如果 Windows 仍允许取消，立即取消。
            $shutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
            try {
                $abort = Start-Process -FilePath $shutdown -ArgumentList '/a' -WindowStyle Hidden -Wait -PassThru
                if ($abort.ExitCode -ne 0) { throw "shutdown.exe 退出码 $($abort.ExitCode)。" }
                Write-Log -Level WARN -Message "$Name 发起的重启已取消，将继续处理后续安装包。"
            } catch {
                Write-Log -Level WARN -Message "$Name 返回 1641（已发起重启），Windows 未确认取消。$($_.Exception.Message)"
            }
        }
        default { throw "$Name 退出码 $ExitCode。" }
    }
}

function Find-DriverInstaller {
    param([IO.FileInfo[]]$Files)

    $Files | Where-Object {
        $_.Extension -eq '.exe' -and $_.BaseName -match '^(setup|install|setupchipset|setupserialio|meisetup|setupme|igxpin)([-_ ]?(x64|64|amd64))?$'
    } | Sort-Object { $_.FullName.Length }, FullName | Select-Object -First 1
}

function Install-DriverInf {
    param([string]$Path, [switch]$Recursive)

    $arguments = @('/add-driver', $Path)
    if ($Recursive) { $arguments += '/subdirs' }
    $arguments += '/install'
    $output = @(& pnputil.exe @arguments | ForEach-Object {
        if ($_ -ne '') {
            Write-Log -Level INFO -Message $_
            $_
        }
    })
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 259 -and
        ($output -match '已成功添加驱动程序(?:程序)?包|Driver package added successfully|already in the driver store') -and
        -not ($output -match '(?:添加|安装)驱动程序(?:程序)?包失败|无法(?:添加|安装)驱动程序(?:程序)?包|Failed to (add|install) driver package|Error (adding|installing) driver package')) {
        if ($output -match '设备上的驱动程序(?:程序)?包是最新的|Driver package is (?:already )?up[ -]to[ -]date on (?:the )?device') {
            Write-Log -Level INFO -Message '设备已安装同等或更合适的驱动，跳过本次安装。'
            return 'Skipped'
        }
        Write-Log -Level INFO -Message 'PnPUtil 已处理驱动包。部分驱动没有匹配设备，或设备已有同等或更合适的驱动。'
        return 'PnPProcessed'
    }
    Complete-DriverInstall -Name 'pnputil' -ExitCode $exitCode
}

function Select-DriverPackages {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw '请在交互式终端中使用 -SelectDrivers。'
    }

    $devices = @(Get-CimInstance -ClassName Win32_PnPSignedDriver `
        -Property DeviceName,FriendlyName,DeviceClass,DriverProviderName,DriverVersion,InfName |
        Where-Object { $_.InfName -match '^oem[0-9]+\.inf$' -and ($_.FriendlyName -or $_.DeviceName) } |
        Sort-Object DeviceClass,DeviceName,FriendlyName,DriverProviderName,DriverVersion,InfName -Unique)
    if ($devices.Count -eq 0) { throw '没有找到可选择的第三方设备驱动。' }

    $classes = @{ DISPLAY = '显卡'; MEDIA = '声卡'; NET = '网卡'; SYSTEM = '系统设备'; SOFTWARECOMPONENT = '软件组件' }
    $selected = [Collections.Generic.HashSet[int]]::new()
    $cursor = $first = 0
    try {
        while ($true) {
            $height = [Math]::Max(1, [Console]::WindowHeight - 5)
            $width = [Math]::Max(1, [Console]::WindowWidth - 1)
            $first = [Math]::Min($first, [Math]::Max(0, $devices.Count - $height))
            $first = [Math]::Max([Math]::Min($first, $cursor), $cursor - $height + 1)
            $last = [Math]::Min($first + $height, $devices.Count)

            Clear-Host
            Write-Host '选择要导出的驱动' -ForegroundColor Cyan
            for ($i = $first; $i -lt $last; $i++) {
                $device = $devices[$i]
                $name = if ($device.FriendlyName) { $device.FriendlyName } else { $device.DeviceName }
                $class = [string]$device.DeviceClass
                if ($classes.ContainsKey($class)) { $class = $classes[$class] }
                $mark = if ($selected.Contains($i)) { 'x' } else { ' ' }
                $pointer = if ($i -eq $cursor) { '>' } else { ' ' }
                $line = "${pointer} [$mark] $class  $name"
                while ($Host.UI.RawUI.LengthInBufferCells($line) -gt $width) {
                    $line = $line.Substring(0, $line.Length - 1)
                }
                Write-Host $line
            }
            $device = $devices[$cursor]
            Write-Host ('{0}  {1}' -f $device.DriverProviderName, $device.DriverVersion)
            Write-Host ('第 {0}/{1} 项，已勾选 {2} 项' -f ($cursor + 1), $devices.Count, $selected.Count)
            Write-Host '↑/↓ 移动  空格 勾选  Enter 导出  Esc 取消'

            switch ([Console]::ReadKey($true).Key) {
                UpArrow { $cursor = [Math]::Max(0, $cursor - 1) }
                DownArrow { $cursor = [Math]::Min($devices.Count - 1, $cursor + 1) }
                PageUp { $cursor = [Math]::Max(0, $cursor - $height) }
                PageDown { $cursor = [Math]::Min($devices.Count - 1, $cursor + $height) }
                Spacebar { if (-not $selected.Add($cursor)) { [void]$selected.Remove($cursor) } }
                Enter {
                    if ($selected.Count -gt 0) {
                        return ($selected | ForEach-Object { $devices[$_].InfName } | Sort-Object -Unique)
                    }
                }
                Escape { return }
            }
        }
    } finally {
        Clear-Host
    }
}

function Export-DriverPackages {
    param([string]$Path, [string[]]$Packages)

    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container) -or
            (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)) {
            throw "导出目标必须是新目录或空目录。$Path"
        }
    }
    [void][IO.Directory]::CreateDirectory($Path)
    $pending = Join-Path $Path $DriverExportPending
    $marker = Join-Path $Path $DriverBackupMarker
    # 同一目标同时只能有一个导出任务。失败时保留标记，避免导入不完整的备份。
    [IO.File]::Open($pending, [IO.FileMode]::CreateNew).Dispose()
    if (Get-ChildItem -LiteralPath $Path -Force | Where-Object Name -ne $DriverExportPending | Select-Object -First 1) {
        [IO.File]::Delete($pending)
        throw "导出目标必须是新目录或空目录。$Path"
    }

    Write-Log -Level INFO -Message "驱动导出目录为 $Path"
    $failed = @(
        foreach ($package in $Packages) {
            Write-Log -Level INFO -Message "正在导出 $package"
            & pnputil.exe /export-driver $package $Path | ForEach-Object {
                if ($_) { Write-Log -Level INFO -Message $_ }
            }
            if ($LASTEXITCODE -ne 0) {
                Write-Log -Level ERROR -Message "$package 导出失败。PnPUtil 退出码 $LASTEXITCODE。"
                $package
            }
        }
    )
    if ($failed.Count -gt 0) { throw "PnPUtil 未完成导出。未完成的备份保留在 $Path。" }
    if (-not (Get-OfflineDriverEntries -Path $Path -InfOnly | Select-Object -First 1)) {
        throw "没有导出可用的第三方驱动 INF。$Path"
    }
    [IO.File]::Move($pending, $marker)
    Write-Log -Level OK -Message "驱动导出完成。$Path"
}

function Get-OfflineDriverEntries {
    param([string]$Path, [switch]$PackageDirectory, [switch]$InfOnly)

    $files = @(Get-ChildItem -LiteralPath $Path -File)
    if ($InfOnly) {
        $files | Where-Object Extension -eq '.inf' | ForEach-Object FullName
    } elseif ($PackageDirectory) {
        $entry = Find-DriverInstaller -Files $files
        if ($entry) {
            $entry.FullName
            return
        }
    }
    if (-not $InfOnly) {
        $files | Where-Object Extension -in '.zip', '.exe', '.msi', '.inf' | ForEach-Object FullName
    }
    foreach ($directory in (Get-ChildItem -LiteralPath $Path -Directory | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })) {
        if ((Test-Path -LiteralPath (Join-Path $directory.FullName $DriverBackupMarker) -PathType Leaf) -or
            (Test-Path -LiteralPath (Join-Path $directory.FullName $DriverExportPending) -PathType Leaf)) { continue }
        Get-OfflineDriverEntries -Path $directory.FullName -PackageDirectory -InfOnly:$InfOnly
    }
}

function Find-OfflineDriverSource {
    param([string]$Path)

    $paths = if ($Path) { $Path } else { Join-Path $ScriptDir 'ExportedDrivers'; Join-Path $ScriptDir 'Drivers' }
    foreach ($candidate in $paths) {
        $directory = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
        if ($directory -isnot [IO.DirectoryInfo]) {
            Write-Host "[INFO] 驱动目录不存在或不可访问。$candidate"
            continue
        }
        $sourcePath = $directory.FullName
        $pending = Join-Path $sourcePath $DriverExportPending
        $marker = Join-Path $sourcePath $DriverBackupMarker
        $wasBackup = Test-Path -LiteralPath $marker -PathType Leaf
        if (Test-Path -LiteralPath $pending -PathType Leaf) {
            Write-Host "[INFO] 驱动备份尚未导出完成。$sourcePath"
            continue
        }
        $infOnly = $wasBackup -or $directory.Name -eq 'ExportedDrivers'
        $entries = @(Get-OfflineDriverEntries -Path $sourcePath -InfOnly:$infOnly | Sort-Object)
        if (Test-Path -LiteralPath $pending -PathType Leaf) {
            Write-Host "[INFO] 驱动备份尚未导出完成。$sourcePath"
            continue
        }
        if (-not $wasBackup -and (Test-Path -LiteralPath $marker -PathType Leaf)) {
            # 扫描期间刚完成导出时，重新读取完整的 INF 清单。
            $infOnly = $true
            $entries = @(Get-OfflineDriverEntries -Path $sourcePath -InfOnly | Sort-Object)
        }
        if ($entries.Count -gt 0) {
            return @{ Path = $sourcePath; InfOnly = $infOnly; Entries = $entries }
        }
        Write-Host "[INFO] 目录中没有可用的驱动或安装包。$sourcePath"
    }
    throw '未找到可用驱动。请复制驱动备份或离线安装包，或使用 -DriverPath 指定目录。'
}

function Install-OfflineDrivers {
    param([hashtable]$Source)

    $path = $Source.Path
    $entries = $Source.Entries
    if ($Source.InfOnly) {
        Write-Section '导入驱动备份'
    } else {
        Write-Section '离线驱动和软件包安装'
        $workDir = Join-Path $ScriptDir '_drivers\offline'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    }
    Write-Log -Level INFO -Message "驱动目录为 $path"

    $index = $skipped = $failed = 0
    foreach ($entry in $entries) {
        $index++
        try {
            Write-Log -Level INFO -Message "正在安装 [$index/$($entries.Count)] $entry"
            $status = if ($Source.InfOnly) { Install-DriverInf -Path $entry } else {
                Invoke-DriverInstall -FilePath $entry -DriverDir $workDir
            }
            if ($status -eq 'Skipped') {
                $skipped++
            } elseif ($status -ne 'PnPProcessed') {
                Write-Log -Level OK -Message "安装完成。$entry"
            }
        } catch {
            $failed++
            Write-Log -Level WARN -Message "离线安装未完成。$entry。$($_.Exception.Message)"
        }
    }
    Write-Log -Level INFO -Message "离线驱动和软件包结果：处理完成 $($entries.Count - $skipped - $failed) 个，跳过 $skipped 个，未完成 $failed 个。"
    return ($failed -eq 0)
}

function Invoke-DriverInstall {
    param([string]$FilePath, [string]$DriverDir)

    $extension = [IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    if ($extension -eq '.zip') {
        $extractDir = Join-Path $DriverDir ([guid]::NewGuid().ToString('N'))
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($FilePath, $extractDir)
            $files = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File)
            $installer = Find-DriverInstaller -Files $files
            if (-not $installer) {
                $installer = $files | Where-Object Extension -eq '.msi' |
                             Sort-Object { $_.FullName.Length } | Select-Object -First 1
            }
            if ($installer) {
                return (Invoke-DriverInstall -FilePath $installer.FullName -DriverDir $DriverDir)
            } elseif ($files | Where-Object Extension -eq '.inf') {
                return (Install-DriverInf -Path (Join-Path $extractDir '*.inf') -Recursive)
            } else {
                throw '压缩包内未找到已识别的安装程序或 INF 文件。'
            }
        } finally {
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    if ([IO.Directory]::Exists($extractDir)) {
                        [IO.Directory]::Delete($extractDir, $true)
                    }
                    break
                } catch {
                    if ($attempt -eq 3) {
                        Write-Log -Level WARN -Message "未能清理解压目录，已保留 $extractDir。$($_.Exception.Message)"
                    } else {
                        Start-Sleep -Milliseconds 500
                    }
                }
            }
        }
        return
    }
    if ($extension -eq '.inf') { return (Install-DriverInf -Path $FilePath) }

    $workingDir = Split-Path -LiteralPath $FilePath
    $name = [IO.Path]::GetFileName($FilePath)
    Write-Log -Level INFO -Message "静默安装：$name"
    switch ($extension) {
        '.exe' {
            $responseFile = Join-Path $workingDir 'setup.iss'
            if ($name -eq 'Setup.exe' -and (Test-Path -LiteralPath $responseFile -PathType Leaf) -and
                (Select-String -LiteralPath $responseFile -Pattern '^Company\s*=\s*Realtek\b' -Quiet)) {
                $silentLog = Join-Path $DriverDir ("realtek-{0}.log" -f [guid]::NewGuid().ToString('N'))
                try {
                    $arguments = '/s /norestart /f1"{0}" /f2"{1}"' -f $responseFile, $silentLog
                    $process = Start-Process -FilePath $FilePath -ArgumentList $arguments -WorkingDirectory $workingDir -Wait -PassThru
                    Complete-DriverInstall -Name $name -ExitCode $process.ExitCode
                    if (-not (Test-Path -LiteralPath $silentLog -PathType Leaf)) {
                        throw 'Realtek 安装程序未生成静默安装结果日志。'
                    }
                    $result = Select-String -LiteralPath $silentLog -Pattern '^\s*ResultCode\s*=\s*(-?\d+)\s*$' |
                              Select-Object -First 1
                    if (-not $result -or $result.Matches[0].Groups[1].Value -ne '0') {
                        $detail = if ($result) { $result.Line.Trim() } else { '缺少 ResultCode' }
                        throw "Realtek 静默安装返回 $detail。"
                    }
                } finally {
                    [IO.File]::Delete($silentLog)
                }
                return
            }
            $arguments = if ($name -in @('SetupME.exe', 'SetupSerialIO.exe')) {
                # Intel 安装指南使用 -s 静默安装，只有加 -b 才请求自动重启。
                $reportDir = Join-Path $DriverDir 'install-logs'
                New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
                Write-Log -Level INFO -Message "$name 的 Intel 安装日志目录：$reportDir"
                '-s -report "{0}"' -f $reportDir
            } elseif ($name -match '^(SetupChipset|MEISetup|igxpin)\.exe$' -or
                             (Get-Item -LiteralPath $FilePath).VersionInfo.CompanyName -match '^Intel\b') {
                '-s -norestart'
            } else {
                '/s /norestart'
            }
            $process = Start-Process -FilePath $FilePath -ArgumentList $arguments -WorkingDirectory $workingDir -Wait -PassThru
        }
        '.msi' {
            $arguments = '/i "{0}" /quiet /norestart REBOOT=ReallySuppress' -f $FilePath
            $process = Start-Process -FilePath msiexec.exe -ArgumentList $arguments -WorkingDirectory $workingDir -Wait -PassThru
        }
        default { throw "不支持的安装包格式：$extension" }
    }
    Complete-DriverInstall -Name $name -ExitCode $process.ExitCode
}

# ═══════════════════════════════════════════════════════════
# 重启提示
# ═══════════════════════════════════════════════════════════

function Prompt-Reboot {
    param([bool]$PackageFailed)

    Write-Section '完成'
    Write-Host "日志已保存至：$LogFile" -ForegroundColor Cyan
    if ($script:NeedReboot) {
        if ($PackageFailed) {
            Write-Host '本次补丁或驱动任务有未完成项，已应用的部分更改需要重启才能完全生效。' -ForegroundColor Yellow
        } else {
            Write-Host '所选任务已处理完毕，需要重启才能完全生效。' -ForegroundColor Yellow
        }
        $choice = Read-Host '是否要重启系统？(Y/N)'
        if ($choice -match '^\s*y\s*$') {
            Write-Log -Level INFO -Message '用户确认重启'
            return $true
        } else {
            Write-Log -Level INFO -Message '用户选择稍后重启'
            Write-Host '请稍后手动重启以使所有设置生效。' -ForegroundColor Yellow
        }
    } elseif (-not $PackageFailed) {
        Write-Host '所有设置已生效，无需重启。' -ForegroundColor Green
    }
    return $false
}

# ═══════════════════════════════════════════════════════════
# 主入口
# ═══════════════════════════════════════════════════════════

function Main {
    # -Help 显示帮助后退出
    if ($Help) {
        Write-Host @'

WinUpdateTool 使用说明

在工具所在目录运行以下命令。

常用命令
  .\WinUpdateTool.cmd -Help       查看帮助（也可用 -h 或 -?）
  .\WinUpdateTool.cmd             全量执行，默认离线安装补丁和驱动，并应用 USB 与电源设置
  .\WinUpdateTool.cmd -Patch      仅安装离线 Windows 补丁
  .\WinUpdateTool.cmd -Driver     优先导入 ExportedDrivers，否则安装 Drivers 中的离线包
  .\WinUpdateTool.cmd -USB        仅应用 USB 重定向、USB 节能及电源设置
  .\WinUpdateTool.cmd -Rollback   将 USB 重定向、USB 节能及睡眠设置恢复为默认值

指定离线目录
  默认从工具目录下的 WinPatches 读取补丁。
  .\WinUpdateTool.cmd -Patch -PatchPath "D:\离线补丁"
  .\WinUpdateTool.cmd -Driver -DriverPath "D:\离线驱动"

导出驱动
  默认创建工具目录下的 ExportedDrivers。自定义目标需为新目录或空目录。
  .\WinUpdateTool.cmd -ExportDrivers
  .\WinUpdateTool.cmd -ExportDrivers -SelectDrivers -DriverPath "D:\驱动备份"
  导入时将备份目录整体复制到目标机器，然后运行 -Driver，或加 -DriverPath 指定备份。

联网安装
  -Online 为本次选中的补丁或驱动任务启用联网安装。
  .\WinUpdateTool.cmd -Online
  .\WinUpdateTool.cmd -Patch -Online
  .\WinUpdateTool.cmd -Driver -Online
  .\WinUpdateTool.cmd -Driver -Online -AdlinkPassword
  .\WinUpdateTool.cmd -Driver -Online -AdlinkLogin

使用提示
  - 执行安装、设置或回退前，请以管理员身份打开命令提示符。
  - 在线驱动支持的机型见工具目录下的 支持产品.psd1。
  - 运行日志保存在工具目录下的 optimize_log.txt。

'@
        exit 0
    }

    if ($SelectDrivers -and -not $ExportDrivers) {
        Write-Host '请将 -SelectDrivers 与 -ExportDrivers 一起使用。' -ForegroundColor Red
        exit 1
    }
    if ($ExportDrivers -and ($Patch -or $USB -or $Driver -or $Rollback -or $Online -or $PatchPath)) {
        Write-Host '请单独运行 -ExportDrivers，可使用 -SelectDrivers 和 -DriverPath。' -ForegroundColor Red
        exit 1
    }

    $runAll = -not ($Patch -or $USB -or $Driver -or $Rollback -or $ExportDrivers)
    $runPatch = -not $Rollback -and ($runAll -or $Patch)
    $runDriver = -not $Rollback -and ($runAll -or $Driver)

    if ($Online -and ($PatchPath -or $DriverPath)) {
        Write-Host '请选择在线或离线安装。使用 -Online 时请移除 -PatchPath 和 -DriverPath。' -ForegroundColor Red
        exit 1
    }
    if (($AdlinkPassword -or $AdlinkLogin) -and -not ($Online -and $runDriver)) {
        Write-Host 'ADLINK 登录选项需要在线驱动安装。请使用 -Driver -Online。' -ForegroundColor Red
        exit 1
    }
    if ($ExportDrivers) {
        $exportPath = Join-Path $ScriptDir 'ExportedDrivers'
        if ($DriverPath) {
            try {
                $provider = $null
                $drive = $null
                $exportPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
                    $DriverPath, [ref]$provider, [ref]$drive)
                if ($provider.Name -ne 'FileSystem') { throw '导出目标必须是文件系统目录。' }
                $root = [IO.Path]::GetPathRoot($exportPath)
                if ($exportPath.Length -gt $root.Length) { $exportPath = $exportPath.TrimEnd('\', '/') }
                $script:PSBoundParameters['DriverPath'] = $exportPath
            } catch {
                Write-Host "无效的驱动导出路径。$DriverPath。$($_.Exception.Message)" -ForegroundColor Red
                exit 1
            }
        }
    } elseif (-not $Online) {
        $preflightFailed = $false
        if ($runPatch) {
            $path = if ($PatchPath) { $PatchPath } else { Join-Path $ScriptDir 'WinPatches' }
            $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if ($item -is [IO.DirectoryInfo]) {
                $offlinePatchPath = $item.FullName
                if ($PatchPath) { $script:PSBoundParameters['PatchPath'] = $offlinePatchPath }
            } else {
                Write-Host "[INFO] 目录不存在或不可访问。$path"
                Write-Host '       请创建该目录并复制离线补丁包（MSU 或 CAB），或通过 -Patch -PatchPath "<现有目录>" 指定目录。'
                $preflightFailed = $true
            }
        }
        if ($runDriver) {
            try {
                $offlineDriverSource = Find-OfflineDriverSource -Path $DriverPath
                if ($DriverPath) { $script:PSBoundParameters['DriverPath'] = $offlineDriverSource.Path }
            } catch {
                Write-Host $_.Exception.Message -ForegroundColor Red
                $preflightFailed = $true
            }
        }
        if ($preflightFailed) { exit 1 }
    }

    Assert-Admin

    Write-Host ''
    Write-Host '==================================================' -ForegroundColor White
    Write-Host '   WinUpdateTool v3.1' -ForegroundColor White
    Write-Host '   纯 PowerShell · 零第三方依赖' -ForegroundColor DarkGray
    Write-Host '==================================================' -ForegroundColor White

    if (-not (Test-Path $LogFile)) {
        New-Item -Path $LogFile -ItemType File -Force | Out-Null
    }

    $modeDisplay = if ($runAll)       { '全量执行' }
                   elseif ($Rollback) { '回退模式' }
                   elseif ($ExportDrivers) { '驱动导出' }
                   else {
                       $parts = @()
                       if ($Patch)  { $parts += '补丁安装' }
                       if ($USB)    { $parts += 'USB/睡眠关闭' }
                       if ($Driver) { $parts += '驱动安装' }
                       $parts -join ' + '
                   }

    Write-Log -Level INFO -Message "========== 脚本启动 [$modeDisplay] =========="
    Write-Log -Level OK -Message '管理员权限验证通过'

    if ($ExportDrivers) {
        try {
            $packages = if ($SelectDrivers) { Select-DriverPackages } else { '*' }
            if ($packages) {
                Export-DriverPackages -Path $exportPath -Packages $packages
            } else {
                Write-Log -Level INFO -Message '已取消驱动导出。'
            }
        } catch {
            Write-Log -Level ERROR -Message "驱动导出未完成。$($_.Exception.Message)"
            exit 1
        } finally {
            Write-Log -Level INFO -Message '========== 脚本结束 =========='
        }
        return
    }

    if ($Online -and $runDriver) {
        try {
            $products = Import-PowerShellDataFile -LiteralPath (Join-Path $ScriptDir '支持产品.psd1')
            $product = Test-ProductModel -Products $products
            $productId = [int]$products[$product]
            if ($productId -le 0) { throw "型号 $product 的 ADLINK pdNo 必须为正整数。" }
        } catch {
            Write-Log -Level ERROR -Message "读取产品映射失败：$($_.Exception.Message)"
            exit 1
        }
    }

    $packageFailed = $false
    if ($Rollback) {
        Invoke-Rollback
    } else {
        if ($runPatch) {
            try {
                $patchOk = if ($Online) { Install-WindowsPatches } else { Install-OfflineWindowsPatches -Path $offlinePatchPath }
                $packageFailed = -not $patchOk
            } catch {
                $packageFailed = $true
                Write-Log -Level WARN -Message "补丁任务未完成。$($_.Exception.Message)"
            }
        }
        if ($runAll -or $USB)    { Invoke-UsbSleepDisable  }
        if ($runDriver) {
            try {
                $driverOk = if ($Online) { Install-AdlinkPackages -Product $product -ProductId $productId } else {
                    Install-OfflineDrivers -Source $offlineDriverSource
                }
                $packageFailed = $packageFailed -or -not $driverOk
            } catch {
                $packageFailed = $true
                Write-Log -Level WARN -Message "驱动任务未完成。$($_.Exception.Message)"
            }
        }
    }

    $restartNow = Prompt-Reboot -PackageFailed $packageFailed
    Write-Log -Level INFO -Message '========== 脚本结束 =========='
    if ($restartNow) { Restart-Computer -Force }
    if ($packageFailed) { exit 1 }
}

Main
