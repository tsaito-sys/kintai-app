// Slack「作業報告」Edge Function
//
// リクエスト: POST { record_id: <kintai.id>, force?: boolean }
//   ・呼び出したユーザー本人の勤怠行だけ送れる
//   ・投稿文の氏名・memo はブラウザから受け取らず、DB から読む
//   ・既に報告済みの行は force: true のときだけ再送する
// 成功時: 200 { slack_reported_at }
// 失敗時: 4xx/5xx { error: 画面に出す日本語メッセージ, code: 機械判定用 }
//
// 必要な secret: SLACK_WEBHOOK_URL（Slack Incoming Webhook の URL）
//   SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY は Supabase が自動設定
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const SLACK_TIMEOUT_MS = 10_000

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS })
  }
  if (req.method !== 'POST') return fail(405, 'method_not_allowed', 'POST で呼び出してください')

  try {
    // ── 1. 呼び出し元の確認（JWT） ──
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return fail(401, 'unauthorized', 'ログインしてください')

    const caller = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } }
    )
    const { data: { user }, error: authErr } = await caller.auth.getUser()
    if (authErr || !user) return fail(401, 'unauthorized', 'ログインの有効期限が切れています。再ログインしてください')

    // ── 2. 入力 ──
    let body: { record_id?: unknown; force?: unknown }
    try { body = await req.json() } catch { return fail(400, 'bad_request', 'リクエストの形式が不正です') }
    const recordId = body.record_id
    if (recordId === undefined || recordId === null || recordId === '' ||
        (typeof recordId !== 'string' && typeof recordId !== 'number')) {
      return fail(400, 'bad_request', 'record_id は必須です')
    }
    const force = body.force === true

    const webhookUrl = Deno.env.get('SLACK_WEBHOOK_URL')
    if (!webhookUrl) return fail(500, 'webhook_not_configured', 'Slack の送信先（SLACK_WEBHOOK_URL）が未設定です。管理者に連絡してください')

    // サービスロール（RLS・列権限を通らない）。読み取りは本人の行に限定してから使う
    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { autoRefreshToken: false, persistSession: false } }
    )

    // ── 3. 勤怠行（本人のものだけ） ──
    const { data: rec, error: recErr } = await admin
      .from('kintai')
      .select('id, user_id, date, memo, slack_reported_at')
      .eq('id', recordId)
      .maybeSingle()
    if (recErr) return fail(500, 'db_error', '勤怠の読み込みに失敗しました: ' + recErr.message)
    // 他人の行も「見つからない」と返す（存在を知らせない）
    if (!rec || rec.user_id !== user.id) return fail(404, 'not_found', 'この勤怠は見つかりません。一覧を更新してください')

    const memo = (rec.memo ?? '').trimEnd()
    if (!memo.trim()) return fail(400, 'empty_memo', '作業内容が空のため報告できません')

    // 行の日付（空・不正なら止める。「今日以外」扱いにはしない）
    const ymd = parseYmd(rec.date)
    if (!ymd) return fail(400, 'invalid_date', '日付が正しくないため報告できません')

    if (rec.slack_reported_at && !force) {
      return fail(409, 'already_reported', 'この勤怠は報告済みです', { slack_reported_at: rec.slack_reported_at })
    }

    // ── 4. 氏名（検証済みの user.id から） ──
    const { data: prof, error: profErr } = await admin
      .from('profiles').select('name').eq('id', user.id).maybeSingle()
    if (profErr) return fail(500, 'db_error', '氏名の読み込みに失敗しました: ' + profErr.message)
    const name = (prof?.name ?? '').trim()
    if (!name) return fail(400, 'no_name', '氏名が未登録です。プロフィールで氏名を登録してください')

    // ── 5. Slack へ送信 ──
    //   今日（送信時点の日本時間）の行は「本日の業務を終了します。」、それ以外は「11/4（水）分の作業報告です。」
    const isToday = rec.date === todayJst()
    const text =
      `${slackEscape(name)}\n` +
      'お疲れ様です。\n' +
      (isToday ? '本日の業務を終了します。\n' : `${formatMdW(ymd)}分の作業報告です。\n`) +
      '\n' +
      '【やったこと】\n' +
      slackEscape(memo)

    let slackRes: Response
    try {
      slackRes = await fetch(webhookUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text }),
        signal: AbortSignal.timeout(SLACK_TIMEOUT_MS),
      })
    } catch (e) {
      const timeout = e instanceof DOMException && e.name === 'TimeoutError'
      return fail(502, timeout ? 'slack_timeout' : 'slack_unreachable',
        timeout ? 'Slack が応答しません（タイムアウト）。時間をおいて再度お試しください'
                : 'Slack に接続できませんでした。時間をおいて再度お試しください')
    }
    const slackBody = (await slackRes.text()).trim()
    if (!slackRes.ok) {
      console.error('[slack-report] Slack error', slackRes.status, slackBody)
      return fail(502, 'slack_error', slackErrorMessage(slackRes.status, slackBody), { slack_status: slackRes.status, slack_body: slackBody })
    }

    // ── 6. 送信できたときだけ報告日時を記録 ──
    //   送信中に memo が書き換えられていたら、送った内容と違うので記録しない
    //   （memo は長文になり得るので URL の絞り込み条件には使わず、読み直して比較する）
    const { data: now, error: nowErr } = await admin
      .from('kintai').select('memo').eq('id', rec.id).eq('user_id', user.id).maybeSingle()
    if (nowErr || !now) {
      console.error('[slack-report] reread error', nowErr)
      return json({ slack_reported_at: null, warning: 'Slack には送信しましたが、報告済みの記録に失敗しました' })
    }
    if (now.memo !== rec.memo) {
      return json({ slack_reported_at: null, warning: 'Slack には送信しましたが、送信中に作業内容が変更されたため報告済みにしていません' })
    }
    const { data: upd, error: updErr } = await admin
      .from('kintai')
      .update({ slack_reported_at: new Date().toISOString() })
      .eq('id', rec.id)
      .eq('user_id', user.id)
      .select('slack_reported_at')
      .maybeSingle()
    if (updErr || !upd) {
      // Slack には送れているので 200 で返し、記録できなかったことだけ伝える
      console.error('[slack-report] update error', updErr)
      return json({ slack_reported_at: null, warning: 'Slack には送信しましたが、報告済みの記録に失敗しました' })
    }
    return json({ slack_reported_at: upd.slack_reported_at })

  } catch (e) {
    console.error(e)
    return fail(500, 'internal_error', 'サーバーエラー: ' + (e instanceof Error ? e.message : String(e)))
  }
})

