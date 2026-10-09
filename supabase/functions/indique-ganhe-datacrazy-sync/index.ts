import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.117.2";

const DATA_SCHEMA = "indique_ganhe_influencer";
const API_BASE = "https://api.g1.datacrazy.io/api/v1";
const PAGE_SIZE = 300;
const MAX_PAGES_PER_INVOCATION = 12;
const MIN_ROUTE_INTERVAL_MS = 3_100; // At most 20 calls/minute/route, below Data Crazy's default 60.
const MAX_BODY_BYTES = 4_096;
const FIRST_SYNC_MONTH = "2026-01-01";
const BEFORE_FIRST_SYNC_MONTH = new Date(Date.parse(`${FIRST_SYNC_MONTH}T00:00:00.000Z`) - 1).toISOString();
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

// These are the nine pipeline IDs confirmed for the Influencers group. The
// human-readable names are checked on every worker invocation so a changed
// pipeline cannot silently reassign a courier.
const PIPELINES: Record<string, { influencerId: string; normalizedName: string }> = {
  "bbd70665-19d8-4264-a966-a3c10a2f68f3": { influencerId: "jhowjhow", normalizedName: "jhowjhow" },
  "5ac642d7-5fee-4e32-85d6-a68cf92179df": { influencerId: "jaiminho", normalizedName: "jaiminho" },
  "a66bf9e6-bbb8-4849-a11b-aec0f8c587ca": { influencerId: "felipe", normalizedName: "felipe" },
  "e3e576a4-4336-43ef-a901-0e6fadfc84b8": { influencerId: "00-brocador", normalizedName: "00broc" },
  "77e27aba-e026-43f2-89c2-013919870736": { influencerId: "vini", normalizedName: "vini" },
  "fd93c020-73f2-4b9f-9aca-11b5a16d2e5a": { influencerId: "gui", normalizedName: "guilherme" },
  "b68625ae-54ee-418c-9e0c-d2a90d1ed665": { influencerId: "biel", normalizedName: "biel" },
  "c872fd90-988e-4377-87cb-04e13f2d849b": { influencerId: "sassa", normalizedName: "sassa" },
  "58d4bdbb-2804-4d8f-a90d-5de3114e5249": { influencerId: "thais", normalizedName: "thais" },
};

type SyncAction = "start" | "status" | "cron-start" | "advance";
type Body = { action?: unknown; runId?: unknown };
type Env = { url: string; publicKey: string; serviceKey: string; dataCrazyKey: string; cronSecret: string };
type JsonObject = Record<string, unknown>;
type Claim = {
  runId: string;
  leaseToken: string;
  phase: "businesses" | "leads" | "ready";
  businessesSkip: number;
  leadsSkip: number;
  businessMonth: string;
  leadMonth: string;
  snapshotUntil: string;
};

class SyncError extends Error {
  constructor(
    message: string,
    readonly retryable: boolean,
    readonly statusCode = 503,
    readonly retryAfterSeconds = 120,
  ) {
    super(message);
  }
}

const lastRequestAt = new Map<string, number>();

function configuredOrigins(): Set<string> {
  return new Set([
    "http://localhost:5173",
    "http://127.0.0.1:5173",
    "http://localhost:8787",
    "http://127.0.0.1:8787",
    "https://indique-ganhe-influencer.flowy-ocean-3139.chatgpt.site",
    "https://indique-influencer.vercel.app",
    "https://indique-influencer-adggg79jo-luizs-projects-6df377ef.vercel.app",
    ...(Deno.env.get("APP_ALLOWED_ORIGINS") ?? "").split(",").map((part) => part.trim()).filter(Boolean),
  ]);
}

function corsHeaders(origin: string | null): Record<string, string> {
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-cron-secret",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  if (origin && configuredOrigins().has(origin)) headers["Access-Control-Allow-Origin"] = origin;
  return headers;
}

function response(origin: string | null, payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders(origin), "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

function namedKey(raw: string | undefined, name: string): string | null {
  if (!raw) return null;
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    const key = (parsed as JsonObject)[name];
    return typeof key === "string" && key.length > 0 ? key : null;
  } catch {
    return null;
  }
}

