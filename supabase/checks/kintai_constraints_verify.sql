-- ============================================================
-- 20261116_kintai_constraints.sql の実行後の確認 SQL（読み取りのみ）
--
-- 使い方:
--   Supabase Dashboard > SQL Editor に「1 ブロックずつ」貼って実行する。
--   すべて SELECT だけで、DB は変更しない。
--   各ブロックの「期待値」と違う結果が出たら、その結果を控えて相談する。
--   まず V1（全部 true になるはずの 1 行）を見て、false の項目があれば V2 以降で詳しく見る。
-- ============================================================


-- ============================================================
-- V1. まとめ（結果は 1 行。期待値: すべて true）
-- ============================================================
SELECT
  -- 制約
  (SELECT count(*) = 5 FROM pg_constraint
    WHERE conrelid = 'public.kintai'::regclass AND contype = 'c' AND convalidated
      AND conname IN ('kintai_date_format_chk', 'kintai_start_time_format_chk', 'kintai_end_time_format_chk',
                      'kintai_break_min_nonneg_chk', 'kintai_work_min_nonneg_chk'))      AS checks_ok,
  (SELECT bool_and(attnotnull) FROM pg_attribute
    WHERE attrelid = 'public.kintai'::regclass
      AND attname IN ('user_id', 'date', 'start_time', 'end_time', 'break_min', 'work_min', 'memo'))
                                                                                         AS not_null_ok,
  (SELECT NOT attnotnull FROM pg_attribute
    WHERE attrelid = 'public.kintai'::regclass AND attname = 'slack_reported_at')       AS slack_reported_at_nullable,

  -- 関数
  (SELECT provolatile = 'i' AND NOT prosecdef AND proconfig = ARRAY['search_path=""']
     FROM pg_proc WHERE oid = 'private.is_valid_ymd(text)'::regprocedure)                AS function_ok,
  has_function_privilege('authenticated', 'private.is_valid_ymd(text)', 'EXECUTE')       AS fn_exec_authenticated,
  has_function_privilege('service_role',  'private.is_valid_ymd(text)', 'EXECUTE')       AS fn_exec_service_role,
  NOT has_function_privilege('anon',      'private.is_valid_ymd(text)', 'EXECUTE')       AS fn_no_exec_anon,
  NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) g
              WHERE p.oid = 'private.is_valid_ymd(text)'::regprocedure AND g.grantee = 0) AS fn_no_exec_public,
  has_schema_privilege('authenticated', 'private', 'USAGE')                              AS schema_usage_authenticated,
  has_schema_privilege('service_role',  'private', 'USAGE')                              AS schema_usage_service_role,
  NOT has_schema_privilege('anon',      'private', 'USAGE')                              AS schema_no_usage_anon,
  NOT EXISTS (SELECT 1 FROM pg_namespace n, aclexplode(n.nspacl) g
              WHERE n.nspname = 'private' AND g.grantee = 0)                             AS schema_no_usage_public,

  -- kintai の権限
  NOT has_table_privilege('anon', 'public.kintai',
        'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')       AS kintai_anon_none,
  NOT has_sequence_privilege('anon', 'public.kintai_id_seq', 'SELECT, UPDATE, USAGE')    AS kintai_seq_anon_none,
  has_table_privilege('authenticated', 'public.kintai', 'SELECT')
    AND has_table_privilege('authenticated', 'public.kintai', 'DELETE')                  AS kintai_auth_select_delete,
  NOT has_table_privilege('authenticated', 'public.kintai',
        'TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')                                       AS kintai_auth_extra_removed,
  has_column_privilege('authenticated', 'public.kintai', 'user_id', 'INSERT')
    AND has_column_privilege('authenticated', 'public.kintai', 'memo', 'UPDATE')         AS kintai_auth_columns_kept,
  NOT has_column_privilege('authenticated', 'public.kintai', 'slack_reported_at', 'UPDATE')
    AND NOT has_column_privilege('authenticated', 'public.kintai', 'user_id', 'UPDATE')  AS kintai_auth_columns_still_limited,
  has_table_privilege('service_role', 'public.kintai', 'SELECT')
    AND has_table_privilege('service_role', 'public.kintai', 'INSERT')
    AND has_table_privilege('service_role', 'public.kintai', 'UPDATE')
    AND has_table_privilege('service_role', 'public.kintai', 'DELETE')                   AS kintai_service_role_ok,

  -- profiles の権限
  NOT has_table_privilege('anon', 'public.profiles',
        'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')       AS profiles_anon_none,
  has_table_privilege('authenticated', 'public.profiles', 'SELECT')
    AND has_table_privilege('authenticated', 'public.profiles', 'INSERT')
    AND has_table_privilege('authenticated', 'public.profiles', 'UPDATE')
    AND has_table_privilege('authenticated', 'public.profiles', 'DELETE')                AS profiles_auth_crud_kept,
  NOT has_table_privilege('authenticated', 'public.profiles',
        'TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')                                       AS profiles_auth_extra_removed;