// 'YYYY-MM-DD' を検証して { y, m, d } に。形式違い・存在しない日付は null
function parseYmd(s: unknown) {
  if (typeof s !== 'string') return null
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s)
  if (!m) return null
  const y = +m[1], mo = +m[2], d = +m[3]
  const dt = new Date(Date.UTC(y, mo - 1, d))
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d) return null
  return { y, m: mo, d }
}

// 送信時点の日本時間（UTC+9、夏時間なし）の日付 'YYYY-MM-DD'
function todayJst() {
  return new Date(Date.now() + 9 * 60 * 60 * 1000).toISOString().slice(0, 10)
}

// { y, m, d } → '11/4（水）'（ゼロ埋めなし・年なし）
function formatMdW({ y, m, d }: { y: number; m: number; d: number }) {
  const w = '日月火水木金土'[new Date(Date.UTC(y, m - 1, d)).getUTCDay()]
  return `${m}/${d}（${w}）`
}

// Slack の制御文字（< > &）を無効化する。<!channel> などのメンションやリンク記法も無効になる
function slackEscape(s: string) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

// Incoming Webhook のエラー応答を日本語に
// https://api.slack.com/messaging/webhooks#handling_errors
function slackErrorMessage(status: number, body: string) {
  const map: Record<string, string> = {
    invalid_token:          'Slack の Webhook URL が無効です（URL の誤りか、Webhook が削除されています）',
    no_service:             'Slack の Webhook が無効化または削除されています',
    no_team:                'Slack のワークスペースが見つかりません（Webhook URL を確認してください）',
    team_disabled:          'Slack のワークスペースが無効化されています',
    channel_not_found:      '投稿先の Slack チャンネルが見つかりません',
    channel_is_archived:    '投稿先の Slack チャンネルはアーカイブされています',
    action_prohibited:      'Slack の管理者設定により投稿できません',
    posting_to_general_channel_denied: 'この Slack チャンネルには投稿権限がありません',
    invalid_payload:        'Slack への送信内容が不正です',
    too_many_attachments:   'Slack への送信内容が不正です',
    rate_limited:           'Slack の送信回数制限に達しました。少し待ってから再度お試しください',
  }
  if (status === 429) return map.rate_limited
  return (map[body] ?? `Slack への送信に失敗しました（${status}）`) + (body ? ` [${body}]` : '')
}

function fail(status: number, code: string, error: string, extra: Record<string, unknown> = {}) {
  return json({ error, code, ...extra }, status)
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  })
}
