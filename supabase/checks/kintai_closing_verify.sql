-- ============================================================
-- 20261119_kintai_closing.sql の実行後の確認 SQL
--
-- ※ 2026-11-19 に本人による取り下げをなくした（20261119_kintai_closing_no_withdraw.sql）。
--   この確認 SQL も取り下げのない仕様に直した（取り下げの関数がないことは S1、
--   提出後に本人が直せず、管理者の差し戻しで直せることは S6 で確かめる）。
--   20261119_kintai_closing_no_withdraw.sql を実行する前に流すと、S1・S6 などが NG になる。
--
-- ※ S4 は「2026年11月中に実行する」前提の項目がある（本物の11月分がまだ締められないことの確認）。
--   2026年12月1日（日本時間）以降に実行すると、S4 の「2026年11月分」の結果は too_early ではなくなる
--   （本人の11月の勤怠の内容によって、no_rows・empty_memo・already になったり、提出が通ったりする。
--     どの場合もテストのブロックごと取り消すので、本番のデータは変わらない）。
--   12月以降は、S4 のその1件だけが NG になるのが正しい。
--
-- 使い方:
--   Supabase Dashboard > SQL Editor に、このファイル全体を貼って 1 回実行する
--   （DROP → CREATE TEMP → DO → SELECT の 4 文で 1 組。最後の SELECT の結果が表で出る）。
--   期待値: 判定の列がすべて OK（先頭の「まとめ」行は NG の件数 0）
--
-- 本番のデータを残さないための作り（kintai_work_min_cleanup_2_verify.sql と同じ）:
--   ・動作テスト（S2〜S9）は 1 件ずつ、DO ブロックの中の BEGIN〜EXCEPTION のブロックで動かし、
--     ブロックの最後で必ずエラーを出してそのブロックを取り消す（ROLLBACK TO SAVEPOINT と同じ動き）。
--     テストがエラーで止まった場合も、同じくブロックごと取り消される。
--     取り消した後も、結果の文字は変数に残るので表に出せる
--   ・1 件のテストは「SQL の手順の並び」で書き、最後の手順の結果（文字）を「結果」に出す
--   ・結果は一時テーブル（pg_temp.closing_result）に入れる。接続が切れると消える
--   ・最後に S0 として、テスト用の行（2099年の勤怠・締め・履歴）が 0 件で、
--     本人の profiles の単価が実行前と同じであることを確かめる
--
-- テストの人と月:
--   本人   … auth.users の一番古いユーザー
--   管理者 … auth.users の 2 番目に古いユーザー（本人とは別の人。JWT に app_metadata.role = 'admin' を入れる）
--            ※ auth.users に 2 人以上いないと実行できない
--   月     … 2099年1月（一部 2099年2月）。本体の関数（private）には「今日」を 2099-02-01 として渡す
--   単価   … テストのブロックの中で本人の profiles.inv_rate を 1500 などに書き換える（取り消すので残らない）
--   勤怠   … 2099-01-05 に 09:00〜18:00 休憩60（480分）と 19:00〜02:00 休憩0（420分。日またぎ）、
--            2099-01-06 に 09:00〜17:30 休憩60（450分）→ 勤務日数 2・行数 3・合計 1350 分
--            単価 1500 円なら金額 1350 × 1500 ÷ 60 = 33750 円
--   本人・管理者として動かすときは、request.jwt.claims を入れて SET LOCAL ROLE authenticated にする
--   （RLS・権限が画面と同じに効く）。ブロックを取り消すと postgres に戻る
--
-- 結果の見方:
--   submitted / approved / returned … 締めの状態
--   数字                 … 件数・勤務時間（分）など
--   55000:名前 など       … エラーで止まった（名前はメッセージの括弧内。画面が見分けに使う）
--   42883:* / 42501:*    … エラーの番号だけを比べる項目（関数がない・権限がない。
--                          PostgreSQL が出す文言は環境で形が変わるため）
--   true / false         … 定義・権限の確認
--
-- 確認する項目:
--   S1  定義・権限（テーブル・RLS・制約・ポリシー・権限・関数・トリガー。取り下げの関数がないこと）
--   S2  提出の成功（勤務日数は日付の重複を除く・前後に空白がある memo は締められる）
--   S3  提出のエラー（月の指定・翌月1日より前・0件・空の memo・二重提出）
--   S4  画面から呼ぶ形の提出（本物の 2026年11月分はまだ締められない・ログインしていない）
--   S5  締めた月の kintai を止める（追加・編集・日付の移動・削除・取り込み）。
--       Slack 報告の印だけの更新・別の月は通る。SQL Editor（postgres）も止まる
--   S6  提出後は本人が取り消せない（取り下げの関数がない・締めの行を書き換えられない）。
--       管理者が差し戻すと、本人が追加・再提出できる
--   S7  承認（管理者だけ・自分の締めは不可・単価なし・金額の切り捨て・承認後も止まる）
--   S8  差し戻し（管理者だけ・自分の締めは不可・承認済からも可・その後は編集と再提出ができる）
--   S9  履歴
--   S10 同時実行の対策（1 つの接続では同時に動かせないため、関数の定義に advisory lock があることだけ確かめる）
--   S0  テスト用の行が残っていない
-- ============================================================

