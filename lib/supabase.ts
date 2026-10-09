import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export const DATA_SCHEMA = "indique_ganhe_influencer";
const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

let browserClient: SupabaseClient | null = null;

export function getSupabase(): SupabaseClient | null {
  if (!supabaseUrl || !publishableKey) return null;
  browserClient ??= createClient(supabaseUrl, publishableKey, {
    auth: {
      autoRefreshToken: true,
      persistSession: true,
      detectSessionInUrl: true,
      flowType: "pkce",
    },
  });
  return browserClient;
}

export async function callAccessApi<T>(payload: Record<string, unknown>): Promise<T> {
  const supabase = getSupabase();
  if (!supabase) throw new Error("O acesso ao Supabase ainda não foi configurado neste Site.");
  const { data, error } = await supabase.functions.invoke("indique-ganhe-access", { body: payload });
  if (error) {
    let message = error.message;
    try {
      const context = error.context as Response | undefined;
      const detail: unknown = context && typeof context.json === "function" ? await context.json() : null;
      if (detail && typeof detail === "object" && "error" in detail && typeof detail.error === "string") message = detail.error;
    } catch { /* Keep the transport error when no JSON response exists. */ }
    throw new Error(message);
  }
  return data as T;
}

export async function callDataCrazySync<T>(payload: { action: "start" | "status"; runId?: string }): Promise<T> {
  const supabase = getSupabase();
  if (!supabase) throw new Error("O acesso ao Supabase ainda não foi configurado neste Site.");
  const { data, error } = await supabase.functions.invoke("indique-ganhe-datacrazy-sync", { body: payload });
  if (error) {
    let message = error.message;
    try {
      const context = error.context as Response | undefined;
      const detail: unknown = context && typeof context.json === "function" ? await context.json() : null;
      if (detail && typeof detail === "object" && "error" in detail && typeof detail.error === "string") message = detail.error;
    } catch { /* Keep the transport error when the function returns no JSON. */ }
    throw new Error(message);
  }
  return data as T;
}

export async function callAdminApi<T>(
  action: string,
  payload: Record<string, unknown>,
): Promise<T> {
  const supabase = getSupabase();
  if (!supabase) throw new Error("O acesso ao Supabase ainda não foi configurado neste Site.");
  let data: unknown;
  let error: { message: string } | null = null;
  if (action === "profile") {
    const { error: claimError } = await supabase.schema(DATA_SCHEMA).rpc("claim_invite");
    if (claimError && !claimError.message.toLowerCase().includes("no pending invite")) error = claimError;
    if (!error) {
      const result = await supabase.schema(DATA_SCHEMA).rpc("current_profile");
      data = result.data;
      error = result.error;
    }
  } else if (action === "admin-overview") {
    const result = await supabase.schema(DATA_SCHEMA).rpc("admin_overview");
    data = result.data; error = result.error;
  } else if (action === "account-name-set") {
    const result = await supabase.schema(DATA_SCHEMA).rpc("update_admin_display_name", {
      p_user_id: payload.userId,
      p_display_name: payload.displayName,
    });
    data = result.data; error = result.error;
  } else if (action === "admin-referrals") {
    const result = await supabase.schema(DATA_SCHEMA).rpc("admin_referrals_page", {
      p_limit: payload.limit,
      p_offset: payload.offset,
      p_influencer_id: payload.influencerId,
      p_search: payload.search,
    });
    data = result.data; error = result.error;
  } else if (action === "import-start") {
    const result = await supabase.schema(DATA_SCHEMA).rpc("start_import", {
      p_kind: payload.kind,
      p_file_name: payload.fileName,
      p_file_hash: payload.fileHash,
      p_metrics: payload.metrics,
      p_total_rows: payload.totalRows,
    });
    data = result.data; error = result.error;
  } else if (action === "import-chunk") {
    const result = await supabase.schema(DATA_SCHEMA).rpc("append_import_rows", {
      p_batch_id: payload.batchId,
      p_rows: payload.rows,
    });
    data = result.data; error = result.error;
  } else if (action === "import-complete") {
    const result = await supabase.schema(DATA_SCHEMA).rpc("complete_import", { p_batch_id: payload.batchId });
    data = result.data; error = result.error;
  } else if (action === "import-cancel") {
    const result = await supabase.schema(DATA_SCHEMA).rpc("cancel_import", { p_batch_id: payload.batchId });
    data = result.data; error = result.error;
  } else if (action === "import-fail") {
    const result = await supabase.schema(DATA_SCHEMA).rpc("fail_import", {
      p_batch_id: payload.batchId,
      p_error_message: payload.errorMessage,
    });
    data = result.data; error = result.error;
  } else if (action === "import-history") {
    const result = await supabase.schema(DATA_SCHEMA).rpc("list_import_history", {
      p_limit: payload.limit,
      p_offset: payload.offset,
      p_status: payload.status,
      p_kind: payload.kind,
    });
    data = result.data; error = result.error;
  } else if (action === "import-events") {
    const result = await supabase.schema(DATA_SCHEMA).rpc("list_import_events", {
      p_batch_id: payload.batchId,
    });
    data = result.data; error = result.error;
  } else if (action === "review-assign") {
    const result = await supabase.schema(DATA_SCHEMA).rpc("assign_review", {
      p_review_id: payload.reviewId,
      p_influencer_id: payload.influencerId,
    });
    data = result.data; error = result.error;
  } else if (action === "invite-account") {
    const result = await supabase.schema(DATA_SCHEMA).rpc("create_account_invite", {
      p_email: payload.email,
      p_influencer_id: payload.influencerId,
    });
    data = result.data; error = result.error;
  } else if (action === "revoke-invite") {
    const result = await supabase.schema(DATA_SCHEMA).rpc("revoke_account_invite", { p_invite_id: payload.inviteId });
    data = result.data; error = result.error;
  } else {
    throw new Error("Ação administrativa desconhecida.");
  }
  if (error) {
    throw new Error(error.message);
  }
  return data as T;
}