function environment(): Env | null {
  const url = Deno.env.get("SUPABASE_URL");
  const publicKey = namedKey(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS"), "default")
    ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY")
    ?? Deno.env.get("SUPABASE_ANON_KEY");
  // Use the app's dedicated secret key. Never fall back to the project's
  // legacy shared service_role key.
  const serviceKey = namedKey(Deno.env.get("SUPABASE_SECRET_KEYS"), "indique_ganhe");
  const dataCrazyKey = Deno.env.get("DATACRAZY_API_KEY");
  const cronSecret = Deno.env.get("DATACRAZY_CRON_SECRET");
  if (!url || !publicKey || !serviceKey || !dataCrazyKey || !cronSecret) return null;
  return { url, publicKey, serviceKey, dataCrazyKey, cronSecret };
}

function client(url: string, key: string, token?: string): SupabaseClient {
  return createClient(url, key, {
    auth: { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false },
    ...(token ? { global: { headers: { Authorization: `Bearer ${token}` } } } : {}),
  });
}

function bearerToken(request: Request): string | null {
  return request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1] ?? null;
}

function sameSecret(actual: string | null, expected: string): boolean {
  if (!actual || actual.length !== expected.length) return false;
  let difference = 0;
  for (let i = 0; i < expected.length; i += 1) difference |= actual.charCodeAt(i) ^ expected.charCodeAt(i);
  return difference === 0;
}

async function readBody(request: Request): Promise<Body | null> {
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > MAX_BODY_BYTES) return null;
  const raw = await request.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) return null;
  try {
    const parsed: unknown = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Body : null;
  } catch {
    return null;
  }
}

async function adminUser(request: Request, env: Env): Promise<{ id: string; client: SupabaseClient } | null> {
  const token = bearerToken(request);
  if (!token) return null;
  const userClient = client(env.url, env.publicKey, token);
  const { data: auth, error: authError } = await userClient.auth.getUser(token);
  if (authError || !auth.user) return null;
  const { data: member, error: memberError } = await userClient.schema(DATA_SCHEMA)
    .from("account_members").select("role").eq("user_id", auth.user.id).maybeSingle();
  if (memberError || member?.role !== "admin") return null;
  return { id: auth.user.id, client: userClient };
}

function rpcData<T>(result: { data: T | null; error: { message: string } | null }, fallback: string): T {
  if (result.error || result.data == null) throw new SyncError(fallback, false, 503);
  return result.data;
}

function object(value: unknown): JsonObject | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : null;
}

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function fieldText(value: unknown): string {
  if (typeof value === "string" || typeof value === "number") return String(value).trim();
  if (Array.isArray(value)) return value.map(fieldText).filter(Boolean).join(", ");
  const item = object(value);
  if (item) return fieldText(item.name ?? item.label ?? item.value);
  return "";
}

function normalized(value: unknown): string {
  return text(value).normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    .toLowerCase().replace(/[^a-z0-9]/g, "");
}

function canonicalUuid(value: unknown): string | null {
  const cleaned = text(value).replace(/^\{|\}$/g, "").toLowerCase();
  return UUID.test(cleaned) ? cleaned : null;
}

function sourceId(value: unknown): string | null {
  const id = text(value);
  if (id.length === 0 || id.length > 128) return null;
  return UUID.test(id) ? id.toLowerCase() : id;
}

function dateOnly(value: unknown): string | null {
  const raw = fieldText(value);
  if (!raw) return null;
  const iso = raw.match(/^(\d{4})-(\d{2})-(\d{2})(?:$|T|\s)/);
  const br = raw.match(/^(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{4})(?:$|\s)/);
  const year = iso ? Number(iso[1]) : br ? Number(br[3]) : 0;
  const month = iso ? Number(iso[2]) : br ? Number(br[2]) : 0;
  const day = iso ? Number(iso[3]) : br ? Number(br[1]) : 0;
  if (!year || !month || !day) return null;
  const d = new Date(Date.UTC(year, month - 1, day));
  return d.getUTCFullYear() === year && d.getUTCMonth() === month - 1 && d.getUTCDate() === day
    ? `${year.toString().padStart(4, "0")}-${month.toString().padStart(2, "0")}-${day.toString().padStart(2, "0")}`
    : null;
}

function cpf(value: unknown): string | null {
  const digits = fieldText(value).replace(/\D/g, "");
  if (digits.length !== 11 || /^(\d)\1{10}$/.test(digits)) return null;
  const digit = (head: string, weight: number) => {
    const sum = [...head].reduce((total, n, i) => total + Number(n) * (weight - i), 0);
    const mod = (sum * 10) % 11;
    return mod === 10 ? 0 : mod;
  };
  return Number(digits[9]) === digit(digits.slice(0, 9), 10)
      && Number(digits[10]) === digit(digits.slice(0, 10), 11) ? digits : null;
}

