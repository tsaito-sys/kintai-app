-- ============================================================
-- 20261118_kintai_work_min_cleanup_1.sql の実行後の確認 SQL
--
-- 使い方:
--   Supabase Dashboard > SQL Editor に、このファイル全体を貼って 1 回実行する
--   （DROP → CREATE TEMP → DO → SELECT の 4 文で 1 組。最後の SELECT の結果が表で出る）。
--   期待値: 判定の列がすべて OK（先頭の「まとめ」行は NG の件数 0）
--
-- 本番のデータを残さないための作り:
--   ・データを変えるテスト（C2〜C5）は、1 件ずつ DO ブロックの中の BEGIN〜EXCEPTION のブロックで動かし、
--     ブロックの最後で必ずエラーを出してそのブロックを取り消す（ROLLBACK TO SAVEPOINT と同じ動き）。
--     テストがエラーで止まった場合も、同じくブロックごと取り消される。
--     取り消した後も、結果の文字は変数に残るので表に出せる
--   ・結果は一時テーブル（pg_temp.cleanup_1_result）に入れる。一時テーブルはこの接続だけのもので、
--     接続が切れると消える。kintai などの本番のテーブルには何も残らない
--   ・最後に C0 として、テスト用の行（memo = 'cleanup_1 verify test'）が 0 件であることも確かめる
--   ・SQL Editor では BEGIN〜ROLLBACK をまとめて書くと最後の結果が表示されないため、
--     この形にしている（kintai_work_min_trigger_verify.sql の W4 と同じく、取り消しは DO の中で行う）
--
-- 本人として動かす方法（kintai_work_min_trigger_verify.sql の W4 と同じ）:
--   auth.users の一番古いユーザーを「本人」とし、request.jwt.claims の sub にそのユーザーを入れ、
--   SET LOCAL ROLE authenticated で画面と同じ役割にする（RLS・列権限が画面と同じに効く）。
--   役割の切り替えもテストのブロックの中で行うので、ブロックを取り消すと postgres に戻る。
--   テストの日付は 2099-02-01〜（本番のデータと重ならない日付）
--
-- 結果の「期待」「結果」の見方:
--   数字           … 保存された work_min（トリガーの計算結果）
--   23514:名前     … CHECK 制約・トリガーのエラーで止まった（名前は画面が見分けに使う名前）
--   23502:…        … NOT NULL のエラー（C4・C5 でこれが出たら NG）
--   true / false   … 定義・権限の確認
--
-- 確認する項目:
--   C1 import_kintai_rows の定義に work_min が残っていない（形・実行権限は今までと同じ）。
--      トリガー関数に「計算しない」分岐の 0 が入っている
--   C2 work_min を含む行データを渡しても取り込める（余分な key は読み飛ばす）。work_min はトリガーの計算結果
--   C3 work_min を含まない行データでも取り込める。work_min はトリガーの計算結果
--      （第2段階の追加・編集と同じく、work_min を指定しない INSERT も確かめる）
--   C4 休憩が -30 のとき、23502 ではなく休憩の CHECK 制約（kintai_break_min_nonneg_chk）のエラーになる
--   C5 時刻の形が不正なとき、23502 ではなく時刻の CHECK 制約のエラーになる
--   C6 既存の行で、work_min と計算結果（退勤 − 出勤、マイナスなら +1440、− 休憩）が食い違う行が 0 件
--   C0 テスト用の行が残っていない
-- ============================================================

DROP TABLE IF EXISTS pg_temp.cleanup_1_result;
CREATE TEMP TABLE cleanup_1_result (
  seq    integer,
  item   text,
  label  text,
  expect text,
  got    text
);

