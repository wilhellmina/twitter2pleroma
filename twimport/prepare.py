"""Twitter アーカイブ → Pleroma 取り込み用データ (JSONL + メディア一覧) に変換する。

使い方:
  python -I prepare.py --account <screen_name> --ytd <YTD形式アーカイブ> [--grailbird <旧形式アーカイブ> ...] --out <出力先>

出力 (<出力先>/<account>/):
  tweets.jsonl   1行1投稿。古い順。import.exs が読む
  media.txt      必要なメディアファイルの一覧 (tweet_media からの相対パス)
  stats.json     件数の内訳
  preview.txt    変換結果の見本 (目視チェック用)
  profile.json   表示名・自己紹介・補足情報。profile.exs が読む
  profile/       アイコン・ヘッダー画像
"""
import argparse, glob, html, json, os, random, re, shutil, sys
from collections import Counter
from datetime import datetime, timezone

TWEPOCH_MS = 1288834974657
ZWSP = "\u200b"
SELF_STATUS_RE = re.compile(r"https?://(?:mobile\.|www\.)?(?:twitter|x)\.com/(\w+)/status(?:es)?/(\d+)\S*", re.I)
LEADING_MENTIONS_RE = re.compile(r"^((?:[.]?@\w+[\s\u3000]+)+)")
MIME = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".gif": "image/gif", ".mp4": "video/mp4"}
ALIASES = set()
BAD_LANGS = {"und", "qme", "qht", "qst", "zxx", "qam", "qct", "qtm", "art", "in", "iw"}


def load_js(path):
    with open(path, encoding="utf-8") as f:
        s = f.read()
    return json.loads(s[s.index("=") + 1:].strip().rstrip(";"))


def load_ytd(d):
    tweets = {}
    for f in sorted(glob.glob(os.path.join(d, "tweet.js")) + glob.glob(os.path.join(d, "tweet-part*.js"))):
        for item in load_js(f):
            t = item.get("tweet", item)
            tweets[t["id_str"]] = t
    acc = load_js(os.path.join(d, "account.js"))[0]["account"]
    return tweets, acc


def load_grailbird(d):
    tweets = {}
    for f in sorted(glob.glob(os.path.join(d, "data", "js", "tweets", "*.js"))):
        for t in load_js(f):
            tweets[t["id_str"]] = t
    return tweets


def snowflake_ms(tid):
    return (int(tid) >> 22) + TWEPOCH_MS


def parse_created(s):
    for fmt in ("%a %b %d %H:%M:%S %z %Y", "%Y-%m-%d %H:%M:%S %z"):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            pass
    raise ValueError(s)


URL_RE = re.compile(r"https?://\S+")


def neutralize(text):
    """@メンションをリンク・通知にならない文字列にする (@ の直後にゼロ幅スペース)。URL の中は触らない。"""
    out, pos = [], 0
    for m in URL_RE.finditer(text):
        out.append(re.sub(r"@(?=[A-Za-z0-9_])", "@" + ZWSP, text[pos:m.start()]))
        out.append(m.group(0))
        pos = m.end()
    out.append(re.sub(r"@(?=[A-Za-z0-9_])", "@" + ZWSP, text[pos:]))
    return "".join(out)


def parse_source(src):
    m = re.match(r'<a href="([^"]*)"[^>]*>(.*)</a>', src or "")
    if m:
        return {"type": "Application", "name": html.unescape(m.group(2)), "url": m.group(1)}
    return {"type": "Application", "name": html.unescape(re.sub(r"<[^>]+>", "", src or "")) or "Twitter", "url": None}


