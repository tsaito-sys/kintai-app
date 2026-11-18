-- ============================================================
-- 段階0の後片付け 第1段階：work_min を画面から受け取らなくても動くようにする（DB の準備）
--
--   後片付け全体の流れ:
--     第1段階（このファイル）… DB の準備
--     第2段階 … 画面（index.html）が work_min を送るのをやめる
--     第3段階 … authenticated の列権限（INSERT・UPDATE）から work_min を外す
--
--   このファイルでやること（1 つのトランザクション）:
--     (a) トリガー関数 kintai_compute_work_min の「計算しない」分岐
--         （時刻の形が不正・休憩が NULL かマイナス）で、work_min が NULL なら 0 を入れる
--         ・画面が work_min を送らなくなると、この分岐では work_min が NULL のまま残る。
--           PostgreSQL は NOT NULL を CHECK 制約より先に確かめるため、
--           「work_min が NULL」（23502）が先に出て、画面の案内文
--           （休憩の値を確認してください・出勤の時刻を確認してください など）が出なくなる。
--           0 を入れておけば、今までどおり休憩・時刻の CHECK 制約（23514）のエラーになる
--         ・0 は kintai_work_min_nonneg_chk（work_min >= 0）に合格するので、
--           ほかの CHECK 制約のエラーが代わりに出ることはない
--         ・計算する分岐（形が正しい場合）は変えない
--     (b) import_kintai_rows を work_min を受け取らない形にする
--         ・INSERT の列一覧・SELECT・受け取る列の定義から work_min を外す
--           （work_min は INSERT 時にトリガーが計算して入れる）
--         ・引数（p_rows jsonb）・戻り値（integer）・SECURITY INVOKER・search_path・
--           エラー・実行権限は 20261117_kintai_import_rpc.sql と同じ
--
--   今の画面（work_min を送る）のままでも動く理由:
--     ・(b) の後も、画面は work_min を含む行データを送ってくる。
--       jsonb_to_recordset は、受け取る列の定義にない key（work_min）を読み飛ばすので、エラーにならない。
--       work_min はトリガーが計算した値になる（今もトリガーで上書きしているので、保存される値は同じ）
--     ・(a) は「計算しない」分岐で work_min が NULL のときだけ効く。
--       今の画面は追加・編集・取り込みのどれでも work_min を送っているので、NULL にはならず、動きは変わらない
--     ・追加・編集の insert / update は画面から直接送っていて、この 2 つの関数の変更とは関係ない
--     ・列権限は変えない（第3段階）
--
-- 実行方法:
--   Supabase Dashboard > SQL Editor にこのファイル全体を貼り、まとめて 1 回実行する。
--   BEGIN〜COMMIT で囲んであるので、途中でエラーになったら全部取り消される。
--   ※ 2 つの関数がない環境（20261117 の移行 SQL を実行していない環境）では、最初の確認でエラーにして止める
--
-- 実行後の確認: supabase/checks/kintai_work_min_cleanup_1_verify.sql
-- 戻す場合    : supabase/rollbacks/20261118_kintai_work_min_cleanup_1_rollback.sql
-- ============================================================

BEGIN;

-- 他の処理がテーブルを掴んでいたら、待ち続けずにエラーで止める
SET LOCAL lock_timeout = '5s';

-- 置き換える 2 つの関数があることを確かめる（なければ全部取り消し）
DO $$
BEGIN
  IF to_regprocedure('public.kintai_compute_work_min()') IS NULL THEN
    RAISE EXCEPTION 'public.kintai_compute_work_min() がありません。先に 20261117_kintai_work_min_trigger.sql を実行してください';
  END IF;
  IF to_regprocedure('public.import_kintai_rows(jsonb)') IS NULL THEN
    RAISE EXCEPTION 'public.import_kintai_rows(jsonb) がありません。先に 20261117_kintai_import_rpc.sql を実行してください';
  END IF;
END;
$$;


-- ------------------------------------------------------------
-- (a) トリガー関数（「計算しない」分岐に 1 行足しただけ。ほかは 20261117_kintai_work_min_trigger.sql と同じ）
--     CREATE OR REPLACE なので、トリガー kintai_compute_work_min はそのまま新しい本体を使う
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
    -- work_min が送られていなくても、NOT NULL（23502）より先に
    -- 休憩・時刻の CHECK 制約（23514）のエラーが出るよう 0 を入れる
    NEW.work_min := coalesce(NEW.work_min, 0);
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

-- 実行権限は 20261117_kintai_work_min_trigger.sql と同じ（CREATE OR REPLACE では変わらないが念のため）
REVOKE ALL ON FUNCTION public.kintai_compute_work_min() FROM PUBLIC, anon, authenticated;


-- ------------------------------------------------------------
-- (b) import_kintai_rows（勤務時間の列を受け取らない・INSERT しない。ほかは 20261117_kintai_import_rpc.sql と同じ）
--     ※ 関数本体には勤務時間の列名を書かない（確認 SQL の C1 で、定義に列名が残っていないことを確かめるため）
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
  -- 勤務時間は kintai の BEFORE INSERT トリガーが計算して入れる。
  -- 行データに勤務時間の key があっても、下の列の定義にないので読み飛ばす
  INSERT INTO public.kintai (date, start_time, end_time, break_min, memo, user_id)
  SELECT r.date, r.start_time, r.end_time, r.break_min, r.memo, v_uid
  FROM jsonb_to_recordset(p_rows) AS r(
    date       text,
    start_time text,
    end_time   text,
    break_min  integer,
    memo       text
  );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- 実行権限は 20261117_kintai_import_rpc.sql と同じ
REVOKE ALL ON FUNCTION public.import_kintai_rows(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.import_kintai_rows(jsonb) TO authenticated;

COMMIT;
