-- ============================================================
-- 月の締め 段階1（DB）：締めテーブル・履歴テーブル・関数・kintai の編集を止めるトリガー
--
--   締めのルール:
--     ・1人×暦月（1日〜末日）で1件。対象は 2026年11月分から
--     ・締められるのは日本時間で翌月1日以降
--     ・流れ: 本人が提出（submitted）→ 管理者が承認（approved）または差し戻し（returned）
--             承認前は本人が取り下げ（withdrawn）できる。承認後の差し戻しは管理者だけ
--             差し戻し・取り下げの後は再提出できる（同じ行を submitted に戻す）
--     ・管理者は自分の締めを承認・差し戻しできない（本人と操作する人が同じならエラー）
--     ・勤怠の行が0件の月、作業内容（memo）が空の行が1件でもある月は締められない
--       （空白だけの memo も空とする: 半角スペース・タブ・改行・全角スペース・ノーブレークスペース）
--     ・勤務日数は日付の重複を除いて数える
--     ・承認時に集計を計算し直し、単価（profiles.inv_rate）と金額を保存する
--       金額 = 勤務時間（分）× 単価 ÷ 60 の切り捨て（税抜。請求書の小計と同じ）
--       単価が NULL か 0 以下なら承認できない
--     ・提出済（submitted）・承認済（approved）の月は、その人の kintai の行を
--       追加・編集・削除できない（カレンダー取り込み・SQL Editor も含む。抜け道は作らない）
--       ※ Slack 報告の印（slack_reported_at）だけの更新は通す
--
--   このファイルで作るもの（1 つのトランザクション）:
--     1. テーブル public.kintai_closing（締め。1人×1月で1行）
--     2. テーブル public.kintai_closing_log（履歴。SQL Editor からだけ見る）
--     3. 処理の本体（private スキーマ。API には出ない。あとで別システムからも使えるよう、
--        操作する人・今日の日付を引数で受け取る）
--          private.kintai_closing_lock_key      … advisory lock の鍵（user_id と月から作る）
--          private.kintai_month_is_closed       … その日付の月が締め（提出済・承認済）か
--          private.kintai_assert_month_open     … 締めた月ならエラー（トリガーから使う）
--          private.kintai_closing_submit        … 提出
--          private.kintai_closing_withdraw      … 取り下げ
--          private.kintai_closing_approve       … 承認
--          private.kintai_closing_return        … 差し戻し
--     4. 画面から呼ぶ関数（public。rpc で呼ぶ）
--          submit_kintai_closing(p_month)              … 本人
--          withdraw_kintai_closing(p_month)            … 本人
--          approve_kintai_closing(p_user_id, p_month)  … 管理者（JWT の app_metadata.role = 'admin'）
--          return_kintai_closing(p_user_id, p_month)   … 管理者
--     5. kintai のトリガー kintai_block_closed_month（締めた月の追加・編集・削除を止める）
--
--   同時に走ったときの対策（advisory lock）:
--     ・鍵は「user_id と月」から作る（private.kintai_closing_lock_key）
--     ・kintai のトリガーはその月の鍵を「共有」で取ってから締めかどうかを見る
--     ・提出・取り下げ・承認・差し戻しは同じ鍵を「排他」で取ってから処理する
--       → 追加の途中に提出が来たら、提出は追加が確定するまで待ってから、その行も含めて数える
--         提出の途中に追加が来たら、追加は提出が確定するまで待ってから「締めた月」で止まる
--     ・鍵はトランザクションの終わりに自動で外れる
--
--   エラー（メッセージの括弧内の名前で画面が見分ける）:
--     kintai_closing_month_invalid   22023 … 1日でない・2026年10月以前
--     kintai_closing_too_early       55000 … 翌月1日より前
--     kintai_closing_already         55000 … すでに提出済・承認済
--     kintai_closing_no_rows         55000 … 勤怠の行が0件
--     kintai_closing_empty_memo      55000 … 作業内容が空の行がある
--     kintai_closing_bad_status      55000 … 今の状態ではその操作ができない・締めがない
--     kintai_closing_no_rate         55000 … 単価が NULL か 0 以下
--     kintai_closing_admin_only      42501 … 管理者でない
--     kintai_closing_self_operation  42501 … 自分の締めを承認・差し戻ししようとした
--     kintai_month_closed            55000 … 締めた月の kintai を追加・編集・削除しようとした
--     （名前なし）                    42501 … ログインしていない
--
--   権限:
--     ・新しいテーブル・自動採番から PUBLIC・anon・authenticated の権限を外し、
--       authenticated には kintai_closing の SELECT だけを付ける（RLS で本人と管理者だけ）
--     ・kintai_closing_log は authenticated も権限なし（SQL Editor からだけ見る）
--     ・書き換えは関数だけ（SECURITY DEFINER）。service_role の権限は Supabase の既定のまま
--     ・public の関数は PUBLIC・anon から EXECUTE を外し、authenticated にだけ付ける
--     ・private の関数とトリガー関数は PUBLIC・anon・authenticated から EXECUTE を外す
--
-- 実行方法:
--   Supabase Dashboard > SQL Editor にこのファイル全体を貼り、まとめて 1 回実行する。
--   BEGIN〜COMMIT で囲んであるので、途中でエラーになったら全部取り消される。
--
-- 実行後の確認: supabase/checks/kintai_closing_verify.sql
-- 戻す場合    : supabase/rollbacks/20261119_kintai_closing_rollback.sql
-- ============================================================

