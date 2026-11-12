-- ============================================================
-- 勤怠管理アプリ Supabase 認証設定SQL
-- Supabase Dashboard > SQL Editor で実行してください
--
-- ロール（管理者かどうか）は app_metadata.role で判定する。
-- user_metadata はユーザー自身が書き換えられるため判定に使わない。
-- 既存環境の移行は supabase/migrations/20261111_role_to_app_metadata.sql と
-- README.md を参照。
-- ============================================================

-- 1. kintaiテーブルに user_id 列を追加
ALTER TABLE kintai ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users(id);

-- 2. profilesテーブルを作成（ユーザーの表示名を管理）
CREATE TABLE IF NOT EXISTS profiles (
  id         uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name       text NOT NULL,
  created_at timestamptz DEFAULT now()
);

-- ============================================================
-- 3. Row Level Security (RLS) を有効化
-- ============================================================
ALTER TABLE kintai    ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles  ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- 4. kintai テーブルの RLS ポリシー
--    管理者: 全行参照可（編集不可はフロントエンドで制御）
--    個人:   自分の行のみ CRUD 可
-- ============================================================
DROP POLICY IF EXISTS "kintai_select"  ON kintai;
DROP POLICY IF EXISTS "kintai_insert"  ON kintai;
DROP POLICY IF EXISTS "kintai_update"  ON kintai;
DROP POLICY IF EXISTS "kintai_delete"  ON kintai;

