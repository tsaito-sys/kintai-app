-- ============================================================
-- 20261117_kintai_import_rpc.sql の実行後の確認 SQL（読み取りのみ）
--
-- 使い方:
--   Supabase Dashboard > SQL Editor に「1 ブロックずつ」貼って実行する。
--   すべて SELECT だけで、DB は変更しない。
--   まず R1（全部 true になるはずの 1 行）を見て、false の項目があれば R2 以降で詳しく見る。
--   ※ R1 は関数がないと function_exists 以外の列がエラーになるため、
--     関数の有無だけを見たいとき（戻した後など）は R1 の 1 列目だけを実行する。
-- ============================================================


-- ============================================================
-- R1. まとめ（結果は 1 行。期待値: すべて true）
-- ============================================================
SELECT
  to_regprocedure('public.import_kintai_rows(jsonb)') IS NOT NULL                       AS function_exists,

  -- 関数の形
  (SELECT p.prorettype = 'integer'::regtype
      AND NOT p.prosecdef                                    -- SECURITY INVOKER
      AND p.proconfig = ARRAY['search_path=""']
      AND l.lanname = 'plpgsql'
     FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
    WHERE p.oid = 'public.import_kintai_rows(jsonb)'::regprocedure)                     AS function_ok,

  -- 実行権限
  has_function_privilege('authenticated', 'public.import_kintai_rows(jsonb)', 'EXECUTE') AS exec_authenticated,
  NOT has_function_privilege('anon',      'public.import_kintai_rows(jsonb)', 'EXECUTE') AS no_exec_anon,
  NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) g
              WHERE p.oid = 'public.import_kintai_rows(jsonb)'::regprocedure
                AND g.grantee = 0)                                                       AS no_exec_public,

  -- 関数の中で使う、本人（authenticated）の権限
  has_table_privilege('authenticated', 'public.kintai', 'SELECT')
    AND has_table_privilege('authenticated', 'public.kintai', 'DELETE')                  AS kintai_select_delete,
  has_column_privilege('authenticated', 'public.kintai', 'date',       'INSERT')
    AND has_column_privilege('authenticated', 'public.kintai', 'start_time', 'INSERT')
    AND has_column_privilege('authenticated', 'public.kintai', 'end_time',   'INSERT')
    AND has_column_privilege('authenticated', 'public.kintai', 'break_min',  'INSERT')
    AND has_column_privilege('authenticated', 'public.kintai', 'work_min',   'INSERT')
    AND has_column_privilege('authenticated', 'public.kintai', 'memo',       'INSERT')
    AND has_column_privilege('authenticated', 'public.kintai', 'user_id',    'INSERT')   AS kintai_insert_columns,
  has_sequence_privilege('authenticated', 'public.kintai_id_seq', 'USAGE')               AS seq_usage,
  has_function_privilege('authenticated', 'private.is_valid_ymd(text)', 'EXECUTE')       AS check_fn_exec;


-- ============================================================
-- R2. 関数の実行権限（ロール別）
--   期待値:
--     authenticated : EXECUTE
--     postgres      : EXECUTE（所有者）
--     service_role  : EXECUTE（Supabase の初期設定で付く。呼んでも auth.uid() が NULL でエラーになる）
--     PUBLIC・anon の行は出ない
-- ============================================================
SELECT
  CASE g.grantee WHEN 0 THEN 'PUBLIC' ELSE g.grantee::regrole::text END AS grantee,
  g.privilege_type
FROM pg_proc p
CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) g
WHERE p.oid = 'public.import_kintai_rows(jsonb)'::regprocedure
ORDER BY 1;


-- ============================================================
-- R3. 関数の定義（期待値: migrations/20261117_kintai_import_rpc.sql の CREATE FUNCTION と同じ）
-- ============================================================
SELECT pg_get_functiondef('public.import_kintai_rows(jsonb)'::regprocedure) AS definition;


-- ============================================================
-- R4. kintai の RLS ポリシー（関数は本人の権限で動くので、これがそのまま効く）
--   期待値: kintai_delete / kintai_insert / kintai_select / kintai_update の 4 件
--     kintai_delete  DELETE  (auth.uid() = user_id)
--     kintai_insert  INSERT  with_check: (auth.uid() = user_id)
-- ============================================================
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public' AND tablename = 'kintai'
ORDER BY policyname;
