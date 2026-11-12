# 勤怠管理アプリ（kintai-app）

`index.html` 1 ファイルで動く勤怠管理アプリ。データと認証は Supabase（プロジェクト ref: `hgiflgrsvocvdlfnqckp`）。

| ファイル | 内容 |
|---|---|
| `index.html` | アプリ本体（勤怠一覧・Googleカレンダー連携・請求書作成・ユーザー管理） |
| `supabase_setup.sql` | テーブル・RLS・SQL 関数の定義（SQL Editor で実行。何度実行しても同じ結果になる） |
| `supabase/functions/admin-user/` | Edge Function：管理者によるユーザー作成・削除 |
| `supabase/migrations/` | 既存環境向けの一回限りの移行 SQL |

## ロール（管理者）について

- 管理者かどうかは **`app_metadata.role = 'admin'`** で判定する（RLS・SQL 関数・Edge Function・画面すべて）。
- `user_metadata` はログイン中のユーザー自身が書き換えられるため、判定には使わない。
- 管理者の付け外しは `supabase_setup.sql` の「管理者ユーザーの設定方法」の SQL で行う。反映は対象ユーザーの再ログイン後。

---

## Edge Function のデプロイ

前提：Node.js（`npx` が使えること）。Supabase CLI は `npx` 経由で使うのでインストール不要。
PowerShell で、このリポジトリのフォルダから実行する。

```powershell
# 初回のみ：Supabase にログイン（ブラウザが開く）
npx supabase login

# デプロイ
npx supabase functions deploy admin-user --project-ref hgiflgrsvocvdlfnqckp
```

- 反映はコマンド完了直後から。
- デプロイ済みの関数一覧：`npx supabase functions list --project-ref hgiflgrsvocvdlfnqckp`
- ログ：Supabase Dashboard > Edge Functions > admin-user > Logs

## secret（環境変数）の設定

Edge Function から `Deno.env.get('名前')` で読む値。ブラウザには渡らない。

```powershell
# 設定（既にあれば上書き）
npx supabase secrets set 名前=値 --project-ref hgiflgrsvocvdlfnqckp

# 一覧（値はハッシュ表示）
npx supabase secrets list --project-ref hgiflgrsvocvdlfnqckp

# 削除
npx supabase secrets unset 名前 --project-ref hgiflgrsvocvdlfnqckp
```

- Dashboard > Edge Functions > Secrets からも設定できる。
- 設定後は関数を再デプロイしなくても次の呼び出しから反映される。
- `SUPABASE_URL` / `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_ROLE_KEY` は Supabase が自動で設定するので登録不要（`admin-user` が使うのはこの 3 つだけ）。
- 値に `&` などの記号が含まれる場合は `'名前=値'` のようにシングルクォートで囲む。

---

## Slack 作業報告（slack-report）

一覧の各行の「Slackに報告」ボタンから、その行の作業内容を Slack に投稿する。

- ブラウザは行の id だけを Edge Function `slack-report` に送る。氏名（`profiles.name`）と作業内容（`kintai.memo`）は関数側が DB から読む。送れるのは自分の行だけ。
- Slack の Webhook URL は secret `SLACK_WEBHOOK_URL` にだけ置く（コード・DB・`index.html` には書かない）。
- 送信に成功したら関数が `kintai.slack_reported_at` を記録する。ログインユーザーはこの列を書き込めない（列権限）。memo を編集すると DB のトリガーで印が消える。
- DB 側の定義：`supabase_setup.sql` の「10.」（初回反映・戻し方は `supabase/migrations/20261112_slack_report.sql`）。

### Webhook URL の用意

Slack の「Incoming Webhooks」を有効にしたアプリで、投稿先チャンネルを選んで URL（`https://hooks.slack.com/services/...`）を発行する。
Webhook は発行時に選んだチャンネル（または自分宛て DM）に固定される。

### secret の設定・差し替え

```powershell
# 設定（差し替えも同じコマンド。上書きされる）
npx supabase secrets set SLACK_WEBHOOK_URL=<ここにURL> --project-ref hgiflgrsvocvdlfnqckp

# 設定されているか確認（値はハッシュで表示される）
npx supabase secrets list --project-ref hgiflgrsvocvdlfnqckp
```

- 差し替えは再デプロイ不要。次の送信から新しい URL が使われる。
- URL は秘密情報。チャットやコミットに貼らない。漏れた場合は Slack 側で Webhook を削除して作り直し、上のコマンドで差し替える。

### デプロイ

```powershell
npx supabase functions deploy slack-report --project-ref hgiflgrsvocvdlfnqckp
```

### 送信できないとき

画面のトースト（右下）に理由が出る。詳細は Dashboard > Edge Functions > slack-report > Logs。

| 表示 | 主な原因 |
|---|---|
| Slack の送信先（SLACK_WEBHOOK_URL）が未設定です | secret 未設定 |
| Webhook URL が無効です／無効化または削除されています | URL の誤り、Slack 側で Webhook 削除 |
| 投稿先の Slack チャンネルが見つかりません／アーカイブされています | チャンネル削除・アーカイブ |
| 氏名が未登録です | `profiles.name` が空 |
| 日付が正しくないため報告できません | その行の `date` が空、または `YYYY-MM-DD` の実在する日付でない |
| 未保存の変更があります | その行を編集中（先に「保存」する） |

---

## ロール判定の app_metadata 移行（2026-11）

既存環境で `user_metadata.role` から `app_metadata.role` に切り替える一回限りの手順。
**順番を守ること。** 特に手順 2（管理者の再ログイン）を飛ばして手順 4 を実行すると、管理者が一時的に何も見えなくなる。

| # | 作業 | 場所 |
|---|---|---|
| 1 | 移行 SQL の **STEP 1**（確認 → app_metadata へコピー → 確認） | SQL Editor：`supabase/migrations/20261111_role_to_app_metadata.sql` |
| 2 | **管理者全員がログアウト → ログイン** | アプリ |
| 3 | Edge Function `admin-user` をデプロイ | PowerShell |
| 4 | `supabase_setup.sql` を全文実行（RLS・SQL 関数を app_metadata 判定に） | SQL Editor |
| 5 | `index.html` を push → 公開ページを強制再読み込み（Ctrl+F5）して管理者画面を確認 | git / ブラウザ |
| 6 | 移行 SQL の **STEP 2**（user_metadata から role を削除 → 確認） | SQL Editor |
| 7 | 管理者は再ログイン（推奨） | アプリ |

なぜこの順番か：

- RLS（手順 4）はログイン中トークン（JWT）に入っている `app_metadata` を見る。トークンは発行時の値のままなので、手順 1 の後に**再ログインしてトークンを作り直さないと**、手順 4 の直後から管理者の一覧が自分の分だけになり、ユーザー管理も「admin only」で失敗する。
- Edge Function（手順 3）はトークンではなくサーバー上の最新ユーザー情報を見るので、手順 1 の後ならいつでもよい。
- 手順 1〜5 の間は `user_metadata.role` も残しているので、古い `index.html` のままでも管理者画面が出る。
- 手順 6 を手順 5 より先に行うと、古い `index.html` を開いている管理者がトークン更新後に一般ユーザー画面になる。

ブラウザでトークンの中身を確かめたい場合（開発者ツールのコンソールで）：

```js
(await sb.auth.getSession()).data.session.user.app_metadata
// → { provider: "email", providers: [...], role: "admin" } なら OK
```