function phone(value: unknown): { value: string | null; unavailable: boolean } {
  const raw = fieldText(value);
  if (!raw) return { value: null, unavailable: false };
  if (/[eE][+-]?\d+/.test(raw)) return { value: null, unavailable: true };
  const digits = raw.replace(/\D/g, "");
  return { value: digits.length >= 10 && digits.length <= 13 ? digits : null, unavailable: false };
}

function extraFields(lead: JsonObject): Map<string, JsonObject> {
  const fields = new Map<string, JsonObject>();
  const source = lead.additionalFields;
  if (!Array.isArray(source)) return fields;
  for (const item of source) {
    const field = object(item);
    if (!field) continue;
    const name = normalized(object(field.additionalField)?.name ?? field.name);
    if (name) fields.set(name, field);
  }
  return fields;
}

function extraValue(field: JsonObject | undefined): unknown {
  for (const candidate of [field?.value, field?.valueDate, field?.valueText]) {
    if (candidate !== null && candidate !== undefined && fieldText(candidate)) return candidate;
  }
  return null;
}

function businessRow(value: unknown): JsonObject | null {
  const business = object(value);
  if (!business) return null;
  const businessId = sourceId(business.id);
  const leadId = sourceId(business.leadId);
  const stage = object(business.stage);
  const pipeline = object(stage?.pipeline) ?? object(business.pipeline);
  const pipelineId = text(pipeline?.id ?? stage?.pipelineId ?? business.pipelineId).toLowerCase();
  const influencerId = PIPELINES[pipelineId]?.influencerId;
  return businessId && leadId && influencerId ? { businessId, leadId, influencerId } : null;
}

function leadRow(value: unknown): JsonObject | null {
  const lead = object(value);
  if (!lead) return null;
  const leadId = sourceId(lead.id);
  const fields = extraFields(lead);
  const uuid = canonicalUuid(extraValue(fields.get("iddoentregador")));
  if (!leadId || !uuid) return null;
  const region = fieldText(extraValue(fields.get("regioes"))) || fieldText(object(lead.address)?.city);
  const releasedAt = dateOnly(extraValue(fields.get("liberadodia")));
  const number = phone(lead.rawPhone ?? lead.phone);
  return {
    leadId,
    uuid,
    name: text(lead.name),
    region,
    releasedAt,
    phone: number.value,
    cpf: cpf(lead.taxId),
    phoneUnavailable: number.unavailable,
  };
}

function toClaim(value: unknown): Claim | null {
  const item = object(value);
  if (!item) return null;
  const phase = item.phase;
  const runId = text(item.runId);
  const leaseToken = text(item.leaseToken);
  const businessMonth = text(item.businessMonth);
  const leadMonth = text(item.leadMonth);
  const snapshotUntil = text(item.snapshotUntil);
  if (!runId || !leaseToken || !/^\d{4}-\d{2}-\d{2}$/.test(businessMonth)
    || !/^\d{4}-\d{2}-\d{2}$/.test(leadMonth) || !Number.isFinite(Date.parse(snapshotUntil))
    || (phase !== "businesses" && phase !== "leads" && phase !== "ready")) return null;
  return {
    runId,
    leaseToken,
    phase,
    businessesSkip: Number(item.businessesSkip) || 0,
    leadsSkip: Number(item.leadsSkip) || 0,
    businessMonth,
    leadMonth,
    snapshotUntil,
  };
}

async function wait(ms: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, ms));
}

