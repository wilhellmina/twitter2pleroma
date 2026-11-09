# 取り込んだ投稿を Mastodon API の形で表示して確認する。
#
#   pleroma rpc 'Code.eval_string(File.read!("/tmp/twimport/verify.exs"), args: %{nickname: "alice"})'
#
# args: nickname (確認するユーザー), viewer (見る側のユーザー。省略で本人), limit (省略で 20)
require Ecto.Query; import Ecto.Query
Logger.put_process_level(self(), :info)
args = binding()[:args]
user = Pleroma.User.get_cached_by_nickname(args.nickname)
viewer = Pleroma.User.get_cached_by_nickname(args[:viewer] || args.nickname)
acts = Pleroma.Web.ActivityPub.ActivityPub.fetch_user_activities(user, viewer, %{limit: args[:limit] || 20})
IO.puts("timeline order: " <> Enum.map_join(acts, ", ", & &1.data["published"] |> String.slice(0, 10)))
for a <- acts do
  s = Pleroma.Web.MastodonAPI.StatusView.render("show.json", activity: a, for: viewer)
  IO.inspect(%{id: s.id, created_at: s.created_at, visibility: s.visibility, content: s.content, in_reply_to_id: s.in_reply_to_id,
    quote: s[:pleroma][:quote_id] || (s[:quote] && s.quote.id), mentions: Enum.map(s.mentions, & &1.acct), tags: Enum.map(s.tags, & &1.name),
    media: Enum.map(s.media_attachments, &{&1.type, &1.url}), application: s.application, language: s.language, sensitive: s.sensitive}, limit: :infinity, printable_limit: :infinity)
end
root = Pleroma.Config.get!([Pleroma.Uploaders.Local, :uploads])
for a <- acts, att <- (Pleroma.Object.normalize(a, fetch: false).data["attachment"] || []), %{"href" => h} <- att["url"] do
  p = Path.join(root, URI.parse(h).path |> String.replace_prefix("/media/", "") |> URI.decode())
  IO.puts("file #{File.exists?(p)} #{if File.exists?(p), do: File.stat!(p).size} #{p}")
end
IO.inspect(Pleroma.Repo.aggregate(from(n in Pleroma.Notification, where: n.inserted_at > ago(15, "minute")), :count), label: :notifications_last_15min)
IO.inspect(Pleroma.Repo.aggregate(from(j in Oban.Job, where: j.inserted_at > ago(15, "minute")), :count), label: :oban_jobs_last_15min)
