# Twitter アーカイブ (prepare.py の出力) を Pleroma に取り込む。稼働中のノードの中で評価する:
#
#   pleroma rpc 'Code.eval_string(File.read!("/tmp/twimport/import.exs"), args: %{...})'
#
# args:
#   action:   :import | :status | :rollback
#   nickname: 取り込み先のローカルユーザー
#   dir:      tweets.jsonl と media/ があるディレクトリ (コンテナ内のパス)
#   only:     このツイートIDだけ取り込む (依存する親ツイート・引用元も自動で含める)。省略で全件
#   limit:    先頭から N 件だけ
#   async:    true ならバックグラウンドで走らせてすぐ戻る (進捗は dir/progress.log)
#   then:     async のとき、続けて流す別アカウントの args のリスト
#   workers:  並列数 (省略で 1)。リプ・引用でつながる投稿は同じワーカーで古い順に処理する
#             DB の接続プールは 10 本なので、Web 側の分を残して 4 くらいまで
#   async_commit: true でコミット時のディスク同期を待たない (HDD だと効く)
#   visibility: "public" | "unlisted" | "private" (省略で "unlisted")
#
# 通常の投稿経路 (CommonAPI.post) との違い:
#   - published を元ツイートの日時にし、activity の ID も同じ時刻の FlakeId にする
#     (タイムラインは ID 順なので、過去の位置に並ぶ)
#   - ストリーミング・通知・連合・MRF (ObjectAgePolicy が古い投稿を未収載化するため)・リンクカード取得をしない
#   - 取り込んだものは twimport.map に記録 (再開・取り消し用)

