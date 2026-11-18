-- ============================================================
-- 20261118_kintai_work_min_cleanup_2.sql を元に戻す
--   ・authenticated の kintai に対する列権限に、work_min の INSERT・UPDATE を付け直す
--     （第3段階の前と同じ: INSERT 7 列・UPDATE 6 列）
--   ・ほかの列の権限・トリガー・関数は変えない
--
-- ※ 戻しても画面・取り込みは今までどおり動く（第2段階の画面は work_min を送らないので、
--   権限があってもなくても同じ。work_min はトリガーが計算した値で上書きされる）。
--   戻すと「古い画面（work_min を送る）でも保存できる」状態になるだけ。
-- ※ 第1段階（20261118_kintai_work_min_cleanup_1_rollback.sql）まで戻す場合は、
--   必ずこのファイルを「先に」実行する。逆の順だと、import_kintai_rows が work_min を
--   INSERT する形に戻るのに権限がないため、カレンダー取り込みが止まる。
--
-- 実行方法:
--   Supabase Dashboard > SQL Editor にこのファイル全体を貼り、まとめて 1 回実行する。
--   BEGIN〜COMMIT で囲んであるので、途中でエラーになったら全部取り消される。
--
-- 戻した後の確認:
--   supabase/checks/schema_check.sql の ⑩（INSERT 7 列・UPDATE 6 列に戻っていること）
--   supabase/checks/kintai_import_rpc_verify.sql の R1（kintai_insert_columns が true）
--   （kintai_work_min_cleanup_2_verify.sql の D1・D2・D4 は、戻した後は NG になるのが正しい）
-- ============================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

GRANT INSERT (work_min), UPDATE (work_min) ON public.kintai TO authenticated;

-- 戻した後の列権限が第3段階の前と 1 列も違わないことを確かめる（違えば全部取り消し）
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

  IF v_ins IS DISTINCT FROM 'break_min,date,end_time,memo,start_time,user_id,work_min' THEN
    RAISE EXCEPTION '戻した後の INSERT の列権限が想定と違います（今: %）', v_ins;
  END IF;
  IF v_upd IS DISTINCT FROM 'break_min,date,end_time,memo,start_time,work_min' THEN
    RAISE EXCEPTION '戻した後の UPDATE の列権限が想定と違います（今: %）', v_upd;
  END IF;
END;
$$;

COMMIT;
