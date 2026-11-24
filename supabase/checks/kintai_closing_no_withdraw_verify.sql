-- ============================================================
-- 20261119_kintai_closing_no_withdraw.sql（本人による取り下げをなくす）の実行後の確認 SQL
--
-- 使い方:
--   Supabase Dashboard > SQL Editor に、このファイル全体を貼って 1 回実行する
--   （DROP → CREATE TEMP → DO → SELECT の 4 文で 1 組。最後の SELECT の結果が表で出る）。
--   期待値: 判定の列がすべて OK（先頭の「まとめ」行は NG の件数 0）
--   締めの機能全体の確認は kintai_closing_verify.sql（こちらも続けて実行する）
--
-- 本番のデータを残さないための作り（kintai_closing_verify.sql と同じ）:
--   ・動作テスト（W5〜W8）は 1 件ずつ、DO ブロックの中の BEGIN〜EXCEPTION のブロックで動かし、
--     ブロックの最後で必ずエラーを出してそのブロックを取り消す
--   ・テストの人は auth.users の一番古いユーザー（本人）と 2 番目に古いユーザー（管理者役）、
--     月は 2099年1月。本体の関数（private）には「今日」を 2099-02-01 として渡す
--   ・テスト用アカウント（433697e1-99b3-4448-a38c-65025fcbb729）の 2026年11月分には書き込まない。
--     W9 で、その締めが「提出済」のまま残っていることを読むだけで確かめる
--     （承認・差し戻しの確認を進めた後に実行すると、W9 はその状態になるので NG になる）
--   ・最後に W0 として、テスト用の行（2099年の勤怠・締め・履歴）が 0 件で、
--     本人の profiles の単価が実行前と同じであることを確かめる
--
-- 結果の見方:
--   42883:*                         … 関数がない（取り下げを呼べない）
--   42501:*                         … 権限がない
--     （期待が「番号:*」の項目は、エラーの番号だけを比べる。PostgreSQL が出す文言は、
--       メッセージの中の名前の取り出し方や環境の言語で形が変わるため）
--   55000:名前 など                 … エラーで止まった（名前はメッセージの括弧内）
--
-- 確認する項目:
--   W1  取り下げの関数がない（public・private のどちらにも）
--   W2  提出・承認・差し戻しの関数と権限は残っている
--   W3  テーブルの決まり（状態 withdrawn・履歴の withdraw）は前のデータのために残っている
--   W5  取り下げを呼べない（本人・管理者・SQL Editor の本体）
--   W6  提出済の月は、本人には直す方法がない（締めの行の直接書き換え・勤怠の編集・再提出）
--   W7  管理者が差し戻すと、本人が直して再提出できる（提出済から・承認済から）
--   W8  前に取り下げた行（状態 withdrawn）からも再提出できる
--   W9  テスト用アカウントの 2026年11月分は提出済のまま（読むだけ）
--   W0  テスト用の行が残っていない
-- ============================================================

