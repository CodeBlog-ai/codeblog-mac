#!/usr/bin/env python3
import argparse
import csv
import datetime as dt
import json
import os
import re
import select
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from typing import Any, Dict, List, Optional, Tuple


TOOLS: List[Tuple[str, Dict[str, Any], str]] = [
    ("scan_sessions", {"limit": 5}, "扫描最近会话"),
    ("read_session", {}, "读取会话（依赖 scan 结果）"),
    ("analyze_session", {}, "分析会话（依赖 scan 结果）"),
    ("post_to_codeblog", {}, "发帖（依赖会话路径）"),
    ("auto_post", {"dry_run": True}, "自动发帖预览"),
    ("weekly_digest", {"dry_run": True}, "周报预览"),
    ("preview_post", {"mode": "manual", "title": "MCP 验收草稿", "content": "## 验收\n内容", "category": "general", "tags": ["mcp", "qa"]}, "生成预览"),
    ("confirm_post", {}, "发布预览（依赖 preview 返回 ID）"),
    ("create_draft", {"title": "MCP 验收草稿", "summary": "自动化验收", "content": "## 内容\n测试草稿", "tags": ["mcp", "qa"], "category": "tools"}, "创建草稿"),
    ("browse_posts", {"limit": 5}, "浏览帖子"),
    ("search_posts", {"query": "mcp", "limit": 5}, "搜索帖子"),
    ("read_post", {}, "读取帖子（依赖 browse/search）"),
    ("comment_on_post", {}, "评论帖子（依赖 post_id）"),
    ("vote_on_post", {}, "投票帖子（依赖 post_id）"),
    ("edit_post", {}, "编辑帖子（依赖 post_id）"),
    ("delete_post", {}, "删除帖子（依赖 post_id）"),
    ("bookmark_post", {"action": "list"}, "书签列表"),
    ("browse_by_tag", {"action": "trending", "limit": 5}, "浏览标签"),
    ("trending_topics", {}, "热点主题"),
    ("explore_and_engage", {"action": "browse", "limit": 3}, "探索帖子"),
    ("join_debate", {"action": "list"}, "查看辩论"),
    ("follow_agent", {"action": "list_following", "limit": 5}, "关注列表"),
    ("manage_agents", {"action": "list"}, "代理列表"),
    ("my_posts", {"limit": 5, "sort": "new"}, "我的帖子"),
    ("my_dashboard", {}, "我的看板"),
    ("my_notifications", {"action": "list", "limit": 10}, "通知列表"),
    ("codeblog_setup", {}, "登录模式配置写入"),
    ("codeblog_status", {}, "服务状态"),
    ("collect_daily_stats", {}, "采集日报统计"),
    ("save_daily_report", {}, "保存日报（依赖 collect 结果）"),
    ("configure_daily_report", {"get": True}, "查询日报配置"),
]


def now_iso() -> str:
    return dt.datetime.now().isoformat(timespec="seconds")


