#!/usr/bin/env python3
"""Gmail 批量打标签（按会话 thread 处理）。

用法（详见 README.md）:
    python gmail_labeler.py dry-run            # 只读：生成 plan.csv + 统计 + 「其他通知」发件人汇总
    python gmail_labeler.py apply              # 按 plan.csv 正式加标签（只加，不删、不移出收件箱、不标已读）

安全设计:
- 授权范围 gmail.modify；本脚本只调用 labels.list / threads.list / threads.get / threads.modify(addLabelIds)。
- apply 只读取你审核过的 plan.csv，所见即所得；可以直接在 CSV 里手改 labels 列。
- 每成功一个会话就追加写入 applied.log，中断后重跑自动跳过已完成的；threads.modify 只加标签本身也是幂等的。
"""
import argparse
import csv
import json
import random
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime
from email.utils import parseaddr
from pathlib import Path

BASE = Path(__file__).resolve().parent
SCOPES = ["https://www.googleapis.com/auth/gmail.modify"]
CREDENTIALS_FILE = BASE / "credentials.json"
TOKEN_FILE = BASE / "token.json"
CACHE_FILE = BASE / "cache_threads.jsonl"     # dry-run 元数据缓存（断点续跑、重跑更快）
PLAN_FILE = BASE / "plan.csv"
OTHERS_FILE = BASE / "others_by_sender.csv"
APPLIED_LOG = BASE / "applied.log"            # apply 成功记录（threadId \t labels）
FAILED_LOG = BASE / "failed.log"              # apply 失败记录（重跑会再试）

DEFAULT_QUERY = "in:inbox has:nouserlabels after:2026/01/01 before:2026/05/23"

# 只使用这些现有标签，不新建
LABEL_NAMES = ["财务", "网购", "出行", "求职", "广告", "安全", "孩子教育", "医疗预约", "PMI", "其他通知"]
FALLBACK_LABEL = "其他通知"

# 限速：Gmail 每用户 250 配额单位/秒，threads.get / threads.modify 各 10 单位 → 理论上限 25 次/秒，留足余量
MAX_REQUESTS_PER_SEC = 8
MAX_RETRIES = 7

# ===================================================================================
# 分类规则：从上到下，命中第一条即停止。
#   每条规则的 when 是若干条件（OR），每个条件内的字段同时满足（AND）：
#     senders         发件人匹配其一：含 @ 的按完整地址精确匹配；否则按域名匹配（含子域名，如 x.smbc.co.jp）
#     subject         主题包含其中任一关键词（不区分大小写）
#     not_subject     主题不包含其中任何关键词
#     sender_contains 发件人显示名或地址包含其中任一关键词（不区分大小写）
#   also: 命中本规则后，若主题包含关键词，再额外加的标签
# ===================================================================================
SECURITY_SUBJECT = ["認証コード", "认证码", "验证码", "ログイン通知", "パスワード",
                    "Security alert", "sign-in", "SSH key", "パスキー"]
FINANCE_SUBJECT = ["領収書", "receipt", "請求", "お支払", "引落"]
TRAVEL_CALENDAR_SUBJECT = ["Flight", "Train", "航班", "新幹線"]
AMAZON_ORDER_SUBJECT = ["注文", "発送", "出荷", "お届け", "配達", "配送", "返品", "返金",
                        "order", "shipped", "shipment", "delivered", "delivery"]
# tesla.com 中非营销（交易/服务类）邮件的主题关键词 —— 不含这些的才算营销归「广告」
TESLA_TRANSACTIONAL_SUBJECT = ["注文", "納車", "お支払", "領収", "請求", "予約", "アカウント", "ソフトウェア",
                               "order", "delivery", "receipt", "invoice", "payment", "appointment",
                               "service", "account", "software", "registration"]
