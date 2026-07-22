# imagebuilder

构建包含 [`luci-app-daede`](https://github.com/kenzok8/openwrt-daede) 的
ImmortalWrt 固件，支持多种设备配置。

## 架构

```
openwrt-image-builder/
├── .github/workflows/build-image.yml   # GitHub Actions workflow
├── config/
│   ├── schema.json                      # 配置文件 JSON Schema
│   └── profiles/                        # 设备配置文件
│       ├── friendlyarm_nanopi-r2s.json
│       └── x86_64.json
├── files/                               # 注入固件的系统文件
├── scripts/
│   ├── build.sh                         # 主构建入口
│   ├── validate.sh                      # Preflight 依赖预检
│   ├── discover.sh                      # 包发现工具
│   └── lib/
│       ├── bootstrap.sh                 # ImageBuilder 下载/解压/缓存
│       ├── common.sh                    # 日志、下载函数
│       ├── package_manager.sh           # 第三方 APK 生命周期
│       └── validator.py                 # JSON Schema 验证器
└── README.md
```

## 构建流程

`build.sh` 执行 6 步流水线：

1. **配置验证** — JSON Schema 静态校验，阻止格式错误
2. **Bootstrap** — 下载并解压 ImmortalWrt ImageBuilder（带缓存）
3. **第三方 APK** — 从 GitHub Release 下载 luci-app-daede 等包
4. **Preflight** — `make manifest` 依赖求解预检
5. **注入文件** — 复制 `files/` 和设备专属 overlay
6. **构建固件** — `make image` 生成最终固件

## 现有设备配置

| 配置文件 | 设备 | 架构 | daede 架构 | 根分区 |
|----------|------|------|-----------|--------|
| `friendlyarm_nanopi-r2s` | NanoPi R2S | rockchip/armv8 | aarch64_cortex-a53 | 512 MB |
| `x86_64` | x86 虚拟机/物理机 | x86/64 | x86_64 | 1024 MB |

## 添加新设备

### 1. 创建配置文件

在 `config/profiles/` 目录创建 JSON 文件，文件名即设备名：

```bash
# 例如添加 NanoPi R5S
cp config/profiles/friendlyarm_nanopi-r2s.json config/profiles/friendlyarm_nanopi-r5s.json
```

### 2. 编辑配置

配置文件字段说明：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `target` | string | 是 | OpenWrt 架构，如 `rockchip/armv8`、`x86/64` |
| `profile` | string | 是 | 设备 profile 名，如 `friendlyarm_nanopi-r2s`、`generic` |
| `extra_image_name` | string | 是 | 输出文件名后缀，如 `r2s`、`x86` |
| `rootfs_partsize` | integer | 是 | 根文件系统分区大小（MB） |
| `imagebuilder_url` | string | 是 | ImmortalWrt ImageBuilder 下载地址 |
| `daede_arch` | string | 否 | daede APK 的架构名（见下表） |
| `packages.add` | array | 是 | 要安装的包列表 |
| `packages.remove` | array | 是 | 要移除的包列表 |
| `custom_apks` | array | 否 | 第三方 APK 定义 |

#### daede 架构对照表

daede release 使用 OpenWrt 子架构命名，**不是** 裸架构名：

| 裸架构 | 正确的 `daede_arch` |
|--------|---------------------|
| aarch64 (Cortex-A53) | `aarch64_cortex-a53` |
| aarch64 (Cortex-A72) | `aarch64_cortex-a72` |
| aarch64 (通用) | `aarch64_generic` |
| x86_64 | `x86_64` |
| armv7 (Cortex-A7) | `arm_cortex-a7_neon-vfpv4` |
| armv7 (Cortex-A9) | `arm_cortex-a9_neon` |
| i386 | `i386_pentium4` |

#### 自定义 APK 示例

`custom_apks` 支持两种来源：

```json
"custom_apks": [
  {
    "name": "luci-app-daede",
    "source_type": "github_release",
    "repo": "kenzok8/openwrt-daede",
    "tag": "latest",
    "arch": "aarch64_cortex-a53"
  },
  {
    "name": "my-package",
    "source_type": "direct_url",
    "url": "https://example.com/my-package.apk"
  }
]
```

### 3. 更新 Workflow

在 `.github/workflows/build-image.yml` 的 `profile` 选项中添加新设备：

```yaml
options:
  - "friendlyarm_nanopi-r2s"
  - "friendlyarm_nanopi-r5s"  # 添加这一行
  - "x86_64"
```

### 4. （可选）设备专属 overlay

如果设备需要特殊配置文件，创建 overlay 目录：

```bash
mkdir -p config/profiles/friendlyarm_nanopi-r5s/files/etc/uci-defaults
```

该目录下的文件会在构建时合并到固件的 `/etc/` 中。

### 5. 本地测试

```bash
scripts/build.sh config/profiles/friendlyarm_nanopi-r5s.json
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

| 输入项 | 默认值 | 说明 |
|--------|--------|------|
| `profile` | `friendlyarm_nanopi-r2s` | 目标设备配置 |
| `publish_release` | `false` | 发布到 GitHub Release |
| `preflight` | `true` | 构建前依赖预检 |

## 首次启动默认值

- LAN IP：`192.168.100.1/24`
- WAN：DHCP
- SSH 端口：`22`
- Root 密码：`password`（首次登录后请修改）
- Web 界面：nginx 反向代理 LuCI，HTTPS 端口 443
