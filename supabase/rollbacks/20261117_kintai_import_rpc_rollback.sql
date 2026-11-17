-- ============================================================
-- 20261117_kintai_import_rpc.sql を元に戻す
--   public.import_kintai_rows(jsonb) を消す
--
-- ※ 先に画面（index.html）を、rpc を呼ばない版（delete → insert の版）に戻すこと。
--   関数を消したまま rpc を呼ぶ版を使うと、カレンダー取り込みが
--   「取り込み失敗」になる（行は消えない）。
--
-- 実行方法:
--   Supabase Dashboard > SQL Editor にこのファイル全体を貼り、まとめて 1 回実行する。
--
-- 戻した後の確認: supabase/checks/kintai_import_rpc_verify.sql の R1
--                 （function_exists が false になる）
-- ============================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.import_kintai_rows(jsonb);

COMMIT;