MEDICAL_SUBJECT = ["診療", "予約確認", "クリニック", "病院"]
# 判断「发件人是诊所」：显示名/地址里含这些词
CLINIC_SENDER_HINTS = ["クリニック", "病院", "医院", "歯科", "診療所", "内科", "外科", "皮膚科", "眼科",
                       "耳鼻", "小児科", "整形", "clinic", "hospital", "dental", "medical", "iryo", "byoin"]
# 显示名看不出来的诊所，把地址或域名补到这里
CLINIC_SENDERS = []
JOB_KEYWORDS = ["recruit", "agent", "転職", "求人", "headhunt", "linkedin"]

RULES = [
    {
        "label": "孩子教育",
        "when": [{"senders": ["kawaijuku.jp", "ecc.co.jp"]}],
        "also": [{"subject": ["学費", "学费", "請求", "入金", "受領"], "labels": ["财务"]}],
    },
    {
        "label": "PMI",
        "when": [{"senders": ["bigpulse.com", "pmi.org"]}],
    },
    {
        "label": "安全",
        "when": [
            {"senders": ["accounts.google.com", "noreply-maps-timeline@google.com", "paypay-corp.co.jp",
                         "point.recruit.co.jp", "myaccount.ring.com", "notifications.ring.com",
                         "facebookmail.com", "notice-os.roborock.com", "shinkin-appbank.jp",
                         "mail-jcn.dnp-cdms.jp"]},
            {"senders": ["mail.anthropic.com"], "subject": ["Security alert"]},
            {"subject": SECURITY_SUBJECT},  # 不管发件人
        ],
    },
    {
        "label": "财务",
        "when": [
            {"senders": ["kddi-fs.com", "smbc.co.jp", "rokinbank.or.jp", "itcenex.com",
                         "invoice+statements@mail.anthropic.com", "mx.starbucks.co.jp"]},
            {"senders": ["nsp.mdj.jp"], "subject": ["ご注文"]},
            {"subject": FINANCE_SUBJECT},  # 不管发件人
        ],
    },
    {
        "label": "出行",
        "when": [
            {"senders": ["concursolutions.com", "jalan.net", "smile-etc.jp", "accesso.co.jp", "airwait.jp"]},
            {"senders": ["calendar-notification@google.com"], "subject": TRAVEL_CALENDAR_SUBJECT},
        ],
    },
    {
        "label": "网购",
        "when": [
            {"senders": ["alibaba.com", "txn-email.playstation.com"]},
            {"senders": ["amazon.co.jp"], "subject": AMAZON_ORDER_SUBJECT},
        ],
    },
    {
        "label": "广告",
        "when": [
            {"senders": ["ent.mb.softbank.jp", "engage.canva.com", "email.claude.com", "infoemail.microsoft.com",
                         "msg.amazonmusic.com", "email.playstation.com", "hakuto-k.jp", "personal.freee.co.jp"]},
            {"senders": ["tesla.com"], "not_subject": TESLA_TRANSACTIONAL_SUBJECT},
        ],
    },
    {
        "label": "医疗预约",
        "when": [
            {"subject": MEDICAL_SUBJECT, "sender_contains": CLINIC_SENDER_HINTS},
            {"subject": MEDICAL_SUBJECT, "senders": CLINIC_SENDERS},
        ],
    },
    {
        "label": "求职",
        "when": [
            {"subject": JOB_KEYWORDS},
            {"sender_contains": JOB_KEYWORDS},
        ],
    },
]


# ----------------------------------------------------------------------------- 分类
def _contains_any(text, keywords):
    return any(k.casefold() in text for k in keywords)


def _sender_in(addr, entries):
    domain = addr.rsplit("@", 1)[-1]
    for e in entries:
        e = e.lower()
        if "@" in e:
            if addr == e:
                return True
        elif domain == e or domain.endswith("." + e):
            return True
    return False


def _match(cond, addr, name, subject):
    if "senders" in cond and not _sender_in(addr, cond["senders"]):
        return False
    if "subject" in cond and not _contains_any(subject, cond["subject"]):
        return False
    if "not_subject" in cond and _contains_any(subject, cond["not_subject"]):
        return False
    if "sender_contains" in cond and not _contains_any(f"{name} {addr}", cond["sender_contains"]):
        return False
    return True


