-- ============================================================
-- kintai の制約追加（形式 CHECK・NOT NULL・権限の整理）前の事前確認 SQL（読み取りのみ）
--
-- 使い方:
--   Supabase Dashboard > SQL Editor に「1 ブロックずつ」貼って実行する。
--   （1 回に複数の文を実行すると、最後の文の結果しか表示されない）
--   すべて SELECT だけで、DB は変更しない。
--   SQL Editor は postgres ロールで動くので、RLS に関係なく全員分の行が対象になる。
--   P2 の結果には氏名と user_id が含まれる（作業内容 memo は出さない）。
--
-- 想定している形式（制約案）:
--   date       'YYYY-MM-DD'（実在する日付。13月・2月30日などは不可）
--   start_time 'HH:MM'（00:00〜23:59。25時などは不可）
--   end_time   'HH:MM'（同上。終了 < 開始＝日またぎは許可）
-- ============================================================


-- ============================================================
-- P1. 件数の集計（結果は 1 行）
--   date_bad / start_bad / end_bad … 想定の形式から外れる行（NULL・空文字を含む）
--   time_with_seconds … 'HH:MM:SS' の形の行（制約で秒を許すかの判断用。start_bad / end_bad にも含まれる）
--   *_null / memo_empty / memo_blank … NOT NULL にできるかの判断用
--   break_negative ～ over_24h … 範囲チェック（任意）を入れられるかの判断用
--   期待値: 0 以外が出た項目は P2 で中身を見る
-- ============================================================
WITH k AS (
  SELECT *,
    CASE
      WHEN date IS NULL THEN 'NULL'
      WHEN date = '' THEN '空文字'
      WHEN date !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN '形式'
      WHEN substr(date, 1, 4)::int < 1 THEN '年'
      WHEN substr(date, 6, 2)::int NOT BETWEEN 1 AND 12 THEN '月'
      WHEN substr(date, 9, 2)::int NOT BETWEEN 1 AND
           extract(day FROM make_date(substr(date, 1, 4)::int, substr(date, 6, 2)::int, 1)
                            + interval '1 month - 1 day')::int THEN '日'
    END AS date_problem,
    CASE
      WHEN start_time IS NULL THEN 'NULL'
      WHEN start_time = '' THEN '空文字'
      WHEN start_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN NULL
      WHEN start_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$' THEN '秒あり'
      ELSE '形式・範囲外'
    END AS start_problem,
    CASE
      WHEN end_time IS NULL THEN 'NULL'
      WHEN end_time = '' THEN '空文字'
      WHEN end_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN NULL
      WHEN end_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$' THEN '秒あり'
      ELSE '形式・範囲外'
    END AS end_problem
  FROM public.kintai
)
SELECT
  count(*)                                                          AS total_rows,
  count(*) FILTER (WHERE date_problem  IS NOT NULL)                 AS date_bad,
  count(*) FILTER (WHERE start_problem IS NOT NULL)                 AS start_bad,
  count(*) FILTER (WHERE end_problem   IS NOT NULL)                 AS end_bad,
  count(*) FILTER (WHERE start_problem = '秒あり' OR end_problem = '秒あり') AS time_with_seconds,
  count(*) FILTER (WHERE user_id   IS NULL)                         AS user_id_null,
  count(*) FILTER (WHERE break_min IS NULL)                         AS break_min_null,
  count(*) FILTER (WHERE work_min  IS NULL)                         AS work_min_null,
  count(*) FILTER (WHERE memo      IS NULL)                         AS memo_null,
  count(*) FILTER (WHERE memo = '')                                 AS memo_empty,
  count(*) FILTER (WHERE memo <> '' AND btrim(memo, E' \t\r\n　') = '') AS memo_blank,
  count(*) FILTER (WHERE break_min < 0)                             AS break_negative,
  count(*) FILTER (WHERE work_min  < 0)                             AS work_negative,
  count(*) FILTER (WHERE work_min = 0)                              AS work_zero,
  count(*) FILTER (WHERE break_min > 1440 OR work_min > 1440)       AS over_24h,
  min(substr(date, 1, 4)) FILTER (WHERE date_problem IS NULL)       AS min_year,
  max(substr(date, 1, 4)) FILTER (WHERE date_problem IS NULL)       AS max_year
FROM k;