DROP TABLE IF EXISTS pg_temp.closing_result;
CREATE TEMP TABLE closing_result (
  seq    integer,
  item   text,
  label  text,
  expect text,
  got    text
);

DO $$
DECLARE
  v_uid         uuid;
  v_admin       uuid;
  v_rate_before text;
  v_got         text;
  v_steps       text[];
  v_n           integer;
  v_seq         integer := 0;
  v_case        record;      -- テスト 1 件（SQL のテーブルの別名 c とぶつからない名前にする）
  c_marker      constant text := 'closing verify test';

  -- よく使う手順（{uid} = 本人、{admin} = 管理者、{marker} = テスト用の作業内容 に置き換えて実行する）
  c_ins         constant text := $q$INSERT INTO public.kintai (date, start_time, end_time, break_min, memo, user_id) VALUES
                   ('2099-01-05', '09:00', '18:00', 60, '{marker}', '{uid}'),
                   ('2099-01-05', '19:00', '02:00',  0, '{marker}', '{uid}'),
                   ('2099-01-06', '09:00', '17:30', 60, '{marker}', '{uid}')$q$;
  c_ins_feb     constant text := $q$INSERT INTO public.kintai (date, start_time, end_time, break_min, memo, user_id) VALUES
                   ('2099-02-03', '09:00', '18:00', 60, '{marker}', '{uid}')$q$;
  c_ins_admin   constant text := $q$INSERT INTO public.kintai (date, start_time, end_time, break_min, memo, user_id) VALUES
                   ('2099-01-05', '09:00', '18:00', 60, '{marker}', '{admin}')$q$;
  c_submit      constant text := $q$SELECT private.kintai_closing_submit('{uid}', '2099-01-01', '{uid}', '2099-02-01')$q$;
  c_submit_adm  constant text := $q$SELECT private.kintai_closing_submit('{admin}', '2099-01-01', '{admin}', '2099-02-01')$q$;
  c_rate        constant text := $q$INSERT INTO public.profiles (id, name, inv_rate) VALUES ('{uid}', 'closing verify', 1500)
                   ON CONFLICT (id) DO UPDATE SET inv_rate = 1500$q$;
  c_rate_null   constant text := $q$INSERT INTO public.profiles (id, name, inv_rate) VALUES ('{uid}', 'closing verify', NULL)
                   ON CONFLICT (id) DO UPDATE SET inv_rate = NULL$q$;
  c_as_user     constant text := $q$SELECT set_config('request.jwt.claims', '{"sub":"{uid}","role":"authenticated"}', true)$q$;
  c_as_admin    constant text := $q$SELECT set_config('request.jwt.claims', '{"sub":"{admin}","role":"authenticated","app_metadata":{"role":"admin"}}', true)$q$;
  c_role        constant text := 'SET LOCAL ROLE authenticated';
  c_reset       constant text := 'RESET ROLE';
  c_approve     constant text := $q$SELECT public.approve_kintai_closing('{uid}', '2099-01-01')$q$;
  c_return      constant text := $q$SELECT public.return_kintai_closing('{uid}', '2099-01-01')$q$;
  c_withdraw    constant text := $q$SELECT public.withdraw_kintai_closing('2099-01-01'::date)::text$q$;   -- 2026-11-19 に消した関数（呼べないことの確認用）
  c_status      constant text := $q$SELECT status FROM public.kintai_closing WHERE user_id = '{uid}' AND month = '2099-01-01'$q$;
  c_ins_jan10   constant text := $q$INSERT INTO public.kintai (date, start_time, end_time, break_min, memo, user_id) VALUES
                   ('2099-01-10', '09:00', '18:00', 60, '{marker}', '{uid}') RETURNING work_min::text$q$;
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at, id LIMIT 1;
  SELECT id INTO v_admin FROM auth.users WHERE id <> v_uid ORDER BY created_at, id LIMIT 1;
  IF v_uid IS NULL OR v_admin IS NULL THEN
    RAISE EXCEPTION 'auth.users に 2 人以上いないため確認できません（本人と管理者役に別の人が必要）';
  END IF;
  SELECT coalesce((SELECT coalesce(p.inv_rate::text, 'null') FROM public.profiles p WHERE p.id = v_uid), '（行なし）')
    INTO v_rate_before;

  -- ---------- S1・S10 定義・権限（読み取りのみ） ----------
  INSERT INTO pg_temp.closing_result
  SELECT v_seq + n, item, label, expect, coalesce(got, 'null')
  FROM (VALUES
    (1, 'S1', 'テーブルが 2 つあり、どちらも RLS が有効', 'true',
        (SELECT (count(*) = 2 AND bool_and(c.relrowsecurity))::text FROM pg_class c
          WHERE c.oid IN (to_regclass('public.kintai_closing'), to_regclass('public.kintai_closing_log')))),
    (2, 'S1', '締めテーブルの制約（主キー・一意・CHECK・外部キー。名前順）',
        'kintai_closing_approved_chk,kintai_closing_counts_chk,kintai_closing_month_chk,kintai_closing_pkey,kintai_closing_status_chk,kintai_closing_user_id_fkey,kintai_closing_user_month_key',
        (SELECT string_agg(conname::text, ',' ORDER BY conname) FROM pg_constraint
          WHERE conrelid = 'public.kintai_closing'::regclass AND contype IN ('p', 'u', 'c', 'f'))),
    (3, 'S1', 'ポリシー（締めは SELECT の 1 件だけ、履歴は 0 件）', 'kintai_closing:SELECT',
        (SELECT string_agg(tablename || ':' || cmd, ',' ORDER BY tablename, policyname) FROM pg_policies
          WHERE schemaname = 'public' AND tablename IN ('kintai_closing', 'kintai_closing_log'))),
    (4, 'S1', '締め：authenticated は SELECT だけ', 'true',
        (has_table_privilege('authenticated', 'public.kintai_closing', 'SELECT')
         AND NOT has_table_privilege('authenticated', 'public.kintai_closing',
               'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER'))::text),
    (5, 'S1', '履歴：authenticated は権限なし', 'true',
        (NOT has_table_privilege('authenticated', 'public.kintai_closing_log',
               'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER'))::text),
    (6, 'S1', '締め・履歴：anon は権限なし', 'true',
        (NOT has_table_privilege('anon', 'public.kintai_closing',
               'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
         AND NOT has_table_privilege('anon', 'public.kintai_closing_log',
               'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER'))::text),
    (7, 'S1', '自動採番：anon・authenticated は権限なし', 'true',
        (NOT has_sequence_privilege('anon',          'public.kintai_closing_id_seq',     'USAGE, SELECT, UPDATE')
         AND NOT has_sequence_privilege('authenticated', 'public.kintai_closing_id_seq',     'USAGE, SELECT, UPDATE')
         AND NOT has_sequence_privilege('anon',          'public.kintai_closing_log_id_seq', 'USAGE, SELECT, UPDATE')
         AND NOT has_sequence_privilege('authenticated', 'public.kintai_closing_log_id_seq', 'USAGE, SELECT, UPDATE'))::text),
    (8, 'S1', '締め・履歴・自動採番：PUBLIC の権限なし', 'true',
        (NOT EXISTS (SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) g
                      WHERE c.oid IN ('public.kintai_closing'::regclass, 'public.kintai_closing_log'::regclass,
                                      'public.kintai_closing_id_seq'::regclass, 'public.kintai_closing_log_id_seq'::regclass)
                        AND g.grantee = 0))::text),
    (9, 'S1', '画面から呼ぶ関数 3 つ：SECURITY DEFINER・search_path・authenticated だけ実行できる', '3',
        (SELECT count(*)::text FROM pg_proc p
          WHERE p.oid IN (to_regprocedure('public.submit_kintai_closing(date)'),
                          to_regprocedure('public.approve_kintai_closing(uuid, date)'),
                          to_regprocedure('public.return_kintai_closing(uuid, date)'))
            AND p.prosecdef AND p.proconfig = ARRAY['search_path=""']
            AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
            AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
            AND p.proacl IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) g WHERE g.grantee = 0))),
    (10, 'S1', 'private の関数 6 つ：search_path・PUBLIC・anon・authenticated は実行できない', '6',
        (SELECT count(*)::text FROM pg_proc p
          WHERE p.oid IN (to_regprocedure('private.kintai_closing_lock_key(uuid, date)'),
                          to_regprocedure('private.kintai_month_is_closed(uuid, text)'),
                          to_regprocedure('private.kintai_assert_month_open(uuid, text)'),
                          to_regprocedure('private.kintai_closing_submit(uuid, date, uuid, date)'),
                          to_regprocedure('private.kintai_closing_approve(uuid, date, uuid)'),
                          to_regprocedure('private.kintai_closing_return(uuid, date, uuid)'))
            AND p.proconfig = ARRAY['search_path=""']
            AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
            AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
            AND p.proacl IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) g WHERE g.grantee = 0))),
    (11, 'S1', 'private の関数のうち SECURITY DEFINER は 5 つ（鍵を作る関数以外）', '5',
        (SELECT count(*)::text FROM pg_proc p
          WHERE p.pronamespace = 'private'::regnamespace AND p.prosecdef
            AND p.proname IN ('kintai_closing_lock_key', 'kintai_month_is_closed', 'kintai_assert_month_open',
                              'kintai_closing_submit', 'kintai_closing_approve', 'kintai_closing_return'))),
    (12, 'S1', 'トリガー関数：SECURITY DEFINER・PUBLIC・anon・authenticated は実行できない', 'true',
        (SELECT (p.prosecdef AND p.proconfig = ARRAY['search_path=""']
                 AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
                 AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
                 AND p.proacl IS NOT NULL
                 AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) g WHERE g.grantee = 0))::text
           FROM pg_proc p WHERE p.oid = to_regprocedure('public.kintai_block_closed_month()'))),
    (13, 'S1', 'トリガー kintai_block_closed_month：有効・BEFORE・行ごと・INSERT/UPDATE/DELETE', 'true',
        -- tgtype のビット: 1 = ROW, 2 = BEFORE, 4 = INSERT, 8 = DELETE, 16 = UPDATE
        (SELECT (t.tgenabled = 'O' AND (t.tgtype & 31) = 31 AND t.tgattr::text = ''
                 AND t.tgfoid = to_regprocedure('public.kintai_block_closed_month()'))::text
           FROM pg_trigger t
          WHERE t.tgrelid = 'public.kintai'::regclass AND t.tgname = 'kintai_block_closed_month')),
    (14, 'S1', 'kintai の BEFORE トリガー（名前順に動く。締めの確認が勤務時間の計算より先）',
        'kintai_block_closed_month,kintai_compute_work_min,kintai_reset_slack_reported',
        (SELECT string_agg(t.tgname::text, ',' ORDER BY t.tgname) FROM pg_trigger t
          WHERE t.tgrelid = 'public.kintai'::regclass AND NOT t.tgisinternal AND (t.tgtype & 2) = 2)),
    (15, 'S10', '提出・承認・差し戻しの本体に排他の advisory lock がある', '3',
        (SELECT count(*)::text FROM pg_proc p
          WHERE p.oid IN (to_regprocedure('private.kintai_closing_submit(uuid, date, uuid, date)'),
                          to_regprocedure('private.kintai_closing_approve(uuid, date, uuid)'),
                          to_regprocedure('private.kintai_closing_return(uuid, date, uuid)'))
            AND position('pg_advisory_xact_lock(private.kintai_closing_lock_key(' IN pg_get_functiondef(p.oid)) > 0)),
    (16, 'S10', 'トリガーが使う関数に共有の advisory lock がある', 'true',
        (SELECT (position('pg_advisory_xact_lock_shared(private.kintai_closing_lock_key(' IN pg_get_functiondef(p.oid)) > 0)::text
           FROM pg_proc p WHERE p.oid = to_regprocedure('private.kintai_assert_month_open(uuid, text)'))),
    (17, 'S1', '取り下げの関数がない（2026-11-19 になくした。public・private を名前で数える）', '0',
        (SELECT count(*)::text FROM pg_proc p
          WHERE p.pronamespace IN ('public'::regnamespace, 'private'::regnamespace)
            AND p.proname IN ('withdraw_kintai_closing', 'kintai_closing_withdraw')))
  ) AS v(n, item, label, expect, got);
  v_seq := v_seq + 17;

  -- ---------- S2〜S9 動作テスト（1 件ずつ取り消す） ----------
  FOR v_case IN
    SELECT * FROM (VALUES
      -- S2 提出の成功
      ('S2', '提出：同じ日に2行・別の日に1行 → 状態・勤務日数・行数・合計（分）',
       ARRAY[c_ins, c_submit,
             $q$SELECT status || ' ' || work_days || ' ' || row_count || ' ' || total_work_min
                FROM public.kintai_closing WHERE user_id = '{uid}' AND month = '2099-01-01'$q$],
       'submitted 2 3 1350'),
      ('S2', '提出：作業内容の前後に全角スペース・改行があっても、中身があれば締められる',
       ARRAY[c_ins,
             $q$INSERT INTO public.kintai (date, start_time, end_time, break_min, memo, user_id)
                VALUES ('2099-01-07', '09:00', '18:00', 60, chr(12288) || '作業' || chr(10), '{uid}')$q$,
             c_submit, c_status],
       'submitted'),

      -- S3 提出のエラー（本体の関数を直接呼ぶ）
      ('S3', '2026年10月分は締められない',
       ARRAY[c_ins, $q$SELECT private.kintai_closing_submit('{uid}', '2026-10-01', '{uid}', '2026-11-01')::text$q$],
       '22023:kintai_closing_month_invalid'),
      ('S3', '月の指定が1日でない（2099-01-02）',
       ARRAY[c_ins, $q$SELECT private.kintai_closing_submit('{uid}', '2099-01-02', '{uid}', '2099-02-01')::text$q$],
       '22023:kintai_closing_month_invalid'),
      ('S3', '翌月1日より前（今日 = 2099-01-31）',
       ARRAY[c_ins, $q$SELECT private.kintai_closing_submit('{uid}', '2099-01-01', '{uid}', '2099-01-31')::text$q$],
       '55000:kintai_closing_too_early'),
      ('S3', '勤怠が0件',
       ARRAY[c_submit],
       '55000:kintai_closing_no_rows'),
      ('S3', '勤怠が別の月（2099年2月）にしかない',
       ARRAY[c_ins_feb, c_submit],
       '55000:kintai_closing_no_rows'),
      ('S3', '作業内容が空文字の行がある',
       ARRAY[c_ins, $q$INSERT INTO public.kintai (date, start_time, end_time, break_min, memo, user_id)
                       VALUES ('2099-01-07', '09:00', '18:00', 60, '', '{uid}')$q$, c_submit],
       '55000:kintai_closing_empty_memo'),
      ('S3', '作業内容が半角スペースだけの行がある',
       ARRAY[c_ins, $q$INSERT INTO public.kintai (date, start_time, end_time, break_min, memo, user_id)
                       VALUES ('2099-01-07', '09:00', '18:00', 60, '   ', '{uid}')$q$, c_submit],
       '55000:kintai_closing_empty_memo'),
      ('S3', '作業内容が全角スペースだけの行がある',
       ARRAY[c_ins, $q$INSERT INTO public.kintai (date, start_time, end_time, break_min, memo, user_id)
                       VALUES ('2099-01-07', '09:00', '18:00', 60, chr(12288) || chr(12288), '{uid}')$q$, c_submit],
       '55000:kintai_closing_empty_memo'),
      ('S3', '作業内容が改行・タブだけの行がある',
       ARRAY[c_ins, $q$INSERT INTO public.kintai (date, start_time, end_time, break_min, memo, user_id)
                       VALUES ('2099-01-07', '09:00', '18:00', 60, chr(10) || chr(13) || chr(9), '{uid}')$q$, c_submit],
       '55000:kintai_closing_empty_memo'),
      ('S3', '作業内容がノーブレークスペースだけの行がある',
       ARRAY[c_ins, $q$INSERT INTO public.kintai (date, start_time, end_time, break_min, memo, user_id)
                       VALUES ('2099-01-07', '09:00', '18:00', 60, chr(160), '{uid}')$q$, c_submit],
       '55000:kintai_closing_empty_memo'),
      ('S3', '二重提出',
       ARRAY[c_ins, c_submit, c_submit],
       '55000:kintai_closing_already'),

      -- S4 画面から呼ぶ形の提出（本人として）
      ('S4', '本物の2026年11月分は、11月中はまだ締められない（※12月以降に実行するとこの1件は変わる）',
       ARRAY[c_as_user, c_role, $q$SELECT (public.submit_kintai_closing('2026-11-01')).status$q$],
       '55000:kintai_closing_too_early'),
      ('S4', '2026年10月分は締められない',
       ARRAY[c_as_user, c_role, $q$SELECT (public.submit_kintai_closing('2026-10-01')).status$q$],
       '22023:kintai_closing_month_invalid'),
      ('S4', '2099年1月分は今日の日付では締められない',
       ARRAY[c_ins, c_as_user, c_role, $q$SELECT (public.submit_kintai_closing('2099-01-01')).status$q$],
       '55000:kintai_closing_too_early'),
      ('S4', 'ログインしていない（JWT に sub がない）',
       ARRAY[$q$SELECT set_config('request.jwt.claims', '{"role":"authenticated"}', true)$q$, c_role,
             $q$SELECT (public.submit_kintai_closing('2099-01-01')).status$q$],
       '42501:ログインしていません。再ログインしてください'),

      -- S5 締めた月の kintai を止める（提出の後、本人として）
      ('S5', '締めた月に追加',
       ARRAY[c_ins, c_submit, c_as_user, c_role, c_ins_jan10],
       '55000:kintai_month_closed'),
      ('S5', '締めた月の行の内容を編集',
       ARRAY[c_ins, c_submit, c_as_user, c_role,
             $q$UPDATE public.kintai SET start_time = '10:00' WHERE user_id = '{uid}' AND date = '2099-01-06' RETURNING work_min::text$q$],
       '55000:kintai_month_closed'),
      ('S5', '締めた月の行の日付を別の月へ移す（2099-01-06 → 2099-02-06）',
       ARRAY[c_ins, c_submit, c_as_user, c_role,
             $q$UPDATE public.kintai SET date = '2099-02-06' WHERE user_id = '{uid}' AND date = '2099-01-06' RETURNING date$q$],
       '55000:kintai_month_closed'),
      ('S5', '別の月の行の日付を締めた月へ移す（2099-02-03 → 2099-01-07）',
       ARRAY[c_ins, c_ins_feb, c_submit, c_as_user, c_role,
             $q$UPDATE public.kintai SET date = '2099-01-07' WHERE user_id = '{uid}' AND date = '2099-02-03' RETURNING date$q$],
       '55000:kintai_month_closed'),
      ('S5', '締めた月の行を削除',
       ARRAY[c_ins, c_submit, c_as_user, c_role,
             $q$DELETE FROM public.kintai WHERE user_id = '{uid}' AND date = '2099-01-06' RETURNING date$q$],
       '55000:kintai_month_closed'),
      ('S5', 'カレンダー取り込みに締めた月の日付が入っている',
       ARRAY[c_ins, c_submit, c_as_user, c_role,
             $q$SELECT public.import_kintai_rows('[{"date":"2099-01-08","start_time":"09:00","end_time":"18:00","break_min":60,"memo":"{marker}"}]'::jsonb)::text$q$],
       '55000:kintai_month_closed'),
      ('S5', 'カレンダー取り込みに締めた月と別の月が混ざっている（全体が止まる）',
       ARRAY[c_ins, c_submit, c_as_user, c_role,
             $q$SELECT public.import_kintai_rows('[{"date":"2099-02-08","start_time":"09:00","end_time":"18:00","break_min":60,"memo":"{marker}"},{"date":"2099-01-08","start_time":"09:00","end_time":"18:00","break_min":60,"memo":"{marker}"}]'::jsonb)::text$q$],
       '55000:kintai_month_closed'),
      ('S5', '（通る）カレンダー取り込みが別の月（2099年2月）だけなら取り込める（件数）',
       ARRAY[c_ins, c_submit, c_as_user, c_role,
             $q$SELECT public.import_kintai_rows('[{"date":"2099-02-08","start_time":"09:00","end_time":"18:00","break_min":60,"memo":"{marker}"}]'::jsonb)::text$q$],
       '1'),
      ('S5', '（通る）別の月（2099年2月）への追加（work_min）',
       ARRAY[c_ins, c_submit, c_as_user, c_role,
             $q$INSERT INTO public.kintai (date, start_time, end_time, break_min, memo, user_id)
                VALUES ('2099-02-09', '09:00', '18:00', 60, '{marker}', '{uid}') RETURNING work_min::text$q$],
       '480'),
      ('S5', '（通る）Slack 報告の印（slack_reported_at）だけの更新（印の付いた行数）',
       ARRAY[c_ins, c_submit,
             $q$UPDATE public.kintai SET slack_reported_at = now() WHERE user_id = '{uid}' AND date = '2099-01-06'$q$,
             $q$SELECT count(*)::text FROM public.kintai
                 WHERE user_id = '{uid}' AND date = '2099-01-06' AND slack_reported_at IS NOT NULL$q$],
       '1'),
      ('S5', 'SQL Editor（postgres）からの編集も止まる（抜け道なし）',
       ARRAY[c_ins, c_submit,
             $q$UPDATE public.kintai SET memo = 'x' WHERE user_id = '{uid}' AND date = '2099-01-06' RETURNING memo$q$],
       '55000:kintai_month_closed'),

      -- S6 提出後は本人が取り消せない。管理者の差し戻しで直せる（2026-11-19 に取り下げをなくした）
      ('S6', '本人は取り下げを呼べない（関数がない）',
       ARRAY[c_ins, c_submit, c_as_user, c_role, c_withdraw],
       '42883:*'),   -- 関数がない（文言は環境で変わるので番号だけ見る）
      ('S6', '本人は締めの行を直接書き換えられない',
       ARRAY[c_ins, c_submit, c_as_user, c_role,
             $q$UPDATE public.kintai_closing SET status = 'returned' WHERE user_id = '{uid}' AND month = '2099-01-01' RETURNING status$q$],
       '42501:*'),   -- 権限がない（文言は環境で変わるので番号だけ見る）
      ('S6', '提出済 → 管理者が差し戻し → 本人が追加できる（work_min）',
       ARRAY[c_ins, c_submit, c_as_admin, c_role, c_return, c_reset, c_as_user, c_role, c_ins_jan10],
       '480'),
      ('S6', '提出済 → 管理者が差し戻し → 再提出できる',
       ARRAY[c_ins, c_submit, c_as_admin, c_role, c_return, c_reset, c_submit, c_status],
       'submitted'),

      -- S7 承認
      ('S7', '管理者でない（本人）は承認できない',
       ARRAY[c_ins, c_rate, c_submit, c_as_user, c_role, c_approve],
       '42501:kintai_closing_admin_only'),
      ('S7', '管理者は自分の締めを承認できない',
       ARRAY[c_ins_admin, c_submit_adm, c_as_admin, c_role,
             $q$SELECT public.approve_kintai_closing('{admin}', '2099-01-01')$q$],
       '42501:kintai_closing_self_operation'),
      ('S7', '単価が NULL なら承認できない',
       ARRAY[c_ins, c_rate_null, c_submit, c_as_admin, c_role, c_approve],
       '55000:kintai_closing_no_rate'),
      ('S7', '承認：状態・単価・金額・勤務日数・行数・合計・承認した人',
       ARRAY[c_ins, c_rate, c_submit, c_as_admin, c_role,
             $q$SELECT r.status || ' ' || r.rate || ' ' || r.amount || ' ' || r.work_days || ' '
                       || r.row_count || ' ' || r.total_work_min || ' ' || (r.approved_by = '{admin}')::text
                FROM public.approve_kintai_closing('{uid}', '2099-01-01') r$q$],
       'approved 1500 33750 2 3 1350 true'),
      ('S7', '金額は切り捨て（単価 1001 円 → 1350 × 1001 ÷ 60 = 22522.5）',
       ARRAY[c_ins,
             $q$INSERT INTO public.profiles (id, name, inv_rate) VALUES ('{uid}', 'closing verify', 1001)
                ON CONFLICT (id) DO UPDATE SET inv_rate = 1001$q$,
             c_submit, c_as_admin, c_role,
             $q$SELECT r.amount::text FROM public.approve_kintai_closing('{uid}', '2099-01-01') r$q$],
       '22522'),
      ('S7', '提出されていない月は承認できない',
       ARRAY[c_as_admin, c_role, c_approve],
       '55000:kintai_closing_bad_status'),
      ('S7', '承認済をもう一度承認できない',
       ARRAY[c_ins, c_rate, c_submit, c_as_admin, c_role, c_approve, c_approve],
       '55000:kintai_closing_bad_status'),
      ('S7', '承認の後も、本人はその月に追加できない',
       ARRAY[c_ins, c_rate, c_submit, c_as_admin, c_role, c_approve, c_reset, c_as_user, c_role, c_ins_jan10],
       '55000:kintai_month_closed'),

      -- S8 差し戻し
      ('S8', '管理者でない（本人）は差し戻しできない',
       ARRAY[c_ins, c_submit, c_as_user, c_role, c_return],
       '42501:kintai_closing_admin_only'),
      ('S8', '管理者は自分の締めを差し戻しできない',
       ARRAY[c_ins_admin, c_submit_adm, c_as_admin, c_role,
             $q$SELECT public.return_kintai_closing('{admin}', '2099-01-01')$q$],
       '42501:kintai_closing_self_operation'),
      ('S8', '提出済 → 差し戻し',
       ARRAY[c_ins, c_submit, c_as_admin, c_role, $q$SELECT (public.return_kintai_closing('{uid}', '2099-01-01')).status$q$],
       'returned'),
      ('S8', '承認済 → 差し戻し（状態・単価・金額・承認日時が空・差し戻した人）',
       ARRAY[c_ins, c_rate, c_submit, c_as_admin, c_role, c_approve,
             $q$SELECT r.status || ' ' || coalesce(r.rate::text, 'null') || ' ' || coalesce(r.amount::text, 'null')
                       || ' ' || (r.approved_at IS NULL)::text || ' ' || (r.returned_by = '{admin}')::text
                FROM public.return_kintai_closing('{uid}', '2099-01-01') r$q$],
       'returned null null true true'),
      ('S8', '差し戻しの後は、本人が編集してから再提出できる',
       ARRAY[c_ins, c_rate, c_submit, c_as_admin, c_role, c_approve, c_return, c_reset,
             c_as_user, c_role,
             $q$UPDATE public.kintai SET start_time = '10:00' WHERE user_id = '{uid}' AND date = '2099-01-06'$q$,
             c_reset, c_submit,
             $q$SELECT status || ' ' || total_work_min FROM public.kintai_closing
                 WHERE user_id = '{uid}' AND month = '2099-01-01'$q$],
       'submitted 1290'),
      ('S8', '差し戻し済の締めをもう一度差し戻しできない',
       ARRAY[c_ins, c_submit, c_as_admin, c_role, c_return, c_return],
       '55000:kintai_closing_bad_status'),

      -- S9 履歴（提出 → 承認 → 差し戻し → 再提出 → 差し戻し）
      ('S9', '履歴の操作と状態の変化（古い順）',
       ARRAY[c_ins, c_rate, c_submit, c_as_admin, c_role, c_approve, c_return, c_reset, c_submit,
             c_as_admin, c_role, c_return, c_reset,
             $q$SELECT string_agg(action || ':' || coalesce(from_status, '-') || '>' || to_status, ',' ORDER BY id)
                FROM public.kintai_closing_log WHERE user_id = '{uid}' AND month = '2099-01-01'$q$],
       'submit:->submitted,approve:submitted>approved,return:approved>returned,submit:returned>submitted,return:submitted>returned'),
      ('S9', '履歴の操作した人（古い順）',
       ARRAY[c_ins, c_rate, c_submit, c_as_admin, c_role, c_approve, c_return, c_reset, c_submit,
             c_as_admin, c_role, c_return, c_reset,
             $q$SELECT string_agg(action || ':' || CASE actor WHEN '{uid}' THEN '本人' WHEN '{admin}' THEN '管理者'
                                                          ELSE coalesce(actor::text, 'null') END, ',' ORDER BY id)
                FROM public.kintai_closing_log WHERE user_id = '{uid}' AND month = '2099-01-01'$q$],
       'submit:本人,approve:管理者,return:管理者,submit:本人,return:管理者'),
      ('S9', '承認の履歴に単価と金額が残る',
       ARRAY[c_ins, c_rate, c_submit, c_as_admin, c_role, c_approve, c_reset,
             $q$SELECT rate || ' ' || amount FROM public.kintai_closing_log
                 WHERE user_id = '{uid}' AND month = '2099-01-01' AND action = 'approve'$q$],
       '1500 33750'),
      ('S9', '本人（authenticated）は履歴を読めない',
       ARRAY[c_ins, c_submit, c_as_user, c_role,
             $q$SELECT count(*)::text FROM public.kintai_closing_log$q$],
       '42501:kintai_closing_log')   -- permission denied for table kintai_closing_log（表名だけを取り出して比べる）
    ) AS v(item, label, steps, expect)
  LOOP
    v_got := NULL;
    SELECT array_agg(replace(replace(replace(s, '{uid}', v_uid::text), '{admin}', v_admin::text), '{marker}', c_marker)
                     ORDER BY ord)
      INTO v_steps
    FROM unnest(v_case.steps) WITH ORDINALITY AS t(s, ord);
    v_n := array_length(v_steps, 1);

    BEGIN
      FOR i IN 1 .. v_n - 1 LOOP
        EXECUTE v_steps[i];
      END LOOP;
      EXECUTE v_steps[v_n] INTO v_got;
      v_got := coalesce(v_got, '（結果なし）');

      -- 必ずここでブロックを取り消す（テスト用の行を残さない。役割も postgres に戻る）
      RAISE EXCEPTION 'rollback this test' USING ERRCODE = 'TSTRB';
    EXCEPTION
      WHEN SQLSTATE 'TSTRB' THEN
        NULL;  -- 取り消し済み。v_got は残っている
      WHEN others THEN
        v_got := SQLSTATE || ':' ||
                 coalesce(substring(SQLERRM FROM '(kintai_(?:closing|month)_[a-z_]+)'), SQLERRM);
    END;

    v_seq := v_seq + 1;
    INSERT INTO pg_temp.closing_result VALUES (v_seq, v_case.item, v_case.label, v_case.expect, v_got);
  END LOOP;

  -- ---------- S0 テスト用の行が残っていない ----------
  INSERT INTO pg_temp.closing_result VALUES
    (v_seq + 1, 'S0', 'テスト用の勤怠（本人・管理者役の 2099年の行）の数', '0',
     (SELECT count(*)::text FROM public.kintai
       WHERE user_id IN (v_uid, v_admin) AND left(date, 4) = '2099')),
    (v_seq + 2, 'S0', 'テスト用の締め（2099年）の数', '0',
     (SELECT count(*)::text FROM public.kintai_closing WHERE month >= DATE '2099-01-01')),
    (v_seq + 3, 'S0', 'テスト用の履歴（2099年）の数', '0',
     (SELECT count(*)::text FROM public.kintai_closing_log WHERE month >= DATE '2099-01-01')),
    (v_seq + 4, 'S0', '本人の profiles の単価が実行前と同じ', v_rate_before,
     coalesce((SELECT coalesce(p.inv_rate::text, 'null') FROM public.profiles p WHERE p.id = v_uid), '（行なし）'));
END;
$$;

-- 結果（先頭の「まとめ」行で NG の件数を見る。期待値: 0）
WITH r AS (
  SELECT seq, item, label, expect, got,
         CASE WHEN got IS NOT DISTINCT FROM expect
                OR (right(expect, 2) = ':*' AND split_part(got, ':', 1) = split_part(expect, ':', 1))
              THEN 'OK' ELSE 'NG' END AS judge
  FROM pg_temp.closing_result
)
SELECT judge AS 判定, item AS 項目, label AS 内容, expect AS 期待, got AS 結果
FROM (
  SELECT 0 AS seq, CASE WHEN count(*) FILTER (WHERE judge = 'NG') = 0 THEN 'OK' ELSE 'NG' END AS judge,
         'まとめ' AS item, 'NG の件数' AS label, '0' AS expect,
         (count(*) FILTER (WHERE judge = 'NG'))::text AS got
  FROM r
  UNION ALL
  SELECT seq, judge, item, label, expect, got FROM r
) t
ORDER BY seq;
