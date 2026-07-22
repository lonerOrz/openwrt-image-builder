#!/usr/bin/env python3
"""远程零开销包发现 — 通过 profiles.json 实时查询设备默认内置包列表"""
import sys
import json
import urllib.request
from urllib.parse import urljoin


def get_profiles_json(ib_url):
    base_url = "/".join(ib_url.split("/")[:-1]) + "/"
    profiles_url = urljoin(base_url, "profiles.json")
    print(f"正在从远端请求平台配置索引: {profiles_url} ...")

    req = urllib.request.Request(profiles_url, headers={"User-Agent": "openwrt-imagebuilder"})
    with urllib.request.urlopen(req, timeout=15) as res:
        return json.loads(res.read().decode('utf-8'))


def extract_device_title(profile_data):
    """从 OpenWrt/ImmortalWrt 标准的 profiles.json 结构中兼容解析设备标题"""
    titles = profile_data.get("titles", [])
    if isinstance(titles, list) and len(titles) > 0:
        first_title = titles[0]
        if isinstance(first_title, dict):
            title = first_title.get("title")
            if title:
                return title
            vendor = first_title.get("vendor", "")
            model = first_title.get("model", "")
            if vendor or model:
                return f"{vendor} {model}".strip()
    return profile_data.get("title") or "Unknown Device"


def main():
    if len(sys.argv) < 2:
        print("Usage: discover.py <profile.json>", file=sys.stderr)
        sys.exit(1)

    profile_json_path = sys.argv[1]
    with open(profile_json_path, 'r', encoding='utf-8') as f:
        config = json.load(f)

    ib_url = config.get("imagebuilder_url")
    target_profile = config.get("profile")

    if not ib_url or not target_profile:
        print("错误: 配置文件中缺少 imagebuilder_url 或 profile 定义。")
        sys.exit(1)

    try:
        profiles_data = get_profiles_json(ib_url)
    except Exception as e:
        print(f"错误: 无法获取远端平台元数据 ({e})。请检查网络。")
        sys.exit(1)

    profiles = profiles_data.get("profiles", {})
    target_packages = profiles_data.get("target_packages", [])

    if target_profile not in profiles:
        print(f"错误: 在远端列表中未找到 profile: '{target_profile}'")
        print(f"当前平台可用 profiles 列表: {list(profiles.keys())}")
        sys.exit(1)

    profile_data = profiles[target_profile]
    device_packages = profile_data.get("device_packages", [])
    default_packages = sorted(list(set(target_packages + device_packages)))

    device_title = extract_device_title(profile_data)

    print("\n" + "=" * 60)
    print(f" 设备 [{target_profile}] ({device_title}) 默认集成的软件包列表")
    print("=" * 60)
    print(f"总计集成基础包数: {len(default_packages)}")
    for pkg in default_packages:
        print(f"  - {pkg}")

    print("\n" + "=" * 60)
    config_remove = config.get("packages", {}).get("remove", [])
    redundant_removes = [pkg for pkg in config_remove if pkg not in default_packages]
    valid_removes = [pkg for pkg in config_remove if pkg in default_packages]

    print(" 当前配置验证结果:")
    print(f"  - 有效移除包: {', '.join(valid_removes) if valid_removes else '无'}")
    if redundant_removes:
        print(f"\n  警告: 以下声明需要 remove 的包，由于默认固件原本就不含此包，因此该配置是多余的:")
        for pkg in redundant_removes:
            print(f"    - {pkg}")
    print("=" * 60 + "\n")


if __name__ == "__main__":
    main()
