# imagebuilder

构建包含 [`luci-app-daede`](https://github.com/kenzok8/openwrt-daede) 的
ImmortalWrt 固件，支持多种设备配置。

## 架构

```
openwrt-image-builder/
├── .github/workflows/
│   └── build-image.yml              # GitHub Actions workflow（profile 动态选择）
├── config/
│   ├── schema.json                  # 配置文件 JSON Schema
│   └── profiles/                    # 设备配置文件
│       ├── friendlyarm_nanopi-r2s.json
│       └── x86_64.json
├── files/                           # 注入固件的系统文件
├── scripts/
│   ├── build.sh                     # 主构建入口
│   ├── validate.sh                  # Preflight 依赖预检
│   ├── discover.sh                  # 包发现工具
│   └── lib/
│       ├── bootstrap.sh             # ImageBuilder 下载/解压/缓存
│       ├── common.sh                # 日志、下载函数
│       ├── package_manager.sh       # 第三方 APK 生命周期
│       ├── templater.py             # 模板渲染引擎
│       └── validator.py             # JSON Schema 验证器
└── README.md
```

## 构建流程

`build.sh` 执行 6 步流水线：

1. **配置验证** — JSON Schema 静态校验，阻止格式错误
2. **Bootstrap** — 下载并解压 ImmortalWrt ImageBuilder（带缓存）
3. **第三方 APK** — 从 GitHub Release 下载 luci-app-daede 等包（自动清理 25.12.x 架构后缀）
4. **Preflight** — `make manifest` 依赖求解预检
5. **注入文件** — 渲染模板 + 复制 `files/` 和设备专属 overlay
6. **构建固件** — `make image` 生成最终固件

## 设备配置

| 配置文件 | 设备 | 架构 | daede 架构 | 根分区 |
|----------|------|------|-----------|--------|
| `friendlyarm_nanopi-r2s` | NanoPi R2S | rockchip/armv8 | aarch64_cortex-a53 | 512 MB |
| `x86_64` | x86 虚拟机/物理机 | x86/64 | x86_64 | 1024 MB |

## 功能配置

配置文件支持以下功能字段：

### network（网络配置）

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `lan_ip` | string | `192.168.100.1` | LAN 口管理地址 |
| `root_password` | string | `password` | root 密码 |
| `ssl_cn` | string | `ImmortalWrt` | SSL 证书 CN |
| `enable_pppoe` | boolean | `false` | 启用 PPPoE 拨号 |
| `pppoe_account` | string | `""` | PPPoE 宽带账号 |
| `pppoe_password` | string | `""` | PPPoE 宽带密码 |

> `network` 字段优先级高于 `system`，未设置 `network` 时回退到 `system`（向后兼容）。

### features（功能开关）

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `include_docker` | boolean | `false` | 集成 Docker（追加 luci-i18n-dockerman-zh-cn） |
| `enable_store` | boolean | `false` | 集成 iStore 商店（追加 luci-app-store） |
| `enable_firewall_wan_accept` | boolean | `true` | WAN 口允许入站 |

## 首次启动行为

首次启动时 `99-daed-test-network` 脚本自动配置：

- LAN IP：由 `network.lan_ip` 决定，默认 `192.168.100.1/24`
- SSH：dropbear 监听所有接口（非仅 LAN）
- Web：nginx 反向代理 LuCI，HTTPS 端口 443
- IPv6：LAN + WAN 均启用，RADV/DHCPv6 服务端
- WAN：DHCP（PPPoE 可选）
- Docker 防火墙：如启用，自动创建 docker zone + forwarding
- Android TV DNS：自动映射 `time.android.com` → `216.239.36.1`

## 添加新设备

### 1. 创建配置文件

```bash
cp config/profiles/x86_64.json config/profiles/my-device.json
```

### 2. 编辑配置

配置文件字段说明：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `target` | string | 是 | OpenWrt 架构，如 `rockchip/armv8`、`x86/64` |
| `profile` | string | 是 | 设备 profile 名 |
| `extra_image_name` | string | 是 | 输出文件名后缀 |
| `rootfs_partsize` | integer | 是 | 根文件系统分区大小（MB） |
| `imagebuilder_url` | string | 是 | ImmortalWrt ImageBuilder 下载地址 |
| `daede_arch` | string | 否 | daede APK 的架构名 |
| `network` | object | 否 | 网络/功能配置（见上表） |
| `features` | object | 否 | 功能开关（见上表） |
| `packages.add` | array | 是 | 要安装的包列表 |
| `packages.remove` | array | 是 | 要移除的包列表 |
| `custom_apks` | array | 否 | 第三方 APK 定义 |

### 3. 本地测试

```bash
scripts/build.sh config/profiles/my-device.json
```

## 本地构建

### 前置依赖

```bash
sudo apt-get install -y \
  build-essential clang flex bison gawk gettext git \
  libncurses-dev libssl-dev python3 python3-distutils \
  rsync unzip zstd file wget curl jq
```

### 构建命令

```bash
# 指定配置文件
scripts/build.sh config/profiles/friendlyarm_nanopi-r2s.json

# 环境变量覆盖
PREFLIGHT=0 scripts/build.sh config/profiles/x86_64.json

# 发现某配置可用的内置包
scripts/discover.sh config/profiles/friendlyarm_nanopi-r2s.json | grep dae
```

### 构建产物

输出在 `out/` 目录：

- `daede-<name>-squashfs-efi.img.gz` — EFI 引导镜像（dd 写盘）
- `daede-<name>-squashfs-sdcard.img.gz` — SD 卡镜像
- `daede-<name>-rootfs.tar.gz` — 裸文件系统（LXC 容器用）
- `daede-<name>.manifest` — 已安装包清单
- `sha256sums` — 校验和

## GitHub Actions

运行 `Build daede image` workflow：

### 输入项

| 输入项 | 默认值 | 说明 |
|--------|--------|------|
| `luci_version` | `25.12-SNAPSHOT` | ImmortalWrt 版本 |
| `rootfs_size` | 设备默认 | 固件大小（MB） |
| `custom_router_ip` | `192.168.100.1` | 路由器管理地址 |
| `include_docker` | `false` | 集成 Docker |
| `enable_store` | `false` | 集成 iStore 商店 |
| `enable_pppoe` | `false` | 启用 PPPoE 拨号 |
| `pppoe_account` | — | PPPoE 宽带账号 |
| `pppoe_password` | — | PPPoE 宽带密码 |
| `publish_release` | `false` | 发布到 GitHub Release |
| `preflight` | `true` | 构建前依赖预检 |

## 25.12.x APK 兼容性说明

25.12.x ImageBuilder 使用 APK 包管理器，与旧版 opkg/ipk 有以下区别：

1. **APK 文件名必须与内部元数据完全一致** — 不能重命名 APK 文件
2. **第三方 APK 可能带多余架构后缀** — `clean_apk_filename()` 自动去除 `_all`、`_x86_64` 等后缀
3. **架构必须严格匹配** — `aarch64_cortex-a53` 不能用于 `aarch64_generic` ImageBuilder