BEGIN;

-- 他の処理がテーブルを掴んでいたら、待ち続けずにエラーで止める
SET LOCAL lock_timeout = '5s';

-- 前提の確認（違えば全部取り消し）
DO $$
BEGIN
  IF to_regclass('public.kintai_closing') IS NOT NULL OR to_regclass('public.kintai_closing_log') IS NOT NULL THEN
    RAISE EXCEPTION 'kintai_closing / kintai_closing_log がすでにあります。このファイルは実行済みの可能性があります';
  END IF;
  IF to_regprocedure('private.is_valid_ymd(text)') IS NULL THEN
    RAISE EXCEPTION 'private.is_valid_ymd(text) がありません。先に 20261116_kintai_constraints.sql を実行してください';
  END IF;
  IF to_regprocedure('public.kintai_compute_work_min()') IS NULL THEN
    RAISE EXCEPTION 'public.kintai_compute_work_min() がありません。先に 20261117_kintai_work_min_trigger.sql を実行してください';
  END IF;
END;
$$;


-- ------------------------------------------------------------
-- 1. 締めテーブル
-- ------------------------------------------------------------
CREATE TABLE public.kintai_closing (
  id             bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  user_id        uuid NOT NULL,                -- 本人
  month          date NOT NULL,                -- その月の1日
  status         text NOT NULL,                -- submitted / approved / returned / withdrawn
  work_days      integer NOT NULL,             -- 勤務日数（日付の重複を除く）。提出時に入れ、承認時に計算し直す
  total_work_min integer NOT NULL,             -- work_min の合計（分）
  row_count      integer NOT NULL,             -- 行数（参考）
  submitted_at   timestamptz NOT NULL,         -- 最後に提出した日時
  approved_at    timestamptz,                  -- 承認の日時
  approved_by    uuid,                         -- 承認した人（別システムからの操作に備え、参照は付けない）
  rate           integer,                      -- 承認時の単価（profiles.inv_rate）
  amount         bigint,                       -- 承認時の金額 = total_work_min × rate ÷ 60 の切り捨て
  returned_at    timestamptz,                  -- 差し戻しの日時
  returned_by    uuid,                         -- 差し戻した人
  withdrawn_at   timestamptz,                  -- 取り下げの日時
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kintai_closing_pkey           PRIMARY KEY (id),
  CONSTRAINT kintai_closing_user_id_fkey   FOREIGN KEY (user_id) REFERENCES auth.users(id),
  CONSTRAINT kintai_closing_user_month_key UNIQUE (user_id, month),
  CONSTRAINT kintai_closing_month_chk
    CHECK (extract(day FROM month) = 1 AND month >= DATE '2026-11-01'),
  CONSTRAINT kintai_closing_status_chk
    CHECK (status IN ('submitted', 'approved', 'returned', 'withdrawn')),
  CONSTRAINT kintai_closing_counts_chk
    CHECK (work_days >= 1 AND row_count >= work_days AND total_work_min >= 0),
  -- 承認済なら承認の日時・単価・金額が入っている
  -- （approved_by は別システムからの操作で NULL になり得るので、ここでは確かめない）
  CONSTRAINT kintai_closing_approved_chk
    CHECK (status <> 'approved' OR (approved_at IS NOT NULL AND rate > 0 AND amount >= 0))
);

ALTER TABLE public.kintai_closing ENABLE ROW LEVEL SECURITY;

