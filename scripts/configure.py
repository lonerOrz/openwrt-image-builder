#!/usr/bin/env python3
"""交互式 Profile 生成向导 - 动态定制固件参数"""
import os
import json
import sys
import urllib.request
from urllib.parse import urljoin

PRESETS = {
    "1": {
        "name": "x86_64",
        "target": "x86/64",
        "profile": "generic",
        "extra_image_name": "x86",
        "rootfs_partsize": 1024,
        "daede_arch": "x86_64",
        "imagebuilder_url": "https://downloads.immortalwrt.org/releases/25.12-SNAPSHOT/targets/x86/64/immortalwrt-imagebuilder-25.12-SNAPSHOT-x86-64.Linux-x86_64.tar.zst",
    },
    "2": {
        "name": "friendlyarm_nanopi-r2s",
        "target": "rockchip/armv8",
        "profile": "friendlyarm_nanopi-r2s",
        "extra_image_name": "r2s",
        "rootfs_partsize": 512,
        "daede_arch": "aarch64_cortex-a53",
        "imagebuilder_url": "https://downloads.immortalwrt.org/releases/25.12-SNAPSHOT/targets/rockchip/armv8/immortalwrt-imagebuilder-25.12-SNAPSHOT-rockchip-armv8.Linux-x86_64.tar.zst",
    }
}


def fetch_default_packages(ib_url, profile):
    try:
        base_url = "/".join(ib_url.split("/")[:-1]) + "/"
        profiles_url = urljoin(base_url, "profiles.json")
        req = urllib.request.Request(profiles_url, headers={"User-Agent": "openwrt-imagebuilder"})
        with urllib.request.urlopen(req, timeout=10) as res:
            data = json.loads(res.read().decode('utf-8'))
            target_pkgs = data.get("target_packages", [])
            profile_data = data.get("profiles", {}).get(profile, {})
            dev_pkgs = profile_data.get("device_packages", [])

            device_title = "Unknown Device"
            titles = profile_data.get("titles", [])
            if isinstance(titles, list) and len(titles) > 0:
                first = titles[0]
                if isinstance(first, dict):
                    device_title = first.get("title") or f"{first.get('vendor', '')} {first.get('model', '')}".strip() or "Unknown Device"

            return sorted(list(set(target_pkgs + dev_pkgs))), device_title
    except Exception as e:
        print(f"无法自动获取在线默认包列表 ({e})，将跳过可选剔除项交互推荐。")
        return None, "Unknown Device"


def prompt(text, default=""):
    suffix = f" [{default}]" if default else ""
    val = input(f"{text}{suffix}: ").strip()
    return val if val else default


def main():
    print("=" * 60)
    print("        OpenWrt/ImmortalWrt 固件定制交互式配置向导")
    print("=" * 60)

    print("\n请选择目标硬件平台基础模板:")
    for k, v in PRESETS.items():
        print(f"  [{k}] {v['name']} ({v['target']})")
    print("  [3] 自定义其他未知平台")

    choice = prompt("输入选项", "1")

    if choice in PRESETS:
        config = PRESETS[choice].copy()
    else:
        target = prompt("输入 Target (如 mvebu/cortexa72)")
        profile = prompt("输入 Profile 标识符")
        extra_image_name = prompt("输入输出文件名后缀 (如 r4s)", "custom")

        while True:
            try:
                rootfs_partsize = int(prompt("输入 RootFS 分区大小 (MB)", "1024"))
                break
            except ValueError:
                print("输入格式不正确，请输入纯数字 (例如: 1024)")

        daede_arch = prompt("输入 CPU 架构体系 (如 aarch64_cortex-a72)")
        imagebuilder_url = prompt("输入 ImageBuilder 下载直链 (.tar.zst / .tar.xz)")

        config = {
            "target": target,
            "profile": profile,
            "extra_image_name": extra_image_name,
            "rootfs_partsize": rootfs_partsize,
            "daede_arch": daede_arch,
            "imagebuilder_url": imagebuilder_url,
            "name": extra_image_name
        }

    print("\n[INFO] 正在向远程平台获取默认软件包数据...")
    default_packages, device_title = fetch_default_packages(config["imagebuilder_url"], config["profile"])

    print("\n--- 1. 网络与系统参数配置 ---")
    lan_ip = prompt("局域网 LAN 管理 IP", "192.168.100.1")
    root_password = prompt("管理员(root)初始化密码", "password")
    ssl_cn = prompt("HTTPS 证书 CN 标识", "ImmortalWrt")

    config["system"] = {
        "lan_ip": lan_ip,
        "root_password": root_password,
        "ssl_cn": ssl_cn
    }

    print("\n--- 2. 自定义软件包配置 ---")
    if default_packages:
        print(f"已为您推荐分析 [{device_title}] 包含的 {len(default_packages)} 个默认内置包。")

    add_input = prompt("请列出需要额外新增集成的软件 (英文逗号分隔)", "luci-theme-argon,luci-app-daede,curl,nano,nginx")
    add_list = [x.strip() for x in add_input.split(",") if x.strip()]

    remove_list = []
    if default_packages:
        print("\n以下是可能不需要的常见预装膨胀包，输入 y 快速加入删除列表:")
        common_bloats = ["luci-app-wifihistory", "luci-app-advancedplus", "luci-app-filemanager", "luci-app-wizard", "coremark", "ds-lite", "luci-app-attendedsysupgrade"]
        for bloat in common_bloats:
            if bloat in default_packages:
                ans = prompt(f"  是否移除包 {bloat}?", "y")
                if ans.lower() == 'y':
                    remove_list.append(bloat)
    else:
        remove_input = prompt("请列出需要移除的预装包 (用逗号分隔)", "coremark,ds-lite")
        remove_list = [x.strip() for x in remove_input.split(",") if x.strip()]

    config["packages"] = {
        "add": add_list,
        "remove": remove_list
    }

    config["custom_apks"] = [
        {
            "name": "luci-app-daede",
            "source_type": "github_release",
            "repo": "kenzok8/openwrt-daede",
            "tag": "latest",
            "arch": config["daede_arch"]
        }
    ]

    profile_name = config.pop("name")
    out_dir = "config/profiles"
    os.makedirs(out_dir, exist_ok=True)
    out_file = os.path.join(out_dir, f"{profile_name}.json")

    with open(out_file, 'w', encoding='utf-8') as f:
        json.dump(config, f, indent=2, ensure_ascii=False)

    print("\n" + "=" * 60)
    print(f"Profile 配置文件已成功生成: {out_file}")
    print("您可以使用下列命令开始动态固件构建流程:")
    print(f"  ./scripts/build.sh {out_file}")
    print("=" * 60 + "\n")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\n操作已取消，向导退出。")
        sys.exit(0)