-- ============================================================
-- P2. 引っかかる行の明細（最大 200 行）
--   P1 で 0 以外が出た項目について、どの行かを確かめる。
--   memo は出さず、空かどうか（memo_state）だけを出す。
--   期待値: 0 行（memo が空の古い行がある場合は、その行が「memo 空」で出る）
-- ============================================================
WITH k AS (
  SELECT *,
    CASE
      WHEN date IS NULL THEN 'NULL'
      WHEN date = '' THEN '空文字'
      WHEN date !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN '形式'
      WHEN substr(date, 1, 4)::int < 1 THEN '年'
      WHEN substr(date, 6, 2)::int NOT BETWEEN 1 AND 12 THEN '月'
      WHEN substr(date, 9, 2)::int NOT BETWEEN 1 AND
           extract(day FROM make_date(substr(date, 1, 4)::int, substr(date, 6, 2)::int, 1)
                            + interval '1 month - 1 day')::int THEN '日'
    END AS date_problem,
    CASE
      WHEN start_time IS NULL THEN 'NULL'
      WHEN start_time = '' THEN '空文字'
      WHEN start_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN NULL
      WHEN start_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$' THEN '秒あり'
      ELSE '形式・範囲外'
    END AS start_problem,
    CASE
      WHEN end_time IS NULL THEN 'NULL'
      WHEN end_time = '' THEN '空文字'
      WHEN end_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN NULL
      WHEN end_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$' THEN '秒あり'
      ELSE '形式・範囲外'
    END AS end_problem
  FROM public.kintai
)
SELECT p.name, k.user_id, k.id, k.date, k.start_time, k.end_time, k.break_min, k.work_min,
  CASE WHEN k.memo IS NULL THEN 'NULL'
       WHEN k.memo = '' THEN '空文字'
       WHEN btrim(k.memo, E' \t\r\n　') = '' THEN '空白のみ'
       ELSE 'あり' END AS memo_state,
  concat_ws(', ',
    CASE WHEN k.user_id IS NULL        THEN 'user_id NULL' END,
    CASE WHEN k.date_problem  IS NOT NULL THEN 'date: '       || k.date_problem  END,
    CASE WHEN k.start_problem IS NOT NULL THEN 'start_time: ' || k.start_problem END,
    CASE WHEN k.end_problem   IS NOT NULL THEN 'end_time: '   || k.end_problem   END,
    CASE WHEN k.break_min IS NULL      THEN 'break_min NULL' END,
    CASE WHEN k.work_min  IS NULL      THEN 'work_min NULL' END,
    CASE WHEN k.memo IS NULL OR btrim(k.memo, E' \t\r\n　') = '' THEN 'memo 空' END,
    CASE WHEN k.break_min < 0 OR k.work_min < 0 THEN '負の値' END,
    CASE WHEN k.break_min > 1440 OR k.work_min > 1440 THEN '24時間超' END
  ) AS problem
FROM k
LEFT JOIN public.profiles p ON p.id = k.user_id
WHERE k.user_id IS NULL
   OR k.date_problem IS NOT NULL OR k.start_problem IS NOT NULL OR k.end_problem IS NOT NULL
   OR k.break_min IS NULL OR k.work_min IS NULL
   OR k.memo IS NULL OR btrim(k.memo, E' \t\r\n　') = ''
   OR k.break_min < 0 OR k.work_min < 0
   OR k.break_min > 1440 OR k.work_min > 1440
ORDER BY k.date, k.id
LIMIT 200;


-- ============================================================
-- P3. テーブル単位の権限（ロール別にまとめて表示）
--   kintai・profiles と、kintai の id 用シーケンス
--   2026-11-16 の結果（schema_check.sql ⑨）:
--     kintai   anon / authenticated … DELETE, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE
--     profiles anon / authenticated … 上記 + INSERT, UPDATE
-- ============================================================
SELECT c.relname AS object_name,
  CASE c.relkind WHEN 'r' THEN 'table' WHEN 'S' THEN 'sequence' END AS kind,
  CASE g.grantee WHEN 0 THEN 'PUBLIC' ELSE g.grantee::regrole::text END AS grantee,
  string_agg(g.privilege_type, ', ' ORDER BY g.privilege_type) AS privileges
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL aclexplode(coalesce(c.relacl, acldefault(
  CASE c.relkind WHEN 'S' THEN 's' ELSE 'r' END::"char", c.relowner))) g
WHERE n.nspname = 'public'
  AND (c.relname IN ('kintai', 'profiles')
       OR c.oid = pg_get_serial_sequence('public.kintai', 'id')::regclass)
GROUP BY c.relname, c.relkind, g.grantee
ORDER BY 1, 3;


-- ============================================================
-- P4. 列ごとの権限（ロール・権限別にまとめて表示。0 行なら列ごとの権限はなし）
--   2026-11-16 の結果（schema_check.sql ⑩）:
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
-- P5. 既存のスキーマ一覧（制約用の関数を置くスキーマ名が既にあるかの確認）
--   pg_ と information_schema は除く
-- ============================================================
SELECT nspname AS schema_name, pg_get_userbyid(nspowner) AS owner
FROM pg_namespace
WHERE nspname NOT LIKE 'pg\_%' AND nspname <> 'information_schema'
ORDER BY 1;
