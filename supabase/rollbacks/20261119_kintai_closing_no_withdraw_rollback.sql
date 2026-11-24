-- ============================================================
-- 20261119_kintai_closing_no_withdraw.sql を元に戻す
--   ・取り下げの関数 2 つを、20261119_kintai_closing.sql と同じ定義・権限で作り直す
--       private.kintai_closing_withdraw(uuid, date, uuid) … 本体（PUBLIC・anon・authenticated は実行できない）
--       public.withdraw_kintai_closing(date)              … 画面から呼ぶ（authenticated だけ実行できる）
--   ・テーブル・行・ほかの関数・トリガーは変えない
--
-- ※ 戻すと、本人がまた提出済（承認前）の締めを取り下げられるようになる。
-- ※ 画面（index.html）は取り下げのボタンをなくした版のままなので、画面からは取り下げできない
--   （画面も戻す場合は、取り下げをなくす前の index.html に戻す）。
--
-- 実行方法:
--   Supabase Dashboard > SQL Editor にこのファイル全体を貼り、まとめて 1 回実行する。
--   BEGIN〜COMMIT で囲んであるので、途中でエラーになったら全部取り消される。
--
-- 戻した後の確認（どちらも NULL でなく、true になるのが正しい）:
--   SELECT to_regprocedure('public.withdraw_kintai_closing(date)'),
--          to_regprocedure('private.kintai_closing_withdraw(uuid, date, uuid)'),
--          has_function_privilege('authenticated', 'public.withdraw_kintai_closing(date)', 'EXECUTE')
--          AND NOT has_function_privilege('anon', 'public.withdraw_kintai_closing(date)', 'EXECUTE')
--          AND NOT has_function_privilege('authenticated', 'private.kintai_closing_withdraw(uuid, date, uuid)', 'EXECUTE');
--   （戻した後は kintai_closing_verify.sql・kintai_closing_no_withdraw_verify.sql の取り下げに関する項目が NG になる）
-- ============================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
  IF to_regclass('public.kintai_closing') IS NULL THEN
    RAISE EXCEPTION 'public.kintai_closing がありません。締めの機能（20261119_kintai_closing.sql）が入っていません';
  END IF;
  IF to_regprocedure('private.kintai_closing_lock_key(uuid, date)') IS NULL THEN
    RAISE EXCEPTION 'private.kintai_closing_lock_key(uuid, date) がありません';
  END IF;
END;
$$;

-- 取り下げ（提出済のときだけ）
CREATE OR REPLACE FUNCTION private.kintai_closing_withdraw(
  p_user_id uuid, p_month date, p_actor uuid)
RETURNS public.kintai_closing
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row  public.kintai_closing;
BEGIN
  IF p_user_id IS NULL OR p_month IS NULL THEN
    RAISE EXCEPTION 'ユーザーと月を指定してください（kintai_closing_month_invalid）'
      USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(private.kintai_closing_lock_key(p_user_id, p_month));

  SELECT * INTO v_row
  FROM public.kintai_closing c
  WHERE c.user_id = p_user_id AND c.month = p_month
  FOR UPDATE;

  IF v_row.id IS NULL OR v_row.status <> 'submitted' THEN
    RAISE EXCEPTION '取り下げできるのは提出済（承認前）の締めだけです（kintai_closing_bad_status）'
      USING ERRCODE = '55000';
  END IF;

  UPDATE public.kintai_closing c
     SET status = 'withdrawn', withdrawn_at = now(), updated_at = now()
   WHERE c.id = v_row.id
  RETURNING * INTO v_row;

  INSERT INTO public.kintai_closing_log (
    closing_id, user_id, month, action, from_status, to_status, actor, work_days, total_work_min)
  VALUES (v_row.id, p_user_id, p_month, 'withdraw', 'submitted', 'withdrawn', p_actor,
          v_row.work_days, v_row.total_work_min);

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION private.kintai_closing_withdraw(uuid, date, uuid) FROM PUBLIC, anon, authenticated;

-- 取り下げ（本人）
CREATE OR REPLACE FUNCTION public.withdraw_kintai_closing(p_month date)
RETURNS public.kintai_closing
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'ログインしていません。再ログインしてください' USING ERRCODE = '42501';
  END IF;
  RETURN private.kintai_closing_withdraw(v_uid, p_month, v_uid);
END;
$$;

REVOKE ALL ON FUNCTION public.withdraw_kintai_closing(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.withdraw_kintai_closing(date) TO authenticated;

COMMIT;
