# 项目说明：引望客户系统优化脚本

## 客户要求

纯脚本模式（PowerShell，不依赖第三方 GUI 工具）一键完成以下功能：

> **前提条件**：所有操作仅在产品型号为 **IMB-C47** 时执行。脚本启动时先检测本机型号，不匹配则退出。

1. **产品型号检测**
   - 读取 WMI `Win32_ComputerSystemProduct.Name`，确认值为 `IMB-C47`，否则退出并提示。

2. **系统补丁一键安装**
   - 检测、下载并安装所有 Windows 系统更新，支持有无重启两种情况。

3. **关闭 USB 节能、重定向及睡眠功能**
   - 关闭 USB 重定向（RemoteFX USB 设备重定向）
   - 关闭 USB 节能（USB 选择性挂起；设备管理器中取消"允许计算机关闭此设备以节约电源"）
   - 关闭系统睡眠与休眠（电源选项全部设为"从不"，禁用休眠文件）

4. **IMB-C47 驱动包自动下载并安装**
   - 来源：https://www.adlinktech.com.cn/Products/DownloadSoftwareDriver.aspx?lang=zh_cn&pdNo=2184&kind=DR
   - 覆盖两个操作系统分类：**Windows 10\11** 和 **Windows 11**
   - Windows 10\11 驱动包（截图确认）：
     - Audio_v6.0.9079.1（303.89 MB）
     - Chipset_v10.1.19600.8418（5.00 MB）
     - Graphics_v31.0.101.4644（610.56 MB）
     - ME_v2335.5.26.0（1033.32 MB）
     - SerialIO_v30.100.2237.26（3.25 MB）
   - Windows 11 驱动包（截图确认）：
     - Ethernet(i225-i226)_v2.1.3.3（0.60 MB）
   - 下载后自动静默安装（`/s`、`/quiet`、`/passive` 等参数），安装完毕记录日志。

## 参考文档

| 文档 | 操作要点 |
|------|---------|
| `关闭USB重定向.docx` | gpedit.msc → 计算机配置 → 管理模板 → Windows 组件 → 远程桌面服务 → 远程桌面会话客户端 → **RemoteFX USB 设备重定向** → 禁用，完成后重启 |
| `关闭USB节能及系统睡眠优化设置.docx` | 设备管理器 → 通用串行总线控制器 → 每个 USB 设备 → 电源管理 → 取消节能勾选；电源选项中睡眠/关闭显示器/硬盘/休眠均设为"从不"/"禁用" |

## 技术实现决策

- **型号检测**：`(Get-WmiObject Win32_ComputerSystemProduct).Name`，不含 `IMB-C47` 则立即退出。
- **权限**：脚本运行时检测管理员身份，非管理员自动以管理员重启。
- **补丁安装**：使用系统内置 COM 对象 `Microsoft.Update.Session`，零外部依赖。
- **USB 重定向**：策略 `TS_USB_REDIRECTION_DISABLE` 无 disabledValue，"已禁用"= 向本地 GPO `Machine\Registry.pol` 写 `**del.fUsbRedirectionEnableMode`；**必须同时更新 `GroupPolicy\gpt.ini`**（Version+1，并在 `gPCMachineExtensionNames` 中登记 RemoteFX USB CSE `{4BCD6CDE-777B-48B6-9804-43568E23545D}`），否则 gpupdate 不会调用该 CSE，设置不生效。
- **USB 节能**：全局禁用 `HKLM\SYSTEM\CurrentControlSet\Services\USB\DisableSelectiveSuspend = 1`；设备管理器"允许计算机关闭此设备以节约电源"勾选框 = WMI `root\wmi:MSPower_DeviceEnable.Enable`，对设备类 `USB`（通用串行总线控制器）下所有设备设为 `False`。
- **电源选项**：对当前活动方案用 `powercfg /setac|dcvalueindex SCHEME_CURRENT` 设置 DISKIDLE / STANDBYIDLE / HIBERNATEIDLE = 0（从不）、HYBRIDSLEEP = 0、USB 选择性暂停 = 0、PCIe ASPM = 0（关闭），然后 `/setactive` 并回读校验。`powercfg` 是外部命令，失败不抛异常，须检查 `$LASTEXITCODE`。不执行 `powercfg /h off`（会让休眠/混合睡眠项从电源选项界面消失，与 SOP 截图不符）。
- **驱动下载**：通过页面 HTML 解析（`Invoke-WebRequest`）提取驱动下载 URL，逐包 `Invoke-WebRequest` 下载到临时目录，解压后按扩展名选择安装方式（`.exe /s`、`.msi /quiet`、`pnputil /add-driver`）。
- **日志**：所有操作写入同目录 `optimize_log.txt`，带时间戳。

## 交付物

```
引望/
├── CLAUDE.md                           # 本文件（项目说明）
├── 实现方案.md                         # 详细实现方案说明
├── 一键优化.ps1                        # 主脚本（型号检测 + 补丁 + USB + 睡眠 + 驱动）
├── 关闭USB重定向.docx                  # 参考文档1
└── 关闭USB节能及系统睡眠优化设置.docx  # 参考文档2
```

## 使用方式

右键 `一键优化.ps1` → 以管理员身份运行（或在管理员 PowerShell 中执行）。
脚本会先检测产品型号，若为 IMB-C47 则逐步执行所有模块，完成后提示是否需要重启。
