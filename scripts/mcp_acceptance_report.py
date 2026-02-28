#!/usr/bin/env python3
import csv
import sys


def main(path: str) -> None:
    with open(path, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))

    total = len(rows)
    passed = sum(1 for row in rows if row.get("MCP调用通过") == "是")
    integrated = sum(1 for row in rows if row.get("客户端已接入") == "是")
    dialogue = sum(1 for row in rows if row.get("对话触发通过") == "是")
    capsule_start = sum(1 for row in rows if row.get("胶囊开始态正常") == "是")
    capsule_end = sum(1 for row in rows if row.get("胶囊结束态正常") == "是")

    print(f"工具总数: {total}")
    print(f"客户端已接入: {integrated}/{total}")
    print(f"MCP调用通过: {passed}/{total}")
    print(f"对话触发通过: {dialogue}/{total}")
    print(f"胶囊开始态正常: {capsule_start}/{total}")
    print(f"胶囊结束态正常: {capsule_end}/{total}")

    failures = [row for row in rows if row.get("MCP调用通过") != "是"]
    if failures:
        print("\n未通过工具:")
        for row in failures:
            print(f"- {row['工具名']}: {row.get('最近结果','')} | {row.get('发现问题','')}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: mcp_acceptance_report.py <matrix_csv>")
        raise SystemExit(1)
    main(sys.argv[1])