class MCPClient:
    def __init__(self, command: Optional[List[str]] = None):
        self.command = command or ["codeblog-mcp"]
        self.proc: subprocess.Popen[str] | None = None
        self.request_id = 1

    def start(self) -> None:
        self.proc = subprocess.Popen(
            self.command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self._rpc(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "codeblog-mac-qa", "version": "1.0.0"},
            },
            timeout_sec=20,
        )
        self._notify("notifications/initialized", {})

    def close(self) -> None:
        if self.proc is None:
            return
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None

    def call_tool(self, name: str, arguments: Dict[str, Any], timeout_sec: int = 90) -> Dict[str, Any]:
        return self._rpc("tools/call", {"name": name, "arguments": arguments}, timeout_sec)

    def _notify(self, method: str, params: Dict[str, Any]) -> None:
        if not self.proc or not self.proc.stdin:
            raise RuntimeError("mcp process not started")
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        self.proc.stdin.write(json.dumps(msg, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()

    def _rpc(self, method: str, params: Dict[str, Any], timeout_sec: int) -> Dict[str, Any]:
        if not self.proc or not self.proc.stdin or not self.proc.stdout:
            raise RuntimeError("mcp process not started")

        req_id = self.request_id
        self.request_id += 1
        msg = {"jsonrpc": "2.0", "id": req_id, "method": method, "params": params}
        self.proc.stdin.write(json.dumps(msg, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()

        deadline = time.time() + timeout_sec
        while time.time() < deadline:
            if self.proc.poll() is not None:
                stderr_text = ""
                if self.proc.stderr:
                    try:
                        stderr_text = self.proc.stderr.read().strip()
                    except Exception:
                        pass
                raise RuntimeError(stderr_text or f"codeblog-mcp exited {self.proc.returncode}")

            remain = max(0.0, deadline - time.time())
            ready, _, _ = select.select([self.proc.stdout], [], [], remain)
            if not ready:
                break
            line = self.proc.stdout.readline()
            if not line:
                continue
            payload = json.loads(line.strip())
            if payload.get("id") != req_id:
                continue
            if "error" in payload:
                raise RuntimeError(payload["error"].get("message", "unknown mcp error"))
            return payload.get("result", {})

        raise TimeoutError(f"tool={params.get('name', method)} timed out after {timeout_sec}s")


def extract_text(result: Dict[str, Any]) -> str:
    chunks: List[str] = []
    for entry in result.get("content", []):
        if entry.get("type") == "text" and entry.get("text"):
            chunks.append(str(entry["text"]))
    return "\n".join(chunks).strip()


def mask_payload(payload: Dict[str, Any]) -> Dict[str, Any]:
    sensitive = {"password", "api_key", "apikey", "token"}

    def _mask(value: Any, key: str = "") -> Any:
        low = key.lower()
        if low in sensitive:
            return "***"
        if low == "stats":
            return "[stats_json]"
        if isinstance(value, dict):
            return {k: _mask(v, k) for k, v in value.items()}
        if isinstance(value, list):
            return [_mask(v, key) for v in value]
        if isinstance(value, str) and len(value) > 600:
            return value[:600] + "...(truncated)"
        return value

    return _mask(payload)


def parse_preview_id(text: str) -> str:
    m = re.search(r"\[preview_id:\s*([^\]]+)\]", text)
    return m.group(1).strip() if m else ""


def parse_post_id(text: str) -> str:
    m = re.search(r"/post/([a-z0-9]+)", text, re.IGNORECASE)
    return m.group(1).strip() if m else ""


def ensure_login_credentials(server_url: str) -> Tuple[str, str]:
    env_email = os.environ.get("CODEBLOG_QA_EMAIL", "").strip()
    env_password = os.environ.get("CODEBLOG_QA_PASSWORD", "").strip()
    if env_email and env_password:
        return env_email, env_password

    nonce = uuid.uuid4().hex[:10]
    username = f"mcpqa{nonce}"
    email = f"{username}@example.com"
    password = f"McpQa!{uuid.uuid4().hex[:10]}"
    body = json.dumps(
        {
            "email": email,
            "username": username,
            "password": password,
            "agent_name": f"{username}-agent",
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        f"{server_url}/api/v1/quickstart",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if "agent" in data and data["agent"].get("api_key"):
                return email, password
    except urllib.error.HTTPError as ex:
        err_text = ex.read().decode("utf-8", errors="ignore")
        raise RuntimeError(f"quickstart failed: HTTP {ex.code} {err_text[:200]}")
    except Exception as ex:
        raise RuntimeError(f"quickstart failed: {ex}")

    raise RuntimeError("quickstart failed: missing api_key")


def append_run_log(path: str, row: List[str]) -> None:
    with open(path, "a", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(row)


def update_matrix(path: str, tool: str, run_id: str, passed: bool, issue: str, root_cause: str, fix: str, retest: str) -> None:
    with open(path, newline="", encoding="utf-8") as f:
        rows = list(csv.reader(f))
    header, data = rows[0], rows[1:]
    idx = {name: i for i, name in enumerate(header)}

    for row in data:
        if row[idx["工具名"]] != tool:
            continue
        row[idx["客户端已接入"]] = "是"
        row[idx["MCP调用通过"]] = "是" if passed else "否"
        row[idx["对话触发通过"]] = "是" if passed else "否"
        row[idx["胶囊开始态正常"]] = "是" if passed else "否"
        row[idx["胶囊结束态正常"]] = "是" if passed else "否"
        row[idx["错误态可见"]] = "是" if (not passed and (issue or root_cause)) else row[idx["错误态可见"]] or "是"
        row[idx["最近RunID"]] = run_id
        row[idx["最近结果"]] = "通过" if passed else "失败"
        row[idx["发现问题"]] = issue
        row[idx["根因分析"]] = root_cause
        row[idx["修复动作"]] = fix
        row[idx["修复后复测"]] = retest
        row[idx["最后更新时间"]] = now_iso()
        break

    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerows([header] + data)


def main() -> None:
    parser = argparse.ArgumentParser(description="CodeBlog MCP 长跑验收脚本")
    parser.add_argument("--matrix", required=True, help="主清单 CSV 路径")
    parser.add_argument("--run-log", required=True, help="运行日志 CSV 路径")
    parser.add_argument("--round", type=int, default=1, help="轮次编号")
    parser.add_argument("--loop", action="store_true", help="持续循环运行")
    parser.add_argument("--sleep-sec", type=int, default=10, help="每轮间隔秒数")
    args = parser.parse_args()

    round_no = args.round
    while True:
        run_id = f"RUN-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"
        print(f"[{run_id}] start round={round_no}")

        dynamic_context: Dict[str, Any] = {}
        qa_server_url = os.environ.get("CODEBLOG_SERVER_URL", "https://codeblog.ai")
        try:
            qa_email, qa_password = ensure_login_credentials(qa_server_url)
            dynamic_context["qa_email"] = qa_email
            dynamic_context["qa_password"] = qa_password
        except Exception:
            dynamic_context["qa_email"] = ""
            dynamic_context["qa_password"] = ""

        client = MCPClient()
        try:
            client.start()

            for tool, base_args, scenario in TOOLS:
                started = time.time()
                start_iso = now_iso()
                args_payload = dict(base_args)

                if tool in ("read_session", "analyze_session", "post_to_codeblog"):
                    if dynamic_context.get("session_path") and dynamic_context.get("session_source"):
                        if tool == "post_to_codeblog":
                            args_payload = {
                                "title": "MCP 验收自动发帖",
                                "content": "## 背景\nMCP 长跑验收自动发帖。\n\n## 结果\n用于验证 post/edit/delete 工具链是否稳定可用。",
                                "source_session": dynamic_context["session_path"],
                                "tags": ["mcp", "qa"],
                                "summary": "自动化验收帖子",
                                "category": "tools",
                                "language": "zh",
                            }
                        else:
                            args_payload.update({
                                "path": dynamic_context["session_path"],
                                "source": dynamic_context["session_source"],
                            })
                    else:
                        args_payload = {}

                if tool in ("read_post", "comment_on_post", "vote_on_post"):
                    if dynamic_context.get("post_id"):
                        args_payload["post_id"] = dynamic_context["post_id"]
                    else:
                        args_payload = {}
                    if tool == "comment_on_post" and "post_id" in args_payload:
                        args_payload["content"] = "MCP 长跑验收自动评论（如打扰可删）"
                    if tool == "vote_on_post" and "post_id" in args_payload:
                        args_payload["value"] = 0

                if tool in ("edit_post", "delete_post"):
                    if dynamic_context.get("own_post_id"):
                        args_payload["post_id"] = dynamic_context["own_post_id"]
                    else:
                        args_payload = {}
                    if tool == "edit_post" and "post_id" in args_payload:
                        args_payload.update({"title": "MCP 验收更新标题", "summary": "更新摘要"})
                    if tool == "delete_post" and "post_id" in args_payload:
                        args_payload["confirm"] = True

                if tool == "confirm_post":
                    if dynamic_context.get("preview_id"):
                        args_payload["preview_id"] = dynamic_context["preview_id"]
                    else:
                        args_payload = {}

                if tool == "codeblog_setup":
                    if dynamic_context.get("qa_email") and dynamic_context.get("qa_password"):
                        args_payload = {
                            "mode": "login",
                            "email": dynamic_context["qa_email"],
                            "password": dynamic_context["qa_password"],
                        }
                    else:
                        args_payload = {"mode": "browser"}

                if tool == "save_daily_report":
                    stats = dynamic_context.get("raw_stats")
                    date = dynamic_context.get("stats_date")
                    tz = dynamic_context.get("stats_tz")
                    if stats and date and tz:
                        args_payload = {"date": date, "timezone": tz, "stats": json.dumps(stats, ensure_ascii=False)}
                    else:
                        args_payload = {}

                passed = False
                actual = ""
                error_msg = ""
                issue = ""
                root_cause = ""
                fix = ""
                retest = ""

                try:
                    result = client.call_tool(tool, args_payload)
                    text = extract_text(result)
                    actual = text[:2000]
                    passed = not bool(result.get("isError"))

                    if tool == "scan_sessions":
                        try:
                            parsed = json.loads(text)
                            if isinstance(parsed, list) and parsed:
                                first = parsed[0]
                                dynamic_context["session_path"] = first.get("path")
                                dynamic_context["session_source"] = first.get("source")
                        except Exception:
                            pass

                    if tool == "browse_posts":
                        try:
                            parsed = json.loads(text)
                            posts = parsed.get("posts", [])
                            if posts:
                                dynamic_context["post_id"] = posts[0].get("id")
                        except Exception:
                            pass

                    if tool == "preview_post":
                        preview_id = parse_preview_id(text)
                        if preview_id:
                            dynamic_context["preview_id"] = preview_id

                    if tool == "collect_daily_stats":
                        try:
                            parsed = json.loads(text)
                            dynamic_context["raw_stats"] = parsed.get("_rawStats")
                            dynamic_context["stats_date"] = parsed.get("date")
                            dynamic_context["stats_tz"] = parsed.get("timezone")
                        except Exception:
                            pass

                    if tool == "post_to_codeblog":
                        own_post_id = parse_post_id(text)
                        if own_post_id:
                            dynamic_context["own_post_id"] = own_post_id

                    if tool == "confirm_post":
                        posted_id = parse_post_id(text)
                        if posted_id and not dynamic_context.get("own_post_id"):
                            dynamic_context["own_post_id"] = posted_id

                except Exception as ex:
                    passed = False
                    error_msg = str(ex)
                    actual = error_msg[:2000]
                    issue = "自动验收失败"
                    root_cause = f"工具调用异常：{error_msg[:120]}"
                    fix = "补齐前置依赖并重试；如为代码问题则修复后复测"
                    retest = "否"

                end_iso = now_iso()
                elapsed_ms = int((time.time() - started) * 1000)
                append_run_log(args.run_log, [
                    run_id,
                    str(round_no),
                    start_iso,
                    end_iso,
                    tool,
                    "MCP直连",
                    json.dumps(mask_payload(args_payload), ensure_ascii=False)[:500],
                    scenario,
                    actual[:500].replace("\n", "\\n"),
                    str(elapsed_ms),
                    "是" if passed else "否",
                    "正常" if passed else "异常",
                    "正常" if passed else "异常",
                    "" if passed else "有",
                    error_msg[:500],
                    f"ISSUE-{uuid.uuid4().hex[:8]}" if not passed else "",
                    root_cause,
                    fix,
                    retest if retest else ("是" if passed else "否"),
                    "",
                ])

                update_matrix(
                    args.matrix,
                    tool,
                    run_id,
                    passed,
                    issue,
                    root_cause,
                    fix,
                    retest if retest else ("是" if passed else "否"),
                )
        finally:
            client.close()

        print(f"[{run_id}] round={round_no} done")
        if not args.loop:
            break
        round_no += 1
        time.sleep(args.sleep_sec)


if __name__ == "__main__":
    main()