def classify(from_header, subject):
    """返回 (标签列表, 命中规则说明)。"""
    name, addr = parseaddr(from_header or "")
    addr = addr.lower()
    name = name.casefold()
    subj = (subject or "").casefold()
    for rule in RULES:
        for i, cond in enumerate(rule["when"]):
            if _match(cond, addr, name, subj):
                labels = [rule["label"]]
                for extra in rule.get("also", []):
                    if _contains_any(subj, extra["subject"]):
                        labels += [l for l in extra["labels"] if l not in labels]
                return labels, f"{rule['label']}#{i + 1}"
    return [FALLBACK_LABEL], "fallback"


# ----------------------------------------------------------------------------- API 基础
class RateLimiter:
    def __init__(self, per_sec):
        self.interval = 1.0 / per_sec
        self.last = 0.0

    def wait(self):
        delay = self.last + self.interval - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        self.last = time.monotonic()


limiter = RateLimiter(MAX_REQUESTS_PER_SEC)


def _is_retryable(e):
    from googleapiclient.errors import HttpError
    if isinstance(e, HttpError):
        status = e.resp.status
        if status in (429, 500, 502, 503, 504):
            return True
        if status == 403:
            body = (e.content or b"").decode("utf-8", "ignore")
            return any(r in body for r in ("rateLimitExceeded", "userRateLimitExceeded", "backendError"))
        return False
    import httplib2
    from google.auth.exceptions import TransportError
    return isinstance(e, (OSError, TimeoutError, httplib2.HttpLib2Error, TransportError))


def call(make_request):
    """带限速 + 指数退避重试执行一个 API 请求。make_request: 返回 HttpRequest 的无参函数。"""
    for attempt in range(MAX_RETRIES + 1):
        limiter.wait()
        try:
            return make_request().execute()
        except Exception as e:
            if attempt >= MAX_RETRIES or not _is_retryable(e):
                raise
            delay = min(64, 2 ** attempt) + random.uniform(0, 1)
            retry_after = getattr(getattr(e, "resp", None), "get", lambda *_: None)("retry-after")
            if retry_after and str(retry_after).isdigit():
                delay = max(delay, int(retry_after))
            print(f"  ! {type(e).__name__}: {str(e)[:120]} —— {delay:.1f}s 后第 {attempt + 1} 次重试", file=sys.stderr)
            time.sleep(delay)


def get_service():
    from google.auth.exceptions import RefreshError
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build

    creds = None
    if TOKEN_FILE.exists():
        creds = Credentials.from_authorized_user_file(str(TOKEN_FILE), SCOPES)
    if creds and not creds.valid and creds.expired and creds.refresh_token:
        try:
            creds.refresh(Request())
        except RefreshError:
            print("token 已失效（测试模式下 7 天过期属正常），重新登录…")
            creds = None
    if not creds or not creds.valid:
        if not CREDENTIALS_FILE.exists():
            sys.exit(f"找不到 {CREDENTIALS_FILE}，请先按 README 下载 OAuth 桌面应用凭证。")
        flow = InstalledAppFlow.from_client_secrets_file(str(CREDENTIALS_FILE), SCOPES)
        creds = flow.run_local_server(port=0)
    TOKEN_FILE.write_text(creds.to_json(), encoding="utf-8")
    try:
        TOKEN_FILE.chmod(0o600)
    except OSError:
        pass
    return build("gmail", "v1", credentials=creds, cache_discovery=False)


def get_label_ids(svc):
    resp = call(lambda: svc.users().labels().list(userId="me"))
    by_name = {l["name"]: l["id"] for l in resp.get("labels", [])}
    missing = [n for n in LABEL_NAMES if n not in by_name]
    if missing:
        user_labels = sorted(l["name"] for l in resp.get("labels", []) if l.get("type") == "user")
        sys.exit(f"以下标签在 Gmail 中不存在（脚本不会新建）：{missing}\n现有用户标签：{user_labels}")
    return {n: by_name[n] for n in LABEL_NAMES}


