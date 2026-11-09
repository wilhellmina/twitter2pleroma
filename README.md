# twitter2pleroma

Twitter のアーカイブを Pleroma に取り込むスクリプト。元の日時・画像・動画・自分宛てのリプライのスレッドを残したまま入れる。

自分のインスタンスに管理者として入れる前提。Pleroma の内部 API を直接呼ぶので、バージョンが変わると動かないことがある。動作を確認したのは Pleroma 2.11.1（Docker）。

## 対応するアーカイブ

- 2019 年ごろの形式（`tweet.js`、`tweet-part*.js`、`tweet_media/`）。`--ytd` に指定する。必須。
- 旧形式（Grailbird、`data/js/tweets/*.js`）。`--grailbird` に指定する。任意で、`--ytd` に無いツイートだけを足す。

2022 年以降の形式（`data/tweets.js`）は `survey.py` でしか読めない。

## ファイル

| ファイル | 内容 |
|---|---|
| `twimport/survey.py` | フォルダ内のアーカイブを一覧する（アカウント、件数、期間） |
| `twimport/prepare.py` | アーカイブを `out/<account>/` に変換する（`tweets.jsonl`、`media.txt`、`profile.json` など） |
| `twimport/import.exs` | Pleroma 内で動かす。取り込み・状況確認・取り消し |
| `twimport/profile.exs` | 表示名・自己紹介・アイコン・ヘッダーを設定する |
| `twimport/verify.exs` | 取り込んだ投稿を API の形で表示する |

## 変換ルール

- RT は除外。`--skip-regex` に一致する本文も除外する（bot の自動投稿など）
- t.co は元の URL に戻す。画像の t.co は消す
- `@name` は `@` の直後にゼロ幅スペースを入れる（リンク・通知にしない）
- 自分へのリプライはスレッドとしてつなぐ
- 他人へのリプライは先頭に `↩ @相手 への返信 <元ツイートの URL>` を付ける
- 自分のツイートの引用は引用投稿にする
- 投稿元クライアントは via 欄に入る
- 公開範囲は既定で未収載

## 使い方

```bash
# 1. 変換
python -I twimport/prepare.py --account alice --ytd <アーカイブ> [--grailbird <旧アーカイブ>] [--alias 旧ID] [--skip-regex '<正規表現>'] --out out

# 2. メディアをまとめる
tar -cf media.tar -C <アーカイブ>/tweet_media -T out/alice/media.txt

# 3. コンテナに置く（取り込み先のユーザーは先に作っておく）
docker exec pleroma mkdir -p /tmp/twimport/alice/media
docker cp twimport/import.exs pleroma:/tmp/twimport/
docker cp out/alice/tweets.jsonl pleroma:/tmp/twimport/alice/
docker exec -i pleroma tar -xf - -C /tmp/twimport/alice/media < media.tar

# 4. 取り込み（バックグラウンドで動く。止まってもまた流せば続きから再開する）
docker exec pleroma /opt/pleroma/bin/pleroma rpc 'Code.eval_string(File.read!("/tmp/twimport/import.exs"), args: %{action: :import, async: true, workers: 4, async_commit: true, nickname: "alice", dir: "/tmp/twimport/alice"})'
docker exec pleroma tail -f /tmp/twimport/alice/progress.log

# 状況確認 / 取り消し
... args: %{action: :status, nickname: "alice"}
... args: %{action: :rollback, nickname: "alice"}

# プロフィール（dir に profile.json と profile/ を置く）
docker exec pleroma /opt/pleroma/bin/pleroma rpc 'Code.eval_string(File.read!("/tmp/twimport/profile.exs"), args: %{nickname: "alice", dir: "/tmp/twimport/alice"})'
```

`import.exs` の引数は、ファイル先頭のコメントに全部書いてある（`only`、`limit`、`then`、`visibility` など）。

## しくみ

通常の投稿処理（`ActivityDraft`）で投稿を組み立て、DB への保存だけを自前で行う。

- `published` を元の日時にする。activity の ID も同じ時刻の FlakeId にする（タイムラインは ID 順なので、過去の位置に並ぶ）
- 連合・通知・ストリーミング・MRF・リンクカードは通らない（通常の経路だと ObjectAgePolicy が古い投稿を未収載にする）
- 取り込んだ投稿は `twimport.map` テーブルに記録する（再開と取り消しに使う）

## 注意

- 取り込む前に DB をバックアップしておく
- HDD だと、コミットごとのディスク同期が `counter_cache` トリガーの行ロックを長く握るので、並列にしても遅い。`async_commit: true` で速くなる（毎秒 37 件 → 500〜800 件）。落ちて消えるのは直近 1 秒弱の分で、再実行すれば入り直す
- 取り込み中に `import.exs` をもう一度読み込んでも、モジュールは定義し直さない（定義し直すと取り込み中のプロセスが落ちるため）
- 止めるには `pleroma rpc 'Process.exit(Process.whereis(:twimport_runner), :kill)'`
- Pleroma-FE はいいね一覧も投稿 ID 順に並べ替える。そのため、取り込んだ古い投稿にいいねすると一覧の一番下に回る

## License

MIT
