-- ============================================================
-- 20261118_kintai_work_min_cleanup_2.sql の実行後の確認 SQL
--
-- 使い方:
--   Supabase Dashboard > SQL Editor に、このファイル全体を貼って 1 回実行する
--   （DROP → CREATE TEMP → DO → SELECT の 4 文で 1 組。最後の SELECT の結果が表で出る）。
--   期待値: 判定の列がすべて OK（先頭の「まとめ」行は NG の件数 0）
--
-- 本番のデータを残さないための作り（kintai_work_min_cleanup_1_verify.sql と同じ）:
--   ・データを変えるテスト（D3〜D5）は、1 件ずつ DO ブロックの中の BEGIN〜EXCEPTION のブロックで動かし、
--     ブロックの最後で必ずエラーを出してそのブロックを取り消す（ROLLBACK TO SAVEPOINT と同じ動き）。
--     テストがエラーで止まった場合も、同じくブロックごと取り消される。
--     取り消した後も、結果の文字は変数に残るので表に出せる
--   ・結果は一時テーブル（pg_temp.cleanup_2_result）に入れる。一時テーブルはこの接続だけのもので、
--     接続が切れると消える。kintai などの本番のテーブルには何も残らない
--   ・最後に D0 として、テスト用の行（memo = 'cleanup_2 verify test'）が 0 件であることも確かめる
--
-- 本人として動かす方法（kintai_work_min_cleanup_1_verify.sql と同じ）:
--   auth.users の一番古いユーザーを「本人」とし、request.jwt.claims の sub にそのユーザーを入れ、
--   SET LOCAL ROLE authenticated で画面と同じ役割にする（RLS・列権限が画面と同じに効く）。
--   役割の切り替えもテストのブロックの中で行うので、ブロックを取り消すと postgres に戻る。
--   テストの日付は 2099-03-01〜（本番のデータと重ならない日付）
--
-- 結果の「期待」「結果」の見方:
--   数字           … 保存された work_min（トリガーの計算結果）
--   42501          … 権限エラー（work_min を書こうとして止まった）
--   23514:名前     … CHECK 制約・トリガーのエラーで止まった（名前は画面が見分けに使う名前）
--   23502:…        … NOT NULL のエラー（D5 でこれが出たら NG）
--   true / false   … 権限の確認
--   列名の並び     … 権限のある列（名前順）
--
-- 確認する項目:
--   D1 authenticated は work_min の INSERT・UPDATE 権限を持たない。SELECT は持つ
--   D2 ほかの列の INSERT・UPDATE 権限は変わっていない（列の一覧で確かめる）。
--      テーブル単位の INSERT・UPDATE がない、SELECT・DELETE がある、anon は何も持たない（どれも今までどおり）
--   D3 本人として、work_min を指定しない INSERT・UPDATE・import_kintai_rows が成功し、
--      work_min がトリガーの計算結果になる（普通の勤務と日またぎ）
--   D4 本人として、work_min を指定した INSERT・UPDATE は権限エラー（42501）になる
--   D5 休憩 -30、時刻の形が不正のときのエラーは、第1段階と同じ制約のエラーのまま
--   D6 既存の行で、work_min と計算結果（退勤 − 出勤、マイナスなら +1440、− 休憩）が食い違う行が 0 件
--   D0 テスト用の行が残っていない
-- ============================================================

