-- ============================================================
-- 20261117_kintai_work_min_trigger.sql を元に戻す
--   トリガー kintai_compute_work_min と関数 public.kintai_compute_work_min() を消す
--
-- 戻した後:
--   ・work_min は画面・取り込みから渡された値がそのまま保存される（実行前と同じ）
--   ・トリガーが計算して保存した値は、そのまま残る（書き戻さない）
--   ・同じ時刻・休憩 ≧ 勤務時間・12時間超えは DB では止まらなくなる
--     （画面側の入力チェックは残る。取り込みにはチェックがない）
--   ※ 画面（index.html）は戻さなくても動く（work_min は今も画面で計算して送っている）。
--     ただし日をまたぐ勤務は、画面の計算（+1440）の値がそのまま保存される
--
-- 実行方法:
--   Supabase Dashboard > SQL Editor にこのファイル全体を貼り、まとめて 1 回実行する。
--
-- 戻した後の確認: supabase/checks/kintai_work_min_trigger_verify.sql の W1 の 1 列目
--                 （function_exists が false、trigger_exists も false）
-- ============================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- 関数を使っているトリガーを先に消す
DROP TRIGGER IF EXISTS kintai_compute_work_min ON public.kintai;
DROP FUNCTION IF EXISTS public.kintai_compute_work_min();

COMMIT;
