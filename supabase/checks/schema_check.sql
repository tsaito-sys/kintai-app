-- ============================================================
-- 本番 DB の定義・データの状態を確かめる SQL（読み取りのみ）
--
-- 使い方:
--   Supabase Dashboard > SQL Editor に「1 ブロックずつ」貼って実行する。
--   （1 回に複数の文を実行すると、最後の文の結果しか表示されない）
--   すべて SELECT だけで、DB は変更しない。
--   SQL Editor は postgres ロールで動くので、RLS に関係なく全員分の行が対象になる。
--   ⑫・⑬ の結果には氏名と user_id が含まれる（作業内容 memo は出さない）。
--
-- 「2026-11-16 の結果」は、初回に確認したときの値。
--   定義やデータを変えたあとに実行して、意図した差だけが出ているかを見る。
-- ============================================================


-- ============================================================
-- ① 列の定義（kintai・profiles）
--   2026-11-16 の結果: supabase_setup.sql の 0. と 2.・7. のとおり
--     kintai.date / start_time / end_time は text 型、id は bigint の IDENTITY (BY DEFAULT)
-- ============================================================
SELECT c.relname AS table_name, a.attnum AS pos, a.attname AS column_name,
  format_type(a.atttypid, a.atttypmod) AS data_type,
  a.attnotnull AS not_null,
  pg_get_expr(d.adbin, d.adrelid) AS default_value,
  CASE a.attidentity WHEN 'a' THEN 'ALWAYS' WHEN 'd' THEN 'BY DEFAULT' END AS identity,
  CASE a.attgenerated WHEN 's' THEN 'STORED' END AS generated,
  col_description(a.attrelid, a.attnum) AS comment
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
WHERE n.nspname = 'public' AND c.relname IN ('kintai', 'profiles')
  AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY c.relname, a.attnum;


-- ============================================================
-- ② 制約（主キー・一意・CHECK・外部キー。他テーブルから参照している外部キーも含む）
--   2026-11-16 の結果: 4 件
--     kintai_pkey, kintai_user_id_fkey（ON DELETE 指定なし）,
--     profiles_pkey, profiles_id_fkey（ON DELETE CASCADE）
-- ============================================================
SELECT conrelid::regclass AS table_name, conname,
  CASE contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'u' THEN 'UNIQUE' WHEN 'c' THEN 'CHECK'
               WHEN 'f' THEN 'FOREIGN KEY' WHEN 'x' THEN 'EXCLUDE' WHEN 'n' THEN 'NOT NULL'
               ELSE contype::text END AS kind,
  pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid  IN ('public.kintai'::regclass, 'public.profiles'::regclass)
   OR confrelid IN ('public.kintai'::regclass, 'public.profiles'::regclass)
ORDER BY 1, 3, 2;


-- ============================================================
-- ③ インデックス
--   2026-11-16 の結果: kintai_pkey, profiles_pkey の 2 件のみ
-- ============================================================
SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'public' AND tablename IN ('kintai', 'profiles')
ORDER BY 1, 2;


-- ============================================================
-- ④ トリガー
--   2026-11-16 の結果: kintai_reset_slack_reported（enabled）の 1 件のみ
-- ============================================================
SELECT tgrelid::regclass AS table_name, tgname,
  CASE tgenabled WHEN 'O' THEN 'enabled' WHEN 'D' THEN 'disabled'
                 WHEN 'R' THEN 'replica' WHEN 'A' THEN 'always' END AS status,
  pg_get_triggerdef(oid) AS definition
FROM pg_trigger
WHERE tgrelid IN ('public.kintai'::regclass, 'public.profiles'::regclass)
  AND NOT tgisinternal
ORDER BY 1, 2;


-- ============================================================
-- ⑤ トリガーが呼ぶ関数の中身
--   2026-11-16 の結果: kintai_reset_slack_reported()（supabase_setup.sql の 10. と同じ）
-- ============================================================
SELECT DISTINCT p.oid::regprocedure::text AS function, pg_get_functiondef(p.oid) AS definition
FROM pg_trigger t
JOIN pg_proc p ON p.oid = t.tgfoid
WHERE t.tgrelid IN ('public.kintai'::regclass, 'public.profiles'::regclass)
  AND NOT t.tgisinternal;


-- ============================================================
-- ⑥ public スキーマの SQL 関数の一覧
--   2026-11-16 の結果: admin_create_user, admin_delete_user,
--     kintai_reset_slack_reported, list_users_for_admin の 4 件。
--     どれも実行権限が PUBLIC（=X/postgres）と anon にも付いている（Supabase の既定）
-- ============================================================
SELECT p.oid::regprocedure::text AS function,
  pg_get_function_result(p.oid) AS returns,
  p.prosecdef AS security_definer,
  p.proconfig AS settings,
  array_to_string(p.proacl, ', ') AS execute_acl
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
ORDER BY p.proname;