def pick_media(t, files_by_tweet, media_dir):
    """ツイートのメディアを tweet_media のファイルに対応づける。戻り値: (使うファイル一覧, 見つからなかった数)"""
    ents = (t.get("extended_entities") or {}).get("media") or (t.get("entities") or {}).get("media") or []
    if not ents:
        return [], 0
    avail = files_by_tweet.get(t["id_str"], [])
    picked, missing = [], 0
    for m in ents:
        if m.get("type") in ("video", "animated_gif"):
            variants = [v for v in (m.get("video_info") or {}).get("variants", []) if v.get("content_type") == "video/mp4"]
            variants.sort(key=lambda v: int(v.get("bitrate", 0)), reverse=True)
            cand = [f"{t['id_str']}-{os.path.basename(v['url'].split('?')[0])}" for v in variants]
            hit = next((c for c in cand if c in avail), None)
            if not hit:  # 名前で引けなければ一番大きい mp4
                mp4s = [f for f in avail if f.endswith(".mp4") and f not in picked]
                hit = max(mp4s, key=lambda f: os.path.getsize(os.path.join(media_dir, f)), default=None)
        else:
            base = os.path.basename((m.get("media_url_https") or m.get("media_url") or "").split("?")[0])
            hit = f"{t['id_str']}-{base}" if f"{t['id_str']}-{base}" in avail else None
        if hit and hit not in picked:
            picked.append(hit)
        elif not hit:
            missing += 1
    return picked, missing