async function apiGet(env: Env, route: "pipelines" | "businesses" | "leads", params?: URLSearchParams): Promise<{ data: unknown[]; remaining: number | null; resetSeconds: number | null }> {
  const url = `${API_BASE}/${route}${params ? `?${params.toString()}` : ""}`;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const last = lastRequestAt.get(route) ?? 0;
    const delay = Math.max(0, MIN_ROUTE_INTERVAL_MS - (Date.now() - last));
    if (delay) await wait(delay);
    lastRequestAt.set(route, Date.now());
    let result: Response;
    try {
      result = await fetch(url, {
        method: "GET",
        headers: { Authorization: `Bearer ${env.dataCrazyKey}`, Accept: "application/json" },
        signal: AbortSignal.timeout(20_000),
      });
    } catch {
      if (attempt < 2) { await wait(1_500 * (attempt + 1)); continue; }
      throw new SyncError("A API Data Crazy está temporariamente indisponível.", true, 503, 60);
    }
    if (result.status === 429 || result.status >= 500) {
      const retrySeconds = retryAfterSeconds(result.headers.get("Retry-After"));
      const delayMs = retrySeconds !== null ? Math.min(retrySeconds * 1_000, 3_600_000)
        : 2_000 * (attempt + 1);
      if (attempt < 2 && delayMs <= 8_000) { await wait(delayMs); continue; }
      throw new SyncError(
        "A API Data Crazy atingiu o limite ou está indisponível; a sincronização continuará depois.",
        true,
        503,
        retrySeconds ?? 60,
      );
    }
    if (result.status === 401 || result.status === 403) {
      throw new SyncError("A chave da API Data Crazy foi recusada. Confira o secret do servidor.", false, 503);
    }
    if (!result.ok) throw new SyncError(`A API Data Crazy respondeu com HTTP ${result.status}.`, false, 503);
    let body: unknown;
    try { body = await result.json(); } catch { throw new SyncError("Resposta inválida da API Data Crazy.", false); }
    const items = object(body)?.data;
    if (!Array.isArray(items)) throw new SyncError("Formato inesperado da API Data Crazy.", false);
    const remainingHeader = result.headers.get("X-RateLimit-Remaining");
    const remainingRaw = remainingHeader === null ? NaN : Number(remainingHeader);
    const resetHeader = result.headers.get("X-RateLimit-Reset");
    const resetRaw = resetHeader === null ? NaN : Number(resetHeader);
    return {
      data: items,
      remaining: Number.isFinite(remainingRaw) ? remainingRaw : null,
      resetSeconds: Number.isFinite(resetRaw) && resetRaw >= 0 ? Math.ceil(resetRaw) : null,
    };
  }
  throw new SyncError("A API Data Crazy está indisponível.", true, 503, 60);
}

async function checkPipelines(env: Env): Promise<void> {
  const { data } = await apiGet(env, "pipelines");
  const seen = new Set<string>();
  for (const value of data) {
    const pipeline = object(value);
    const id = text(pipeline?.id).toLowerCase();
    const mapped = PIPELINES[id];
    if (!mapped) continue;
    const group = object(pipeline?.group);
    const groupName = normalized(group?.name ?? pipeline?.group);
    if (groupName !== "influencers" || normalized(pipeline?.name) !== mapped.normalizedName) {
      throw new SyncError("O mapeamento de uma pipeline Data Crazy mudou. A lista atual foi preservada.", false);
    }
    seen.add(id);
  }
  if (seen.size !== Object.keys(PIPELINES).length) {
    throw new SyncError("Uma ou mais pipelines de influenciadores não foram encontradas. A lista atual foi preservada.", false);
  }
}

async function checkDateCoverage(env: Env): Promise<void> {
  // The monthly cursor starts in 2026. Fail closed if the tenant has older
  // records, so a new historic import never silently disappears.
  for (const route of ["businesses", "leads"] as const) {
    const params = new URLSearchParams({ skip: "0", take: "1" });
    params.set("filter[createdAtLessOrEqual]", BEFORE_FIRST_SYNC_MONTH);
    const { data } = await apiGet(env, route, params);
    if (data.length > 0) {
      throw new SyncError("Há registros Data Crazy anteriores a 2026. A lista atual foi preservada para ampliar o período da coleta.", false);
    }
  }
}

function nextMonth(month: string): string {
  const date = new Date(`${month}T00:00:00.000Z`);
  if (!Number.isFinite(date.getTime())) throw new SyncError("Mês de coleta inválido.", false);
  date.setUTCMonth(date.getUTCMonth() + 1);
  return date.toISOString().slice(0, 10);
}

function pageParams(phase: Claim["phase"], skip: number, month: string, snapshotUntil: string): URLSearchParams {
  const params = new URLSearchParams({ skip: String(skip), take: String(PAGE_SIZE) });
  const start = `${month}T00:00:00.000Z`;
  const end = new Date(Math.min(Date.parse(snapshotUntil), Date.parse(`${nextMonth(month)}T00:00:00.000Z`) - 1));
  if (start > end.toISOString()) throw new SyncError("Janela de coleta inválida.", false);
  params.set("filter[createdAtGreaterOrEqual]", start);
  params.set("filter[createdAtLessOrEqual]", end.toISOString());
  if (phase === "leads") params.set("complete[additionalFields]", "true");
  return params;
}