# ----------------------------------------------------------------------------- dry-run
def list_threads(svc, query, limit):
    threads, token = [], None
    while True:
        resp = call(lambda: svc.users().threads().list(userId="me", q=query, maxResults=500, pageToken=token))
        threads += resp.get("threads", [])
        print(f"  已列出 {len(threads)} 个会话…")
        token = resp.get("nextPageToken")
        if not token or (limit and len(threads) >= limit):
            break
    return threads[:limit] if limit else threads


def load_cache():
    cache = {}
    if CACHE_FILE.exists():
        with CACHE_FILE.open(encoding="utf-8") as f:
            for line in f:
                try:
                    d = json.loads(line)
                    cache[d["id"]] = d
                except (json.JSONDecodeError, KeyError):
                    pass  # 中断时可能写了半行，忽略
    return cache


def fetch_meta(svc, tid):
    t = call(lambda: svc.users().threads().get(
        userId="me", id=tid, format="metadata", metadataHeaders=["From", "Subject", "Date"]))
    msgs = t.get("messages", [])
    # 以会话中第一封「不是自己发出」的邮件为准；全是自己发的就取第一封
    pick = next((m for m in msgs if "SENT" not in m.get("labelIds", [])), msgs[0] if msgs else {})
    headers = {h["name"].lower(): h["value"] for h in pick.get("payload", {}).get("headers", [])}
    ts = int(pick.get("internalDate", "0")) / 1000
    return {
        "id": tid,
        "historyId": t.get("historyId"),
        "date": datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M") if ts else "",
        "from": headers.get("from", ""),
        "subject": headers.get("subject", ""),
        "messages": len(msgs),
    }


def dry_run(args):
    svc = get_service()
    get_label_ids(svc)  # 提前确认标签都存在
    print(f"查询：{args.query}")
    threads = list_threads(svc, args.query, args.limit)
    print(f"共 {len(threads)} 个会话，开始读取发件人/主题（只读）…")

    cache = load_cache()
    rows = []
    with CACHE_FILE.open("a", encoding="utf-8") as cf:
        for i, t in enumerate(threads, 1):
            meta = cache.get(t["id"])
            if not meta or meta.get("historyId") != t.get("historyId"):
                meta = fetch_meta(svc, t["id"])
                cf.write(json.dumps(meta, ensure_ascii=False) + "\n")
                cf.flush()
            labels, rule = classify(meta["from"], meta["subject"])
            rows.append({**meta, "labels": ";".join(labels), "rule": rule})
            if i % 100 == 0:
                print(f"  {i}/{len(threads)}")

    with Path(args.out).open("w", encoding="utf-8-sig", newline="") as f:  # utf-8-sig: Excel 打开不乱码
        w = csv.writer(f)
        w.writerow(["threadId", "date", "from", "subject", "labels", "rule", "messages", "link"])
        for r in rows:
            w.writerow([r["id"], r["date"], r["from"], r["subject"], r["labels"], r["rule"], r["messages"],
                        f"https://mail.google.com/mail/u/0/#all/{r['id']}"])

    counts = Counter(l for r in rows for l in r["labels"].split(";"))
    print(f"\n计划已写入 {args.out}（未修改任何邮件）\n\n== 各标签会话数 ==")
    for name in LABEL_NAMES:
        print(f"  {name:<6} {counts.get(name, 0):>5}")
    print(f"  {'合计会话':<6} {len(rows):>5}（「孩子教育+财务」双标签的会话两边都计数）")

    report_others(rows)