def convert(t, me, me_id, imported_ids, files_by_tweet, media_dir, stats):
    tid = t["id_str"]
    text = t.get("full_text") or t.get("text") or ""
    ents = t.get("entities") or {}

    # t.co を元の URL に戻す / 画像の t.co は消す
    for u in ents.get("urls") or []:
        if u.get("url") and u.get("expanded_url"):
            text = text.replace(u["url"], u["expanded_url"])
    for m in ((t.get("extended_entities") or {}).get("media") or []) + (ents.get("media") or []):
        if m.get("url"):
            text = text.replace(m["url"], "")
    text = html.unescape(text)

    rec = {"tweet_id": tid}
    reply_to = t.get("in_reply_to_status_id_str") or (str(t["in_reply_to_status_id"]) if t.get("in_reply_to_status_id") else None)
    reply_user = t.get("in_reply_to_user_id_str") or (str(t["in_reply_to_user_id"]) if t.get("in_reply_to_user_id") else None)
    reply_name = t.get("in_reply_to_screen_name")

    # 自分自身へのメンション (改名前の名前も含む) は ID で判定する
    self_names = {me.lower()} | ALIASES | {u["screen_name"].lower() for u in ents.get("user_mentions") or []
                                 if (u.get("id_str") or str(u.get("id"))) == me_id and u.get("screen_name")}

    header = ""
    if reply_to:
        m = LEADING_MENTIONS_RE.match(text)
        lead = m.group(1) if m else ""
        names = re.findall(r"@(\w+)", lead)
        body = text[len(lead):]
        if reply_user == me_id and reply_to in imported_ids:
            # 自分へのリプ → スレッドとしてつなぐ。先頭の自分宛てメンションだけ外す
            others = [n for n in names if n.lower() not in self_names]
            text = (" ".join("@" + n for n in others) + " " + body).strip() if others else body
            rec["in_reply_to_tweet_id"] = reply_to
            stats["self_reply_threaded"] += 1
        else:
            names = [n for n in names if n.lower() not in self_names] or names
            if not names and reply_name:
                names = [reply_name]
            who = " ".join("@" + n for n in names) if names else "ツイート"
            url = f"https://twitter.com/{reply_name or 'i/web'}/status/{reply_to}"
            header = f"↩ {who} への返信 {url}\n\n"
            text = body
            stats["reply_other" if reply_user != me_id else "self_reply_orphan"] += 1

    # 自分のツイートの引用 → Pleroma の引用投稿にする (本文が空になるなら URL は残す)
    for m in SELF_STATUS_RE.finditer(text):
        qid = m.group(2)
        if qid in imported_ids and int(qid) < int(tid) and "quote_tweet_id" not in rec:
            rec["quote_tweet_id"] = qid
            rest = text.replace(m.group(0), "")
            if rest.strip() or header:
                text = rest
            stats["self_quote"] += 1

    text = neutralize(header + text).strip()
    text = re.sub(r"[ \t\u3000]+$", "", text, flags=re.M)

    files, missing = pick_media(t, files_by_tweet, media_dir)
    stats["media_files"] += len(files)
    stats["media_missing"] += missing
    if missing:
        stats["tweets_with_missing_media"] += 1
    if not text and not files:
        text = f"https://twitter.com/{me}/status/{tid}"
        stats["empty_text_fallback"] += 1

    ms = snowflake_ms(tid)
    created = parse_created(t["created_at"])
    if abs(created.timestamp() * 1000 - ms) > 2000:  # Snowflake でない古い ID 対策
        ms = int(created.timestamp() * 1000)
        stats["date_from_created_at"] += 1
    rec["published"] = datetime.fromtimestamp(ms / 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{ms % 1000:03d}Z"
    rec["ms"] = ms
    rec["status"] = text
    rec["media"] = [{"file": f, "mime": MIME.get(os.path.splitext(f)[1].lower(), "application/octet-stream")} for f in files]
    rec["sensitive"] = bool(t.get("possibly_sensitive"))
    lang = t.get("lang")
    if lang and lang not in BAD_LANGS and re.fullmatch(r"[a-z]{2}", lang):
        rec["language"] = lang
    rec["generator"] = parse_source(t.get("source"))
    return rec


def old_screen_names(ytd):
    p = os.path.join(ytd, "screen-name-change.js")
    if not os.path.exists(p):
        return []
    names = []
    for item in load_js(p):
        c = item["screenNameChange"]["screenNameChange"]
        for n in (c.get("changedFrom"), c.get("changedTo")):
            if n and n not in names:
                names.append(n)
    return names


def resolve_tco(url):
    """t.co の短縮 URL を 1 回だけたどって元の URL にする (失敗したらそのまま)。"""
    if not url.startswith("https://t.co/"):
        return url
    import urllib.request

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None

    try:
        urllib.request.build_opener(NoRedirect).open(urllib.request.Request(url, method="HEAD"), timeout=10)
    except urllib.error.HTTPError as e:
        return e.headers.get("Location") or url
    except Exception:
        pass
    return url


def write_profile(ytd, out, acc):
    """表示名・自己紹介・アイコン・ヘッダー・補足情報を profile.json と profile/ に書き出す (profile.exs が読む)。"""
    prof = load_js(os.path.join(ytd, "profile.js"))[0]["profile"]
    desc = prof.get("description") or {}
    me = acc["username"]
    fields = [{"name": "Twitter", "value": f"https://twitter.com/{me}"}]
    if desc.get("website"):
        fields.append({"name": "Web", "value": resolve_tco(desc["website"])})
    if desc.get("location"):
        fields.append({"name": "場所", "value": desc["location"]})
    fields.append({"name": "Twitter 開始", "value": acc["createdAt"][:10]})
    olds = [n for n in old_screen_names(ytd) if n.lower() != me.lower()]
    if olds:
        fields.append({"name": "旧ID", "value": " / ".join(olds)})

    pdir = os.path.join(out, "profile")
    os.makedirs(pdir, exist_ok=True)
    media = {}
    for key, url_key, name in (("avatar", "avatarMediaUrl", "avatar"), ("banner", "headerMediaUrl", "header")):
        url = prof.get(url_key) or ""
        if not url or "default_profile" in url:
            continue  # Twitter の初期アイコンは持ってこない
        src = os.path.join(ytd, "profile_media", f"{acc['accountId']}-{os.path.basename(url)}")
        if not os.path.exists(src):
            continue
        with open(src, "rb") as f:
            head = f.read(8)
        ext, mime = (".png", "image/png") if head.startswith(b"\x89PNG") else (".gif", "image/gif") if head.startswith(b"GIF8") else (".jpg", "image/jpeg")
        shutil.copyfile(src, os.path.join(pdir, name + ext))
        media[key] = {"file": f"profile/{name}{ext}", "mime": mime}

    data = {"name": acc.get("accountDisplayName") or me, "bio": neutralize(html.unescape(desc.get("bio") or "")),
            "fields": fields, **media}
    with open(os.path.join(out, "profile.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--account", required=True)
    ap.add_argument("--ytd", required=True)
    ap.add_argument("--grailbird", action="append", default=[])
    ap.add_argument("--out", required=True)
    ap.add_argument("--alias", action="append", default=[], help="自分の旧スクリーンネーム (screen-name-change.js の分は自動で入る)")
    ap.add_argument("--preview", type=int, default=60)
    ap.add_argument("--profile-only", action="store_true", help="プロフィールだけ書き出す")
    ap.add_argument("--skip-regex", action="append", default=[], help="本文がこの正規表現に一致するツイートを除外 (bot の自動投稿など)")
    a = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    ALIASES.update(n.lower() for n in a.alias)
    ALIASES.update(n.lower() for n in old_screen_names(a.ytd))
    skip_res = [re.compile(r) for r in a.skip_regex]

    tweets, acc = load_ytd(a.ytd)
    me, me_id = acc["username"], acc["accountId"]
    assert me.lower() == a.account.lower(), f"アーカイブのアカウントが違う: {me}"
    out = os.path.join(a.out, a.account)
    os.makedirs(out, exist_ok=True)
    profile = write_profile(a.ytd, out, acc)
    if a.profile_only:
        print(json.dumps(profile, ensure_ascii=False, indent=1))
        return
    stats = Counter(ytd=len(tweets))
    for g in a.grailbird:
        for tid, t in load_grailbird(g).items():
            if tid not in tweets:
                tweets[tid] = t
                stats["grailbird_only"] += 1
                if (t.get("entities") or {}).get("media"):
                    stats["grailbird_only_with_media"] += 1

    media_dir = os.path.join(a.ytd, "tweet_media")
    files_by_tweet = {}
    for f in os.listdir(media_dir):
        files_by_tweet.setdefault(f.split("-", 1)[0], []).append(f)

    keep = []
    for t in tweets.values():
        text = t.get("full_text") or t.get("text") or ""
        if t.get("retweeted_status") or text.startswith("RT @"):
            stats["skip_rt"] += 1
        elif any(r.search(text) for r in skip_res):
            stats["skip_regex"] += 1
        else:
            keep.append(t)
    keep.sort(key=lambda t: int(t["id_str"]))
    imported_ids = {t["id_str"] for t in keep}

    recs = [convert(t, me, me_id, imported_ids, files_by_tweet, media_dir, stats) for t in keep]
    stats["import"] = len(recs)
    stats["longest_status"] = max(len(r["status"]) for r in recs)

    with open(os.path.join(out, "tweets.jsonl"), "w", encoding="utf-8", newline="\n") as f:
        for r in recs:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    with open(os.path.join(out, "media.txt"), "w", encoding="utf-8", newline="\n") as f:
        for r in recs:
            for m in r["media"]:
                f.write(m["file"] + "\n")
    with open(os.path.join(out, "stats.json"), "w", encoding="utf-8") as f:
        json.dump(dict(stats), f, ensure_ascii=False, indent=1)

    random.seed(42)
    sample = random.sample(recs, min(a.preview, len(recs)))
    sample += [r for r in recs if "quote_tweet_id" in r][:3] + [r for r in recs if "in_reply_to_tweet_id" in r][:3]
    sample += [r for r in recs if r["status"].startswith("↩")][:3] + [r for r in recs if any(m["mime"] == "video/mp4" for m in r["media"])][:2]
    with open(os.path.join(out, "preview.txt"), "w", encoding="utf-8", newline="\n") as f:
        for r in sorted(sample, key=lambda r: r["ms"]):
            extra = {k: r[k] for k in ("in_reply_to_tweet_id", "quote_tweet_id") if k in r}
            f.write(f"--- {r['tweet_id']} {r['published']} via {r['generator']['name']} media={[m['file'] for m in r['media']]} {extra}\n")
            f.write(r["status"].replace(ZWSP, "") + "\n")
    print(json.dumps(dict(stats), ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
