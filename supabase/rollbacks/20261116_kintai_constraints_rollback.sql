-- ============================================================
-- 20261116_kintai_constraints.sql を元に戻す
--
-- 戻した後の状態（事前確認 P3・P4 の結果と同じ）:
--   kintai        anon          : DELETE, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE
--                 authenticated : DELETE, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE
--                                 ＋ 列ごとの INSERT 7 列 / UPDATE 6 列（実行 SQL で変えていないので触らない）
--   kintai_id_seq anon          : SELECT, UPDATE, USAGE
--   profiles      anon          : DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE
--                 authenticated : 同上
--   kintai の NOT NULL は id / created_at だけ、CHECK 制約なし
--   private スキーマと private.is_valid_ymd は無し
--
-- 実行方法:
--   Supabase Dashboard > SQL Editor にこのファイル全体を貼り、まとめて 1 回実行する。
--   BEGIN〜COMMIT で囲んであるので、途中でエラーになったら全部取り消される。
--   ※ 実行 SQL と同じく postgres ロール（SQL Editor の既定）で実行すること。
--     権限の付与者（grantor）が postgres になり、実行前と同じ形に戻る。
--   ※ private スキーマに他のオブジェクトを足していた場合、DROP SCHEMA がエラーで止まる
--     （CASCADE は使わない。足した物を確認してから対応する）
--
-- 戻した後の確認: supabase/checks/schema_check.sql の ②・⑨・⑩ と、
--                 supabase/checks/kintai_constraints_precheck.sql の P3・P4・P5
-- ============================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- ------------------------------------------------------------
-- 1. 権限を戻す
-- ------------------------------------------------------------
GRANT DELETE, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE
  ON TABLE public.kintai TO anon;
GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE
  ON TABLE public.kintai TO authenticated;

GRANT SELECT, UPDATE, USAGE
  ON SEQUENCE public.kintai_id_seq TO anon;

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE
  ON TABLE public.profiles TO anon;
GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE
  ON TABLE public.profiles TO authenticated;

-- ------------------------------------------------------------
-- 2. kintai の CHECK 制約と NOT NULL を外す
--    （関数を消す前に、関数を使っている制約を先に外す）
-- ------------------------------------------------------------
ALTER TABLE public.kintai
  DROP CONSTRAINT IF EXISTS kintai_date_format_chk,
  DROP CONSTRAINT IF EXISTS kintai_start_time_format_chk,
  DROP CONSTRAINT IF EXISTS kintai_end_time_format_chk,
  DROP CONSTRAINT IF EXISTS kintai_break_min_nonneg_chk,
  DROP CONSTRAINT IF EXISTS kintai_work_min_nonneg_chk,
  ALTER COLUMN user_id    DROP NOT NULL,
  ALTER COLUMN date       DROP NOT NULL,
  ALTER COLUMN start_time DROP NOT NULL,
  ALTER COLUMN end_time   DROP NOT NULL,
  ALTER COLUMN break_min  DROP NOT NULL,
  ALTER COLUMN work_min   DROP NOT NULL,
  ALTER COLUMN memo       DROP NOT NULL;

-- ------------------------------------------------------------
-- 3. 日付判定関数と private スキーマを消す
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS private.is_valid_ymd(text);
DROP SCHEMA IF EXISTS private;

COMMIT;