-- ============================================================
-- ⑦ public スキーマのテーブル一覧と RLS の有効・無効
--   2026-11-16 の結果: kintai・profiles の 2 件。どちらも rls_enabled = true, rls_forced = false
-- ============================================================
SELECT c.relname AS name,
  CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view' WHEN 'm' THEN 'matview' WHEN 'p' THEN 'partitioned' END AS kind,
  c.relrowsecurity AS rls_enabled,
  c.relforcerowsecurity AS rls_forced,
  pg_get_userbyid(c.relowner) AS owner,
  c.reltuples::bigint AS approx_rows
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'v', 'm', 'p')
ORDER BY c.relname;


-- ============================================================
-- ⑧ RLS ポリシー
--   2026-11-16 の結果: 7 件（supabase_setup.sql の 4.・5. と同じ）
-- ============================================================
SELECT tablename, policyname, permissive, roles, cmd,
  qual AS using_expr, with_check AS with_check_expr
FROM pg_policies
WHERE schemaname = 'public' AND tablename IN ('kintai', 'profiles')
ORDER BY 1, 2;


-- ============================================================
-- ⑨ テーブル単位の権限
--   2026-11-16 の結果:
--     kintai   … anon / authenticated に INSERT・UPDATE なし（10. で外した）。
--                 DELETE・SELECT・TRUNCATE・TRIGGER・REFERENCES・MAINTAIN はあり
--     profiles … anon / authenticated にすべての権限あり（INSERT・UPDATE・TRUNCATE を含む）
-- ============================================================
SELECT c.relname AS table_name,
  CASE g.grantee WHEN 0 THEN 'PUBLIC' ELSE g.grantee::regrole::text END AS grantee,
  g.privilege_type, g.is_grantable
FROM pg_class c
CROSS JOIN LATERAL aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) g
WHERE c.oid IN ('public.kintai'::regclass, 'public.profiles'::regclass)
ORDER BY 1, 2, 3;


-- ============================================================
-- ⑩ 列ごとの権限（明示的に付けた分だけ。0 行なら列ごとの権限はなし）
--   2026-11-16 の結果: kintai の authenticated に
--     INSERT 7 列（date, start_time, end_time, break_min, work_min, memo, user_id）
--     UPDATE 6 列（date, start_time, end_time, break_min, work_min, memo）。profiles はなし
-- ============================================================
SELECT c.relname AS table_name,
  CASE g.grantee WHEN 0 THEN 'PUBLIC' ELSE g.grantee::regrole::text END AS grantee,
  g.privilege_type, a.attname AS column_name
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
CROSS JOIN LATERAL aclexplode(a.attacl) g
WHERE a.attrelid IN ('public.kintai'::regclass, 'public.profiles'::regclass)
  AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY 1, 2, 3, a.attnum;


-- ============================================================
-- ⑪ データの状態（件数の集計。結果は 1 行）
--   date / start_time / end_time は text 型なので、形式が正しい値だけを時刻に変換する。
--   work_min_mismatch は「終了 > 開始」の行だけを数える（日またぎは end_before_start に出る）
--   2026-11-16 の結果: total_rows 142, dup_groups 1, dup_rows 2, end_before_start 4,
--     ほかは 0。first_date 2026-01-22, last_date 2026-11-30
-- ============================================================
WITH k AS (
  SELECT id, user_id, date, break_min, work_min,
    CASE WHEN start_time ~ '^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$' THEN start_time::time END AS st,
    CASE WHEN end_time   ~ '^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$' THEN end_time::time   END AS et,
    (start_time IS NOT NULL AND start_time !~ '^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$')
 OR (end_time   IS NOT NULL AND end_time   !~ '^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$') AS bad_time,
    (date IS NOT NULL AND date !~ '^\d{4}-\d{2}-\d{2}$') AS bad_date
  FROM public.kintai
),
dup AS (
  SELECT user_id, date, count(*) AS n
  FROM k WHERE user_id IS NOT NULL AND date IS NOT NULL
  GROUP BY user_id, date HAVING count(*) > 1
)
SELECT
  (SELECT count(*) FROM k)                                        AS total_rows,
  (SELECT count(*) FROM k WHERE user_id IS NULL)                  AS user_id_null,
  (SELECT count(*) FROM k WHERE date IS NULL OR date = '')        AS date_null_or_empty,
  (SELECT count(*) FROM k WHERE bad_date)                         AS bad_date_format,
  (SELECT count(*) FROM k WHERE bad_time)                         AS bad_time_format,
  (SELECT count(*) FROM dup)                                      AS dup_groups,
  (SELECT coalesce(sum(n), 0) FROM dup)                           AS dup_rows,
  (SELECT count(*) FROM k WHERE st IS NULL OR et IS NULL)         AS time_null_or_bad,
  (SELECT count(*) FROM k WHERE et < st)                          AS end_before_start,
  (SELECT count(*) FROM k WHERE et = st)                          AS end_equals_start,
  (SELECT count(*) FROM k WHERE et > st
     AND work_min IS DISTINCT FROM
         (extract(epoch FROM (et - st)) / 60)::int - coalesce(break_min, 0)) AS work_min_mismatch,
  (SELECT count(*) FROM k WHERE work_min IS NULL)                 AS work_min_null,
  (SELECT count(*) FROM k WHERE break_min IS NULL)                AS break_min_null,
  (SELECT count(*) FROM k WHERE work_min < 0 OR break_min < 0)    AS negative_values,
  (SELECT min(date) FROM k WHERE NOT bad_date)                    AS first_date,
  (SELECT max(date) FROM k WHERE NOT bad_date)                    AS last_date;