CREATE POLICY "kintai_select" ON kintai FOR SELECT USING (
  auth.uid() = user_id
  OR (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
);
CREATE POLICY "kintai_insert" ON kintai FOR INSERT WITH CHECK (
  auth.uid() = user_id
);
CREATE POLICY "kintai_update" ON kintai FOR UPDATE USING (
  auth.uid() = user_id
);
CREATE POLICY "kintai_delete" ON kintai FOR DELETE USING (
  auth.uid() = user_id
);

-- ============================================================
-- 5. profiles テーブルの RLS ポリシー
-- ============================================================
DROP POLICY IF EXISTS "profiles_select" ON profiles;
DROP POLICY IF EXISTS "profiles_insert" ON profiles;
DROP POLICY IF EXISTS "profiles_update" ON profiles;

CREATE POLICY "profiles_select" ON profiles FOR SELECT USING (
  auth.uid() = id
  OR (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
);
CREATE POLICY "profiles_insert" ON profiles FOR INSERT WITH CHECK (
  auth.uid() = id
);
CREATE POLICY "profiles_update" ON profiles FOR UPDATE USING (
  auth.uid() = id
);

-- ============================================================
-- 6. 既存データをあなたのアカウントに紐付ける場合
--    SupabaseダッシュボードのAuthentication > Usersから
--    あなたのユーザーIDを確認し、下記を編集して実行してください
-- ============================================================
-- UPDATE kintai SET user_id = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' WHERE user_id IS NULL;

-- ============================================================
-- 【管理者ユーザーの設定方法】
-- ロールは app_metadata に入れる（User Metadata ではない）。
-- ダッシュボードでは app_metadata を直接編集できないため、
-- SQL Editor で下記のメールアドレスを書き換えて実行する:
--
--   UPDATE auth.users
--   SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb
--   WHERE email = 'admin@example.com';
--
-- 管理者を外す場合:
--   UPDATE auth.users
--   SET raw_app_meta_data = raw_app_meta_data - 'role'
--   WHERE email = 'admin@example.com';
--
-- ※ 反映は対象ユーザーが「ログアウト → ログイン」した後
--   （ログイン中のトークンには変更前の値が入っているため）
-- ※ アプリのユーザー管理画面で「管理者」として作成した場合は自動で設定される
-- ============================================================

-- ============================================================
-- 【ユーザー作成方法（セルフサインアップは無効化）】
-- Supabase Dashboard > Authentication > Providers
-- Email > 「Confirm email」と「Enable email signup」の設定:
--   - Enable email signup: OFF（管理者のみ作成可能）
-- Supabase Dashboard > Authentication > Users > 「Add user」
-- メールアドレスと仮パスワードを設定して作成
-- ============================================================

-- ============================================================
-- 7. profiles テーブルに請求書設定カラムを追加
--    ユーザーごとに発行者情報・振込先情報・時給単価を保存する
-- ============================================================
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS inv_issuer       text;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS inv_zip          text;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS inv_address      text;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS inv_tel          text;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS inv_email        text;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS inv_invoice_reg  text;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS inv_rate         integer;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS inv_bank         text;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS inv_branch       text;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS inv_branch_no    text;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS inv_account_type text;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS inv_account_no   text;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS inv_account_name text;

-- ============================================================
-- 8. ユーザー管理画面用 SQL 関数（管理者がユーザー一覧を取得）
--    ※ この関数を実行しないとユーザー管理画面の一覧が表示されません
-- ============================================================
CREATE OR REPLACE FUNCTION list_users_for_admin()
RETURNS TABLE (
  id               uuid,
  email            text,
  name             text,
  role             text,
  created_at       timestamptz,
  email_confirmed  bool
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 管理者のみ実行可能
  -- ※ role 未設定(NULL)でも弾くため <> ではなく IS DISTINCT FROM を使う
  IF (auth.jwt() -> 'app_metadata' ->> 'role') IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'admin only';
  END IF;

  RETURN QUERY
  SELECT
    au.id::uuid,
    au.email::text,
    p.name::text,
    COALESCE(au.raw_app_meta_data ->> 'role', 'user')::text,
    au.created_at::timestamptz,
    (au.email_confirmed_at IS NOT NULL)::bool
  FROM auth.users au
  LEFT JOIN public.profiles p ON p.id = au.id
  ORDER BY au.created_at;
END;
$$;

-- 認証済みユーザーに実行権限を付与（RLS 内で管理者チェックあり）
GRANT EXECUTE ON FUNCTION list_users_for_admin() TO authenticated;

-- ============================================================
-- 9. ユーザー作成・削除関数（SQL 版）
--    ※ 現在のアプリ（index.html）はユーザーの作成・削除に
--      Edge Function「admin-user」を使っており、この2関数は呼んでいない。
--      予備として残しているため、ロール判定は app_metadata に揃えてある。
-- ============================================================
CREATE OR REPLACE FUNCTION admin_create_user(
  p_email    text,
  p_password text,
  p_role     text DEFAULT 'user'
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := gen_random_uuid();
BEGIN
  IF (auth.jwt() -> 'app_metadata' ->> 'role') IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'admin only';
  END IF;

  IF p_role NOT IN ('user', 'admin') THEN
    RAISE EXCEPTION '不正なロール: %', p_role;
  END IF;

  INSERT INTO auth.users (
    id, aud, role, email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at, updated_at
  ) VALUES (
    v_uid,
    'authenticated',
    'authenticated',
    p_email,
    extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(),
    -- ロールは app_metadata に入れる（ユーザー自身は書き換えられない）
    '{"provider":"email","providers":["email"]}'::jsonb || jsonb_build_object('role', p_role),
    '{}'::jsonb,
    now(),
    now()
  );

  RETURN jsonb_build_object('id', v_uid, 'email', p_email);
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'このメールアドレスは既に使用されています: %', p_email;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_create_user(text, text, text) TO authenticated;

-- ============================================================

CREATE OR REPLACE FUNCTION admin_delete_user(p_user_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF (auth.jwt() -> 'app_metadata' ->> 'role') IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'admin only';
  END IF;

  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION '自分自身は削除できません';
  END IF;

  DELETE FROM auth.users WHERE id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ユーザーが見つかりません';
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_delete_user(uuid) TO authenticated;

-- ============================================================
-- 10. Slack「作業報告」
--     ・slack_reported_at（報告日時）は Edge Function「slack-report」
--       （サービスロール）だけが書き込む。ログインユーザーは列権限で書き込み不可
--     ・memo が変わったら slack_reported_at を NULL に戻す
--     既存環境への初回反映・確認 SELECT・戻し方は
--     supabase/migrations/20261112_slack_report.sql を参照
-- ============================================================
BEGIN;

ALTER TABLE public.kintai ADD COLUMN IF NOT EXISTS slack_reported_at timestamptz;

-- テーブル単位の INSERT / UPDATE を外し、アプリが使う列だけ付け直す
--   INSERT: 新規追加・カレンダー取り込みが使う 7 列
--   UPDATE: 編集が使う 6 列（user_id は含めない）
REVOKE INSERT, UPDATE ON public.kintai FROM anon, authenticated;
GRANT INSERT (date, start_time, end_time, break_min, work_min, memo, user_id)
  ON public.kintai TO authenticated;
GRANT UPDATE (date, start_time, end_time, break_min, work_min, memo)
  ON public.kintai TO authenticated;

CREATE OR REPLACE FUNCTION public.kintai_reset_slack_reported()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.memo IS DISTINCT FROM OLD.memo THEN
    NEW.slack_reported_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS kintai_reset_slack_reported ON public.kintai;
CREATE TRIGGER kintai_reset_slack_reported
  BEFORE UPDATE OF memo ON public.kintai
  FOR EACH ROW EXECUTE FUNCTION public.kintai_reset_slack_reported();

COMMIT;
