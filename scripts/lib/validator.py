#!/usr/bin/env python3
"""零外部依赖的 JSON Schema 校验器，仅验证基本结构和 type 约束"""
import json
import sys


def validate(data, schema, path=""):
    expected_type = schema.get("type")

    if expected_type == "object":
        if not isinstance(data, dict):
            raise TypeError(f"'{path}' 应当是 object, 实际是 {type(data).__name__}")

        for req in schema.get("required", []):
            if req not in data:
                raise KeyError(f"缺失必填字段: '{path}.{req}'" if path else f"缺失必填字段: '{req}'")

        for key, val in data.items():
            if "properties" in schema and key in schema["properties"]:
                validate(val, schema["properties"][key], f"{path}.{key}" if path else key)

    elif expected_type == "array":
        if not isinstance(data, list):
            raise TypeError(f"'{path}' 应当是 array, 实际是 {type(data).__name__}")
        if "items" in schema:
            for i, item in enumerate(data):
                validate(item, schema["items"], f"{path}[{i}]")

    elif expected_type == "string":
        if not isinstance(data, str):
            raise TypeError(f"'{path}' 应当是 string, 实际是 {type(data).__name__}")

    elif expected_type == "integer":
        if not isinstance(data, int) or isinstance(data, bool):
            raise TypeError(f"'{path}' 应当是 integer, 实际是 {type(data).__name__}")

    # 验证 enum 约束
    if "enum" in schema and data not in schema["enum"]:
        raise ValueError(f"'{path}' 的值 '{data}' 不在允许的枚举值 {schema['enum']} 中")


def main():
    if len(sys.argv) < 3:
        print("Usage: validator.py <schema.json> <profile.json>", file=sys.stderr)
        sys.exit(2)

    try:
        with open(sys.argv[1], "r", encoding="utf-8") as f:
            schema = json.load(f)
        with open(sys.argv[2], "r", encoding="utf-8") as f:
            data = json.load(f)

        validate(data, schema)
        print("Profile validation successful.")
        sys.exit(0)
    except Exception as e:
        print(f"Validation Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
