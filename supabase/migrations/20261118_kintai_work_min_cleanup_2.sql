-- ============================================================
-- 段階0の後片付け 第3段階：authenticated の列権限（INSERT・UPDATE）から work_min を外す
--
--   後片付け全体の流れ:
--     第1段階 … DB の準備（20261118_kintai_work_min_cleanup_1.sql）
--     第2段階 … 画面（index.html）が work_min を送るのをやめる（コミット 71da345）
--     第3段階（このファイル）… authenticated の列権限から work_min を外す
--
--   目的:
--     work_min は DB のトリガー kintai_compute_work_min が計算して入れる。
--     ログインユーザー（authenticated）が work_min を直接書けないようにして、
--     「保存される work_min はトリガーの計算結果だけ」を権限でも守る。
--
--   前提（実行前に確かめること）:
--     ・第1段階を本番で実行し、kintai_work_min_cleanup_1_verify.sql が全項目 OK
--       （import_kintai_rows が work_min を INSERT しない・トリガーが NULL のとき 0 を入れる）
--       → このファイルの最初の確認でも DB の定義を確かめ、違えば全部取り消して止める
--     ・第2段階の画面（work_min を送らない）を本番に公開済みで、
--       古い画面（work_min を送る）を開いたままの人がいない
--       → DB からは確かめられない。古い画面のまま追加・編集すると、権限エラー（42501）で保存できなくなる
--         （再読み込みすれば新しい画面になり、保存できる）
--
--   このファイルでやること（1 つのトランザクション）:
--     ・authenticated の kintai に対する列権限から、work_min の INSERT・UPDATE だけを取り消す
--         INSERT: date, start_time, end_time, break_min, work_min, memo, user_id
--              → date, start_time, end_time, break_min, memo, user_id（6 列）
--         UPDATE: date, start_time, end_time, break_min, work_min, memo
--              → date, start_time, end_time, break_min, memo（5 列）
--     ・付け直しはしない（work_min の列権限だけを REVOKE する）
--     ・ほかの列の権限、SELECT・DELETE の権限、anon・service_role の権限は変えない
--     ・取り消す前と後に、authenticated の列権限の一覧が期待どおりかを確かめ、違えば全部取り消して止める
--
--   変えないもの:
--     ・トリガー kintai_compute_work_min（BEFORE INSERT OR UPDATE OF start_time, end_time, break_min, work_min）
--       ※ 列権限は SQL 文に書いた列だけを確かめるので、トリガーが NEW.work_min を書き換えるのは
--         権限と関係なくこれまでどおり動く
--     ・import_kintai_rows（SECURITY INVOKER。第1段階から work_min を INSERT していない）
--     ・画面の編集の .select('work_min')（SELECT 権限は残るので、RETURNING で読める）
--     ・Edge Function slack-report（service_role で動き、work_min を書かない）
--
-- 実行方法:
--   Supabase Dashboard > SQL Editor にこのファイル全体を貼り、まとめて 1 回実行する。
--   BEGIN〜COMMIT で囲んであるので、途中でエラーになったら全部取り消される。
--
-- 実行後の確認: supabase/checks/kintai_work_min_cleanup_2_verify.sql
-- 戻す場合    : supabase/rollbacks/20261118_kintai_work_min_cleanup_2_rollback.sql
-- ============================================================

BEGIN;

-- 他の処理がテーブルを掴んでいたら、待ち続けずにエラーで止める
SET LOCAL lock_timeout = '5s';

-- ------------------------------------------------------------
-- 1. 実行前の確認（どれか 1 つでも違えば全部取り消し）
-- ------------------------------------------------------------
DO $$
DECLARE
  v_ins text;
  v_upd text;