-- 本人の行と、管理者は全員の行を見られる。INSERT・UPDATE・DELETE のポリシーは作らない（関数だけが書く）
CREATE POLICY kintai_closing_select ON public.kintai_closing
  FOR SELECT TO authenticated
  USING (
    (SELECT auth.uid()) = user_id
    OR ((SELECT auth.jwt()) -> 'app_metadata' ->> 'role') = 'admin'
  );

REVOKE ALL ON TABLE public.kintai_closing FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.kintai_closing TO authenticated;
REVOKE ALL ON SEQUENCE public.kintai_closing_id_seq FROM PUBLIC, anon, authenticated;


-- ------------------------------------------------------------
-- 2. 履歴テーブル（SQL Editor からだけ見る）
-- ------------------------------------------------------------
CREATE TABLE public.kintai_closing_log (
  id             bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  closing_id     bigint NOT NULL,
  user_id        uuid NOT NULL,
  month          date NOT NULL,
  action         text NOT NULL,                -- submit / withdraw / approve / return
  from_status    text,                         -- 変わる前（初回の提出は NULL）
  to_status      text NOT NULL,                -- 変わった後
  actor          uuid,                         -- 操作した人（別システムからの操作に備え、NULL 可・参照なし）
  work_days      integer,                      -- その時点の値
  total_work_min integer,
  rate           integer,
  amount         bigint,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kintai_closing_log_pkey            PRIMARY KEY (id),
  CONSTRAINT kintai_closing_log_closing_id_fkey FOREIGN KEY (closing_id) REFERENCES public.kintai_closing(id),
  CONSTRAINT kintai_closing_log_action_chk
    CHECK (action IN ('submit', 'withdraw', 'approve', 'return'))
);

CREATE INDEX kintai_closing_log_closing_id_idx ON public.kintai_closing_log (closing_id);

-- RLS を有効にし、ポリシーは作らない（authenticated からは何も見えない）
ALTER TABLE public.kintai_closing_log ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.kintai_closing_log FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.kintai_closing_log_id_seq FROM PUBLIC, anon, authenticated;


-- ------------------------------------------------------------
-- 3. 処理の本体（private）
-- ------------------------------------------------------------

-- advisory lock の鍵（user_id と月から作る。違う月どうしで値がたまたま重なっても、待ちが出るだけ）
CREATE OR REPLACE FUNCTION private.kintai_closing_lock_key(p_user_id uuid, p_month date)
RETURNS bigint
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT hashtextextended(
           'kintai_closing:' || p_user_id::text || ':' || to_char(p_month, 'YYYY-MM'), 0)
$$;

-- その日付（'YYYY-MM-DD'）の月が締め（提出済・承認済）なら true
--   日付の形が不正・2026年10月以前・user_id が NULL なら false
--   VOLATILE: 呼ばれるたびに、その時点で確定している締めを読む
CREATE OR REPLACE FUNCTION private.kintai_month_is_closed(p_user_id uuid, p_ymd text)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_month date;
BEGIN
  IF p_user_id IS NULL OR NOT private.is_valid_ymd(p_ymd) THEN
    RETURN false;
  END IF;
  v_month := make_date(substr(p_ymd, 1, 4)::int, substr(p_ymd, 6, 2)::int, 1);
  IF v_month < DATE '2026-11-01' THEN
    RETURN false;
  END IF;
  RETURN EXISTS (
    SELECT 1 FROM public.kintai_closing c
    WHERE c.user_id = p_user_id
      AND c.month = v_month
      AND c.status IN ('submitted', 'approved')
  );
END;
$$;

-- 締めた月ならエラー（kintai のトリガーから使う）
--   その月の鍵を共有で取ってから確かめる（提出と同時に走っても、すり抜けない）
--   日付の形が不正なら何もしない（kintai の CHECK 制約のエラーに任せる）
CREATE OR REPLACE FUNCTION private.kintai_assert_month_open(p_user_id uuid, p_ymd text)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_month date;
BEGIN
  IF p_user_id IS NULL OR NOT private.is_valid_ymd(p_ymd) THEN
    RETURN;
  END IF;
  v_month := make_date(substr(p_ymd, 1, 4)::int, substr(p_ymd, 6, 2)::int, 1);
  IF v_month < DATE '2026-11-01' THEN
    RETURN;
  END IF;

  PERFORM pg_advisory_xact_lock_shared(private.kintai_closing_lock_key(p_user_id, v_month));

  IF private.kintai_month_is_closed(p_user_id, p_ymd) THEN
    RAISE EXCEPTION '%年%月は締め（提出済・承認済）のため、追加・編集・削除できません（kintai_month_closed）',
      extract(year FROM v_month), extract(month FROM v_month)
      USING ERRCODE = '55000';
  END IF;
