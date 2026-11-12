-- ============================================================
-- Slack「作業報告」用の DB 変更
--   1. kintai.slack_reported_at 列を追加
--   2. 列権限：ログインユーザーは slack_reported_at を書き込めない
--      （書き込むのは Edge Function「slack-report」＝サービスロールだけ）
--   3. トリガー：memo が変わったら slack_reported_at を NULL に戻す
--
-- 実行方法: Supabase Dashboard > SQL Editor で「STEP 1」をまとめて実行する。
--   BEGIN〜COMMIT で囲んであるので、途中でエラーになったら全部取り消される
--   （REVOKE だけ通って GRANT が通らず、勤怠の保存ができなくなる事態を防ぐため）。
-- 同じ内容を supabase_setup.sql の「10.」にも反映済み。
-- ============================================================


-- ============================================================
-- STEP 0. 実行前の確認（読むだけ）
-- ============================================================
-- (a) kintai の列一覧。アプリが書き込むのは
--     date, start_time, end_time, break_min, work_min, memo, user_id の 7 列。
--     これ以外に「NOT NULL かつ既定値なし」の列が無いことを確認する
--     （あれば今の保存も失敗しているはずなので、通常は無い）。
-- SELECT column_name, data_type, is_nullable, column_default
-- FROM information_schema.columns
-- WHERE table_schema = 'public' AND table_name = 'kintai'
-- ORDER BY ordinal_position;
--
-- (b) 現在のテーブル権限（authenticated に INSERT / UPDATE があるはず）
-- SELECT grantee, privilege_type
-- FROM information_schema.role_table_grants
-- WHERE table_schema = 'public' AND table_name = 'kintai'
-- ORDER BY grantee, privilege_type;


-- ============================================================
-- STEP 1. 本体（まとめて実行）
-- ============================================================
BEGIN;

-- 1. 列の追加
ALTER TABLE public.kintai ADD COLUMN IF NOT EXISTS slack_reported_at timestamptz;

-- 2. 列権限
--    テーブル単位の INSERT / UPDATE 権限があると列単位の制限が効かないので、
--    いったんテーブル単位で外してから、アプリが使う列だけ付け直す。
--    ・INSERT: 新規追加・カレンダー取り込みが使う 7 列
--    ・UPDATE: 編集が使う 6 列（user_id は含めない＝行の持ち主の付け替えも防ぐ）
--    ・SELECT / DELETE は変更しない
--    ・service_role（Edge Function）は変更しない
REVOKE INSERT, UPDATE ON public.kintai FROM anon, authenticated;
GRANT INSERT (date, start_time, end_time, break_min, work_min, memo, user_id)
  ON public.kintai TO authenticated;
GRANT UPDATE (date, start_time, end_time, break_min, work_min, memo)
  ON public.kintai TO authenticated;

-- 3. memo が変わったら報告済みの印を消すトリガー
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


-- ============================================================
-- STEP 2. 実行後の確認（読むだけ）
-- ============================================================
-- SELECT
--   has_column_privilege('authenticated', 'public.kintai', 'slack_reported_at', 'UPDATE') AS can_update_reported, -- false
--   has_column_privilege('authenticated', 'public.kintai', 'slack_reported_at', 'INSERT') AS can_insert_reported, -- false
--   has_column_privilege('authenticated', 'public.kintai', 'memo',    'UPDATE')           AS can_update_memo,     -- true
--   has_column_privilege('authenticated', 'public.kintai', 'user_id', 'INSERT')           AS can_insert_user_id,  -- true
--   has_column_privilege('authenticated', 'public.kintai', 'user_id', 'UPDATE')           AS can_update_user_id,  -- false
--   has_column_privilege('authenticated', 'public.kintai', 'slack_reported_at', 'SELECT') AS can_select_reported; -- true
--
-- SELECT tgname FROM pg_trigger
-- WHERE tgrelid = 'public.kintai'::regclass AND NOT tgisinternal;
-- -- → kintai_reset_slack_reported が出ること
--
-- 最後にアプリで「勤怠追加 → 保存」「既存行の編集 → 保存」が今までどおりできることを確認する。


-- ============================================================
-- 戻す場合（コメントを外して、上から順にまとめて実行）
--   権限を戻してから列を消す。列を消すと報告済みの記録も消える。
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS kintai_reset_slack_reported ON public.kintai;
-- DROP FUNCTION IF EXISTS public.kintai_reset_slack_reported();
-- REVOKE INSERT (date, start_time, end_time, break_min, work_min, memo, user_id) ON public.kintai FROM authenticated;
-- REVOKE UPDATE (date, start_time, end_time, break_min, work_min, memo) ON public.kintai FROM authenticated;
-- GRANT INSERT, UPDATE ON public.kintai TO anon, authenticated;
-- ALTER TABLE public.kintai DROP COLUMN IF EXISTS slack_reported_at;
-- COMMIT;
