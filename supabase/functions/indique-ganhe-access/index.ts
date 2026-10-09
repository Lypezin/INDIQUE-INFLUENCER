import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.117.2";

const DATA_SCHEMA = "indique_ganhe_influencer";
const MAX_BODY_BYTES = 16 * 1024;
const INVITE_LIFETIME_HOURS = 24;
const LOCAL_ORIGINS = [
  "http://localhost:5173",
  "http://127.0.0.1:5173",
  "http://localhost:8787",
  "http://127.0.0.1:8787",
  "https://indique-ganhe-influencer.flowy-ocean-3139.chatgpt.site",
];

type RequestBody = {
  action?: unknown;
  email?: unknown;
  influencerId?: unknown;
  code?: unknown;
  password?: unknown;
};

type ActivationClaim = {
  invite_id: string;
  claim_id: string;
};

function allowedOrigins(): Set<string> {
  const configured = (Deno.env.get("APP_ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);
  return new Set([...LOCAL_ORIGINS, ...configured]);
}

function corsHeaders(origin: string | null): HeadersInit {
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  if (origin && allowedOrigins().has(origin)) {
    headers["Access-Control-Allow-Origin"] = origin;
  }
  return headers;
}

function respond(
  origin: string | null,
  body: Record<string, unknown>,
  status = 200,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(origin), "Content-Type": "application/json; charset=utf-8" },
  });
}

