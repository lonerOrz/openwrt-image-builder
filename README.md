# imagebuilder

构建一个包含 [`luci-app-daede`](https://github.com/kenzok8/openwrt-daede) 的
ImmortalWrt 测试固件，支持多种设备配置。

### 设备配置（Profiles）

项目通过 `profiles/` 目录管理不同设备的构建参数。每个 `.env` 文件定义一个设备配置：

| 配置文件 | 设备 | 架构 | 根分区 |
|----------|------|------|--------|
| `friendlyarm_nanopi-r2s` | NanoPi R2S | rockchip/armv8 | 512 MB |
| `x86_64` | x86 虚拟机/物理机 | x86/64 | 1024 MB |

配置文件包含：`TARGET`、`PROFILE`、`EXTRA_IMAGE_NAME`、`ROOTFS_PARTSIZE`、`DAEDE_ARCH`、`IMAGEBUILDER_URL`、`EXTRA_PACKAGES`。

### 默认固件

- 版本：ImmortalWrt `25.12-SNAPSHOT`
- 默认设备：NanoPi R2S (`friendlyarm_nanopi-r2s`)
- ImageBuilder URL：从设备配置文件中读取

### 预装与精简

R2S 配置在 `EXTRA_PACKAGES` 中精简了以下 ImmortalWrt 默认包：

| 移除的包 | 原因 |
|----------|------|
| `luci-app-attendedsysupgrade` | R2S 用户多为手动刷写，此后台守护进程占内存 |
| `luci-app-wifihistory` / `advancedplus` / `filemanager` / `wizard` | 冗余 LuCI 应用 |
| `coremark` | 基准测试工具，非生产必需 |
| `ds-lite` / `usb-modeswitch` | 国内极少使用 |

### 首次启动默认值

生成的固件首次启动时会应用以下默认配置：

- LAN IP：`192.168.100.1/24`
- WAN：DHCP（自动获取网关和 DNS）
- SSH 端口：`22`
- Root 密码：`password`
- IPv6：已启用
- Web 界面：nginx 反向代理 LuCI，HTTPS（自签名证书），端口 443
  - HTTP 请求自动跳转到 HTTPS
  - LuCI 同时可通过 `/op/` 路径访问

固件内置 root 密码为 `password`，首次登录后请修改密码。如需无人值守登录，
请通过私有 workflow 或 secret 注入 SSH 公钥。

### 构建

在 GitHub Actions 手动运行 `Build daede image` workflow。

workflow 会把生成的固件作为 artifact 上传。当 `publish_release` 设置为
`true` 时，也会发布 GitHub Release。

常用输入项：

- `device_profile`：选择目标设备配置，默认 `friendlyarm_nanopi-r2s`
- `publish_release`：是否发布到 GitHub Release，默认 `false`
- `imagebuilder_url`：可选，覆盖设备配置中的 ImageBuilder URL
- `preflight`：构建前是否先检查软件包清单，默认 `true`
- `rootfs_partsize`：可选，覆盖设备配置中的根分区大小（MB）
- `install_daede`：是否把 `luci-app-daede` 打进固件，默认 `true`
- `daede_release_tag`：使用哪个 `luci-app-daede` release，默认 `latest`
- `daede_apk_url`：直接指定 APK 下载地址；填写后优先使用这个地址

默认情况下不需要修改这些输入项，直接运行 workflow 即可生成固件。

### 添加新设备

1. 在 `profiles/` 目录创建 `your_device.env` 文件，参考现有配置文件的格式
2. 在 workflow 的 `device_profile` 选项中添加新设备名称
3. 可选：创建 `profiles/your_device/files/` 目录放置设备专属的覆盖文件

也可通过环境变量覆盖参数：

- `DEVICE_PROFILE`：指定设备配置文件名（不含 `.env` 后缀）
- `DAEDE_RELEASE_TAG`：默认 `latest`
- `DAEDE_ARCH`：默认 `aarch64`
- `DAEDE_APK_URL`：指定后直接下载该 APK
- `INSTALL_DAEDE`：设为 `0` 可跳过内置 daede