DO $$
DECLARE
  v_uid    uuid;
  v_claims text;
  v_got    text;
  v_seq    integer := 0;
  c        record;
  c_marker constant text := 'cleanup_1 verify test';
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'auth.users にユーザーがいないため確認できません';
  END IF;
  v_claims := json_build_object('sub', v_uid, 'role', 'authenticated')::text;

  -- ---------- C1 定義・権限（読み取りのみ） ----------
  INSERT INTO pg_temp.cleanup_1_result
  SELECT v_seq + n, 'C1', label, 'true', coalesce(ok::text, 'null')
  FROM (VALUES
    (1, 'import_kintai_rows の定義に work_min がない',
        (SELECT position('work_min' IN lower(pg_get_functiondef(p.oid))) = 0
           FROM pg_proc p WHERE p.oid = to_regprocedure('public.import_kintai_rows(jsonb)'))),
    (2, 'import_kintai_rows の形（integer を返す・SECURITY INVOKER・search_path = ''''）',
        (SELECT p.prorettype = 'integer'::regtype AND NOT p.prosecdef
                AND p.proconfig = ARRAY['search_path=""']
           FROM pg_proc p WHERE p.oid = to_regprocedure('public.import_kintai_rows(jsonb)'))),
    (3, 'import_kintai_rows の実行権限（authenticated あり・anon なし・PUBLIC なし）',
        (SELECT has_function_privilege('authenticated', p.oid, 'EXECUTE')
                AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
                AND p.proacl IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) g WHERE g.grantee = 0)
           FROM pg_proc p WHERE p.oid = to_regprocedure('public.import_kintai_rows(jsonb)'))),
    (4, 'トリガー関数の「計算しない」分岐に coalesce(NEW.work_min, 0) がある',
        (SELECT position('coalesce(new.work_min, 0)' IN lower(pg_get_functiondef(p.oid))) > 0
           FROM pg_proc p WHERE p.oid = to_regprocedure('public.kintai_compute_work_min()'))),
    (5, 'トリガー関数の実行権限（PUBLIC・anon・authenticated にない）',
        (SELECT NOT has_function_privilege('anon', p.oid, 'EXECUTE')
                AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
                AND p.proacl IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) g WHERE g.grantee = 0)
           FROM pg_proc p WHERE p.oid = to_regprocedure('public.kintai_compute_work_min()'))),
    (6, 'トリガー kintai_compute_work_min が有効で、トリガー関数を使っている',
        (SELECT t.tgenabled = 'O' AND t.tgfoid = to_regprocedure('public.kintai_compute_work_min()')
           FROM pg_trigger t
          WHERE t.tgrelid = 'public.kintai'::regclass AND t.tgname = 'kintai_compute_work_min'))
  ) AS v(n, label, ok);
  v_seq := v_seq + 6;

  -- ---------- C2〜C5 動きの確認（1 件ずつ取り消す） ----------
  --   kind: rpc    … import_kintai_rows(payload) を呼ぶ（カレンダー取り込みと同じ）
  --         insert … payload の 1 行目を、work_min を指定せずに直接 INSERT（第2段階の追加と同じ）
  FOR c IN
    SELECT * FROM (VALUES
      ('C2', 'rpc・work_min あり（999）・普通の勤務 09:00〜18:00 休憩60',  'rpc',
       '[{"date":"2099-02-01","start_time":"09:00","end_time":"18:00","break_min":60,"work_min":999,"memo":"cleanup_1 verify test"}]'::jsonb,
       '2099-02-01', '480'),
      ('C2', 'rpc・work_min あり（999）・日またぎ 22:00〜06:00 休憩60',    'rpc',
       '[{"date":"2099-02-02","start_time":"22:00","end_time":"06:00","break_min":60,"work_min":999,"memo":"cleanup_1 verify test"}]'::jsonb,
       '2099-02-02', '420'),
      ('C3', 'rpc・work_min なし・普通の勤務 09:00〜18:00 休憩60',        'rpc',
       '[{"date":"2099-02-03","start_time":"09:00","end_time":"18:00","break_min":60,"memo":"cleanup_1 verify test"}]'::jsonb,
       '2099-02-03', '480'),
      ('C3', 'rpc・work_min なし・日またぎ 23:15〜00:00 休憩0',           'rpc',
       '[{"date":"2099-02-04","start_time":"23:15","end_time":"00:00","break_min":0,"memo":"cleanup_1 verify test"}]'::jsonb,
       '2099-02-04', '45'),
      ('C3', '直接 INSERT・work_min 指定なし・09:00〜18:00 休憩60',        'insert',
       '[{"date":"2099-02-05","start_time":"09:00","end_time":"18:00","break_min":60,"memo":"cleanup_1 verify test"}]'::jsonb,
       '2099-02-05', '480'),
      ('C3', '（参考）rpc・work_min なし・同じ時刻はトリガーのエラーのまま', 'rpc',
       '[{"date":"2099-02-06","start_time":"09:00","end_time":"09:00","break_min":0,"memo":"cleanup_1 verify test"}]'::jsonb,
       '2099-02-06', '23514:kintai_work_min_same_time_chk'),
      ('C4', 'rpc・work_min なし・休憩 -30',                              'rpc',
       '[{"date":"2099-02-07","start_time":"09:00","end_time":"18:00","break_min":-30,"memo":"cleanup_1 verify test"}]'::jsonb,
       '2099-02-07', '23514:kintai_break_min_nonneg_chk'),
      ('C4', 'rpc・work_min あり（今の画面と同じ）・休憩 -30',            'rpc',
       '[{"date":"2099-02-08","start_time":"09:00","end_time":"18:00","break_min":-30,"work_min":570,"memo":"cleanup_1 verify test"}]'::jsonb,
       '2099-02-08', '23514:kintai_break_min_nonneg_chk'),
      ('C4', '直接 INSERT・work_min 指定なし・休憩 -30',                  'insert',
       '[{"date":"2099-02-09","start_time":"09:00","end_time":"18:00","break_min":-30,"memo":"cleanup_1 verify test"}]'::jsonb,
       '2099-02-09', '23514:kintai_break_min_nonneg_chk'),
      ('C5', 'rpc・work_min なし・出勤の形が不正（9:00）',                 'rpc',
       '[{"date":"2099-02-10","start_time":"9:00","end_time":"18:00","break_min":60,"memo":"cleanup_1 verify test"}]'::jsonb,
       '2099-02-10', '23514:kintai_start_time_format_chk'),
      ('C5', 'rpc・work_min なし・退勤の形が不正（24:00）',                'rpc',
       '[{"date":"2099-02-11","start_time":"09:00","end_time":"24:00","break_min":60,"memo":"cleanup_1 verify test"}]'::jsonb,
       '2099-02-11', '23514:kintai_end_time_format_chk'),
      ('C5', '直接 INSERT・work_min 指定なし・出勤の形が不正（9:00）',     'insert',
       '[{"date":"2099-02-12","start_time":"9:00","end_time":"18:00","break_min":60,"memo":"cleanup_1 verify test"}]'::jsonb,
       '2099-02-12', '23514:kintai_start_time_format_chk')
    ) AS v(item, label, kind, payload, test_date, expect)
  LOOP
    v_got := NULL;
    BEGIN
      -- ここから本人（authenticated）として動かす。ブロックを取り消すと元に戻る
      PERFORM set_config('request.jwt.claims', v_claims, true);
      EXECUTE 'SET LOCAL ROLE authenticated';

      IF c.kind = 'rpc' THEN
        PERFORM public.import_kintai_rows(c.payload);
      ELSE
        INSERT INTO public.kintai (date, start_time, end_time, break_min, memo, user_id)
        SELECT r.date, r.start_time, r.end_time, r.break_min, r.memo, auth.uid()
        FROM jsonb_to_recordset(c.payload) AS r(
          date text, start_time text, end_time text, break_min integer, memo text);
      END IF;

      SELECT string_agg(k.work_min::text, ',' ORDER BY k.id) INTO v_got
      FROM public.kintai k
      WHERE k.user_id = v_uid AND k.date = c.test_date;
      v_got := coalesce(v_got, '（行がない）');

      -- 必ずここでブロックを取り消す（テスト用の行を残さない）
      RAISE EXCEPTION 'rollback this test' USING ERRCODE = 'TSTRB';
    EXCEPTION
      WHEN SQLSTATE 'TSTRB' THEN
        NULL;  -- 取り消し済み。v_got は残っている
      WHEN others THEN
        v_got := SQLSTATE || ':' || coalesce(substring(SQLERRM FROM '(kintai_[a-z_]+_chk)'), SQLERRM);
    END;

    v_seq := v_seq + 1;
    INSERT INTO pg_temp.cleanup_1_result VALUES (v_seq, c.item, c.label, c.expect, v_got);
  END LOOP;

  -- ---------- C6 既存の行（読み取りのみ） ----------
  v_seq := v_seq + 1;
  INSERT INTO pg_temp.cleanup_1_result
  SELECT v_seq, 'C6', '既存の行で work_min と計算結果が食い違う行の数', '0', count(*)::text
  FROM (
    SELECT work_min,
      ((substr(end_time, 1, 2)::int * 60 + substr(end_time, 4, 2)::int)
     - (substr(start_time, 1, 2)::int * 60 + substr(start_time, 4, 2)::int) + 1440) % 1440
     - break_min AS calc
    FROM public.kintai
  ) k
  WHERE k.calc IS DISTINCT FROM k.work_min;

  -- ---------- C0 テスト用の行が残っていない ----------
  v_seq := v_seq + 1;
  INSERT INTO pg_temp.cleanup_1_result
  SELECT v_seq, 'C0', 'テスト用の行（memo = ''cleanup_1 verify test''）の数', '0', count(*)::text
  FROM public.kintai WHERE memo = c_marker;
END;
$$;

-- 結果（先頭の「まとめ」行で NG の件数を見る。期待値: 0）
WITH r AS (
  SELECT seq, item, label, expect, got,
         CASE WHEN got IS NOT DISTINCT FROM expect THEN 'OK' ELSE 'NG' END AS judge
  FROM pg_temp.cleanup_1_result
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