DROP TABLE IF EXISTS pg_temp.cleanup_2_result;
CREATE TEMP TABLE cleanup_2_result (
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
  v_id     bigint;
  v_seq    integer := 0;
  c        record;
  c_marker constant text := 'cleanup_2 verify test';
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'auth.users にユーザーがいないため確認できません';
  END IF;
  v_claims := json_build_object('sub', v_uid, 'role', 'authenticated')::text;

  -- ---------- D1・D2 権限（読み取りのみ） ----------
  INSERT INTO pg_temp.cleanup_2_result
  SELECT v_seq + n, item, label, expect, coalesce(got, 'null')
  FROM (VALUES
    (1, 'D1', 'authenticated の work_min の INSERT 権限', 'false',
        has_column_privilege('authenticated', 'public.kintai', 'work_min', 'INSERT')::text),
    (2, 'D1', 'authenticated の work_min の UPDATE 権限', 'false',
        has_column_privilege('authenticated', 'public.kintai', 'work_min', 'UPDATE')::text),
    (3, 'D1', 'authenticated の work_min の SELECT 権限', 'true',
        has_column_privilege('authenticated', 'public.kintai', 'work_min', 'SELECT')::text),
    (4, 'D2', 'authenticated の INSERT 権限のある列（名前順）',
        'break_min,date,end_time,memo,start_time,user_id',
        (SELECT string_agg(a.attname::text, ',' ORDER BY a.attname)
           FROM pg_attribute a
          WHERE a.attrelid = 'public.kintai'::regclass AND a.attnum > 0 AND NOT a.attisdropped
            AND has_column_privilege('authenticated', a.attrelid, a.attnum, 'INSERT'))),
    (5, 'D2', 'authenticated の UPDATE 権限のある列（名前順）',
        'break_min,date,end_time,memo,start_time',
        (SELECT string_agg(a.attname::text, ',' ORDER BY a.attname)
           FROM pg_attribute a
          WHERE a.attrelid = 'public.kintai'::regclass AND a.attnum > 0 AND NOT a.attisdropped
            AND has_column_privilege('authenticated', a.attrelid, a.attnum, 'UPDATE'))),
    (6, 'D2', 'authenticated にテーブル単位の INSERT・UPDATE がない', 'true',
        (NOT has_table_privilege('authenticated', 'public.kintai', 'INSERT')
         AND NOT has_table_privilege('authenticated', 'public.kintai', 'UPDATE'))::text),
    (7, 'D2', 'authenticated にテーブル単位の SELECT・DELETE がある', 'true',
        (has_table_privilege('authenticated', 'public.kintai', 'SELECT')
         AND has_table_privilege('authenticated', 'public.kintai', 'DELETE'))::text),
    (8, 'D2', 'anon は kintai の権限を持たない（テーブル単位・列ごとのどちらも）', 'true',
        (NOT has_table_privilege('anon', 'public.kintai',
               'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
         AND NOT EXISTS (
           SELECT 1 FROM pg_attribute a
            WHERE a.attrelid = 'public.kintai'::regclass AND a.attnum > 0 AND NOT a.attisdropped
              AND has_column_privilege('anon', a.attrelid, a.attnum, 'SELECT, INSERT, UPDATE, REFERENCES')))::text)
  ) AS v(n, item, label, expect, got);
  v_seq := v_seq + 8;

  -- ---------- D3〜D5 動きの確認（1 件ずつ取り消す） ----------
  --   kind: rpc       … import_kintai_rows(payload) を呼ぶ（カレンダー取り込みと同じ）
  --         insert    … payload の 1 行目を、work_min を指定せずに直接 INSERT（画面の追加と同じ）
  --         insert_wm … payload の 1 行目を、work_min も指定して直接 INSERT（古い画面の追加と同じ）
  --         update    … payload の 1 行目を work_min を指定せずに INSERT した後、
  --                     upd の出勤・退勤・休憩で UPDATE（画面の編集と同じ。work_min は指定しない）
  --         update_wm … 同じく INSERT した後、upd の出勤・退勤・休憩と work_min で UPDATE（古い画面の編集と同じ）
  FOR c IN
    SELECT * FROM (VALUES
      ('D3', 'rpc・work_min なし・普通の勤務 09:00〜18:00 休憩60',            'rpc',
       '[{"date":"2099-03-01","start_time":"09:00","end_time":"18:00","break_min":60,"memo":"cleanup_2 verify test"}]'::jsonb,
       NULL::jsonb, '2099-03-01', '480'),
      ('D3', 'rpc・work_min なし・日またぎ 22:00〜06:00 休憩60',              'rpc',
       '[{"date":"2099-03-02","start_time":"22:00","end_time":"06:00","break_min":60,"memo":"cleanup_2 verify test"}]'::jsonb,
       NULL::jsonb, '2099-03-02', '420'),
      ('D3', '（参考）rpc・work_min あり（999）でも読み飛ばして取り込める',    'rpc',
       '[{"date":"2099-03-03","start_time":"09:00","end_time":"18:00","break_min":60,"work_min":999,"memo":"cleanup_2 verify test"}]'::jsonb,
       NULL::jsonb, '2099-03-03', '480'),
      ('D3', '直接 INSERT・work_min 指定なし・普通の勤務 09:00〜18:00 休憩60', 'insert',
       '[{"date":"2099-03-04","start_time":"09:00","end_time":"18:00","break_min":60,"memo":"cleanup_2 verify test"}]'::jsonb,
       NULL::jsonb, '2099-03-04', '480'),
      ('D3', '直接 INSERT・work_min 指定なし・日またぎ 23:15〜00:00 休憩0',    'insert',
       '[{"date":"2099-03-05","start_time":"23:15","end_time":"00:00","break_min":0,"memo":"cleanup_2 verify test"}]'::jsonb,
       NULL::jsonb, '2099-03-05', '45'),
      ('D3', 'UPDATE・work_min 指定なし・日またぎ 22:00〜06:00 休憩60 に変更',  'update',
       '[{"date":"2099-03-06","start_time":"09:00","end_time":"18:00","break_min":60,"memo":"cleanup_2 verify test"}]'::jsonb,
       '{"start_time":"22:00","end_time":"06:00","break_min":60}'::jsonb, '2099-03-06', '420'),
      ('D3', 'UPDATE・work_min 指定なし・普通の勤務 09:00〜17:30 休憩60 に変更', 'update',
       '[{"date":"2099-03-07","start_time":"22:00","end_time":"06:00","break_min":60,"memo":"cleanup_2 verify test"}]'::jsonb,
       '{"start_time":"09:00","end_time":"17:30","break_min":60}'::jsonb, '2099-03-07', '450'),
      ('D4', '直接 INSERT・work_min を指定（480）',                           'insert_wm',
       '[{"date":"2099-03-08","start_time":"09:00","end_time":"18:00","break_min":60,"work_min":480,"memo":"cleanup_2 verify test"}]'::jsonb,
       NULL::jsonb, '2099-03-08', '42501'),
      ('D4', 'UPDATE・出勤・退勤・休憩と work_min を指定',                     'update_wm',
       '[{"date":"2099-03-09","start_time":"09:00","end_time":"18:00","break_min":60,"memo":"cleanup_2 verify test"}]'::jsonb,
       '{"start_time":"10:00","end_time":"18:00","break_min":60,"work_min":420}'::jsonb, '2099-03-09', '42501'),
      ('D5', 'rpc・work_min なし・休憩 -30',                                  'rpc',
       '[{"date":"2099-03-10","start_time":"09:00","end_time":"18:00","break_min":-30,"memo":"cleanup_2 verify test"}]'::jsonb,
       NULL::jsonb, '2099-03-10', '23514:kintai_break_min_nonneg_chk'),
      ('D5', '直接 INSERT・work_min 指定なし・休憩 -30',                      'insert',
       '[{"date":"2099-03-11","start_time":"09:00","end_time":"18:00","break_min":-30,"memo":"cleanup_2 verify test"}]'::jsonb,
       NULL::jsonb, '2099-03-11', '23514:kintai_break_min_nonneg_chk'),
      ('D5', 'UPDATE・work_min 指定なし・休憩 -30 に変更',                    'update',
       '[{"date":"2099-03-12","start_time":"09:00","end_time":"18:00","break_min":60,"memo":"cleanup_2 verify test"}]'::jsonb,
       '{"start_time":"09:00","end_time":"18:00","break_min":-30}'::jsonb, '2099-03-12', '23514:kintai_break_min_nonneg_chk'),
      ('D5', 'rpc・work_min なし・出勤の形が不正（9:00）',                     'rpc',
       '[{"date":"2099-03-13","start_time":"9:00","end_time":"18:00","break_min":60,"memo":"cleanup_2 verify test"}]'::jsonb,
       NULL::jsonb, '2099-03-13', '23514:kintai_start_time_format_chk'),
      ('D5', 'rpc・work_min なし・退勤の形が不正（24:00）',                    'rpc',
       '[{"date":"2099-03-14","start_time":"09:00","end_time":"24:00","break_min":60,"memo":"cleanup_2 verify test"}]'::jsonb,
       NULL::jsonb, '2099-03-14', '23514:kintai_end_time_format_chk'),
      ('D5', '直接 INSERT・work_min 指定なし・出勤の形が不正（9:00）',         'insert',
       '[{"date":"2099-03-15","start_time":"9:00","end_time":"18:00","break_min":60,"memo":"cleanup_2 verify test"}]'::jsonb,
       NULL::jsonb, '2099-03-15', '23514:kintai_start_time_format_chk')
    ) AS v(item, label, kind, payload, upd, test_date, expect)
  LOOP
    v_got := NULL;
    BEGIN
      -- ここから本人（authenticated）として動かす。ブロックを取り消すと元に戻る
      PERFORM set_config('request.jwt.claims', v_claims, true);
      EXECUTE 'SET LOCAL ROLE authenticated';

      IF c.kind = 'rpc' THEN
        PERFORM public.import_kintai_rows(c.payload);

      ELSIF c.kind = 'insert_wm' THEN
        INSERT INTO public.kintai (date, start_time, end_time, break_min, work_min, memo, user_id)
        SELECT r.date, r.start_time, r.end_time, r.break_min, r.work_min, r.memo, auth.uid()
        FROM jsonb_to_recordset(c.payload) AS r(
          date text, start_time text, end_time text, break_min integer, work_min integer, memo text);

      ELSE
        -- insert・update・update_wm: まず work_min を指定せずに INSERT（画面の追加と同じ）
        INSERT INTO public.kintai (date, start_time, end_time, break_min, memo, user_id)
        SELECT r.date, r.start_time, r.end_time, r.break_min, r.memo, auth.uid()
        FROM jsonb_to_recordset(c.payload) AS r(
          date text, start_time text, end_time text, break_min integer, memo text)
        RETURNING id INTO v_id;

        IF c.kind = 'update' THEN
          UPDATE public.kintai
             SET start_time = c.upd->>'start_time',
                 end_time   = c.upd->>'end_time',
                 break_min  = (c.upd->>'break_min')::integer
           WHERE id = v_id;
        ELSIF c.kind = 'update_wm' THEN
          UPDATE public.kintai
             SET start_time = c.upd->>'start_time',
                 end_time   = c.upd->>'end_time',
                 break_min  = (c.upd->>'break_min')::integer,
                 work_min   = (c.upd->>'work_min')::integer
           WHERE id = v_id;
        END IF;
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
        v_got := CASE WHEN SQLSTATE = '42501' THEN '42501'
                      ELSE SQLSTATE || ':' || coalesce(substring(SQLERRM FROM '(kintai_[a-z_]+_chk)'), SQLERRM)
                 END;
    END;

    v_seq := v_seq + 1;
    INSERT INTO pg_temp.cleanup_2_result VALUES (v_seq, c.item, c.label, c.expect, v_got);
  END LOOP;

  -- ---------- D6 既存の行（読み取りのみ） ----------
  v_seq := v_seq + 1;
  INSERT INTO pg_temp.cleanup_2_result
  SELECT v_seq, 'D6', '既存の行で work_min と計算結果が食い違う行の数', '0', count(*)::text
  FROM (
    SELECT work_min,
      ((substr(end_time, 1, 2)::int * 60 + substr(end_time, 4, 2)::int)
     - (substr(start_time, 1, 2)::int * 60 + substr(start_time, 4, 2)::int) + 1440) % 1440
     - break_min AS calc
    FROM public.kintai
  ) k
  WHERE k.calc IS DISTINCT FROM k.work_min;

  -- ---------- D0 テスト用の行が残っていない ----------
  v_seq := v_seq + 1;
  INSERT INTO pg_temp.cleanup_2_result
  SELECT v_seq, 'D0', 'テスト用の行（memo = ''cleanup_2 verify test''）の数', '0', count(*)::text
  FROM public.kintai WHERE memo = c_marker;
END;
$$;

-- 結果（先頭の「まとめ」行で NG の件数を見る。期待値: 0）
WITH r AS (
  SELECT seq, item, label, expect, got,
         CASE WHEN got IS NOT DISTINCT FROM expect THEN 'OK' ELSE 'NG' END AS judge
  FROM pg_temp.cleanup_2_result
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
