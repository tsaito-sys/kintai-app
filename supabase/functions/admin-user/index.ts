import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS })
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return json({ error: 'Unauthorized' }, 401)
    }

    // 呼び出し元のJWTを検証してロールを確認
    // ロールは app_metadata で判定する（user_metadata はユーザー自身が書き換えられるため使わない）
    const caller = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } }
    )
    const { data: { user }, error: authErr } = await caller.auth.getUser()
    if (authErr || !user) return json({ error: 'Unauthorized' }, 401)
    if (user.app_metadata?.role !== 'admin') return json({ error: 'Forbidden' }, 403)

    // サービスロールキーはSupabase管理のシークレット（ブラウザ非公開）
    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { autoRefreshToken: false, persistSession: false } }
    )

    const { action, ...params } = await req.json()

    if (action === 'create') {
      const { email, password, role } = params
      if (!email || !password) return json({ error: 'email と password は必須です' }, 400)
      if (password.length < 8)  return json({ error: 'パスワードは8文字以上にしてください' }, 400)
      const newRole = role || 'user'
      if (newRole !== 'user' && newRole !== 'admin') return json({ error: '不正なロール: ' + newRole }, 400)

      const { data, error } = await admin.auth.admin.createUser({
        email,
        password,
        app_metadata: { role: newRole },
        email_confirm: true,
      })
      if (error) return json({ error: error.message }, 400)
      return json({ data })
    }

    if (action === 'delete') {
      const { user_id } = params
      if (!user_id) return json({ error: 'user_id は必須です' }, 400)
      if (user_id === user.id) return json({ error: '自分自身は削除できません' }, 400)

      const { error } = await admin.auth.admin.deleteUser(user_id)
      if (error) return json({ error: error.message }, 400)
      return json({ success: true })
    }

    return json({ error: '不明なアクション: ' + action }, 400)

  } catch (e) {
    console.error(e)
    return json({ error: e instanceof Error ? e.message : String(e) }, 500)
  }
})

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  })
}
