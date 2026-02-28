#!/usr/bin/env python3
import csv
import datetime as dt
from pathlib import Path
from typing import Dict, List


def load_csv(path: Path) -> List[Dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def summarize_matrix(rows: List[Dict[str, str]]) -> Dict[str, str]:
    total = len(rows)
    keys = [
        "客户端已接入",
        "MCP调用通过",
        "对话触发通过",
        "胶囊开始态正常",
        "胶囊结束态正常",
        "错误态可见",
    ]
    out = {"工具总数": str(total)}
    for key in keys:
        passed = sum(1 for r in rows if r.get(key) == "是")
        out[key] = f"{passed}/{total}"
    return out


def summarize_recent_runs(rows: List[Dict[str, str]], n: int = 2) -> List[Dict[str, str]]:
    run_ids: List[str] = []
    for row in rows:
        rid = row.get("RunID", "")
        if rid and rid not in run_ids:
            run_ids.append(rid)
    selected = run_ids[-n:]
    result: List[Dict[str, str]] = []
    for rid in selected:
        subset = [r for r in rows if r.get("RunID") == rid]
        total = len(subset)
        passed = sum(1 for r in subset if r.get("是否通过") == "是")
        result.append({
            "RunID": rid,
            "总数": str(total),
            "通过": str(passed),
            "状态": "通过" if total > 0 and passed == total else "失败",
        })
    return result


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    matrix_path = repo / "qa" / "mcp_tool_acceptance_matrix.csv"
    run_log_path = repo / "qa" / "mcp_tool_run_log.csv"
    report_path = repo / "qa" / "mcp_final_acceptance_report.md"

    matrix_rows = load_csv(matrix_path)
    run_rows = load_csv(run_log_path)

    matrix_summary = summarize_matrix(matrix_rows)
    recent_runs = summarize_recent_runs(run_rows, n=2)

    failed_tools = [r["工具名"] for r in matrix_rows if r.get("MCP调用通过") != "是"]

    now = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    lines: List[str] = []
    lines.append("# MCP 全量接入最终验收报告")
    lines.append("")
    lines.append(f"- 生成时间: {now}")
    lines.append(f"- 主清单: `{matrix_path}`")
    lines.append(f"- 长跑日志: `{run_log_path}`")
    lines.append("")
    lines.append("## 主清单汇总")
    lines.append("")
    lines.append("| 指标 | 结果 |")
    lines.append("|---|---|")
    lines.append(f"| 工具总数 | {matrix_summary['工具总数']} |")
    lines.append(f"| 客户端已接入 | {matrix_summary['客户端已接入']} |")
    lines.append(f"| MCP调用通过 | {matrix_summary['MCP调用通过']} |")
    lines.append(f"| 对话触发通过 | {matrix_summary['对话触发通过']} |")
    lines.append(f"| 胶囊开始态正常 | {matrix_summary['胶囊开始态正常']} |")
    lines.append(f"| 胶囊结束态正常 | {matrix_summary['胶囊结束态正常']} |")
    lines.append(f"| 错误态可见 | {matrix_summary['错误态可见']} |")
    lines.append("")
    lines.append("## 最近两轮全量回归")
    lines.append("")
    lines.append("| RunID | 总数 | 通过 | 状态 |")
    lines.append("|---|---:|---:|---|")
    for run in recent_runs:
        lines.append(f"| {run['RunID']} | {run['总数']} | {run['通过']} | {run['状态']} |")
    lines.append("")
    lines.append("## 失败项")
    lines.append("")
    if failed_tools:
        for tool in failed_tools:
            lines.append(f"- {tool}")
    else:
        lines.append("- 无（主清单 MCP 调用全通过）")

    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(str(report_path))


if __name__ == "__main__":
    main()