# 取り込みがバックグラウンドで動いている間はモジュールを定義し直さない。
# (Erlang は2回目の再定義で古いコードを動かしているプロセスを強制終了するため、status を見ただけで取り込みが止まってしまう)
unless Process.whereis(:twimport_runner) && Code.ensure_loaded?(TwImport) do
  defmodule TwImport do
    import Bitwise
    import Ecto.Query
    alias Pleroma.{Activity, Object, Repo, User}
    alias Pleroma.Web.ActivityPub.{ActivityPub, Utils}
    alias Pleroma.Web.CommonAPI.ActivityDraft

    def setup do
      Repo.query!("CREATE SCHEMA IF NOT EXISTS twimport")

      Repo.query!("""
      CREATE TABLE IF NOT EXISTS twimport.map (
        tweet_id bigint PRIMARY KEY,
        nickname text NOT NULL,
        activity_id uuid NOT NULL UNIQUE,
        object_ap_id text NOT NULL,
        media_object_ids bigint[] NOT NULL DEFAULT '{}',
        inserted_at timestamptz NOT NULL DEFAULT now()
      )
      """)
    end

    # 元ツイートの時刻 (ms) を先頭 64bit に持つ FlakeId。下位はツイート ID から作るので衝突しない
    def flake(tweet_id, ms), do: <<ms::64, band(tweet_id, 0xFFFFFFFFFFFF)::48, 0::16>>

    def done_map(nickname) do
      Repo.query!("SELECT tweet_id, activity_id FROM twimport.map WHERE nickname = $1", [nickname]).rows
      |> Map.new(fn [tid, aid] -> {tid, FlakeId.to_string(aid)} end)
    end

    def read_records(dir) do
      Path.join(dir, "tweets.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
    end

    def pick(records, args) do
      records =
        case args[:only] do
          nil ->
            records

          ids ->
            by_id = Map.new(records, &{&1["tweet_id"], &1})

            want =
              Enum.reduce(List.wrap(ids), MapSet.new(), fn id, acc -> with_deps(to_string(id), by_id, acc) end)

            Enum.filter(records, &MapSet.member?(want, &1["tweet_id"]))
        end

      if args[:limit], do: Enum.take(records, args[:limit]), else: records
    end

    defp with_deps(nil, _, acc), do: acc

    defp with_deps(id, by_id, acc) do
      case by_id[id] do
        nil ->
          acc

        rec ->
          if MapSet.member?(acc, id) do
            acc
          else
            acc = MapSet.put(acc, id)
            acc = with_deps(rec["in_reply_to_tweet_id"], by_id, acc)
            with_deps(rec["quote_tweet_id"], by_id, acc)
          end
      end
    end

    def log(dir, msg) do
      line = "#{DateTime.utc_now() |> DateTime.truncate(:second)} #{msg}\n"
      File.write!(Path.join(dir, "progress.log"), line, [:append])
    end

    def run(args) do
      Logger.put_process_level(self(), :info)
      setup()
      %User{local: true} = user = User.get_cached_by_nickname(args.nickname)
      dir = args.dir
      records = read_records(dir) |> pick(args)
      done = done_map(user.nickname)
      todo = Enum.reject(records, &Map.has_key?(done, String.to_integer(&1["tweet_id"])))
      workers = args[:workers] || 1
      total = length(todo)
      log(dir, "start #{user.nickname}: #{length(records)} selected, #{total} to import, workers=#{workers}")

      # ok / err の件数をワーカー間で共有する
      ctx = %{user: user, dir: dir, args: args, total: total, counter: :counters.new(2, [:atomics]),
              t0: System.monotonic_time(:millisecond)}

      todo
      |> partition(workers)
      |> Task.async_stream(&work(&1, done, ctx), max_concurrency: workers, timeout: :infinity, ordered: false)
      |> Stream.run()

      ok = :counters.get(ctx.counter, 1)
      err = :counters.get(ctx.counter, 2)
      finish(user)
      log(dir, "finished #{user.nickname}: ok=#{ok} err=#{err} total_mapped=#{map_size(done_map(user.nickname))}")
      {:ok, ok, err}
    end

    # 1ワーカー分を古い順に処理する。リプ先・引用元は同じワーカーにいるので先に入っている
    defp work(part, done, ctx) do
      Logger.put_process_level(self(), :info)

      Enum.reduce(part, done, fn rec, done ->
        result =
          try do
            import_one(rec, ctx.user, ctx.dir, done, ctx.args)
          rescue
            e -> {:error, Exception.format(:error, e, __STACKTRACE__) |> String.slice(0, 2000)}
          end

        done =
          case result do
            {:ok, tid, aid} ->
              :counters.add(ctx.counter, 1, 1)
              Map.put(done, tid, aid)

            {:error, reason} ->
              :counters.add(ctx.counter, 2, 1)
              File.write!(Path.join(ctx.dir, "errors.log"), "#{rec["tweet_id"]}\t#{inspect(reason)}\n", [:append])
              done
          end

        ok = :counters.get(ctx.counter, 1)
        err = :counters.get(ctx.counter, 2)

        if rem(ok + err, 500) == 0 do
          rate = (ok + err) * 1000 / max(System.monotonic_time(:millisecond) - ctx.t0, 1)
          log(ctx.dir, "#{ok + err}/#{ctx.total} ok=#{ok} err=#{err} #{Float.round(rate, 1)}/s")
        end

        done
      end)
    end

    # リプ・引用でつながる投稿どうしを同じグループにまとめ (union-find)、グループ単位でワーカーに振り分ける
    def partition(records, 1), do: [records]

    def partition(records, n) do
      ids = MapSet.new(records, & &1["tweet_id"])

      uf =
        Enum.reduce(records, %{}, fn r, uf ->
          [r["in_reply_to_tweet_id"], r["quote_tweet_id"]]
          |> Enum.filter(&(&1 && MapSet.member?(ids, &1)))
          |> Enum.reduce(uf, &union(&2, r["tweet_id"], &1))
        end)

      {keyed, _} =
        Enum.map_reduce(records, uf, fn r, uf ->
          {root, uf} = find(uf, r["tweet_id"])
          {{:erlang.phash2(root, n), r}, uf}
        end)

      # group_by は元の順 (古い順) を保つ
      keyed |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)) |> Map.values()
    end

    defp find(uf, x) do
      case Map.get(uf, x, x) do
        ^x ->
          {x, uf}

        p ->
          {root, uf} = find(uf, p)
          {root, Map.put(uf, x, root)}
      end
    end

    defp union(uf, a, b) do
      {ra, uf} = find(uf, a)
      {rb, uf} = find(uf, b)
      if ra == rb, do: uf, else: Map.put(uf, ra, rb)
    end

    defp lookup(_done, nil), do: nil
    defp lookup(done, tid), do: Map.get(done, String.to_integer(tid))

    defp maybe_put(map, _k, nil), do: map
    defp maybe_put(map, k, v), do: Map.put(map, k, v)

    def import_one(rec, user, dir, done, args \\ %{}) do
      tid = String.to_integer(rec["tweet_id"])
      flake_bin = flake(tid, rec["ms"])
      flake_str = FlakeId.to_string(flake_bin)
      published = rec["published"]

      Repo.transaction(fn ->
        # コミットのたびにディスク同期を待たない (落ちたら直近の数件が消えるだけで、再実行で入り直す)
        if args[:async_commit], do: Repo.query!("SET LOCAL synchronous_commit TO OFF")

        media_ids =
          for m <- rec["media"] do
            upload = %Plug.Upload{path: Path.join([dir, "media", m["file"]]), filename: m["file"], content_type: m["mime"]}
            {:ok, obj} = ActivityPub.upload(upload, actor: user.ap_id)
            obj.id
          end

        params =
          %{
            status: rec["status"],
            visibility: args[:visibility] || "unlisted",
            content_type: "text/plain",
            sensitive: rec["sensitive"],
            media_ids: Enum.map(media_ids, &to_string/1),
            generator: rec["generator"]
          }
          |> maybe_put(:language, rec["language"])
          |> maybe_put(:in_reply_to_status_id, lookup(done, rec["in_reply_to_tweet_id"]))
          |> maybe_put(:quote_id, lookup(done, rec["quote_tweet_id"]))

        draft =
          case ActivityDraft.create(user, params) do
            {:ok, draft} -> draft
            {:error, reason} -> Repo.rollback({:draft, reason})
          end

        %{to: to, actor: actor, context: context, object: object, additional: additional} = draft.changes
        object = Map.put(object, "published", published)

        map =
          %{to: to, actor: actor, published: published, context: context, object: object}
          |> Utils.make_create_data(additional)
          |> Utils.lazy_put_activity_defaults(false)

        recipients =
          Enum.uniq(List.wrap(map["to"]) ++ List.wrap(map["cc"]) ++ List.wrap(map["bcc"]) ++ [map["actor"]])

        {:ok, map, object} = Utils.insert_full_object(map)

        {:ok, _activity} =
          Repo.insert(%Activity{id: flake_str, data: map, local: true, actor: map["actor"], recipients: recipients})

        if object.data["inReplyTo"], do: Object.increase_replies_count(object.data["inReplyTo"])
        if object.data["quoteUrl"], do: Object.increase_quotes_count(object.data["quoteUrl"])

        Repo.query!(
          "INSERT INTO twimport.map (tweet_id, nickname, activity_id, object_ap_id, media_object_ids) VALUES ($1, $2, $3, $4, $5)",
          [tid, user.nickname, flake_bin, object.data["id"], media_ids]
        )

        {tid, flake_str}
      end, timeout: :infinity)
      |> case do
        {:ok, {tid, aid}} -> {:ok, tid, aid}
        {:error, reason} -> {:error, reason}
      end
    end

    # 投稿数と最終投稿日時を合わせる
    def finish(user) do
      User.update_note_count(user)

      last =
        Repo.one(
          from(a in Activity,
            where: a.actor == ^user.ap_id and a.local and fragment("?->>'type' = 'Create'", a.data),
            order_by: [desc: a.id],
            limit: 1,
            select: a.id
          )
        )

      if last do
        <<ms::64, _::64>> = FlakeId.from_string(last)
        at = DateTime.from_unix!(ms, :millisecond) |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)
        Repo.update_all(from(u in User, where: u.id == ^user.id), set: [last_status_at: at])
      end

      User.invalidate_cache(user)
    end

    def status(nickname) do
      setup()
      Repo.query!(
        "SELECT count(*), min(tweet_id), max(tweet_id), coalesce(sum(cardinality(media_object_ids)), 0) FROM twimport.map WHERE nickname = $1",
        [nickname]
      ).rows
    end

    # 取り込んだ投稿・メディアをすべて消す (このスクリプトで入れたものだけ)
    def rollback(nickname) do
      Logger.put_process_level(self(), :info)
      rows = Repo.query!("SELECT activity_id, object_ap_id, media_object_ids FROM twimport.map WHERE nickname = $1", [nickname]).rows
      activity_ids = Enum.map(rows, &Enum.at(&1, 0))
      ap_ids = Enum.map(rows, &Enum.at(&1, 1))
      media_ids = Enum.flat_map(rows, &Enum.at(&1, 2))

      files =
        Repo.all(from(o in Object, where: o.id in ^media_ids, select: o.data))
        |> Enum.flat_map(fn d -> for %{"href" => h} <- List.wrap(d["url"]), do: h end)
        |> Enum.map(fn href -> URI.parse(href).path |> String.replace_prefix("/media/", "") |> URI.decode() end)

      {:ok, _} =
        Repo.transaction(fn ->
          for chunk <- Enum.chunk_every(activity_ids, 1000),
              do: Repo.query!("DELETE FROM activities WHERE id = ANY($1)", [chunk])

          for chunk <- Enum.chunk_every(ap_ids, 1000),
              do: Repo.query!("DELETE FROM objects WHERE data->>'id' = ANY($1)", [chunk])

          for chunk <- Enum.chunk_every(media_ids, 1000),
              do: Repo.query!("DELETE FROM objects WHERE id = ANY($1)", [chunk])

          Repo.query!("DELETE FROM twimport.map WHERE nickname = $1", [nickname])
        end, timeout: :infinity)

      root = Pleroma.Config.get!([Pleroma.Uploaders.Local, :uploads])

      for f <- files do
        path = Path.join(root, f)
        File.rm(path)
        File.rmdir(Path.dirname(path))
      end

      finish(User.get_cached_by_nickname(nickname))
      {:rolled_back, length(rows), length(files)}
    end
  end
end

args = binding()[:args] || %{}

case args[:action] || :import do
  :import ->
    if args[:async] do
      if Process.whereis(:twimport_runner) do
        IO.puts("already running")
      else
        pid =
          spawn(fn ->
            Process.group_leader(self(), Process.whereis(:user))

            # then: [%{nickname:, dir:}, ...] で続けて別アカウントも流せる
            for job <- [Map.delete(args, :then) | List.wrap(args[:then])] do
              try do
                TwImport.run(job)
              rescue
                e -> TwImport.log(job.dir, "CRASH " <> Exception.format(:error, e, __STACKTRACE__))
              end
            end
          end)

        Process.register(pid, :twimport_runner)
        IO.puts("started #{inspect(pid)}; tail #{args.dir}/progress.log")
      end
    else
      IO.inspect(TwImport.run(args), label: :result)
    end

  :status ->
    IO.inspect(TwImport.status(args.nickname), label: :status)
    IO.inspect(Process.whereis(:twimport_runner), label: :runner)

  :rollback ->
    IO.inspect(TwImport.rollback(args.nickname), label: :rollback)
end
