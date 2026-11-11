-- ============================================================
-- ロール判定を user_metadata → app_metadata に移行する
--
-- 背景:
--   user_metadata はログイン中のユーザー自身が
--   sb.auth.updateUser({ data: { role: 'admin' } }) で書き換えられるため、
--   ロール判定に使うと一般ユーザーが管理者になりすませる。
--   app_metadata はサービスロール／SQL からしか書き換えられない。
--
-- 実行方法:
--   Supabase Dashboard > SQL Editor に STEP ごとに貼り付けて実行する。
--   ※ ファイル全体を一度に実行しないこと（STEP 1 と STEP 2 の間に作業がある）
--   ※ 手順全体は README.md「ロール判定の app_metadata 移行」を参照
-- ============================================================


-- ============================================================
-- STEP 1-a. 実行前の確認（読むだけ）
--   管理者が何人いて、role がどこに入っているかを確認する
-- ============================================================
-- SELECT
--   id, email,
--   raw_user_meta_data ->> 'role' AS user_meta_role,
--   raw_app_meta_data  ->> 'role' AS app_meta_role
-- FROM auth.users
-- WHERE raw_user_meta_data ->> 'role' = 'admin'
--    OR raw_app_meta_data  ->> 'role' = 'admin'
-- ORDER BY email;
--
-- 期待値: 管理者の行が user_meta_role = 'admin'、app_meta_role = NULL で並ぶ
--         （ここでの人数を控えておく）


-- ============================================================
-- STEP 1-b. 管理者の role を app_metadata にコピー
--   この時点では user_metadata 側は消さない
--   （古い index.html・古い RLS のままでも動き続けるようにするため）
-- ============================================================
UPDATE auth.users
SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('role', 'admin')
WHERE raw_user_meta_data ->> 'role' = 'admin';


-- ============================================================
-- STEP 1-c. コピー後の確認（読むだけ）
-- ============================================================
-- SELECT
--   id, email,
--   raw_user_meta_data ->> 'role' AS user_meta_role,
--   raw_app_meta_data  ->> 'role' AS app_meta_role
-- FROM auth.users
-- WHERE raw_user_meta_data ->> 'role' = 'admin'
--    OR raw_app_meta_data  ->> 'role' = 'admin'
-- ORDER BY email;
--
-- 期待値: STEP 1-a と同じ人数で、全員 app_meta_role = 'admin'
--
-- 人数だけ見る場合:
-- SELECT
--   count(*) FILTER (WHERE raw_user_meta_data ->> 'role' = 'admin') AS user_meta_admins,
--   count(*) FILTER (WHERE raw_app_meta_data  ->> 'role' = 'admin') AS app_meta_admins
-- FROM auth.users;
-- 期待値: 2つの数が一致


-- ============================================================
-- （STEP 1 と STEP 2 の間に README の手順 2〜5 を行う：
--   管理者の再ログイン → Edge Function デプロイ → supabase_setup.sql の
--   RLS・関数の反映 → index.html の push）
-- ============================================================


-- ============================================================
-- STEP 2-a. user_metadata から role を削除
--   新しい index.html（app_metadata で判定）を push した「後」に実行する。
--   先に実行すると、古い index.html を開いている管理者が
--   トークン更新後に一般ユーザー画面になる。
--   一般ユーザーに残っている {"role":"user"} も紛らわしいので併せて削除する。
-- ============================================================
UPDATE auth.users
SET raw_user_meta_data = raw_user_meta_data - 'role'
WHERE raw_user_meta_data ? 'role';


-- ============================================================
-- STEP 2-b. 削除後の確認（読むだけ）
-- ============================================================
-- SELECT
--   count(*) FILTER (WHERE raw_user_meta_data ? 'role')                AS user_meta_role_left,
--   count(*) FILTER (WHERE raw_app_meta_data ->> 'role' = 'admin')     AS app_meta_admins
-- FROM auth.users;
--
-- 期待値: user_meta_role_left = 0、app_meta_admins = STEP 1-a の人数
