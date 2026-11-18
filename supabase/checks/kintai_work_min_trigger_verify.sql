-- ============================================================
-- 20261117_kintai_work_min_trigger.sql の実行後の確認 SQL
-- ※ 2026-11-18 の後片付け（20261118_kintai_work_min_cleanup_1.sql・_2.sql）以降は結果が変わる項目がある
--   （W3 の関数の定義、W4 の work_min を指定する INSERT・UPDATE は権限エラー 42501 になる。今の確認は kintai_work_min_cleanup_2_verify.sql）
--
-- 使い方:
--   Supabase Dashboard > SQL Editor に「1 ブロックずつ」貼って実行する。
--   W1〜W3・W5 は SELECT だけで、DB は変更しない。
--   W4 は動きの確認で、テスト用の行を INSERT・UPDATE するが、
--   最後に必ずエラーを出して全部取り消すので、本番にデータは残らない（下の W4 の説明を参照）。
--   まず W1（全部 true になるはずの 1 行）を見て、false の項目があれば W2・W3 で詳しく見る。
-- ============================================================


-- ============================================================
-- W1. まとめ（結果は 1 行。期待値: すべて true）
--   関数・トリガーがなくてもエラーにならない（戻した後は function_exists / trigger_exists が false）
-- ============================================================
WITH f AS (
  SELECT to_regprocedure('public.kintai_compute_work_min()') AS oid
),
t AS (
  SELECT tg.* FROM pg_trigger tg
  WHERE tg.tgrelid = 'public.kintai'::regclass AND tg.tgname = 'kintai_compute_work_min'
)
SELECT
  (SELECT oid IS NOT NULL FROM f)                                                     AS function_exists,
  EXISTS (SELECT 1 FROM t)                                                            AS trigger_exists,

  -- 関数の形（trigger を返す、SECURITY INVOKER、search_path = ''）
  (SELECT p.prorettype = 'trigger'::regtype AND NOT p.prosecdef
          AND p.proconfig = ARRAY['search_path=""']
     FROM pg_proc p WHERE p.oid = (SELECT oid FROM f))                                AS function_ok,

  -- 関数の実行権限（PUBLIC・anon・authenticated にない）
  NOT has_function_privilege('anon',          (SELECT oid FROM f), 'EXECUTE')         AS no_exec_anon,
  NOT has_function_privilege('authenticated', (SELECT oid FROM f), 'EXECUTE')         AS no_exec_authenticated,
  NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) g
              WHERE p.oid = (SELECT oid FROM f) AND g.grantee = 0)
    AND (SELECT p.proacl IS NOT NULL FROM pg_proc p WHERE p.oid = (SELECT oid FROM f)) AS no_exec_public,

  -- トリガーの形（有効、行ごと、BEFORE、INSERT と UPDATE、DELETE なし、関数が正しい）
  --   tgtype のビット: 1 = ROW, 2 = BEFORE, 4 = INSERT, 8 = DELETE, 16 = UPDATE
  (SELECT t.tgenabled = 'O'
          AND (t.tgtype & 1) = 1 AND (t.tgtype & 2) = 2
          AND (t.tgtype & 4) = 4 AND (t.tgtype & 16) = 16 AND (t.tgtype & 8) = 0
          AND t.tgfoid = (SELECT oid FROM f)
     FROM t)                                                                          AS trigger_ok,

  -- UPDATE で動く列がちょうど 4 列（slack_reported_at・memo を含まない）
  (SELECT array_agg(a.attname::text ORDER BY a.attname)
     FROM t
     CROSS JOIN LATERAL unnest(t.tgattr) AS c(attnum)
     JOIN pg_attribute a ON a.attrelid = t.tgrelid AND a.attnum = c.attnum)
    = ARRAY['break_min', 'end_time', 'start_time', 'work_min']                       AS trigger_columns_ok;


-- ============================================================
-- W2. kintai のトリガー一覧
--   期待値: 2 件
--     kintai_compute_work_min     … BEFORE INSERT OR UPDATE OF start_time, end_time, break_min, work_min
--                                   ON public.kintai FOR EACH ROW EXECUTE FUNCTION kintai_compute_work_min()
--     kintai_reset_slack_reported … BEFORE UPDATE OF memo（変更なし）
--   enabled はどちらも O
-- ============================================================
SELECT tgname, tgenabled AS enabled, pg_get_triggerdef(oid) AS definition
FROM pg_trigger
WHERE tgrelid = 'public.kintai'::regclass AND NOT tgisinternal
ORDER BY tgname;