DROP TABLE IF EXISTS pg_temp.no_withdraw_result;
CREATE TEMP TABLE no_withdraw_result (
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
  c_marker      constant text := 'closing no withdraw verify test';
  c_test_user   constant uuid := '433697e1-99b3-4448-a38c-65025fcbb729';

  -- よく使う手順（{uid} = 本人、{admin} = 管理者、{marker} = テスト用の作業内容 に置き換えて実行する）
  c_ins         constant text := $q$INSERT INTO public.kintai (date, start_time, end_time, break_min, memo, user_id) VALUES
                   ('2099-01-05', '09:00', '18:00', 60, '{marker}', '{uid}'),
                   ('2099-01-05', '19:00', '02:00',  0, '{marker}', '{uid}'),
                   ('2099-01-06', '09:00', '17:30', 60, '{marker}', '{uid}')$q$;
  c_submit      constant text := $q$SELECT private.kintai_closing_submit('{uid}', '2099-01-01', '{uid}', '2099-02-01')$q$;
  c_rate        constant text := $q$INSERT INTO public.profiles (id, name, inv_rate) VALUES ('{uid}', 'closing verify', 1500)
                   ON CONFLICT (id) DO UPDATE SET inv_rate = 1500$q$;
  c_as_user     constant text := $q$SELECT set_config('request.jwt.claims', '{"sub":"{uid}","role":"authenticated"}', true)$q$;
  c_as_admin    constant text := $q$SELECT set_config('request.jwt.claims', '{"sub":"{admin}","role":"authenticated","app_metadata":{"role":"admin"}}', true)$q$;
  c_role        constant text := 'SET LOCAL ROLE authenticated';
  c_reset       constant text := 'RESET ROLE';
  c_approve     constant text := $q$SELECT public.approve_kintai_closing('{uid}', '2099-01-01')$q$;
  c_return      constant text := $q$SELECT public.return_kintai_closing('{uid}', '2099-01-01')$q$;
  c_withdraw    constant text := $q$SELECT public.withdraw_kintai_closing('2099-01-01'::date)::text$q$;
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

  -- ---------- W1〜W3 定義・権限（読み取りのみ） ----------
  INSERT INTO pg_temp.no_withdraw_result
  SELECT v_seq + n, item, label, expect, coalesce(got, 'null')
  FROM (VALUES
    (1, 'W1', 'public・private に取り下げの関数がない（名前で数える。引数の違う同名の関数も含む）', '0',
        (SELECT count(*)::text FROM pg_proc p
          WHERE p.pronamespace IN ('public'::regnamespace, 'private'::regnamespace)
            AND p.proname IN ('withdraw_kintai_closing', 'kintai_closing_withdraw'))),
    (2, 'W1', 'ほかの関数の中で取り下げの関数を呼んでいない', '0',
        (SELECT count(*)::text FROM pg_proc p
          WHERE p.pronamespace IN ('public'::regnamespace, 'private'::regnamespace)
            AND p.prosrc LIKE '%kintai_closing_withdraw%')),
    (3, 'W2', '画面から呼ぶ関数 3 つ（提出・承認・差し戻し）：SECURITY DEFINER・search_path・authenticated だけ実行できる', '3',
        (SELECT count(*)::text FROM pg_proc p
          WHERE p.oid IN (to_regprocedure('public.submit_kintai_closing(date)'),
                          to_regprocedure('public.approve_kintai_closing(uuid, date)'),
                          to_regprocedure('public.return_kintai_closing(uuid, date)'))
            AND p.prosecdef AND p.proconfig = ARRAY['search_path=""']
            AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
            AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
            AND p.proacl IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) g WHERE g.grantee = 0))),
    (4, 'W2', 'private の関数 6 つ：残っていて、PUBLIC・anon・authenticated は実行できない', '6',
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
    (5, 'W2', 'トリガー kintai_block_closed_month が有効', 'true',
        (SELECT (t.tgenabled = 'O')::text FROM pg_trigger t
          WHERE t.tgrelid = 'public.kintai'::regclass AND t.tgname = 'kintai_block_closed_month')),
    (6, 'W3', '締めの状態の CHECK に withdrawn が残っている（前のデータのため）', 'true',
        (SELECT (pg_get_constraintdef(oid) LIKE '%''withdrawn''%')::text FROM pg_constraint
          WHERE conrelid = 'public.kintai_closing'::regclass AND conname = 'kintai_closing_status_chk')),
    (7, 'W3', '履歴の操作の CHECK に withdraw が残っている（前のデータのため）', 'true',
        (SELECT (pg_get_constraintdef(oid) LIKE '%''withdraw''%')::text FROM pg_constraint
          WHERE conrelid = 'public.kintai_closing_log'::regclass AND conname = 'kintai_closing_log_action_chk'))
  ) AS v(n, item, label, expect, got);
  v_seq := v_seq + 7;

  -- ---------- W5〜W8 動作テスト（1 件ずつ取り消す） ----------
  FOR v_case IN
    SELECT * FROM (VALUES
      -- W5 取り下げを呼べない
      ('W5', '本人として提出済の月を取り下げようとする',
       ARRAY[c_ins, c_submit, c_as_user, c_role, c_withdraw],
       '42883:*'),   -- 関数がない（文言は環境で変わるので番号だけ見る）
      ('W5', '管理者として取り下げを呼ぶ',
       ARRAY[c_ins, c_submit, c_as_admin, c_role, c_withdraw],
       '42883:*'),   -- 関数がない（文言は環境で変わるので番号だけ見る）
      ('W5', 'SQL Editor（postgres）から本体の関数を呼ぶ（抜け道なし）',
       ARRAY[c_ins, c_submit,
             $q$SELECT private.kintai_closing_withdraw('{uid}'::uuid, '2099-01-01'::date, '{uid}'::uuid)::text$q$],
       '42883:*'),   -- 関数がない（文言は環境で変わるので番号だけ見る）

      -- W6 提出済の月は、本人には直す方法がない
      ('W6', '本人が締めの行を直接書き換える（状態を withdrawn に）',
       ARRAY[c_ins, c_submit, c_as_user, c_role,
             $q$UPDATE public.kintai_closing SET status = 'withdrawn' WHERE user_id = '{uid}' AND month = '2099-01-01' RETURNING status$q$],
       '42501:*'),   -- 権限がない（文言は環境で変わるので番号だけ見る）
      ('W6', '本人が締めの行を消す',
       ARRAY[c_ins, c_submit, c_as_user, c_role,
             $q$DELETE FROM public.kintai_closing WHERE user_id = '{uid}' AND month = '2099-01-01' RETURNING status$q$],
       '42501:*'),   -- 権限がない（文言は環境で変わるので番号だけ見る）
      ('W6', '提出済の月の勤怠を本人が編集する',
       ARRAY[c_ins, c_submit, c_as_user, c_role,
             $q$UPDATE public.kintai SET start_time = '10:00' WHERE user_id = '{uid}' AND date = '2099-01-06' RETURNING work_min::text$q$],
       '55000:kintai_month_closed'),
      ('W6', '提出済の月をもう一度提出する（本体の関数・今日 = 2099-02-01）',
       ARRAY[c_ins, c_submit, c_submit],
       '55000:kintai_closing_already'),

      -- W7 管理者が差し戻すと直せる
      ('W7', '提出済 → 管理者が差し戻し → 本人が追加できる（work_min）',
       ARRAY[c_ins, c_submit, c_as_admin, c_role, c_return, c_reset, c_as_user, c_role, c_ins_jan10],
       '480'),
      ('W7', '承認済 → 管理者が差し戻し → 本人が編集して再提出（状態・合計）',
       ARRAY[c_ins, c_rate, c_submit, c_as_admin, c_role, c_approve, c_return, c_reset,
             c_as_user, c_role,
             $q$UPDATE public.kintai SET start_time = '10:00' WHERE user_id = '{uid}' AND date = '2099-01-06'$q$,
             c_reset, c_submit,
             $q$SELECT status || ' ' || total_work_min FROM public.kintai_closing
                 WHERE user_id = '{uid}' AND month = '2099-01-01'$q$],
       'submitted 1290'),

      -- W8 前に取り下げた行からの再提出（取り下げ済の行を SQL で作って試す）
      ('W8', '取り下げ済（withdrawn）の月は本人が追加でき、再提出もできる',
       ARRAY[c_ins, c_submit,
             $q$UPDATE public.kintai_closing SET status = 'withdrawn', withdrawn_at = now()
                 WHERE user_id = '{uid}' AND month = '2099-01-01'$q$,
             c_as_user, c_role, c_ins_jan10, c_reset, c_submit,
             $q$SELECT status || ' ' || row_count || ' ' || (withdrawn_at IS NULL)::text FROM public.kintai_closing
                 WHERE user_id = '{uid}' AND month = '2099-01-01'$q$],
       'submitted 4 true')
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
    INSERT INTO pg_temp.no_withdraw_result VALUES (v_seq, v_case.item, v_case.label, v_case.expect, v_got);
  END LOOP;

  -- ---------- W9 テスト用アカウントの 2026年11月分（読むだけ） ----------
  INSERT INTO pg_temp.no_withdraw_result VALUES
    (v_seq + 1, 'W9', 'テスト用アカウント 433697e1-… の 2026年11月分は提出済のまま', 'submitted',
     coalesce((SELECT c.status FROM public.kintai_closing c
                WHERE c.user_id = c_test_user AND c.month = DATE '2026-11-01'), '（締めなし）'));
  v_seq := v_seq + 1;

  -- ---------- W0 テスト用の行が残っていない ----------
  INSERT INTO pg_temp.no_withdraw_result VALUES
    (v_seq + 1, 'W0', 'テスト用の勤怠（本人・管理者役の 2099年の行）の数', '0',
     (SELECT count(*)::text FROM public.kintai
       WHERE user_id IN (v_uid, v_admin) AND left(date, 4) = '2099')),
    (v_seq + 2, 'W0', 'テスト用の締め（2099年）の数', '0',
     (SELECT count(*)::text FROM public.kintai_closing WHERE month >= DATE '2099-01-01')),
    (v_seq + 3, 'W0', 'テスト用の履歴（2099年）の数', '0',
     (SELECT count(*)::text FROM public.kintai_closing_log WHERE month >= DATE '2099-01-01')),
    (v_seq + 4, 'W0', '本人の profiles の単価が実行前と同じ', v_rate_before,
     coalesce((SELECT coalesce(p.inv_rate::text, 'null') FROM public.profiles p WHERE p.id = v_uid), '（行なし）'));
END;
$$;

-- 結果（先頭の「まとめ」行で NG の件数を見る。期待値: 0）
WITH r AS (
  SELECT seq, item, label, expect, got,
         CASE WHEN got IS NOT DISTINCT FROM expect
                OR (right(expect, 2) = ':*' AND split_part(got, ':', 1) = split_part(expect, ':', 1))
              THEN 'OK' ELSE 'NG' END AS judge
  FROM pg_temp.no_withdraw_result
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