-- ============================================================
-- ⑫ 同じ user_id・同じ date の行の明細（最大 200 行）
--   memo_hash は作業内容から作った短い符号（同じ内容かどうかの見分け用。
--   d41d8cd9 は空の文字列）
--   2026-11-16 の結果: 2026-03-19 の id 69（09:15〜09:45）と id 70（23:15〜00:00）。
--     1日に2回の勤務で、誤りではない
-- ============================================================
SELECT p.name, k.user_id, k.date, k.id,
  k.start_time, k.end_time, k.break_min, k.work_min,
  left(md5(coalesce(k.memo, '')), 8) AS memo_hash,
  k.slack_reported_at
FROM public.kintai k
LEFT JOIN public.profiles p ON p.id = k.user_id
WHERE (k.user_id, k.date) IN (
  SELECT user_id, date FROM public.kintai
  WHERE user_id IS NOT NULL AND date IS NOT NULL
  GROUP BY user_id, date HAVING count(*) > 1
)
ORDER BY p.name, k.date, k.id
LIMIT 200;


-- ============================================================
-- ⑬ 計算が合わない行・おかしな行の明細（最大 200 行）
--   expected_min は日またぎを考えていない（終了 < 開始の行は大きな負の数になる）
--   2026-11-16 の結果: 日またぎの 4 行（id 64, 66, 68, 70。2026-02〜03）のみ。
--     work_min は「終了 − 開始 + 24時間 − 休憩」と一致しており、誤りではない
-- ============================================================
WITH k AS (
  SELECT id, user_id, date, start_time, end_time, break_min, work_min,
    CASE WHEN start_time ~ '^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$' THEN start_time::time END AS st,
    CASE WHEN end_time   ~ '^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$' THEN end_time::time   END AS et
  FROM public.kintai
),
c AS (
  SELECT *, (extract(epoch FROM (et - st)) / 60)::int - coalesce(break_min, 0) AS expected_min
  FROM k
)
SELECT p.name, c.user_id, c.date, c.id, c.start_time, c.end_time, c.break_min, c.work_min, c.expected_min,
  concat_ws(', ',
    CASE WHEN c.user_id IS NULL THEN 'user_id NULL' END,
    CASE WHEN c.date IS NULL OR c.date !~ '^\d{4}-\d{2}-\d{2}$' THEN '日付の形式' END,
    CASE WHEN c.st IS NULL OR c.et IS NULL THEN '時刻 NULL/形式' END,
    CASE WHEN c.et < c.st THEN '終了<開始' END,
    CASE WHEN c.et = c.st THEN '終了=開始' END,
    CASE WHEN c.et > c.st AND c.work_min IS DISTINCT FROM c.expected_min THEN 'work_min 不一致' END,
    CASE WHEN c.work_min IS NULL THEN 'work_min NULL' END,
    CASE WHEN c.work_min < 0 OR c.break_min < 0 THEN '負の値' END
  ) AS problem
FROM c
LEFT JOIN public.profiles p ON p.id = c.user_id
WHERE c.user_id IS NULL
   OR c.date IS NULL OR c.date !~ '^\d{4}-\d{2}-\d{2}$'
   OR c.st IS NULL OR c.et IS NULL OR c.et <= c.st
   OR (c.et > c.st AND c.work_min IS DISTINCT FROM c.expected_min)
   OR c.work_min IS NULL OR c.work_min < 0 OR c.break_min < 0
ORDER BY c.date, c.id
LIMIT 200;
