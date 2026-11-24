-- ============================================================
-- 月の締め：本人による「取り下げ」をなくす（2026-11-19 の方針変更）
--
--   変更後のルール:
--     ・提出後に直すときは、管理者の差し戻しだけ（提出済・承認済のどちらも）
--     ・本人は自分で提出を取り消せない
--
--   このファイルですること（1 つのトランザクション）:
--     ・取り下げの関数 2 つを消す（画面から呼ぶ関数 → 本体の順）
--         public.withdraw_kintai_closing(date)
--         private.kintai_closing_withdraw(uuid, date, uuid)
--       → 画面・SQL Editor のどちらからも取り下げできなくなる（呼ぶと 42883「関数がない」）
--
--   変えないもの:
--     ・テーブルの行（締め・履歴・勤怠）。テスト用アカウントの 2026年11月分の「提出済」もそのまま
--     ・テーブルの定義。状態 withdrawn・履歴の withdraw・列 withdrawn_at は、
--       今日より前に取り下げた行・履歴のために残す（CHECK 制約もそのまま）
--     ・提出・承認・差し戻しの関数とその権限、kintai のトリガー
--       （提出の関数は、取り下げ済の行からも再提出できる作りのまま）
--
-- 実行方法:
--   Supabase Dashboard > SQL Editor にこのファイル全体を貼り、まとめて 1 回実行する。
--   BEGIN〜COMMIT で囲んであるので、途中でエラーになったら全部取り消される。
--   実行すると「取り下げ済の締め・取り下げの履歴の件数」が NOTICE で出る（参考。0 件でなくても止めない）。
--
-- 実行後の確認: supabase/checks/kintai_closing_no_withdraw_verify.sql
--              supabase/checks/kintai_closing_verify.sql（締め全体。2026-11-19 に取り下げなしの仕様に直した）
-- 戻す場合    : supabase/rollbacks/20261119_kintai_closing_no_withdraw_rollback.sql
-- ============================================================

BEGIN;

-- 他の処理が関数を使っていたら、待ち続けずにエラーで止める
SET LOCAL lock_timeout = '5s';

-- 前提の確認（違えば全部取り消し）
DO $$
DECLARE
  v_users     text;
  v_withdrawn bigint;
  v_log       bigint;
BEGIN
  IF to_regclass('public.kintai_closing') IS NULL THEN
    RAISE EXCEPTION 'public.kintai_closing がありません。先に 20261119_kintai_closing.sql を実行してください';
  END IF;
  IF to_regprocedure('public.withdraw_kintai_closing(date)') IS NULL
     OR to_regprocedure('private.kintai_closing_withdraw(uuid, date, uuid)') IS NULL THEN
    RAISE EXCEPTION '取り下げの関数がありません。このファイルは実行済みの可能性があります';
  END IF;

  -- 取り下げの関数を中で呼んでいる関数が、ほかにないこと
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_users
  FROM pg_proc p
  WHERE p.prosrc LIKE '%kintai_closing_withdraw%'
    AND p.oid NOT IN (to_regprocedure('public.withdraw_kintai_closing(date)'),
                      to_regprocedure('private.kintai_closing_withdraw(uuid, date, uuid)'));
  IF v_users IS NOT NULL THEN
    RAISE EXCEPTION '取り下げの関数を使っている関数があります: %', v_users;
  END IF;

  -- 参考：今までに取り下げた行・履歴の件数（行は消さない）
  SELECT count(*) INTO v_withdrawn FROM public.kintai_closing WHERE status = 'withdrawn';
  SELECT count(*) INTO v_log FROM public.kintai_closing_log WHERE action = 'withdraw';
  RAISE NOTICE '取り下げ済の締め: % 件、取り下げの履歴: % 件（どちらもそのまま残す）', v_withdrawn, v_log;
END;
$$;

-- 本体（画面から呼ぶ関数 → 本体の順）
DROP FUNCTION public.withdraw_kintai_closing(date);
DROP FUNCTION private.kintai_closing_withdraw(uuid, date, uuid);

-- 実行後の確認（違えば全部取り消し）
DO $$
DECLARE
  v_count integer;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p
              WHERE p.pronamespace IN ('public'::regnamespace, 'private'::regnamespace)
                AND p.proname IN ('withdraw_kintai_closing', 'kintai_closing_withdraw')) THEN
    RAISE EXCEPTION '取り下げの関数が残っています';
  END IF;

  -- 提出・承認・差し戻しの関数は残り、authenticated だけが実行できる
  SELECT count(*) INTO v_count
  FROM pg_proc p
  WHERE p.oid IN (to_regprocedure('public.submit_kintai_closing(date)'),
                  to_regprocedure('public.approve_kintai_closing(uuid, date)'),
                  to_regprocedure('public.return_kintai_closing(uuid, date)'))
    AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND NOT has_function_privilege('anon', p.oid, 'EXECUTE');
  IF v_count <> 3 THEN
    RAISE EXCEPTION '提出・承認・差し戻しの関数が 3 つそろっていません（% 個）', v_count;
  END IF;

  SELECT count(*) INTO v_count
  FROM pg_proc p
  WHERE p.oid IN (to_regprocedure('private.kintai_closing_submit(uuid, date, uuid, date)'),
                  to_regprocedure('private.kintai_closing_approve(uuid, date, uuid)'),
                  to_regprocedure('private.kintai_closing_return(uuid, date, uuid)'));
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'private の提出・承認・差し戻しの関数が 3 つそろっていません（% 個）', v_count;
  END IF;
END;
$$;

COMMIT;
