# WinUpdateTool 项目说明

## 客户要求

纯脚本模式（PowerShell，不依赖第三方 GUI 工具）一键完成以下功能：

脚本启动时读取 BIOS 中的产品型号，并在 `支持产品.psd1` 中查找对应的 ADLINK 产品编号。当前映射为 `IMB-C47 = 2184`。

1. **产品型号检测**
   - 从 `Win32_BIOS.SMBIOSBIOSVersion` 解析产品型号。型号未登记时，脚本记录原因并退出。

2. **系统补丁一键安装**
   - 检测、下载并安装所有 Windows 系统更新，支持有无重启两种情况。

3. **关闭 USB 节能、重定向及睡眠功能**
   - 关闭 USB 重定向（RemoteFX USB 设备重定向）
   - 关闭 USB 节能（USB 选择性挂起；设备管理器中取消"允许计算机关闭此设备以节约电源"）
   - 关闭系统睡眠与休眠（电源选项全部设为"从不"，禁用休眠文件）

4. **ADLINK 驱动和软件包下载并安装**
   - 来源：https://www.adlinktech.com.cn/Products/DownloadSoftwareDriver.aspx?lang=zh_cn&pdNo=2184&kind=DR
   - Windows 11 匹配 **Windows 10\11** 和 **Windows 11**。Windows 10 匹配 **Windows 10** 和 **Windows 10\11**。
   - Windows 10\11 驱动包（截图确认）：
     - Audio_v6.0.9079.1（303.89 MB）
     - Chipset_v10.1.19600.8418（5.00 MB）
     - Graphics_v31.0.101.4644（610.56 MB）
     - ME_v2335.5.26.0（1033.32 MB）
     - SerialIO_v30.100.2237.26（3.25 MB）
   - Windows 11 驱动包（截图确认）：
     - Ethernet(i225-i226)_v2.1.3.3（0.60 MB）
   - 先列出匹配的驱动和软件包，再逐个下载、安装并记录结果。

## 参考文档

| 文档 | 操作要点 |
|------|---------|
| `关闭USB重定向.docx` | gpedit.msc → 计算机配置 → 管理模板 → Windows 组件 → 远程桌面服务 → 远程桌面会话客户端 → **RemoteFX USB 设备重定向** → 禁用，完成后重启 |
| `关闭USB节能及系统睡眠优化设置.docx` | 设备管理器 → 通用串行总线控制器 → 每个 USB 设备 → 电源管理 → 取消节能勾选；电源选项中睡眠/关闭显示器/硬盘/休眠均设为"从不"/"禁用" |

## 技术实现决策

- **型号检测**通过 `Get-CimInstance -ClassName Win32_BIOS` 读取 `SMBIOSBIOSVersion`，按 `产品型号_版本号` 格式取第一个下划线前的型号。例如 `IMB-C47_2.00.10` 解析为 `IMB-C47`。
- **权限**：脚本运行时检测管理员身份，非管理员自动以管理员重启。
- **补丁安装**：使用系统内置 COM 对象 `Microsoft.Update.Session`，零外部依赖。
- **USB 重定向**：策略 `TS_USB_REDIRECTION_DISABLE` 无 disabledValue，"已禁用"= 向本地 GPO `Machine\Registry.pol` 写 `**del.fUsbRedirectionEnableMode`；**必须同时更新 `GroupPolicy\gpt.ini`**（Version+1，并在 `gPCMachineExtensionNames` 中登记 RemoteFX USB CSE `{4BCD6CDE-777B-48B6-9804-43568E23545D}`），否则 gpupdate 不会调用该 CSE，设置不生效。
- **USB 节能**：全局禁用 `HKLM\SYSTEM\CurrentControlSet\Services\USB\DisableSelectiveSuspend = 1`；设备管理器"允许计算机关闭此设备以节约电源"勾选框 = WMI `root\wmi:MSPower_DeviceEnable.Enable`，对设备类 `USB`（通用串行总线控制器）下所有设备设为 `False`。
- **电源选项**：对当前活动方案用 `powercfg /setac|dcvalueindex SCHEME_CURRENT` 设置 DISKIDLE / STANDBYIDLE / HIBERNATEIDLE = 0（从不）、HYBRIDSLEEP = 0、USB 选择性暂停 = 0、PCIe ASPM = 0（关闭），然后 `/setactive` 并回读校验。`powercfg` 是外部命令，失败不抛异常，须检查 `$LASTEXITCODE`。不执行 `powercfg /h off`（会让休眠/混合睡眠项从电源选项界面消失，与 SOP 截图不符）。
- **驱动下载**从官网页面获取系统分类，再查询 `DownloadSoftData.ashx` 的 `DR`（驱动）和 `SW`（软件） 目录。脚本按 Windows 构建号选分类，以目录编号去重并按文件大小校验下载。安装程序按 EXE、MSI 或 INF 格式调用。
- **日志**：所有操作写入同目录 `optimize_log.txt`，带时间戳。

## 交付物

```
WinUpdateTool/
├── CLAUDE.md                           # 本文件（项目说明）
├── 实现方案.md                         # 详细实现方案说明
├── WinUpdateTool.ps1                        # 主脚本（型号检测 + 补丁 + USB + 睡眠 + 驱动）
├── WinUpdateTool.cmd                        # 使用进程级执行策略启动主脚本
├── 支持产品.psd1                      # 产品型号与 ADLINK pdNo 的映射
├── 关闭USB重定向.docx                  # 参考文档1
└── 关闭USB节能及系统睡眠优化设置.docx  # 参考文档2
```

## 使用方式

启动器为这次运行的 Windows PowerShell 进程设置 `Bypass`，所有模式都可通过同一个入口运行。

| PowerShell 中的命令 | 执行内容 |
|---------------------|----------|
| `.\WinUpdateTool.cmd` | 全量优化 |
| `.\WinUpdateTool.cmd -Patch` | 安装 Windows 补丁 |
| `.\WinUpdateTool.cmd -USB` | USB 和睡眠优化 |
| `.\WinUpdateTool.cmd -Driver` | 下载和安装驱动，官网要求登录时打开窗口 |
| `.\WinUpdateTool.cmd -Rollback` | 回退 USB 和睡眠设置 |
| `.\WinUpdateTool.cmd -Patch -Driver` | 安装补丁和驱动 |

需要提权时，Windows 会弹出管理员授权提示。支持的 ADLINK 产品可在 `支持产品.psd1` 增加一条型号与 `pdNo` 的映射，目录和包清单由官网实时提供。

官网要求登录时，脚本会打开 Windows 凭据窗口。输入 ADLINK 登录邮箱和密码，官网确认登录后，脚本会自动刷新目录并继续下载和安装。登录会话仅用于本次运行。可加 `-AdlinkPassword` 在查询目录前打开登录窗口。

使用已登录的浏览器会话时，运行 `.\WinUpdateTool.cmd -Driver -AdlinkLogin`。在浏览器开发者工具的「网络」面板中，选中发往 `www.adlinktech.com.cn` 的已登录请求，把请求头中 `Cookie` 的值粘贴到脚本的隐藏输入提示中。

可以把手动下载的文件放到 `_drivers`、`_drivers\<pdNo>` 或日志给出的包目录。脚本联网获取本机适用的包清单后，优先安装文件名和大小与官网记录一致的本地包。缺少匹配文件时，下载进度条会显示包序号、包名、百分比和已下载大小。