function getEnvironment(): {
  url: string;
  publishableKey: string;
  activationSecretKey: string;
} | null {
  const url = Deno.env.get("SUPABASE_URL");
  const publishableKey = getNamedKey(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS"), "default")
    ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY")
    ?? Deno.env.get("SUPABASE_ANON_KEY");
  // This function intentionally never falls back to the shared legacy service_role key.
  const activationSecretKey = getNamedKey(Deno.env.get("SUPABASE_SECRET_KEYS"), "indique_ganhe");
  if (!url || !publishableKey || !activationSecretKey) return null;
  return { url, publishableKey, activationSecretKey };
}

function getNamedKey(value: string | undefined, name: string): string | null {
  if (!value) return null;
  try {
    const keys = JSON.parse(value) as Record<string, unknown>;
    const key = keys[name];
    return typeof key === "string" && key.length > 0 ? key : null;
  } catch {
    return null;
  }
}

function createUserClient(
  url: string,
  key: string,
  token: string,
): SupabaseClient {
  return createClient(url, key, {
    auth: { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
}

function createActivationServiceClient(url: string, key: string): SupabaseClient {
  return createClient(url, key, {
    auth: { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false },
  });
}

function bearerToken(request: Request): string | null {
  const value = request.headers.get("authorization");
  const match = value?.match(/^Bearer\s+(.+)$/i);
  return match?.[1] ?? null;
}

function normalizeEmail(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const email = value.trim().toLowerCase();
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return null;
  return email;
}

function randomCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function hashCode(code: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(code));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function isValidCode(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{64}$/i.test(value);
}

async function readBody(request: Request): Promise<RequestBody | null> {
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > MAX_BODY_BYTES) return null;
  const raw = await request.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) return null;
  try {
    const parsed: unknown = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed as RequestBody
      : null;
  } catch {
    return null;
  }
}

async function authenticatedUser(
  request: Request,
  url: string,
  publishableKey: string,
): Promise<{ client: SupabaseClient; user: { id: string; email?: string } } | null> {
  const token = bearerToken(request);
  if (!token) return null;
  const client = createUserClient(url, publishableKey, token);
  const { data, error } = await client.auth.getUser(token);
  if (error || !data.user) return null;
  return { client, user: { id: data.user.id, email: data.user.email } };
}

async function issueInvite(
  request: Request,
  body: RequestBody,
  origin: string | null,
  env: NonNullable<ReturnType<typeof getEnvironment>>,
): Promise<Response> {
  const email = normalizeEmail(body.email);
  const adminInvite = body.action === "issue-admin";
  const influencerId = typeof body.influencerId === "string" ? body.influencerId : "";
  if (!email || (!adminInvite && !influencerId)) {
    return respond(origin, { error: adminInvite ? "Informe um e-mail válido." : "Informe um e-mail e um influenciador válidos." }, 400);
  }

  const authenticated = await authenticatedUser(request, env.url, env.publishableKey);
  if (!authenticated) return respond(origin, { error: "Sessão inválida. Entre novamente." }, 401);

  const { data: membership, error: membershipError } = await authenticated.client
    .schema(DATA_SCHEMA)
    .from("account_members")
    .select("role")
    .eq("user_id", authenticated.user.id)
    .maybeSingle();
  if (membershipError) return respond(origin, { error: "Não foi possível validar o acesso administrativo." }, 500);
  if (membership?.role !== "admin") return respond(origin, { error: "Apenas a administração pode liberar acessos." }, 403);

  const code = randomCode();
  const expiresAt = new Date(Date.now() + INVITE_LIFETIME_HOURS * 60 * 60 * 1000).toISOString();
  const { data, error } = adminInvite
    ? await authenticated.client.schema(DATA_SCHEMA).rpc("issue_admin_activation_invite", {
        p_email: email,
        p_token_hash: await hashCode(code),
        p_expires_at: expiresAt,
      })
    : await authenticated.client.schema(DATA_SCHEMA).rpc("issue_account_activation_invite", {
        p_email: email,
        p_influencer_id: influencerId,
        p_token_hash: await hashCode(code),
        p_expires_at: expiresAt,
      });
  if (error || !data?.invite_id) {
    return respond(origin, { error: error?.message ?? "Não foi possível criar o convite." }, 400);
  }

  return respond(origin, {
    inviteId: data.invite_id,
    code,
    expiresAt: data.expires_at ?? expiresAt,
  }, 201);
}

async function claimExistingAccount(
  request: Request,
  body: RequestBody,
  origin: string | null,
  env: NonNullable<ReturnType<typeof getEnvironment>>,
): Promise<Response> {
  const email = normalizeEmail(body.email);
  if (!email || !isValidCode(body.code)) {
    return respond(origin, { error: "E-mail ou código inválido ou expirado." }, 400);
  }
  const authenticated = await authenticatedUser(request, env.url, env.publishableKey);
  if (!authenticated) return respond(origin, { error: "Sessão inválida. Entre novamente." }, 401);
  if ((authenticated.user.email ?? "").trim().toLowerCase() !== email) {
    return respond(origin, { error: "O e-mail do convite precisa corresponder à conta conectada." }, 403);
  }

  const { data, error } = await authenticated.client
    .schema(DATA_SCHEMA)
    .rpc("claim_account_activation_invite", { p_token_hash: await hashCode(body.code) });
  if (error) return respond(origin, { error: "Não foi possível ativar este convite." }, 400);
  if (!data?.activated) return respond(origin, { error: "E-mail ou código inválido ou expirado." }, 400);
  return respond(origin, { userId: data.user_id, activated: true });
}

async function activateNewAccount(
  body: RequestBody,
  origin: string | null,
  env: NonNullable<ReturnType<typeof getEnvironment>>,
): Promise<Response> {
  const email = normalizeEmail(body.email);
  if (!email || !isValidCode(body.code)) {
    return respond(origin, { error: "E-mail ou código inválido ou expirado." }, 400);
  }
  if (typeof body.password !== "string" || body.password.length < 8 || body.password.length > 128) {
    return respond(origin, { error: "A senha precisa ter entre 8 e 128 caracteres." }, 400);
  }

  const service = createActivationServiceClient(env.url, env.activationSecretKey);
  const claimId = crypto.randomUUID();
  const { data: claim, error: claimError } = await service
    .schema(DATA_SCHEMA)
    .rpc("begin_account_activation", {
      p_email: email,
      p_token_hash: await hashCode(body.code),
      p_claim_id: claimId,
    });
  if (claimError) return respond(origin, { error: "O serviço de ativação está indisponível." }, 503);
  if (!claim?.invite_id || claim.claim_id !== claimId) {
    return respond(origin, { error: "E-mail ou código inválido, expirado ou já utilizado." }, 400);
  }

  const { data: created, error: createError } = await service.auth.admin.createUser({
    email,
    password: body.password,
    email_confirm: true,
  });
  if (createError || !created.user) {
    await service.schema(DATA_SCHEMA).rpc("release_account_activation", {
      p_invite_id: claim.invite_id,
      p_claim_id: claimId,
    });
    if (createError?.status === 422) {
      return respond(origin, {
        error: "Esta conta talvez já exista. Entre com ela e use a opção de resgatar um código de convite.",
      }, 409);
    }
    return respond(origin, { error: "Não foi possível criar a conta. Tente novamente." }, 503);
  }

  const { data: activated, error: activationError } = await service
    .schema(DATA_SCHEMA)
    .rpc("finish_account_activation", {
      p_invite_id: claim.invite_id,
      p_claim_id: claimId,
      p_user_id: created.user.id,
    });
  if (activationError || activated !== true) {
    await service.schema(DATA_SCHEMA).rpc("release_account_activation", {
      p_invite_id: claim.invite_id,
      p_claim_id: claimId,
    });
    return respond(origin, {
      error: "A conta foi criada, mas o vínculo ainda não terminou. Entre com a senha escolhida e resgate o mesmo código.",
    }, 503);
  }

  return respond(origin, { userId: created.user.id, activated: true });
}

Deno.serve(async (request: Request) => {
  const origin = request.headers.get("origin");
  if (origin && !allowedOrigins().has(origin)) {
    return new Response("Origin not allowed", { status: 403 });
  }
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders(origin) });
  }
  if (request.method !== "POST") {
    return respond(origin, { error: "Método não permitido." }, 405);
  }

  const body = await readBody(request);
  if (!body) return respond(origin, { error: "Corpo da solicitação inválido ou muito grande." }, 400);
  const env = getEnvironment();
  if (!env) return respond(origin, { error: "A função ainda não está configurada." }, 503);

  try {
    if (body.action === "issue" || body.action === "issue-admin") return await issueInvite(request, body, origin, env);
    if (body.action === "activate") return await activateNewAccount(body, origin, env);
    if (body.action === "claim") return await claimExistingAccount(request, body, origin, env);
    return respond(origin, { error: "Ação inválida." }, 400);
  } catch {
    // Do not log or echo request values: activate requests contain a plaintext password and invite code.
    return respond(origin, { error: "Não foi possível concluir a solicitação." }, 500);
  }
});