-- ============================================================
-- V2. kintai の制約一覧
--   期待値: 7 件
--     kintai_break_min_nonneg_chk   CHECK ((break_min >= 0))
--     kintai_date_format_chk        CHECK (private.is_valid_ymd(date))
--     kintai_end_time_format_chk    CHECK ((end_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'::text))
--     kintai_start_time_format_chk  CHECK ((start_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'::text))
--     kintai_work_min_nonneg_chk    CHECK ((work_min >= 0))
--     kintai_pkey                   PRIMARY KEY (id)
--     kintai_user_id_fkey           FOREIGN KEY (user_id) REFERENCES auth.users(id)
--   validated はすべて true
-- ============================================================
SELECT conname,
  CASE contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'u' THEN 'UNIQUE' WHEN 'c' THEN 'CHECK'
               WHEN 'f' THEN 'FOREIGN KEY' ELSE contype::text END AS kind,
  convalidated AS validated,
  pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'public.kintai'::regclass
ORDER BY kind, conname;


-- ============================================================
-- V3. kintai の列の NOT NULL
--   期待値: not_null が false なのは slack_reported_at だけ
-- ============================================================
SELECT a.attnum AS pos, a.attname AS column_name,
  format_type(a.atttypid, a.atttypmod) AS data_type, a.attnotnull AS not_null
FROM pg_attribute a
WHERE a.attrelid = 'public.kintai'::regclass AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY a.attnum;


-- ============================================================
-- V4. テーブル単位の権限（ロール別）
--   期待値:
--     kintai         authenticated : DELETE, SELECT
--                    postgres      : 全権限（変更なし）
--                    service_role  : 全権限（変更なし）
--                    anon          : 行なし
--     kintai_id_seq  authenticated / postgres / service_role : SELECT, UPDATE, USAGE
--                    anon          : 行なし
--     profiles       authenticated : DELETE, INSERT, SELECT, UPDATE
--                    postgres / service_role : 全権限（変更なし）
--                    anon          : 行なし
-- ============================================================
SELECT c.relname AS object_name,
  CASE c.relkind WHEN 'r' THEN 'table' WHEN 'S' THEN 'sequence' END AS kind,
  CASE g.grantee WHEN 0 THEN 'PUBLIC' ELSE g.grantee::regrole::text END AS grantee,
  string_agg(g.privilege_type, ', ' ORDER BY g.privilege_type) AS privileges
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL aclexplode(coalesce(c.relacl, acldefault(
  CASE c.relkind WHEN 'S' THEN 's' ELSE 'r' END::"char", c.relowner))) g
WHERE n.nspname = 'public' AND c.relname IN ('kintai', 'kintai_id_seq', 'profiles')
GROUP BY c.relname, c.relkind, g.grantee
ORDER BY 1, 3;


-- ============================================================
-- V5. 列ごとの権限
--   期待値（実行前と同じ）:
--     kintai authenticated INSERT … date, start_time, end_time, break_min, work_min, memo, user_id
--     kintai authenticated UPDATE … date, start_time, end_time, break_min, work_min, memo
-- ============================================================
SELECT c.relname AS table_name,
  CASE g.grantee WHEN 0 THEN 'PUBLIC' ELSE g.grantee::regrole::text END AS grantee,
  g.privilege_type,
  string_agg(a.attname, ', ' ORDER BY a.attnum) AS columns
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
CROSS JOIN LATERAL aclexplode(a.attacl) g
WHERE a.attrelid IN ('public.kintai'::regclass, 'public.profiles'::regclass)
  AND a.attnum > 0 AND NOT a.attisdropped
GROUP BY c.relname, g.grantee, g.privilege_type
ORDER BY 1, 2, 3;


-- ============================================================
-- V6. private スキーマと関数の権限
--   期待値:
--     schema   private                    postgres: CREATE, USAGE / authenticated: USAGE / service_role: USAGE
--     function private.is_valid_ymd(text) postgres: EXECUTE / authenticated: EXECUTE / service_role: EXECUTE
--     （PUBLIC と anon の行は出ない）
-- ============================================================
SELECT 'schema' AS kind, n.nspname AS object_name,
  CASE g.grantee WHEN 0 THEN 'PUBLIC' ELSE g.grantee::regrole::text END AS grantee,
  string_agg(g.privilege_type, ', ' ORDER BY g.privilege_type) AS privileges
FROM pg_namespace n
CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) g
WHERE n.nspname = 'private'
GROUP BY n.nspname, g.grantee
UNION ALL
SELECT 'function', p.oid::regprocedure::text,
  CASE g.grantee WHEN 0 THEN 'PUBLIC' ELSE g.grantee::regrole::text END,
  string_agg(g.privilege_type, ', ' ORDER BY g.privilege_type)
FROM pg_proc p
CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) g
WHERE p.oid = 'private.is_valid_ymd(text)'::regprocedure
GROUP BY p.oid, g.grantee
ORDER BY 1, 2, 3;


-- ============================================================
-- V7. 日付判定関数の動き（期待値: ok 列がすべて true）
-- ============================================================
SELECT input, expected, private.is_valid_ymd(input) AS actual,
  private.is_valid_ymd(input) IS NOT DISTINCT FROM expected AS ok
FROM (VALUES
  ('2026-11-16',  true),
  ('2026-01-31',  true),
  ('2028-02-29',  true),   -- うるう年
  ('2026-02-29',  false),  -- うるう年でない
  ('2026-02-30',  false),
  ('2026-04-31',  false),
  ('2026-13-01',  false),
  ('2026-00-10',  false),
  ('2026-11-00',  false),
  ('0000-01-01',  false),
  ('2026-1-1',    false),
  ('2026/11/16',  false),
  ('２０２６-11-16', false), -- 全角数字
  ('20261-11-16', false),
  ('',            false),
  (NULL,          false)
) AS t(input, expected);


-- ============================================================
-- V8. 既存データが制約に合っているか（期待値: total_rows 142 以上、ng_rows 0）
--   制約は追加時に全行を確かめているので、通常は 0。念のための確認。
-- ============================================================
SELECT count(*) AS total_rows,
  count(*) FILTER (WHERE NOT (
        private.is_valid_ymd(date)
    AND start_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
    AND end_time   ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
    AND break_min >= 0 AND work_min >= 0
    AND user_id IS NOT NULL AND memo IS NOT NULL
  )) AS ng_rows
FROM public.kintai;