function retryAfterSeconds(value: string | null): number | null {
  if (!value) return null;
  const seconds = Number(value);
  if (Number.isFinite(seconds) && seconds >= 0) return Math.ceil(seconds);
  const date = Date.parse(value);
  return Number.isFinite(date) ? Math.max(1, Math.ceil((date - Date.now()) / 1_000)) : null;
}

async function status(service: SupabaseClient, runId?: string | null): Promise<JsonObject | null> {
  const result = await service.schema(DATA_SCHEMA).rpc("get_data_crazy_sync_status", { p_run_id: runId ?? null });
  if (result.error) throw new SyncError("Não foi possível consultar a sincronização.", false);
  return object(result.data);
}

async function fail(service: SupabaseClient, claim: Claim, message: string): Promise<void> {
  await service.schema(DATA_SCHEMA).rpc("fail_data_crazy_sync", {
    p_run_id: claim.runId,
    p_lease_token: claim.leaseToken,
    p_message: message.slice(0, 400),
  });
}

async function work(service: SupabaseClient, env: Env, runId?: string, maxPages = MAX_PAGES_PER_INVOCATION): Promise<JsonObject | null> {
  const claimResult = await service.schema(DATA_SCHEMA).rpc("claim_data_crazy_sync", { p_run_id: runId ?? null });
  if (claimResult.error) throw new SyncError("Não foi possível reservar a sincronização.", false);
  const claim = toClaim(claimResult.data);
  if (!claim) return status(service, runId);
  try {
    await checkPipelines(env);
    await checkDateCoverage(env);
    let published = false;
    let pauseSeconds = 1;
    for (let page = 0; page < maxPages; page += 1) {
      if (claim.phase === "ready") {
        rpcData(await service.schema(DATA_SCHEMA).rpc("publish_data_crazy_sync", {
          p_run_id: claim.runId,
          p_lease_token: claim.leaseToken,
        }), "Não foi possível publicar a sincronização.");
        published = true;
        break;
      }
      const phase = claim.phase;
      const cursor = phase === "businesses" ? claim.businessesSkip : claim.leadsSkip;
      const month = phase === "businesses" ? claim.businessMonth : claim.leadMonth;
      const source = await apiGet(env, phase, pageParams(phase, cursor, month, claim.snapshotUntil));
      const nextCursor = cursor + source.data.length;
      const done = source.data.length < PAGE_SIZE;
      if (!done && nextCursor >= 10_000) {
        throw new SyncError("Um mês atingiu o limite de paginação da Data Crazy. A lista atual foi preservada.", false);
      }
      const rows = source.data.map(phase === "businesses" ? businessRow : leadRow).filter(Boolean);
      const next = object(rpcData(
        await service.schema(DATA_SCHEMA).rpc("append_data_crazy_sync_page", {
          p_run_id: claim.runId,
          p_lease_token: claim.leaseToken,
          p_phase: phase,
          p_cursor: cursor,
          p_rows: rows,
          p_next_cursor: nextCursor,
          // Data Crazy's count has sometimes been a page count. Use the
          // observed final cursor rather than trusting it for termination.
          p_total: done ? nextCursor : null,
          p_done: done,
        }),
        "Não foi possível salvar uma página da sincronização.",
      ));
      if (!next) throw new SyncError("Estado inesperado da sincronização.", false);
      const nextPhase = next.phase;
      if (nextPhase !== "businesses" && nextPhase !== "leads" && nextPhase !== "ready") {
        throw new SyncError("Estado inesperado da sincronização.", false);
      }
      if (Number(next.cursor) !== nextCursor) {
        throw new SyncError("Cursor inesperado da sincronização.", false);
      }
      if (phase === "businesses") {
        claim.businessesSkip = done ? 0 : nextCursor;
        if (done && nextPhase === "businesses") claim.businessMonth = nextMonth(month);
      } else {
        claim.leadsSkip = done ? 0 : nextCursor;
        if (done && nextPhase === "leads") claim.leadMonth = nextMonth(month);
      }
      claim.phase = nextPhase;
      if (source.remaining !== null && source.remaining <= 2) {
        pauseSeconds = Math.max(1, source.resetSeconds ?? 60);
        break;
      }
    }
    if (claim.phase === "ready" && !published) {
      rpcData(await service.schema(DATA_SCHEMA).rpc("publish_data_crazy_sync", {
        p_run_id: claim.runId,
        p_lease_token: claim.leaseToken,
      }), "Não foi possível publicar a sincronização.");
      published = true;
    }
    if (!published) {
      const deferred = await service.schema(DATA_SCHEMA).rpc("defer_data_crazy_sync", {
        p_run_id: claim.runId,
        p_lease_token: claim.leaseToken,
        p_delay_seconds: Math.min(pauseSeconds, 3_600),
      });
      if (deferred.error || deferred.data !== true) {
        throw new SyncError("Não foi possível agendar a próxima etapa da sincronização.", false);
      }
    }
  } catch (error) {
    const syncError = error instanceof SyncError ? error : new SyncError("Falha inesperada na sincronização.", false);
    if (syncError.retryable) {
      const deferred = await service.schema(DATA_SCHEMA).rpc("defer_data_crazy_sync", {
        p_run_id: claim.runId,
        p_lease_token: claim.leaseToken,
        p_delay_seconds: Math.max(1, Math.min(syncError.retryAfterSeconds, 3_600)),
      });
      if (deferred.error || deferred.data !== true) {
        await fail(service, claim, "Não foi possível agendar a retomada da sincronização.");
      }
    } else {
      await fail(service, claim, syncError.message);
    }
    // Retriable errors keep staged pages and cursor intact. The defer RPC
    // prevents the next cron tick from violating Retry-After.
  }
  return status(service, claim.runId);
}