def report_others(rows):
    groups = defaultdict(list)
    for r in rows:
        if r["rule"] == "fallback":
            name, addr = parseaddr(r["from"])
            groups[addr.lower() or r["from"]].append((name, r["subject"]))
    ordered = sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0]))
    with OTHERS_FILE.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["count", "address", "domain", "name", "sample_subjects"])
        for addr, items in ordered:
            samples = " | ".join(dict.fromkeys(s for _, s in items))
            w.writerow([len(items), addr, addr.rsplit("@", 1)[-1], items[0][0], samples[:500]])

    total = sum(len(v) for v in groups.values())
    print(f"\n== 「其他通知」共 {total} 个会话、{len(groups)} 个发件人（完整列表：{OTHERS_FILE.name}）==")
    for addr, items in ordered[:60]:
        print(f"  {len(items):>4}  {addr:<45} {items[0][1][:50]}")
    if len(ordered) > 60:
        print(f"  …其余 {len(ordered) - 60} 个发件人见 CSV")


# ----------------------------------------------------------------------------- apply
def read_done():
    done = set()
    if APPLIED_LOG.exists():
        for line in APPLIED_LOG.read_text(encoding="utf-8").splitlines():
            if line.strip():
                done.add(line.split("\t", 1)[0])
    return done


def apply(args):
    plan = Path(args.plan)
    if not plan.exists():
        sys.exit(f"找不到 {plan}，请先运行 dry-run。")
    with plan.open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))

    svc = get_service()
    label_ids = get_label_ids(svc)
    bad = {l for r in rows for l in r["labels"].split(";") if l and l not in label_ids}
    if bad:
        sys.exit(f"plan 中有不在允许列表内的标签：{bad}（脚本不会新建标签）")

    done = read_done()
    todo = [r for r in rows if r["threadId"] not in done and r["labels"]]
    print(f"plan 共 {len(rows)} 个会话，已完成 {len(rows) - len(todo)}，本次待处理 {len(todo)}")
    if not todo:
        return
    print("操作：threads.modify 只添加标签（不删除标签、不移出收件箱、不标记已读）")
    if not args.yes and input("确认执行？输入 yes 继续：").strip().lower() != "yes":
        print("已取消。")
        return

    ok = fail = 0
    with APPLIED_LOG.open("a", encoding="utf-8") as alog, FAILED_LOG.open("a", encoding="utf-8") as flog:
        for i, r in enumerate(todo, 1):
            tid = r["threadId"]
            ids = [label_ids[l] for l in r["labels"].split(";") if l]
            try:
                call(lambda: svc.users().threads().modify(userId="me", id=tid, body={"addLabelIds": ids}))
            except Exception as e:
                fail += 1
                flog.write(f"{datetime.now():%Y-%m-%d %H:%M:%S}\t{tid}\t{r['labels']}\t{type(e).__name__}: {e}\n")
                flog.flush()
                print(f"  × {tid} 失败：{str(e)[:120]}", file=sys.stderr)
                continue
            ok += 1
            alog.write(f"{tid}\t{r['labels']}\n")
            alog.flush()
            if i % 50 == 0:
                print(f"  {i}/{len(todo)}  成功 {ok}  失败 {fail}")
    print(f"\n完成：成功 {ok}，失败 {fail}。" + (f"失败明细见 {FAILED_LOG.name}，直接重跑 apply 会重试。" if fail else ""))


# -----------------------------------------------------------------------------
def main():
    p = argparse.ArgumentParser(description="Gmail 按会话批量打标签")
    sub = p.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("dry-run", help="只读，生成 plan.csv 和统计")
    d.add_argument("--query", default=DEFAULT_QUERY)
    d.add_argument("--limit", type=int, default=0, help="只处理前 N 个会话（试跑用）")
    d.add_argument("--out", default=str(PLAN_FILE))
    a = sub.add_parser("apply", help="按 plan.csv 正式加标签")
    a.add_argument("--plan", default=str(PLAN_FILE))
    a.add_argument("--yes", action="store_true", help="跳过确认提示")
    args = p.parse_args()
    dry_run(args) if args.cmd == "dry-run" else apply(args)


if __name__ == "__main__":
    main()
