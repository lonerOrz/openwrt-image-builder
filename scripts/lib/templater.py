#!/usr/bin/env python3
"""渲染 .template 文件，将 {{ VAR }} 占位符替换为 profile 中的值"""
import json
import sys
import re
import os


def render_templates(profile_path, target_files_dir):
    with open(profile_path, 'r', encoding='utf-8') as f:
        profile = json.load(f)

    system = profile.get("system", {})
    context = {
        "LAN_IP": system.get("lan_ip", "192.168.100.1"),
        "ROOT_PASSWORD": system.get("root_password", "password"),
        "SSL_CN": system.get("ssl_cn", "ImmortalWrt"),
        "EXTRA_IMAGE_NAME": profile.get("extra_image_name", "custom"),
    }

    for root, _, files in os.walk(target_files_dir):
        for file in files:
            if file.endswith('.template'):
                template_path = os.path.join(root, file)
                output_path = os.path.join(root, file[:-9])  # strip .template

                print(f"[Template] {template_path} -> {output_path}")
                with open(template_path, 'r', encoding='utf-8') as tf:
                    content = tf.read()

                for k, v in context.items():
                    pattern = r"\{\{\s*" + re.escape(k) + r"\s*\}\}"
                    content = re.sub(pattern, str(v), content)

                with open(output_path, 'w', encoding='utf-8') as of:
                    of.write(content)

                try:
                    os.chmod(output_path, os.stat(template_path).st_mode)
                except Exception as e:
                    print(f"Warning: 权限复制失败: {e}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: templater.py <profile.json> <files_dir>", file=sys.stderr)
        sys.exit(1)
    render_templates(sys.argv[1], sys.argv[2])
