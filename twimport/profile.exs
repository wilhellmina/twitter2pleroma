# prepare.py が書き出した profile.json (表示名・自己紹介・補足情報・アイコン・ヘッダー) をローカルユーザーに設定する。
# 中身は Mastodon API のプロフィール更新 (update_credentials) と同じ流れ。
#
#   pleroma rpc 'Code.eval_string(File.read!("/tmp/twimport/profile.exs"), args: %{nickname: "alice", dir: "/tmp/twimport/alice"})'
#
# dir には profile.json と profile/ (画像) を置く。

Logger.put_process_level(self(), :info)

alias Pleroma.User
alias Pleroma.Web.ActivityPub.{Builder, Pipeline, UserView}

args = binding()[:args]
p = Path.join(args.dir, "profile.json") |> File.read!() |> Jason.decode!()
%User{local: true} = user = User.get_cached_by_nickname(args.nickname)

upload = fn %{"file" => file, "mime" => mime} ->
  %Plug.Upload{path: Path.join(args.dir, file), filename: Path.basename(file), content_type: mime}
end

params =
  %{name: p["name"], raw_fields: p["fields"]}
  |> then(fn m -> if p["bio"] in [nil, ""], do: m, else: Map.merge(m, %{bio: p["bio"], raw_bio: p["bio"]}) end)
  |> then(fn m -> if p["avatar"], do: Map.put(m, :avatar, upload.(p["avatar"])), else: m end)
  |> then(fn m -> if p["banner"], do: Map.put(m, :banner, upload.(p["banner"])), else: m end)

changeset = User.update_changeset(user, params)
{:ok, unpersisted} = Ecto.Changeset.apply_action(changeset, :update)
object = UserView.render("user.json", user: unpersisted) |> Map.delete("@context")
{:ok, update_data, []} = Builder.update(user, object)
{:ok, _update, _} = Pipeline.common_pipeline(update_data, local: true, user_update_changeset: changeset)

u = User.get_by_nickname(args.nickname)
IO.inspect(%{name: u.name, bio: u.bio, fields: u.fields, avatar: get_in(u.avatar, ["url", Access.at(0), "href"]),
             banner: get_in(u.banner, ["url", Access.at(0), "href"])}, label: :updated, limit: :infinity, printable_limit: :infinity)