async function start(service: SupabaseClient, env: Env, trigger: "manual" | "scheduled", actorId: string | null): Promise<JsonObject | null> {
  const started = object(rpcData(
    await service.schema(DATA_SCHEMA).rpc("start_data_crazy_sync", {
      p_trigger: trigger,
      p_actor_id: actorId,
    }),
    "Não foi possível iniciar a sincronização.",
  ));
  const runId = text(started?.runId);
  if (!runId) throw new SyncError("Resposta inesperada ao iniciar a sincronização.", false);
  // Return a manual request promptly; cron advances the remaining pages.
  await work(service, env, runId, 1);
  return status(service, runId);
}

Deno.serve(async (request: Request) => {
  const origin = request.headers.get("origin");
  if (origin && !configuredOrigins().has(origin)) return new Response("Origin not allowed", { status: 403 });
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(origin) });
  if (request.method !== "POST") return response(origin, { error: "Método não permitido." }, 405);
  const body = await readBody(request);
  if (!body) return response(origin, { error: "Solicitação inválida ou muito grande." }, 400);
  const action = body.action as SyncAction;
  if (!["start", "status", "cron-start", "advance"].includes(action)) {
    return response(origin, { error: "Ação inválida." }, 400);
  }
  const env = environment();
  if (!env) return response(origin, { error: "A sincronização ainda não está configurada no servidor." }, 503);
  const workerAction = action === "cron-start" || action === "advance";
  if (workerAction && !sameSecret(request.headers.get("x-cron-secret"), env.cronSecret)) {
    return response(origin, { error: "Acesso negado." }, 403);
  }
  const admin = workerAction ? null : await adminUser(request, env);
  if (!workerAction && !admin) return response(origin, { error: "Apenas administradores podem sincronizar a Data Crazy." }, 403);
  const service = client(env.url, env.serviceKey);
  try {
    if (action === "status") {
      const runId = body.runId === undefined || body.runId === null ? null : text(body.runId);
      if (runId && !UUID.test(runId)) return response(origin, { error: "Identificador inválido." }, 400);
      const result = await admin!.client.schema(DATA_SCHEMA).rpc("get_data_crazy_sync_status", { p_run_id: runId });
      if (result.error) throw new SyncError("Não foi possível consultar a sincronização.", false);
      return response(origin, result.data);
    }
    if (action === "start") return response(origin, await start(service, env, "manual", admin!.id));
    if (action === "cron-start") return response(origin, await start(service, env, "scheduled", null));
    return response(origin, await work(service, env));
  } catch (error) {
    // Neither API response bodies nor credentials nor lead data are logged.
    const safe = error instanceof SyncError ? error : new SyncError("Não foi possível concluir a sincronização.", false);
    return response(origin, { error: safe.message }, safe.statusCode);
  }
});