BEGIN
  -- 第1段階が済んでいる（import_kintai_rows に work_min がない・トリガーに coalesce がある）
  IF to_regprocedure('public.import_kintai_rows(jsonb)') IS NULL
     OR position('work_min' IN lower(pg_get_functiondef('public.import_kintai_rows(jsonb)'::regprocedure))) > 0 THEN
    RAISE EXCEPTION 'import_kintai_rows が第1段階の形ではありません。先に 20261118_kintai_work_min_cleanup_1.sql を実行してください';
  END IF;
  IF to_regprocedure('public.kintai_compute_work_min()') IS NULL
     OR position('coalesce(new.work_min, 0)' IN lower(pg_get_functiondef('public.kintai_compute_work_min()'::regprocedure))) = 0 THEN
    RAISE EXCEPTION 'kintai_compute_work_min が第1段階の形ではありません。先に 20261118_kintai_work_min_cleanup_1.sql を実行してください';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                 WHERE t.tgrelid = 'public.kintai'::regclass
                   AND t.tgname = 'kintai_compute_work_min' AND t.tgenabled = 'O') THEN
    RAISE EXCEPTION 'トリガー kintai_compute_work_min がない、または無効です';
  END IF;

  -- authenticated にテーブル単位の INSERT・UPDATE がない
  -- （あると列の REVOKE が効かないため。has_table_privilege は列ごとの権限を数えない）
  IF has_table_privilege('authenticated', 'public.kintai', 'INSERT')
     OR has_table_privilege('authenticated', 'public.kintai', 'UPDATE') THEN
    RAISE EXCEPTION 'authenticated に kintai のテーブル単位の INSERT / UPDATE が付いています。列の権限だけでは止められないため中止します';
  END IF;

  -- 今の列権限の一覧が supabase_setup.sql 10.（第3段階の前）と 1 列も違わない
  SELECT string_agg(a.attname::text, ',' ORDER BY a.attname) INTO v_ins
  FROM pg_attribute a
  WHERE a.attrelid = 'public.kintai'::regclass AND a.attnum > 0 AND NOT a.attisdropped
    AND has_column_privilege('authenticated', a.attrelid, a.attnum, 'INSERT');
  SELECT string_agg(a.attname::text, ',' ORDER BY a.attname) INTO v_upd
  FROM pg_attribute a
  WHERE a.attrelid = 'public.kintai'::regclass AND a.attnum > 0 AND NOT a.attisdropped
    AND has_column_privilege('authenticated', a.attrelid, a.attnum, 'UPDATE');

  IF v_ins IS DISTINCT FROM 'break_min,date,end_time,memo,start_time,user_id,work_min' THEN
    RAISE EXCEPTION '実行前の INSERT の列権限が想定と違います（今: %）', v_ins;
  END IF;
  IF v_upd IS DISTINCT FROM 'break_min,date,end_time,memo,start_time,work_min' THEN
    RAISE EXCEPTION '実行前の UPDATE の列権限が想定と違います（今: %）', v_upd;
  END IF;
END;
$$;


-- ------------------------------------------------------------
-- 2. work_min の列権限だけを取り消す
-- ------------------------------------------------------------
REVOKE INSERT (work_min), UPDATE (work_min) ON public.kintai FROM authenticated;


-- ------------------------------------------------------------
-- 3. 実行後の確認（違えば全部取り消し）
--    ※ 権限を付けた人（grantor）が postgres 以外だと、REVOKE は警告だけで取り消さないことがある。
--      その場合もここで止まる
-- ------------------------------------------------------------
DO $$
DECLARE
  v_ins text;
  v_upd text;
BEGIN
  SELECT string_agg(a.attname::text, ',' ORDER BY a.attname) INTO v_ins
  FROM pg_attribute a
  WHERE a.attrelid = 'public.kintai'::regclass AND a.attnum > 0 AND NOT a.attisdropped
    AND has_column_privilege('authenticated', a.attrelid, a.attnum, 'INSERT');
  SELECT string_agg(a.attname::text, ',' ORDER BY a.attname) INTO v_upd
  FROM pg_attribute a
  WHERE a.attrelid = 'public.kintai'::regclass AND a.attnum > 0 AND NOT a.attisdropped
    AND has_column_privilege('authenticated', a.attrelid, a.attnum, 'UPDATE');

  IF v_ins IS DISTINCT FROM 'break_min,date,end_time,memo,start_time,user_id' THEN
    RAISE EXCEPTION '実行後の INSERT の列権限が想定と違います（今: %）', v_ins;
  END IF;
  IF v_upd IS DISTINCT FROM 'break_min,date,end_time,memo,start_time' THEN
    RAISE EXCEPTION '実行後の UPDATE の列権限が想定と違います（今: %）', v_upd;
  END IF;
  IF NOT has_column_privilege('authenticated', 'public.kintai', 'work_min', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated が work_min を読めなくなっています';
  END IF;
END;
$$;

COMMIT;
