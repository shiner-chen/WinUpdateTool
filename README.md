# WinUpdateTool

WinUpdateTool 是面向 ADLINK 工控机的 Windows PowerShell 优化工具，可安装 Windows 更新、调整 USB 和电源设置，并下载和安装适用于本机的驱动与软件包。当前产品映射包含 `IMB-C47`。

## 运行条件

- Windows 10 或 Windows 11，使用系统自带的 Windows PowerShell 5.1。
- 运行需要本地管理员权限。当前终端权限不足时，脚本会请求管理员授权。
- 在线安装补丁需访问 Windows Update 或企业 WSUS，在线安装驱动需访问 ADLINK 官网。

## 快速开始

将离线补丁复制到脚本同级的 `WinPatches`，将离线驱动和软件包复制到同级的 `Drivers`。在项目目录打开 PowerShell，通过 `WinUpdateTool.cmd` 启动。若所选模块需要的目录不存在，脚本会在安装前提示创建目录、复制安装包，或指定现有目录。

```powershell
.\WinUpdateTool.cmd
```

| 命令 | 执行内容 |
| --- | --- |
| `.\WinUpdateTool.cmd` | 依次安装离线补丁、应用 USB 和电源设置、安装离线驱动与软件包 |
| `.\WinUpdateTool.cmd -Patch` | 安装 `WinPatches` 中适用于本机的补丁 |
| `.\WinUpdateTool.cmd -Patch -PatchPath "D:\离线补丁"` | 安装指定目录中的补丁 |
| `.\WinUpdateTool.cmd -USB` | 关闭 RemoteFX USB 重定向和 USB 节能，调整当前电源计划的睡眠、休眠等设置 |
| `.\WinUpdateTool.cmd -Driver` | 优先导入 `ExportedDrivers` 中的驱动备份，备份缺失或为空时使用 `Drivers` 中的离线包 |
| `.\WinUpdateTool.cmd -Driver -DriverPath "D:\离线驱动"` | 安装指定目录中的驱动与软件包 |
| `.\WinUpdateTool.cmd -ExportDrivers` | 将第三方驱动包导出到脚本同级的 `ExportedDrivers` |
| `.\WinUpdateTool.cmd -ExportDrivers -SelectDrivers -DriverPath "D:\驱动备份"` | 在终端按设备勾选并导出到指定目录 |
| `.\WinUpdateTool.cmd -Patch -Online` | 通过 Windows Update 或企业 WSUS 安装补丁 |
| `.\WinUpdateTool.cmd -Driver -Online` | 从 ADLINK 官网匹配、下载并安装驱动与软件包 |
| `.\WinUpdateTool.cmd -Online` | 全量执行，补丁与驱动模块使用在线模式 |
| `.\WinUpdateTool.cmd -Rollback` | 将 USB 和电源设置恢复为脚本预设的默认值 |
| `.\WinUpdateTool.cmd -Help` | 查看参数说明 |

## 离线安装

补丁模块递归读取 MSU 和 CAB 包，按包元数据安排服务堆栈和累积更新的顺序，由 Windows 判定适用性和已安装状态。安装前置补丁后会重试可继续处理的包。如果某个补丁需要等到重启后才能继续，重启后重新运行原命令。可在补丁目录放置 `Dependencies.psd1` 声明额外的安装依赖，格式见实现方案。[实现方案.md](./实现方案.md)

驱动模块处理 ZIP、EXE、MSI 和 INF。解压后的安装包可放在各自的子目录中，脚本会识别常见的主安装程序。

## 驱动备份与导入

默认将驱动备份放在 `ExportedDrivers`，将厂商离线安装包放在 `Drivers`。两者可以放在同一个上级目录的不同子目录中。自定义导出目标需为新目录或空目录。

通过 `.cmd` 指定带空格的路径时，加双引号并省略路径末尾的反斜杠，例如 `-DriverPath "D:\驱动 备份"`。

使用 `-SelectDrivers` 时，上下方向键移动，空格勾选或取消，Enter 确认导出，Esc 取消。单独运行 `-ExportDrivers` 可导出驱动存储中的全部第三方驱动包。

将备份目录整体复制到目标机器。放在脚本同级并命名为 `ExportedDrivers` 时，运行 `.\WinUpdateTool.cmd -Driver` 即可导入。放在其他位置时，运行 `.\WinUpdateTool.cmd -Driver -DriverPath "D:\驱动备份"`。成功导出的目录可改名，目录中的备份标记会让脚本只导入 INF。需要厂商应用时，另外用 `-DriverPath .\Drivers` 安装离线包。

## 在线驱动与软件包

脚本从 BIOS 的 `SMBIOSBIOSVersion` 读取型号。例如 `IMB-C47_2.00.10` 会解析为 `IMB-C47`，并在 `支持产品.psd1` 中匹配到 ADLINK 产品编号 `2184`。新增同类产品时，可在映射文件中添加一行型号和对应的官网 `pdNo`。[支持产品.psd1](./支持产品.psd1)

Windows 10 匹配官网的 `Windows 10` 和 `Windows 10\11` 分类。Windows 11 匹配 `Windows 11` 和 `Windows 10\11` 分类。脚本会查询驱动与软件目录，可按适用条件读取 `All` 分类。

如果本地包的文件名和大小与官网记录一致，脚本会优先使用本地包。预先下载的包可放到 `_drivers`、`_drivers\<pdNo>` 或日志显示的包目录。联网下载时，进度条显示包序号、包名、百分比和已下载大小。

官网要求登录时，脚本会打开 Windows 凭据窗口。输入 ADLINK 账号邮箱和密码，登录成功后会自动继续。加 `-AdlinkPassword` 可提前打开登录窗口。使用已登录浏览器会话的方式见项目说明。[CLAUDE.md](./CLAUDE.md)

## 日志与重启

主日志位于脚本同目录的 `optimize_log.txt`。在线下载缓存和 Intel ME、SerialIO 安装日志位于 `_drivers`。查看安装结果时，以主日志的最终汇总及相应安装程序的日志为准。

如果所选操作产生待重启的更改，脚本会在任务处理完毕后统一询问是否重启。输入 `Y` 立即重启，输入 `N` 或直接回车留到稍后。

## 项目文档

- [项目需求与维护说明](./CLAUDE.md)
- [技术实现方案](./实现方案.md)
- [关闭 USB 重定向操作说明](./关闭USB重定向.docx)
- [关闭 USB 节能及系统睡眠操作说明](./关闭USB节能及系统睡眠优化设置.docx)