-- ============================================================
-- W3. 関数の定義と実行権限
--   期待値: definition が migrations/20261117_kintai_work_min_trigger.sql の CREATE FUNCTION と同じ
--           acl は postgres（所有者）と service_role だけ（PUBLIC・anon・authenticated はない）
--           ※ service_role には Supabase の初期設定で EXECUTE が付く。トリガー関数は直接呼べないので影響なし
-- ============================================================
SELECT pg_get_functiondef(p.oid) AS definition,
  (SELECT string_agg(CASE g.grantee WHEN 0 THEN 'PUBLIC' ELSE g.grantee::regrole::text END
                     || ':' || g.privilege_type, ', ' ORDER BY 1)
     FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) g) AS acl
FROM pg_proc p
WHERE p.oid = to_regprocedure('public.kintai_compute_work_min()');


-- ============================================================
-- W4. 動きの確認（ルール 1〜5）
--
--   ・auth.users の一番古いユーザーを「本人」として、authenticated の役割に切り替え、
--     2099-01-01 の日付でテスト用の行を INSERT・UPDATE する（画面と同じ権限・RLS で動く）
--   ・最後に必ずエラーを出して終わる。DO ブロック 1 文の中で起きたことは、
--     このエラーですべて取り消されるので、本番にテスト用の行は残らない
--   ・結果はそのエラーメッセージに出る:
--       「【確認結果・すべて取り消し済み】OK n件 / NG n件」と、ケースごとの「期待 / 結果」
--     期待値: NG 0件
--   ・結果の「…_chk」はエラーで止まったときの名前、数字は保存された work_min
-- ============================================================
DO $$
DECLARE
  v_uid  uuid;
  v_id   bigint;
  v_got  text;
  v_ok   integer := 0;
  v_ng   integer := 0;
  v_log  text := '';
  c      record;
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'auth.users にユーザーがいないため確認できません';
  END IF;

  -- 画面から呼ばれたときと同じ状態にする（auth.uid() = v_uid、役割は authenticated）
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  -- ---------- INSERT ----------
  FOR c IN
    SELECT * FROM (VALUES
      ('I1 普通の勤務',                    '09:00', '18:00',  60,   0, '480'),
      ('I2 渡した work_min は上書き',       '09:00', '18:00',  60, 999, '480'),
      ('I3 日またぎ',                      '22:00', '06:00',  60,   0, '420'),
      ('I4 日またぎ（id 64 と同じ形）',     '23:15', '00:00',   0,   0, '45'),
      ('I5 ちょうど12時間',                 '08:00', '21:00',  60,   0, '720'),
      ('I6 同じ時刻',                      '09:00', '09:00',   0,   0, 'kintai_work_min_same_time_chk'),
      ('I7 休憩 = 勤務時間',                '09:00', '10:00',  60,   0, 'kintai_work_min_positive_chk'),
      ('I8 休憩 > 勤務時間',                '09:00', '10:00',  90,   0, 'kintai_work_min_positive_chk'),
      ('I9 12時間 + 1分',                   '08:00', '21:01',  60,   0, 'kintai_work_min_max_chk'),
      ('I10 日またぎで12時間超え（780分）',  '19:00', '09:00',  60,   0, 'kintai_work_min_max_chk'),
      ('I11 出勤の形が不正（今の CHECK）',   '9:00',  '18:00',  60,   0, 'kintai_start_time_format_chk'),
      ('I12 退勤の形が不正（今の CHECK）',   '09:00', '24:00',  60,   0, 'kintai_end_time_format_chk'),
      ('I13 休憩がマイナス（今の CHECK）',   '09:00', '18:00', -30,   0, 'kintai_break_min_nonneg_chk')
    ) AS v(label, st, et, brk, sent, expect)
  LOOP
    BEGIN
      INSERT INTO public.kintai (date, start_time, end_time, break_min, work_min, memo, user_id)
      VALUES ('2099-01-01', c.st, c.et, c.brk, c.sent, 'work_min trigger test', v_uid)
      RETURNING work_min::text INTO v_got;
    EXCEPTION WHEN others THEN
      v_got := CASE WHEN SQLSTATE = '23514'
                    THEN coalesce(substring(SQLERRM FROM '(kintai_[a-z_]+_chk)'), SQLERRM)
                    ELSE SQLSTATE || ' ' || SQLERRM END;
    END;
    IF v_got = c.expect THEN v_ok := v_ok + 1; ELSE v_ng := v_ng + 1; END IF;
    v_log := v_log || format(E'%s %s: 期待 %s / 結果 %s\n',
                             CASE WHEN v_got = c.expect THEN 'OK' ELSE 'NG' END, c.label, c.expect, v_got);
  END LOOP;

  -- ---------- UPDATE（画面の編集と同じく authenticated で更新） ----------
  INSERT INTO public.kintai (date, start_time, end_time, break_min, work_min, memo, user_id)
  VALUES ('2099-01-02', '09:00', '18:00', 60, 0, 'work_min trigger test', v_uid)
  RETURNING id INTO v_id;

  -- U1 日またぎに変更 → 420
  BEGIN
    UPDATE public.kintai SET start_time = '21:00', end_time = '05:00', break_min = 60
    WHERE id = v_id RETURNING work_min::text INTO v_got;
  EXCEPTION WHEN others THEN v_got := SQLSTATE || ' ' || SQLERRM;
  END;
  IF v_got = '420' THEN v_ok := v_ok + 1; ELSE v_ng := v_ng + 1; END IF;
  v_log := v_log || format(E'%s U1 日またぎに変更: 期待 420 / 結果 %s\n',
                           CASE WHEN v_got = '420' THEN 'OK' ELSE 'NG' END, v_got);

  -- U2 work_min だけを書き換えても計算し直される → 420 のまま
  BEGIN
    UPDATE public.kintai SET work_min = 1
    WHERE id = v_id RETURNING work_min::text INTO v_got;
  EXCEPTION WHEN others THEN v_got := SQLSTATE || ' ' || SQLERRM;
  END;
  IF v_got = '420' THEN v_ok := v_ok + 1; ELSE v_ng := v_ng + 1; END IF;
  v_log := v_log || format(E'%s U2 work_min だけ書き換え: 期待 420 / 結果 %s\n',
                           CASE WHEN v_got = '420' THEN 'OK' ELSE 'NG' END, v_got);

  -- U3 同じ時刻に変更 → エラー
  BEGIN
    UPDATE public.kintai SET end_time = '21:00'
    WHERE id = v_id RETURNING work_min::text INTO v_got;
  EXCEPTION WHEN others THEN
    v_got := coalesce(substring(SQLERRM FROM '(kintai_[a-z_]+_chk)'), SQLSTATE || ' ' || SQLERRM);
  END;
  IF v_got = 'kintai_work_min_same_time_chk' THEN v_ok := v_ok + 1; ELSE v_ng := v_ng + 1; END IF;
  v_log := v_log || format(E'%s U3 同じ時刻に変更: 期待 kintai_work_min_same_time_chk / 結果 %s\n',
                           CASE WHEN v_got = 'kintai_work_min_same_time_chk' THEN 'OK' ELSE 'NG' END, v_got);

  -- U4 休憩を長くする（勤務 480 分に休憩 480 分）→ エラー
  BEGIN
    UPDATE public.kintai SET break_min = 480
    WHERE id = v_id RETURNING work_min::text INTO v_got;
  EXCEPTION WHEN others THEN
    v_got := coalesce(substring(SQLERRM FROM '(kintai_[a-z_]+_chk)'), SQLSTATE || ' ' || SQLERRM);
  END;
  IF v_got = 'kintai_work_min_positive_chk' THEN v_ok := v_ok + 1; ELSE v_ng := v_ng + 1; END IF;
  v_log := v_log || format(E'%s U4 休憩を勤務時間と同じに: 期待 kintai_work_min_positive_chk / 結果 %s\n',
                           CASE WHEN v_got = 'kintai_work_min_positive_chk' THEN 'OK' ELSE 'NG' END, v_got);

  -- 必ずエラーで終わり、ここまでの INSERT・UPDATE をすべて取り消す
  RAISE EXCEPTION E'【確認結果・すべて取り消し済み】OK %件 / NG %件\n%', v_ok, v_ng, v_log;
