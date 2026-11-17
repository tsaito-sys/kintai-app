-- ============================================================
-- kintai の守りを固める（段階0の2）
--   1. private スキーマと日付判定関数 private.is_valid_ymd(text) を作る
--   2. kintai に NOT NULL と CHECK 制約を足す
--        NOT NULL : user_id, date, start_time, end_time, break_min, work_min, memo
--                   （memo は空文字を許す。slack_reported_at は NULL のまま許す）
--        CHECK    : date は実在する 'YYYY-MM-DD'
--                   start_time / end_time は 'HH:MM'（00:00〜23:59、秒なし）
--                   break_min >= 0、work_min >= 0
--        ※ 終了 < 開始（日またぎ）は止めない。同じ日の複数行も止めない
--   3. 使っていない権限を外す
--        kintai         : anon の全権限、authenticated の TRUNCATE / REFERENCES / TRIGGER / MAINTAIN
--        kintai_id_seq  : anon の全権限
--        profiles       : anon の全権限、authenticated の TRUNCATE / REFERENCES / TRIGGER / MAINTAIN
--        ※ authenticated の SELECT・DELETE・列ごとの INSERT / UPDATE（kintai）、
--          INSERT / UPDATE / DELETE / SELECT（profiles）、service_role・postgres は変えない
--
-- 前提（事前確認 supabase/checks/kintai_constraints_precheck.sql の結果）:
--   142 行すべてが上の制約に合格（memo が空文字の 58 行は NOT NULL に合格）。
--   private スキーマは存在しない。
--
-- 実行方法:
--   Supabase Dashboard > SQL Editor にこのファイル全体を貼り、まとめて 1 回実行する。
--   BEGIN〜COMMIT で囲んであるので、途中でエラーになったら全部取り消される
--   （既存の行が制約に合わない場合も、ADD CONSTRAINT / SET NOT NULL がエラーになり全部取り消し）。
--
-- 実行後の確認: supabase/checks/kintai_constraints_verify.sql
-- 戻す場合    : supabase/rollbacks/20261116_kintai_constraints_rollback.sql
-- ============================================================

BEGIN;

-- 他の処理がテーブルを掴んでいたら、待ち続けずにエラーで止める
SET LOCAL lock_timeout = '5s';


-- ------------------------------------------------------------
-- 1. private スキーマと日付判定関数
--    ・private は API（PostgREST）に公開しないスキーマ
--      （Dashboard > Settings > API の Exposed schemas に足さないこと）
--    ・CHECK 制約の関数は「書き込んだユーザーの権限」で実行されるため、
--      kintai に書き込む authenticated と service_role にだけ USAGE / EXECUTE を付ける
--    ・CREATE SCHEMA は IF NOT EXISTS を付けない（既にあればエラーで止める）
-- ------------------------------------------------------------
CREATE SCHEMA private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA private TO authenticated, service_role;

-- 'YYYY-MM-DD' の形で、実在する日付なら true（NULL・空文字・13月・2月30日・0000年などは false）
--   ・CASE で順に確かめるので、形が違う値で型変換エラーにはならない
--   ・数字は [0-9]（全角数字などは通さない）
CREATE FUNCTION private.is_valid_ymd(p text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p IS NULL THEN false
    WHEN p !~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' THEN false
    WHEN substr(p, 1, 4)::int < 1 THEN false
    ELSE substr(p, 9, 2)::int
         <= extract(day FROM make_date(substr(p, 1, 4)::int, substr(p, 6, 2)::int, 1)
                             + interval '1 month - 1 day')::int
  END
$$;

REVOKE ALL ON FUNCTION private.is_valid_ymd(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.is_valid_ymd(text) TO authenticated, service_role;


-- ------------------------------------------------------------
-- 2. kintai の NOT NULL と CHECK 制約
-- ------------------------------------------------------------
ALTER TABLE public.kintai
  ALTER COLUMN user_id    SET NOT NULL,
  ALTER COLUMN date       SET NOT NULL,
  ALTER COLUMN start_time SET NOT NULL,
  ALTER COLUMN end_time   SET NOT NULL,
  ALTER COLUMN break_min  SET NOT NULL,
  ALTER COLUMN work_min   SET NOT NULL,
  ALTER COLUMN memo       SET NOT NULL,
  ADD CONSTRAINT kintai_date_format_chk
    CHECK (private.is_valid_ymd(date)),
  ADD CONSTRAINT kintai_start_time_format_chk
    CHECK (start_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  ADD CONSTRAINT kintai_end_time_format_chk
    CHECK (end_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  ADD CONSTRAINT kintai_break_min_nonneg_chk
    CHECK (break_min >= 0),
  ADD CONSTRAINT kintai_work_min_nonneg_chk
    CHECK (work_min >= 0);


-- ------------------------------------------------------------
-- 3. 使っていない権限を外す
--    （REVOKE は付いていない権限を指定してもエラーにならない）
-- ------------------------------------------------------------
-- kintai
REVOKE ALL ON TABLE public.kintai FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public.kintai FROM authenticated;

-- kintai の id 用シーケンス（authenticated の分は変えない）
REVOKE ALL ON SEQUENCE public.kintai_id_seq FROM anon;

-- profiles（authenticated の SELECT / INSERT / UPDATE / DELETE は変えない）
REVOKE ALL ON TABLE public.profiles FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public.profiles FROM authenticated;

COMMIT;
