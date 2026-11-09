"""Survey Twitter archives in a directory: account, tweet counts, date ranges."""
import json, os, sys, glob
from datetime import datetime
from email.utils import parsedate_to_datetime

def load_js(path):
    with open(path, encoding="utf-8") as f:
        s = f.read()
    return json.loads(s[s.index("=") + 1:].strip().rstrip(";"))

def parse_date(s):
    for fmt in ("%a %b %d %H:%M:%S %z %Y", "%Y-%m-%d %H:%M:%S %z"):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            pass
    return parsedate_to_datetime(s)

def summarize(name, acct, tweets, media_dir):
    n = len(tweets)
    rts = sum(1 for t in tweets if t.get("retweeted_status") or t.get("full_text", t.get("text", "")).startswith("RT @"))
    replies = sum(1 for t in tweets if t.get("in_reply_to_status_id_str") or t.get("in_reply_to_status_id"))
    self_replies = sum(1 for t in tweets if (t.get("in_reply_to_user_id_str") or str(t.get("in_reply_to_user_id", ""))) == str(acct.get("id")))
    with_media = sum(1 for t in tweets if (t.get("extended_entities") or t.get("entities", {})).get("media"))
    dates = [parse_date(t["created_at"]) for t in tweets if t.get("created_at")]
    nmedia = len(os.listdir(media_dir)) if media_dir and os.path.isdir(media_dir) else 0
    print(f"=== {name}")
    print(f"  account: @{acct.get('screen_name')} id={acct.get('id')}")
    print(f"  tweets={n} RT={rts} replies={replies} (self={self_replies}) with_media={with_media} media_files={nmedia}")
    if dates:
        print(f"  range: {min(dates).date()} .. {max(dates).date()}")

def main(root):
    for d in sorted(os.listdir(root)):
        p = os.path.join(root, d)
        if not os.path.isdir(p):
            continue
        try:
            if os.path.exists(os.path.join(p, "data", "js", "user_details.js")):
                ud = load_js(os.path.join(p, "data", "js", "user_details.js"))
                tweets = []
                for f in sorted(glob.glob(os.path.join(p, "data", "js", "tweets", "*.js"))):
                    tweets += load_js(f)
                summarize(d + " [grailbird]", {"screen_name": ud.get("screen_name"), "id": ud.get("id")}, tweets, None)
            else:
                base = os.path.join(p, "data") if os.path.isdir(os.path.join(p, "data")) else p
                acc = load_js(os.path.join(base, "account.js"))[0]["account"]
                acct = {"screen_name": acc.get("username"), "id": acc.get("accountId")}
                tweets = []
                files = sorted(glob.glob(os.path.join(base, "tweets*.js")) + glob.glob(os.path.join(base, "tweet.js")) + glob.glob(os.path.join(base, "tweet-part*.js")))
                for f in files:
                    for item in load_js(f):
                        tweets.append(item.get("tweet", item))
                md = os.path.join(base, "tweets_media") if os.path.isdir(os.path.join(base, "tweets_media")) else os.path.join(base, "tweet_media")
                summarize(d + f" [ytd: {', '.join(os.path.basename(f) for f in files)}]", acct, tweets, md)
        except Exception as e:
            print(f"=== {d}: ERROR {type(e).__name__}: {e}")

if __name__ == "__main__":
    main(sys.argv[1])