END;
$$;


-- ============================================================
-- W5. 今ある行のうち、ルールに合わない行（読み取りのみ。参考）
--   トリガーは今ある行を書き換えないので、ここに出た行もそのまま残っている。
--   出た行は、次に画面で編集して保存したときに計算し直される（ルールに合わなければ保存できない）
--   calc は ルール 1 の計算結果（同じ時刻は 0）
--   期待値: 0 行（日またぎの id 64, 66, 68, 70 は calc と work_min が一致するので出ない）
-- ============================================================
SELECT id, date, start_time, end_time, break_min, work_min, calc,
  concat_ws(', ',
    CASE WHEN start_time = end_time THEN '同じ時刻' END,
    CASE WHEN calc <> work_min THEN 'work_min 不一致' END,
    CASE WHEN start_time <> end_time AND calc <= 0 THEN '0 以下' END,
    CASE WHEN calc > 720 THEN '12時間超え' END
  ) AS problem
FROM (
  SELECT *,
    ((substr(end_time, 1, 2)::int * 60 + substr(end_time, 4, 2)::int)
   - (substr(start_time, 1, 2)::int * 60 + substr(start_time, 4, 2)::int) + 1440) % 1440
   - break_min AS calc
  FROM public.kintai
) k
WHERE start_time = end_time OR calc <> work_min OR calc <= 0 OR calc > 720
ORDER BY date, id;
