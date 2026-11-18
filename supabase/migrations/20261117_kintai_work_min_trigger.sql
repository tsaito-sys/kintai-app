-- ============================================================
-- 勤務時間（work_min）を DB 側で計算する
--   トリガー関数 public.kintai_compute_work_min() と
--   トリガー kintai_compute_work_min を作る
--
--   ルール:
--     1. work_min ＝ 退勤 − 出勤 − 休憩（分）。退勤が出勤より前なら翌日の退勤として +1440 分
--     2. 出勤と退勤が同じ時刻はエラー          … kintai_work_min_same_time_chk
--     3. 計算結果が 0 以下（休憩 ≧ 勤務時間）はエラー … kintai_work_min_positive_chk
--     4. 計算結果が 720 分（12 時間）を超えたらエラー … kintai_work_min_max_chk
--     5. 画面から渡された work_min は使わず、計算結果で上書きする
--   ・エラーコードは 23514（check_violation）。メッセージに上の名前を入れる
--     （画面は「23514 かつメッセージに名前を含むか」で見分ける。index.html の IMPORT_CHECK_MESSAGES）
--     ※ この 3 つの名前は本物の CHECK 制約としては作らない（エラーの見分け用の名前）
--   ・時刻の形が不正なとき・休憩が NULL かマイナスのときは計算せずにそのまま通す。
--     その後の今の CHECK 制約（kintai_start_time_format_chk など）・NOT NULL でエラーになり、
--     画面の案内文は今までと変わらない
--
--   トリガーは BEFORE INSERT OR UPDATE OF start_time, end_time, break_min, work_min。
--     ・slack_reported_at だけの更新（Edge Function slack-report）や memo だけの更新では動かない
--     ・画面の編集は 6 列をまとめて送るので、保存のたびに計算し直される
--   今ある行は書き換えない（このファイルに UPDATE はない）。
--     今ある行は、次に出勤・退勤・休憩・work_min を含む更新をしたときに計算し直される。
--   import_kintai_rows と列ごとの権限は変えない
--     （画面・取り込みは今までどおり work_min を送るが、トリガーで上書きされる）
--
-- 実行権限:
--   トリガー関数は PUBLIC・anon・authenticated から EXECUTE を外す
--   （トリガーとして呼ばれるときは EXECUTE 権限を確かめない。直接は呼べないようにする）
--
-- 実行方法:
--   Supabase Dashboard > SQL Editor にこのファイル全体を貼り、まとめて 1 回実行する。
--   BEGIN〜COMMIT で囲んであるので、途中でエラーになったら全部取り消される。
--   ※ 画面（index.html）より「先に」実行してよい。今の画面のままでも動く
--     （日をまたぐ勤務は今の画面では入力できないまま。画面の更新で入力できるようになる）
--
-- 実行後の確認: supabase/checks/kintai_work_min_trigger_verify.sql
-- 戻す場合    : supabase/rollbacks/20261117_kintai_work_min_trigger_rollback.sql
-- ============================================================

BEGIN;

-- 他の処理がテーブルを掴んでいたら、待ち続けずにエラーで止める
SET LOCAL lock_timeout = '5s';


-- ------------------------------------------------------------
-- 1. トリガー関数
--    ・CREATE OR REPLACE は付けない（既にあればエラーで止める）
--    ・時刻の形の判定は CHECK 制約 kintai_start_time_format_chk / kintai_end_time_format_chk と同じ式
-- ------------------------------------------------------------
CREATE FUNCTION public.kintai_compute_work_min()
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
-- 2. トリガー
-- ------------------------------------------------------------
CREATE TRIGGER kintai_compute_work_min
  BEFORE INSERT OR UPDATE OF start_time, end_time, break_min, work_min ON public.kintai
  FOR EACH ROW EXECUTE FUNCTION public.kintai_compute_work_min();

COMMIT;
