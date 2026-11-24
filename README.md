# WinUpdateTool

WinUpdateTool 是面向 ADLINK 工控机的 Windows PowerShell 优化工具，可安装 Windows 更新、调整 USB 和电源设置，并下载和安装适用于本机的驱动与软件包。当前产品映射包含 `IMB-C47`。

## 运行条件

- Windows 10 或 Windows 11，使用系统自带的 Windows PowerShell 5.1。
- 运行需要本地管理员权限。当前终端权限不足时，脚本会请求管理员授权。
- 安装更新时需能访问 Windows Update 或企业 WSUS。驱动模块需访问 ADLINK 官网获取适用的软件包清单。

## 快速开始

下载或克隆仓库，在项目目录打开 PowerShell，通过 `一键优化.cmd` 启动。启动器的 PowerShell 执行策略仅对本次进程生效。

```powershell
.\一键优化.cmd
```

| 命令 | 执行内容 |
| --- | --- |
| `.\一键优化.cmd` | 依次安装 Windows 更新、应用 USB 和电源设置、处理驱动与软件包 |
| `.\一键优化.cmd -Patch` | 安装 Windows 更新 |
| `.\一键优化.cmd -USB` | 关闭 RemoteFX USB 重定向和 USB 节能，调整当前电源计划的睡眠、休眠等设置 |
| `.\一键优化.cmd -Driver` | 下载并安装匹配的驱动与软件包 |
| `.\一键优化.cmd -Patch -Driver` | 安装 Windows 更新、驱动与软件包 |
| `.\一键优化.cmd -Rollback` | 将 USB 和电源设置恢复为脚本预设的默认值 |
| `.\一键优化.cmd -Help` | 查看参数说明 |

## 驱动与软件包

脚本从 BIOS 的 `SMBIOSBIOSVersion` 读取型号。例如 `IMB-C47_2.00.10` 会解析为 `IMB-C47`，并在 `支持产品.psd1` 中匹配到 ADLINK 产品编号 `2184`。新增同类产品时，可在映射文件中添加一行型号和对应的官网 `pdNo`。[支持产品.psd1](./支持产品.psd1)

Windows 10 匹配官网的 `Windows 10` 和 `Windows 10\11` 分类。Windows 11 匹配 `Windows 11` 和 `Windows 10\11` 分类。脚本会查询驱动与软件目录，可按适用条件读取 `All` 分类。

如果本地包的文件名和大小与官网记录一致，脚本会优先使用本地包。预先下载的包可放到 `_drivers`、`_drivers\<pdNo>` 或日志显示的包目录。联网下载时，进度条显示包序号、包名、百分比和已下载大小。

官网要求登录时，脚本会打开 Windows 凭据窗口。输入 ADLINK 账号邮箱和密码，登录成功后会自动继续。加 `-AdlinkPassword` 可提前打开登录窗口。使用已登录浏览器会话的方式见项目说明。[CLAUDE.md](./CLAUDE.md)

## 日志与重启

主日志位于脚本同目录的 `optimize_log.txt`。下载缓存和 Intel ME、SerialIO 安装日志位于 `_drivers`。查看安装结果时，以主日志的最终汇总及相应安装程序的日志为准。

如果所选操作产生待重启的更改，脚本会在任务处理完毕后统一询问是否重启。输入 `Y` 立即重启，输入 `N` 或直接回车留到稍后。

## 项目文档

- [项目需求与维护说明](./CLAUDE.md)
- [技术实现方案](./实现方案.md)
- [关闭 USB 重定向操作说明](./关闭USB重定向.docx)
- [关闭 USB 节能及系统睡眠操作说明](./关闭USB节能及系统睡眠优化设置.docx)