END;
$$;

-- 提出
--   p_today: 「今日」（日本時間）。画面から呼ぶ関数が渡す。確認用 SQL では先の日付を渡して試す
CREATE OR REPLACE FUNCTION private.kintai_closing_submit(
  p_user_id uuid, p_month date, p_actor uuid, p_today date)
RETURNS public.kintai_closing
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row   public.kintai_closing;
  v_prev  text;
  v_days  integer;
  v_min   integer;
  v_rows  integer;
  v_blank integer;
BEGIN
  IF p_user_id IS NULL OR p_month IS NULL OR p_today IS NULL THEN
    RAISE EXCEPTION 'ユーザー・月・今日の日付を指定してください（kintai_closing_month_invalid）'
      USING ERRCODE = '22023';
  END IF;
  IF extract(day FROM p_month) <> 1 OR p_month < DATE '2026-11-01' THEN
    RAISE EXCEPTION '締められる月ではありません。2026年11月以降の月の1日を指定してください（kintai_closing_month_invalid）'
      USING ERRCODE = '22023';
  END IF;
  IF p_today < (p_month + interval '1 month')::date THEN
    RAISE EXCEPTION '%年%月はまだ締められません。翌月1日以降に締めてください（kintai_closing_too_early）',
      extract(year FROM p_month), extract(month FROM p_month)
      USING ERRCODE = '55000';
  END IF;

  -- この人のこの月の追加・編集・削除が終わるのを待ち、以降は止める
  PERFORM pg_advisory_xact_lock(private.kintai_closing_lock_key(p_user_id, p_month));

  SELECT * INTO v_row
  FROM public.kintai_closing c
  WHERE c.user_id = p_user_id AND c.month = p_month
  FOR UPDATE;

  IF v_row.id IS NOT NULL AND v_row.status IN ('submitted', 'approved') THEN
    RAISE EXCEPTION 'この月はすでに提出済または承認済です（kintai_closing_already）'
      USING ERRCODE = '55000';
  END IF;
  v_prev := v_row.status;   -- 初回は NULL

  SELECT count(DISTINCT k.date)::integer,
         coalesce(sum(k.work_min), 0)::integer,
         count(*)::integer,
         count(*) FILTER (WHERE k.memo ~ '^[\s　 ]*$')::integer
    INTO v_days, v_min, v_rows, v_blank
  FROM public.kintai k
  WHERE k.user_id = p_user_id
    AND left(k.date, 7) = to_char(p_month, 'YYYY-MM');

  IF v_rows = 0 THEN
    RAISE EXCEPTION 'この月の勤怠がないため締められません（kintai_closing_no_rows）'
      USING ERRCODE = '55000';
  END IF;
  IF v_blank > 0 THEN
    RAISE EXCEPTION '作業内容が空の勤怠が%件あるため締められません（kintai_closing_empty_memo）', v_blank
      USING ERRCODE = '55000';
  END IF;

  IF v_row.id IS NULL THEN
    INSERT INTO public.kintai_closing (
      user_id, month, status, work_days, total_work_min, row_count, submitted_at)
    VALUES (p_user_id, p_month, 'submitted', v_days, v_min, v_rows, now())
    RETURNING * INTO v_row;
  ELSE
    -- 差し戻し・取り下げの後の再提出。前回の承認・差し戻し・取り下げの値は消す（経緯は履歴に残る）
    UPDATE public.kintai_closing c
       SET status = 'submitted', work_days = v_days, total_work_min = v_min, row_count = v_rows,
           submitted_at = now(),
           approved_at = NULL, approved_by = NULL, rate = NULL, amount = NULL,
           returned_at = NULL, returned_by = NULL, withdrawn_at = NULL,
           updated_at = now()
     WHERE c.id = v_row.id
    RETURNING * INTO v_row;
  END IF;

  INSERT INTO public.kintai_closing_log (
    closing_id, user_id, month, action, from_status, to_status, actor, work_days, total_work_min)
  VALUES (v_row.id, p_user_id, p_month, 'submit', v_prev, 'submitted', p_actor, v_days, v_min);

  RETURN v_row;
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

