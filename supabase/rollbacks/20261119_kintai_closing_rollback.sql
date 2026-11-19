-- ============================================================
-- 20261119_kintai_closing.sql を元に戻す
--   ・kintai のトリガー kintai_block_closed_month とトリガー関数を消す
--     （締めた月でも kintai を追加・編集・削除できる状態に戻る）
--   ・画面から呼ぶ関数 4 つ（submit / withdraw / approve / return_kintai_closing）を消す
--   ・private の関数 7 つを消す
--   ・テーブル kintai_closing_log・kintai_closing を消す
--   ・kintai・profiles・既存の関数・トリガー（kintai_compute_work_min など）は変えない
--
-- ※ 締めと履歴のデータも消える。本物の締めを始めた後に戻すと、締めの記録がなくなる。
--   そのため、kintai_closing に行が1件でもあれば止める。
--   それでも戻す場合は、下の c_allow_delete を true に書き換えてから実行する
--   （消す前に、必要なら kintai_closing・kintai_closing_log を SELECT して控えておく）。
-- ※ 段階2以降の画面（締めの関数を呼ぶ画面）を公開した後に戻すと、画面の締めのボタンがエラーになる。
--
-- 実行方法:
--   Supabase Dashboard > SQL Editor にこのファイル全体を貼り、まとめて 1 回実行する。
--   BEGIN〜COMMIT で囲んであるので、途中でエラーになったら全部取り消される。
--
-- 戻した後の確認（どれも NULL・0 件になるのが正しい）:
--   SELECT to_regclass('public.kintai_closing'), to_regclass('public.kintai_closing_log'),
--          to_regprocedure('public.submit_kintai_closing(date)'),
--          to_regprocedure('private.kintai_closing_submit(uuid, date, uuid, date)'),
--          (SELECT count(*) FROM pg_trigger
--            WHERE tgrelid = 'public.kintai'::regclass AND tgname = 'kintai_block_closed_month');
--   （kintai_closing_verify.sql は、戻した後は実行するとエラーになる）
-- ============================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- 締めのデータがあれば止める
DO $$
DECLARE
  c_allow_delete constant boolean := false;   -- 締めのデータごと消してよい場合だけ true にする
  v_count bigint;
BEGIN
  IF to_regclass('public.kintai_closing') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.kintai_closing' INTO v_count;
    IF v_count > 0 AND NOT c_allow_delete THEN
      RAISE EXCEPTION 'kintai_closing に % 件の締めがあります。消してよければ c_allow_delete を true にしてください', v_count;
    END IF;
  END IF;
END;
$$;

-- 1. トリガーとトリガー関数
DROP TRIGGER IF EXISTS kintai_block_closed_month ON public.kintai;
DROP FUNCTION IF EXISTS public.kintai_block_closed_month();

-- 2. 画面から呼ぶ関数
DROP FUNCTION IF EXISTS public.submit_kintai_closing(date);
DROP FUNCTION IF EXISTS public.withdraw_kintai_closing(date);
DROP FUNCTION IF EXISTS public.approve_kintai_closing(uuid, date);
DROP FUNCTION IF EXISTS public.return_kintai_closing(uuid, date);

-- 3. private の関数
DROP FUNCTION IF EXISTS private.kintai_closing_submit(uuid, date, uuid, date);
DROP FUNCTION IF EXISTS private.kintai_closing_withdraw(uuid, date, uuid);
DROP FUNCTION IF EXISTS private.kintai_closing_approve(uuid, date, uuid);
DROP FUNCTION IF EXISTS private.kintai_closing_return(uuid, date, uuid);
DROP FUNCTION IF EXISTS private.kintai_assert_month_open(uuid, text);
DROP FUNCTION IF EXISTS private.kintai_month_is_closed(uuid, text);
DROP FUNCTION IF EXISTS private.kintai_closing_lock_key(uuid, date);

-- 4. テーブル（履歴が締めを参照しているので、履歴から消す。ポリシー・自動採番も一緒に消える）
DROP TABLE IF EXISTS public.kintai_closing_log;
DROP TABLE IF EXISTS public.kintai_closing;

COMMIT;
