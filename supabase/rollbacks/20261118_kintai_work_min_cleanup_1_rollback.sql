-- ============================================================
-- 20261118_kintai_work_min_cleanup_1.sql を元に戻す
--   ・トリガー関数 kintai_compute_work_min … 20261117_kintai_work_min_trigger.sql の本体に戻す
--     （「計算しない」分岐で work_min に 0 を入れる 1 行をなくす）
--   ・import_kintai_rows … 20261117_kintai_import_rpc.sql の本体に戻す
--     （画面から受け取った work_min を INSERT する形）
--   ・どちらも CREATE OR REPLACE で本体だけ戻す。トリガー・実行権限は実行前と同じにする
--
-- ※ 戻せるのは第3段階（列権限から work_min を外す）の「前」だけ。
--   列権限を外した後に戻すと、import_kintai_rows が work_min を INSERT しようとして
--   権限エラーになり、カレンダー取り込みが止まる。
-- ※ 第2段階（画面が work_min を送らない）の後に戻した場合、取り込み・追加・編集は動くが、
--   時刻の形が不正・休憩がマイナスのとき、エラーが「work_min が NULL」（23502）になり、
--   画面の案内文が出なくなる（推測）。
--
-- 実行方法:
--   Supabase Dashboard > SQL Editor にこのファイル全体を貼り、まとめて 1 回実行する。
--   BEGIN〜COMMIT で囲んであるので、途中でエラーになったら全部取り消される。
--
-- 戻した後の確認:
--   supabase/checks/kintai_work_min_trigger_verify.sql の W1・W3・W4
--   supabase/checks/kintai_import_rpc_verify.sql の R1・R3
--   （kintai_work_min_cleanup_1_verify.sql の C1 は、戻した後は NG になるのが正しい）
-- ============================================================

BEGIN;

SET LOCAL lock_timeout = '5s';


-- ------------------------------------------------------------
-- 1. トリガー関数を 20261117_kintai_work_min_trigger.sql の本体に戻す
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.kintai_compute_work_min()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_span integer;  -- 退勤 − 出勤（分。日またぎは +1440）
  v_work integer;  -- v_span − 休憩
BEGIN
  -- 形が不正・休憩が NULL かマイナスなら計算しない（今の CHECK 制約・NOT NULL のエラーに任せる）
  IF NEW.start_time IS NULL OR NEW.end_time IS NULL OR NEW.break_min IS NULL
     OR NEW.start_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     OR NEW.end_time   !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     OR NEW.break_min < 0 THEN
    RETURN NEW;
  END IF;

  v_span := (substr(NEW.end_time,   1, 2)::int * 60 + substr(NEW.end_time,   4, 2)::int)
          - (substr(NEW.start_time, 1, 2)::int * 60 + substr(NEW.start_time, 4, 2)::int);
  IF v_span < 0 THEN
    v_span := v_span + 1440;  -- 退勤が出勤より前 → 翌日の退勤
  END IF;

  IF v_span = 0 THEN
    RAISE EXCEPTION '出勤と退勤が同じ時刻です（kintai_work_min_same_time_chk）'
      USING ERRCODE = '23514', CONSTRAINT = 'kintai_work_min_same_time_chk';
  END IF;

  v_work := v_span - NEW.break_min;

  IF v_work <= 0 THEN
    RAISE EXCEPTION '休憩が勤務時間（%分）以上です（kintai_work_min_positive_chk）', v_span
      USING ERRCODE = '23514', CONSTRAINT = 'kintai_work_min_positive_chk';
  END IF;

  IF v_work > 720 THEN
    RAISE EXCEPTION '勤務時間が12時間を超えています（休憩を除いて%分）（kintai_work_min_max_chk）', v_work
      USING ERRCODE = '23514', CONSTRAINT = 'kintai_work_min_max_chk';
  END IF;

  NEW.work_min := v_work;  -- 画面から渡された値は使わない
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.kintai_compute_work_min() FROM PUBLIC, anon, authenticated;


-- ------------------------------------------------------------
-- 2. import_kintai_rows を 20261117_kintai_import_rpc.sql の本体に戻す
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.import_kintai_rows(p_rows jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_count integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'ログインしていません。再ログインしてください'
      USING ERRCODE = '42501';
  END IF;

  -- OR の評価順は決まっていないため、配列かどうかを確かめてから長さを見る
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION '取り込む行の形式が正しくありません（配列ではありません）'
      USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION '取り込む行がありません'
      USING ERRCODE = '22023';
  END IF;

  -- 取り込む日付の自分の行を消す
  DELETE FROM public.kintai AS k
  WHERE k.user_id = v_uid
    AND k.date IN (
      SELECT r.date
      FROM jsonb_to_recordset(p_rows) AS r(date text)
    );

  -- 追加する（列の型は kintai の定義に合わせる。user_id は auth.uid()）
  INSERT INTO public.kintai (date, start_time, end_time, break_min, work_min, memo, user_id)
  SELECT r.date, r.start_time, r.end_time, r.break_min, r.work_min, r.memo, v_uid
  FROM jsonb_to_recordset(p_rows) AS r(
    date       text,
    start_time text,
    end_time   text,
    break_min  integer,
    work_min   integer,
    memo       text
  );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.import_kintai_rows(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.import_kintai_rows(jsonb) TO authenticated;

COMMIT;