-- 承認（提出済のときだけ）。集計を計算し直し、単価と金額を保存する
CREATE OR REPLACE FUNCTION private.kintai_closing_approve(
  p_user_id uuid, p_month date, p_actor uuid)
RETURNS public.kintai_closing
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row    public.kintai_closing;
  v_days   integer;
  v_min    integer;
  v_rows   integer;
  v_rate   integer;
  v_amount bigint;
BEGIN
  IF p_user_id IS NULL OR p_month IS NULL THEN
    RAISE EXCEPTION 'ユーザーと月を指定してください（kintai_closing_month_invalid）'
      USING ERRCODE = '22023';
  END IF;
  IF p_actor = p_user_id THEN
    RAISE EXCEPTION '自分の締めは承認できません（kintai_closing_self_operation）'
      USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(private.kintai_closing_lock_key(p_user_id, p_month));

  SELECT * INTO v_row
  FROM public.kintai_closing c
  WHERE c.user_id = p_user_id AND c.month = p_month
  FOR UPDATE;

  IF v_row.id IS NULL OR v_row.status <> 'submitted' THEN
    RAISE EXCEPTION '承認できるのは提出済の締めだけです（kintai_closing_bad_status）'
      USING ERRCODE = '55000';
  END IF;

  SELECT count(DISTINCT k.date)::integer, coalesce(sum(k.work_min), 0)::integer, count(*)::integer
    INTO v_days, v_min, v_rows
  FROM public.kintai k
  WHERE k.user_id = p_user_id
    AND left(k.date, 7) = to_char(p_month, 'YYYY-MM');

  IF v_rows = 0 THEN
    -- 提出後は行を消せないので、ふつうは起きない
    RAISE EXCEPTION 'この月の勤怠がないため承認できません（kintai_closing_no_rows）'
      USING ERRCODE = '55000';
  END IF;

  SELECT p.inv_rate INTO v_rate FROM public.profiles p WHERE p.id = p_user_id;
  IF v_rate IS NULL OR v_rate <= 0 THEN
    RAISE EXCEPTION '単価（時給）が登録されていないため承認できません（kintai_closing_no_rate）'
      USING ERRCODE = '55000';
  END IF;

  -- 時間 × 単価 の切り捨て（請求書の小計 Math.floor(合計分 / 60 × 単価) と同じ）
  v_amount := (v_min::bigint * v_rate) / 60;

  UPDATE public.kintai_closing c
     SET status = 'approved', work_days = v_days, total_work_min = v_min, row_count = v_rows,
         approved_at = now(), approved_by = p_actor, rate = v_rate, amount = v_amount,
         updated_at = now()
   WHERE c.id = v_row.id
  RETURNING * INTO v_row;

  INSERT INTO public.kintai_closing_log (
    closing_id, user_id, month, action, from_status, to_status, actor,
    work_days, total_work_min, rate, amount)
  VALUES (v_row.id, p_user_id, p_month, 'approve', 'submitted', 'approved', p_actor,
          v_days, v_min, v_rate, v_amount);

  RETURN v_row;
END;
$$;

-- 差し戻し（提出済・承認済のとき）。承認の値は消す（経緯は履歴に残る）
CREATE OR REPLACE FUNCTION private.kintai_closing_return(
  p_user_id uuid, p_month date, p_actor uuid)
RETURNS public.kintai_closing
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row  public.kintai_closing;
  v_prev text;
BEGIN
  IF p_user_id IS NULL OR p_month IS NULL THEN
    RAISE EXCEPTION 'ユーザーと月を指定してください（kintai_closing_month_invalid）'
      USING ERRCODE = '22023';
  END IF;
  IF p_actor = p_user_id THEN
    RAISE EXCEPTION '自分の締めは差し戻しできません（kintai_closing_self_operation）'
      USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(private.kintai_closing_lock_key(p_user_id, p_month));

  SELECT * INTO v_row
  FROM public.kintai_closing c
  WHERE c.user_id = p_user_id AND c.month = p_month
  FOR UPDATE;

  IF v_row.id IS NULL OR v_row.status NOT IN ('submitted', 'approved') THEN
    RAISE EXCEPTION '差し戻しできるのは提出済・承認済の締めだけです（kintai_closing_bad_status）'
      USING ERRCODE = '55000';
  END IF;
  v_prev := v_row.status;

  UPDATE public.kintai_closing c
     SET status = 'returned', returned_at = now(), returned_by = p_actor,
         approved_at = NULL, approved_by = NULL, rate = NULL, amount = NULL,
         updated_at = now()
   WHERE c.id = v_row.id
  RETURNING * INTO v_row;

  INSERT INTO public.kintai_closing_log (
    closing_id, user_id, month, action, from_status, to_status, actor, work_days, total_work_min)
  VALUES (v_row.id, p_user_id, p_month, 'return', v_prev, 'returned', p_actor,
          v_row.work_days, v_row.total_work_min);

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION private.kintai_closing_lock_key(uuid, date)            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.kintai_month_is_closed(uuid, text)             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.kintai_assert_month_open(uuid, text)           FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.kintai_closing_submit(uuid, date, uuid, date)  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.kintai_closing_withdraw(uuid, date, uuid)      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.kintai_closing_approve(uuid, date, uuid)       FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.kintai_closing_return(uuid, date, uuid)        FROM PUBLIC, anon, authenticated;


-- ------------------------------------------------------------
-- 4. 画面から呼ぶ関数（public）
-- ------------------------------------------------------------

-- 提出（本人）。今日は日本時間
CREATE OR REPLACE FUNCTION public.submit_kintai_closing(p_month date)
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
  RETURN private.kintai_closing_submit(v_uid, p_month, v_uid, (now() AT TIME ZONE 'Asia/Tokyo')::date);
END;
$$;

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

-- 承認（管理者）
CREATE OR REPLACE FUNCTION public.approve_kintai_closing(p_user_id uuid, p_month date)
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
  IF (auth.jwt() -> 'app_metadata' ->> 'role') IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION '管理者だけが承認できます（kintai_closing_admin_only）' USING ERRCODE = '42501';
  END IF;
  RETURN private.kintai_closing_approve(p_user_id, p_month, v_uid);
END;
$$;

-- 差し戻し（管理者）
CREATE OR REPLACE FUNCTION public.return_kintai_closing(p_user_id uuid, p_month date)
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
  IF (auth.jwt() -> 'app_metadata' ->> 'role') IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION '管理者だけが差し戻しできます（kintai_closing_admin_only）' USING ERRCODE = '42501';
  END IF;
  RETURN private.kintai_closing_return(p_user_id, p_month, v_uid);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_kintai_closing(date)          FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.withdraw_kintai_closing(date)        FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.approve_kintai_closing(uuid, date)   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.return_kintai_closing(uuid, date)    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_kintai_closing(date)        TO authenticated;
GRANT EXECUTE ON FUNCTION public.withdraw_kintai_closing(date)      TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_kintai_closing(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.return_kintai_closing(uuid, date)  TO authenticated;


-- ------------------------------------------------------------
-- 5. kintai の編集を止めるトリガー
--    ・INSERT は新しい行の月、DELETE は消す行の月、UPDATE は変更前と変更後の両方の月を確かめる
--    ・UPDATE で中身の列（date, start_time, end_time, break_min, work_min, memo, user_id）が
--      どれも変わっていなければ通す（Slack 報告の印 slack_reported_at だけの更新のため）
--    ・名前の順で kintai_compute_work_min より先に動く（締めた月では勤務時間のエラーより先に止まる）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.kintai_block_closed_month()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.date       IS NOT DISTINCT FROM OLD.date
     AND NEW.start_time IS NOT DISTINCT FROM OLD.start_time
     AND NEW.end_time   IS NOT DISTINCT FROM OLD.end_time
     AND NEW.break_min  IS NOT DISTINCT FROM OLD.break_min
     AND NEW.work_min   IS NOT DISTINCT FROM OLD.work_min
     AND NEW.memo       IS NOT DISTINCT FROM OLD.memo
     AND NEW.user_id    IS NOT DISTINCT FROM OLD.user_id THEN
    RETURN NEW;
  END IF;

  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    PERFORM private.kintai_assert_month_open(OLD.user_id, OLD.date);
  END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    PERFORM private.kintai_assert_month_open(NEW.user_id, NEW.date);
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

-- トリガーとして呼ばれるときは EXECUTE 権限を確かめないので、直接は呼べないようにする
REVOKE ALL ON FUNCTION public.kintai_block_closed_month() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER kintai_block_closed_month
  BEFORE INSERT OR UPDATE OR DELETE ON public.kintai
  FOR EACH ROW EXECUTE FUNCTION public.kintai_block_closed_month();

COMMIT;
