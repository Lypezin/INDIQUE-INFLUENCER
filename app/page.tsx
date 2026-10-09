"use client";

import { useCallback, useEffect, useMemo, useState, useSyncExternalStore, type ChangeEvent, type FormEvent } from "react";
import type { Session } from "@supabase/supabase-js";
import {
  ArrowDownUp, ArrowRight, Award, BarChart3, Check, CheckCircle2, ChevronDown,
  CircleAlert, ClipboardList, CloudUpload, Download, Eye, EyeOff, FileSpreadsheet,
  CalendarDays, Gift, History, LoaderCircle, LogOut, Mail, MapPin, Menu, Moon, Search, ShieldCheck, Sun, UserRound, Users, XCircle,
} from "lucide-react";
import { callAccessApi, callAdminApi, callDataCrazySync, DATA_SCHEMA, getSupabase } from "@/lib/supabase";
import {
  parsePerformance, type ImportPreview, type PerformanceImportRow,
  repairTextEncoding,
} from "@/lib/importers";

type Role = "admin" | "influencer";
type Profile = { user_id: string; role: Role; influencer_id: string | null; email: string; display_name: string | null };
type Influencer = { id: string; name: string; route_goal: number; prize_cents: number; is_demo?: boolean };
type Referral = {
  referral_id: string;
  uuid: string;
  name: string;
  region: string | null;
  released_at: string | null;
  phone: string | null;
  cpf: string | null;
  routes: number;
  route_goal: number;
  prize_cents: number;
  prize_unlocked: boolean;
  routes_remaining: number;
  influencer_name: string;
};
type ImportSummary = { id: string; kind: string; file_name: string; status: string; created_at: string; metrics: Record<string, number> };
type ImportHistoryEntry = {
  id: string; kind: "data_crazy" | "performance"; source?: "api" | "file"; file_name: string; file_hash_prefix: string;
  status: "staging" | "completed" | "failed" | "cancelled"; metrics: Record<string, number>;
  expected_rows: number; staged_rows: number; created_at: string; completed_at: string | null;
  finished_at: string | null; error_message: string | null; actor_email: string | null; actor_display_name?: string | null;
  duration_seconds: number; last_event_message: string | null;
};
type ImportHistorySummary = { total: number; staging: number; completed: number; failed: number; cancelled: number };
type ImportHistoryResult = { items: ImportHistoryEntry[]; total: number; summary: ImportHistorySummary };
type ImportEvent = { id: number; event_type: string; message: string; details: Record<string, unknown>; created_at: string; actor_email: string | null; actor_display_name?: string | null };
type DataCrazySyncRun = {
  id: string; status: "running" | "completed" | "failed"; phase: string;
  processed: number; total: number; metrics: Record<string, number>;
  windowMonth?: string | null; errorMessage: string | null; startedAt: string; completedAt: string | null;
};
type Review = { id: string; uuid: string; name: string; region: string | null; raw_influencer: string; status: string };
type Member = { user_id: string; email: string; role: Role; display_name: string | null; influencer_id: string | null; influencer_name: string | null };
type PendingInvite = { id: string; email: string; role: Role; influencer_name: string | null; created_at: string };
type AdminOverview = { influencers: Influencer[]; availableInfluencers: Influencer[]; imports: ImportSummary[]; reviews: Review[]; reviewCount: number; members: Member[]; invites: PendingInvite[]; referralCount: number; contributionTotal: number };
type PerformanceCoverageCity = { city: string; firstDate: string | null; lastDate: string | null; rowCount: number; importCount: number };
type PerformanceCoverage = { firstDate: string | null; lastDate: string | null; rowCount: number; importCount: number; uncapturedImportCount: number; cities: PerformanceCoverageCity[] };
type AdminReferral = { uuid: string; name: string; region: string | null; released_at: string | null; phone: string | null; cpf: string | null; influencer_id: string; influencer_name: string; routes: number; route_goal: number; prize_cents: number; prize_unlocked: boolean; routes_remaining: number };
type AdminReferralsResult = { items: AdminReferral[]; total: number; totalRoutes: number; unlockedCount: number; unlockedPrizeCents: number };
type TabId = "dashboard" | "referrals" | "data-crazy" | "performance" | "reviews" | "accounts" | "profile" | "imports";
type Theme = "light" | "dark";

const fmtMoney = (cents: number) => new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" }).format(cents / 100);
const fmtNumber = (number: number) => new Intl.NumberFormat("pt-BR").format(number);
const fmtDate = (value: string | null) => {
  if (!value) return "Não informada";
  const dateOnly = value.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  const date = dateOnly
    ? new Date(Number(dateOnly[1]), Number(dateOnly[2]) - 1, Number(dateOnly[3]))
    : new Date(value);
  return Number.isNaN(date.getTime()) ? "Não informada" : date.toLocaleDateString("pt-BR");
};
const fmtDateRange = (first: string | null, last: string | null) => {
  if (!first || !last) return "Sem dados";
  const start = fmtDate(first);
  const end = fmtDate(last);
  return start === end ? start : `${start} – ${end}`;
};
const subscribeRecovery = (callback: () => void) => {
  window.addEventListener("hashchange", callback);
  window.addEventListener("popstate", callback);
  return () => { window.removeEventListener("hashchange", callback); window.removeEventListener("popstate", callback); };
};
const getRecoverySnapshot = () => typeof window !== "undefined" && (window.location.hash.includes("type=recovery") || window.location.search.includes("type=recovery"));
const getRecoveryServerSnapshot = () => false;
const adminTabs: { id: TabId; label: string; icon: typeof BarChart3 }[] = [
  { id: "dashboard", label: "Visão geral", icon: BarChart3 },
  { id: "referrals", label: "Indicados", icon: Users },
  { id: "data-crazy", label: "Data Crazy", icon: FileSpreadsheet },
  { id: "performance", label: "Performance", icon: ArrowDownUp },
  { id: "reviews", label: "Revisões", icon: ClipboardList },
  { id: "accounts", label: "Acessos", icon: Users },
  { id: "profile", label: "Meu perfil", icon: UserRound },
  { id: "imports", label: "Importações", icon: History },
];

function savedAdminTab(email: string): TabId {
  if (typeof window === "undefined") return "dashboard";
  try {
    const value = window.localStorage.getItem(`indique-ganhe:admin-tab:${email.trim().toLowerCase()}`);
    return adminTabs.some((tab) => tab.id === value) ? value as TabId : "dashboard";
  } catch { return "dashboard"; }
}

export default function Home() {
  const supabase = useMemo(() => getSupabase(), []);
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [influencer, setInfluencer] = useState<Influencer | null>(null);
  const [referrals, setReferrals] = useState<Referral[]>([]);
  const [lastImportAt, setLastImportAt] = useState<string | null>(null);
  const [overview, setOverview] = useState<AdminOverview | null>(null);
  const [loading, setLoading] = useState(true);
  const recoveryMode = useSyncExternalStore(subscribeRecovery, getRecoverySnapshot, getRecoveryServerSnapshot);
  const [loadError, setLoadError] = useState("");
  const [activeTab, setActiveTab] = useState<TabId>("dashboard");
  const [theme, setTheme] = useState<Theme>("light");
  const [mobileMenu, setMobileMenu] = useState(false);
  const [search, setSearch] = useState("");
  const [onlyUnlocked, setOnlyUnlocked] = useState(false);

  useEffect(() => {
    try { if (window.localStorage.getItem("indique-ganhe:theme") === "dark") setTheme("dark"); }
    catch { /* Theme preference is optional when browser storage is unavailable. */ }
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    document.documentElement.style.colorScheme = theme;
    try { window.localStorage.setItem("indique-ganhe:theme", theme); }
    catch { /* The current theme still works when browser storage is unavailable. */ }
  }, [theme]);

  const selectTab = useCallback((tab: TabId) => {
    setActiveTab(tab);
    if (profile?.role !== "admin") return;
    try { window.localStorage.setItem(`indique-ganhe:admin-tab:${profile.email.trim().toLowerCase()}`, tab); }
    catch { /* The current view still works when browser storage is unavailable. */ }
  }, [profile]);

  const updateProfileDisplayName = useCallback((userId: string, displayName: string | null) => {
    setProfile((current) => current?.user_id === userId ? { ...current, display_name: displayName } : current);
  }, []);

  const loadWorkspace = useCallback(async () => {
    setLoading(true);
    setLoadError("");
    try {
      const nextProfile = await callAdminApi<Profile>("profile", {});
      setProfile(nextProfile);
      if (nextProfile.role === "admin") {
        const data = await callAdminApi<AdminOverview>("admin-overview", {});
        setOverview(data);
        setInfluencer(null);
        setReferrals([]);
        setLastImportAt(null);
        setActiveTab(savedAdminTab(nextProfile.email));
      } else {
        const [{ data: influencerData, error: influencerError }, referralData, { data: importDate, error: importDateError }] = await Promise.all([
          supabase!.schema(DATA_SCHEMA).from("influencers").select("id,name,route_goal,prize_cents,is_demo").eq("id", nextProfile.influencer_id).single(),
          (async () => {
            const all: Referral[] = [];
            for (let offset = 0; ; offset += 500) {
              const { data, error } = await supabase!.schema(DATA_SCHEMA).from("referral_progress")
                .select("referral_id,uuid,name,region,released_at,phone,cpf,routes,route_goal,prize_cents,prize_unlocked,routes_remaining,influencer_name")
                .order("prize_unlocked", { ascending: false }).order("routes", { ascending: false }).order("uuid")
                .range(offset, offset + 499);
              if (error) throw error;
              all.push(...((data ?? []) as Referral[]).map((item) => ({
                ...item,
                name: repairTextEncoding(item.name),
                region: item.region ? repairTextEncoding(item.region) : null,
              })));
              if (!data || data.length < 500) break;
            }
            return all;
          })(),
          supabase!.schema(DATA_SCHEMA).rpc("last_import_at"),
        ]);
        if (influencerError) throw influencerError;
        if (importDateError) throw importDateError;
        setInfluencer(influencerData as Influencer);
        setReferrals(referralData);
        setLastImportAt(importDate as string | null);
        setOverview(null);
        setActiveTab("dashboard");
      }
    } catch (error) {
      setLoadError(error instanceof Error ? error.message : "Não foi possível carregar seus dados.");
    } finally {
      setLoading(false);
    }
  }, [supabase]);

  const refreshAdmin = useCallback(async () => {
    setOverview(await callAdminApi<AdminOverview>("admin-overview", {}));
  }, []);

  useEffect(() => {
    if (!supabase) return;
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      if (data.session) void loadWorkspace();
      else setLoading(false);
    });
    const { data: listener } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setSession(nextSession);
      if (nextSession) void loadWorkspace();
      else {
        setProfile(null);
        setInfluencer(null);
        setReferrals([]);
        setLastImportAt(null);
        setOverview(null);
        setLoading(false);
      }
    });
    return () => listener.subscription.unsubscribe();
  }, [supabase, loadWorkspace]);

  if (!supabase) return <ConfigurationNotice />;
  if (recoveryMode) return <ResetPassword supabase={supabase} />;
  if (loading && !session) return <Splash />;
  if (!session) return <Login supabase={supabase} />;
  if (loading && !profile) return <Splash />;
  if (!profile) return session
    ? <AccessPending email={session.user.email ?? ""} error={loadError} onSignOut={() => void supabase.auth.signOut()} />
    : <Login supabase={supabase} initialError={loadError || "Sua conta ainda não está vinculada. Peça ao administrador que envie um convite."} />;

  const isAdmin = profile.role === "admin";
  const visibleTabs = isAdmin ? adminTabs.filter((tab) => tab.id !== "profile") : adminTabs.slice(0, 1);
  const title = isAdmin ? "Administração" : `Indicações de ${influencer?.name ?? "você"}`;
  const subtitle = isAdmin ? "Indicados, corridas, revisões e acessos" : "Corridas e prêmios por entregador";

  return (
    <main className="portal-shell min-h-screen bg-[#f6f8fc] text-[#172a40]">
      <div className="mx-auto flex min-h-screen max-w-[1600px]">
        <aside className="sticky top-0 hidden h-screen w-[250px] shrink-0 self-start flex-col overflow-y-auto border-r border-[#dfe6f0] bg-white px-5 py-7 lg:flex">
          <Brand />
          <div className="mt-12 text-xs font-bold uppercase tracking-[.18em] text-[#63788e]">Menu</div>
          <nav className="mt-3 space-y-1.5">
            {visibleTabs.map((tab) => <NavButton key={tab.id} tab={tab} active={activeTab === tab.id} onClick={() => selectTab(tab.id)} />)}
          </nav>
        </aside>

        <section className="min-w-0 flex-1">
          <header className="sticky top-0 z-20 flex h-[76px] items-center justify-between gap-2 border-b border-[#dfe6f0] bg-white/95 px-3 backdrop-blur-md sm:px-8 lg:px-10">
            <div className="flex min-w-0 items-center gap-2 sm:gap-3">
              {isAdmin && <button onClick={() => setMobileMenu(!mobileMenu)} className="flex size-11 items-center justify-center rounded-lg text-[#526981] hover:bg-[#f0f4f9] lg:hidden" aria-label={mobileMenu ? "Fechar menu" : "Abrir menu"} aria-expanded={mobileMenu}><Menu size={21} /></button>}
              <div className="min-w-0"><div className="truncate text-sm font-semibold sm:text-[15px]">{title}</div><div className="mt-0.5 hidden text-xs text-[#7a8b8e] sm:block">{subtitle}</div></div>
            </div>
            <div className="flex shrink-0 items-center gap-1 sm:gap-3">
              <div className="hidden text-right sm:block"><div className="text-xs font-semibold">{isAdmin ? profile.display_name || "Administrador" : influencer?.name}</div><div className="mt-0.5 max-w-44 truncate text-[13px] text-[#87979a]">{profile.email}</div></div>
              {isAdmin ? <button type="button" onClick={() => { selectTab("profile"); setMobileMenu(false); }} aria-label="Abrir meu perfil" aria-current={activeTab === "profile" ? "page" : undefined} title="Meu perfil" className="account-avatar flex size-11 shrink-0 items-center justify-center rounded-full bg-[#eaf1fa] text-sm font-bold text-[#1f61af] transition hover:bg-[#dbeafd]">{(profile.display_name?.trim().split(/\s+/).slice(0, 2).map((part) => part[0]).join("") || "AD").toUpperCase()}</button> : <div className="flex size-10 shrink-0 items-center justify-center rounded-full bg-[#eaf1fa] text-sm font-bold text-[#1f61af]">{(influencer?.name?.slice(0, 2) ?? "IG").toUpperCase()}</div>}
              <button onClick={() => setTheme((current) => current === "dark" ? "light" : "dark")} className="flex size-11 items-center justify-center rounded-lg text-[#60758b] hover:bg-[#f0f4f9]" title={`Ativar modo ${theme === "dark" ? "claro" : "escuro"}`} aria-label={`Ativar modo ${theme === "dark" ? "claro" : "escuro"}`}>{theme === "dark" ? <Sun size={19}/> : <Moon size={19}/>}</button>
              <button onClick={() => void supabase.auth.signOut()} className="flex size-11 items-center justify-center rounded-lg text-[#60758b] hover:bg-[#f0f4f9]" title="Sair" aria-label="Sair"><LogOut size={19} /></button>
            </div>
          </header>

          {mobileMenu && <><button className="fixed inset-0 z-20 bg-[#112e53]/20 lg:hidden" aria-label="Fechar menu" onClick={() => setMobileMenu(false)}/><div className="fixed inset-x-0 top-[76px] z-30 border-b border-[#dfe6f0] bg-white px-4 py-3 shadow-lg lg:hidden">{visibleTabs.map((tab) => <NavButton key={tab.id} tab={tab} active={activeTab === tab.id} onClick={() => { selectTab(tab.id); setMobileMenu(false); }} />)}</div></>}
          <div className="mx-auto max-w-[1320px] px-4 pb-12 pt-7 sm:px-8 sm:pt-9 lg:px-10">
            {loadError && <div className="mb-5 flex items-start gap-3 rounded-xl border border-[#f2d8bd] bg-[#fffaf4] p-4 text-sm text-[#84572f]"><CircleAlert size={18} className="mt-0.5 shrink-0" />{loadError}</div>}
            {!isAdmin ? <InfluencerDashboard referrals={referrals} influencer={influencer} lastImportAt={lastImportAt} search={search} setSearch={setSearch} onlyUnlocked={onlyUnlocked} setOnlyUnlocked={setOnlyUnlocked} /> : (
              <AdminDashboard activeTab={activeTab} overview={overview} profile={profile} refresh={refreshAdmin} onTab={selectTab} onAdminNameSaved={updateProfileDisplayName} />
            )}
          </div>
        </section>
      </div>
    </main>
  );
}

function Brand() {
  return <div className="brand-lockup"><img src="/entrego-mark.png" className="size-[2.65rem] shrink-0" alt="Entrego"/><div><div className="brand-name">Indique <span>e Ganhe</span></div><div className="brand-description">Indicações e recompensas</div></div></div>;
}

function NavButton({ tab, active, onClick }: { tab: { id: TabId; label: string; icon: typeof BarChart3 }; active: boolean; onClick: () => void }) {
  const Icon = tab.icon;
  return <button onClick={onClick} className={`flex w-full items-center gap-3 rounded-xl px-3.5 py-3 text-left text-[13px] font-semibold transition ${active ? "bg-[#eaf1fa] text-[#205b9e]" : "text-[#60758b] hover:bg-[#f5f8f7] hover:text-[#24444a]"}`}><Icon size={17} strokeWidth={1.8} />{tab.label}{active && <span className="ml-auto size-1.5 rounded-full bg-[#2f6fc2]" />}</button>;
}

function Splash() {
  return <main className="grid min-h-screen place-items-center bg-[#f6f8fc]"><div className="flex items-center gap-3 rounded-2xl border border-[#e5ebf4] bg-white px-5 py-4 text-sm text-[#526981] shadow-sm"><LoaderCircle className="animate-spin text-[#1f61af]" size={19} />Abrindo seu painel…</div></main>;
}

function ConfigurationNotice() {
  return <main className="grid min-h-screen place-items-center bg-[#f6f8fc] p-6"><div className="max-w-lg rounded-3xl border border-[#dfe6f0] bg-white p-8 shadow-[0_20px_70px_-40px_#234b43]"><Brand /><div className="mt-8 flex size-11 items-center justify-center rounded-2xl bg-[#fff4e2] text-[#b17922]"><CircleAlert size={20} /></div><h1 className="mt-4 text-xl font-bold">Conexão pendente</h1><p className="mt-2 text-sm leading-6 text-[#60758b]">O portal está pronto para conectar ao Supabase. Falta configurar a URL e a chave publicável do projeto antes de habilitar o login.</p></div></main>;
}

function Login({ supabase, initialError = "" }: { supabase: NonNullable<ReturnType<typeof getSupabase>>; initialError?: string }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [mode, setMode] = useState<"login" | "activate" | "reset">("login");
  const [code, setCode] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(initialError);
  const [notice, setNotice] = useState("");

  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true); setError(""); setNotice("");
    try {
      if (mode === "activate") {
        await callAccessApi({ action: "activate", email: email.trim().toLowerCase(), code: code.trim(), password });
        const { error: loginError } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
        if (loginError) throw loginError;
      } else if (mode === "reset") {
        const { error: resetError } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: window.location.origin });
        if (resetError) throw resetError;
        setNotice("Se este e-mail estiver cadastrado, você receberá as instruções para redefinir sua senha.");
      } else {
        const { error: loginError } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
        if (loginError) throw loginError;
      }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Não foi possível concluir o acesso.");
    } finally { setBusy(false); }
  }

  return <main className="login-page">
    <section className="login-context">
      <Brand />
      <div className="login-context-copy">
        <h1>Suas indicações, em um só lugar.</h1>
        <p>Consulte as corridas de cada entregador e saiba quanto falta para cada prêmio.</p>
        <div className="login-rule" aria-hidden="true"><span/><span/><span/><span/></div>
      </div>
      <span className="login-footer">INDIQUE E GANHE</span>
    </section>
    <section className="login-form-area">
      <div className="login-mobile-brand"><Brand /></div>
      <div className="login-form-card">
        <h2>{mode === "login" ? "Acesse seu painel" : mode === "activate" ? "Crie sua senha" : "Redefina sua senha"}</h2>
        <p className="login-intro">{mode === "activate" ? "Use o código recebido da administração para ativar seu acesso." : mode === "reset" ? "Enviaremos um link para o e-mail cadastrado." : "Entre com seu e-mail e senha para consultar suas indicações."}</p>
        <form onSubmit={submit} className="login-form">
          <label>E-mail<input autoComplete="email" type="email" required value={email} onChange={(event) => setEmail(event.target.value)} placeholder="seu@email.com" /></label>
          {mode === "activate" && <label>Código de ativação<input autoComplete="one-time-code" required value={code} onChange={(event) => setCode(event.target.value)} placeholder="Código enviado pelo administrador" /></label>}
          {mode !== "reset" && <label>Senha<span className="password-field"><input autoComplete={mode === "activate" ? "new-password" : "current-password"} type={showPassword ? "text" : "password"} minLength={8} required value={password} onChange={(event) => setPassword(event.target.value)} placeholder={mode === "activate" ? "Crie uma senha de 8 caracteres ou mais" : "Sua senha"}/><button type="button" onClick={() => setShowPassword(!showPassword)} aria-label={showPassword ? "Ocultar senha" : "Mostrar senha"}>{showPassword ? <EyeOff size={19}/> : <Eye size={19}/>}</button></span></label>}
          {error && <p role="alert" className="form-error">{error}</p>}
          {notice && <p role="status" className="form-notice">{notice}</p>}
          <button disabled={busy} className="primary-action">{busy ? <LoaderCircle size={18} className="animate-spin"/> : <>{mode === "login" ? "Entrar" : mode === "activate" ? "Ativar acesso" : "Enviar link"}<ArrowRight size={18}/></>}</button>
        </form>
        <div className="login-links">{mode === "login" ? <><button onClick={() => { setMode("activate"); setError(""); setNotice(""); }}>Primeiro acesso</button><button onClick={() => { setMode("reset"); setError(""); setNotice(""); }}>Esqueci a senha</button></> : <button onClick={() => { setMode("login"); setError(""); setNotice(""); }}>Voltar para entrar</button>}</div>
      </div>
    </section>
  </main>;
}

function AccessPending({ email, error, onSignOut }: { email: string; error: string; onSignOut: () => void }) {
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [claimError, setClaimError] = useState("");
  async function claim(event: FormEvent) {
    event.preventDefault(); setBusy(true); setClaimError("");
    try {
      await callAccessApi({ action: "claim", email, code: code.trim() });
      window.location.reload();
    } catch (cause) { setClaimError(cause instanceof Error ? cause.message : "Não foi possível ativar esta conta."); }
    finally { setBusy(false); }
  }
  return <main className="grid min-h-screen place-items-center bg-[#f6f8fc] p-5"><div className="w-full max-w-md rounded-xl bg-white p-6 shadow-sm sm:p-8"><Brand/><h1 className="mt-8 text-2xl font-semibold">Ative sua conta</h1><p className="mt-2 text-sm leading-6 text-[#60758b]">Você entrou com <strong>{email}</strong>. Insira o código fornecido pela administração para vincular suas indicações.</p><form onSubmit={claim} className="login-form"><label>Código de ativação<input required autoComplete="one-time-code" value={code} onChange={(event)=>setCode(event.target.value)} placeholder="Código recebido da administração"/></label>{(claimError || error) && <p role="alert" className="form-error">{claimError || error}</p>}<button disabled={busy} className="primary-action">{busy ? "Ativando…" : "Ativar conta"}</button></form><button onClick={onSignOut} className="mt-4 min-h-11 text-sm font-semibold text-[#205b9e]">Sair desta conta</button></div></main>;
}

function ResetPassword({ supabase }: { supabase: NonNullable<ReturnType<typeof getSupabase>> }) {
  const [password, setPassword] = useState(""); const [confirm, setConfirm] = useState(""); const [error, setError] = useState(""); const [done, setDone] = useState(false); const [busy, setBusy] = useState(false);
  async function submit(event: FormEvent) {
    event.preventDefault(); setError("");
    if (password !== confirm) { setError("As senhas não são iguais."); return; }
    setBusy(true);
    const { error: updateError } = await supabase.auth.updateUser({ password });
    setBusy(false);
    if (updateError) setError(updateError.message); else setDone(true);
  }
  return <main className="grid min-h-screen place-items-center bg-[#f6f8fc] p-5"><section className="w-full max-w-[410px] rounded-3xl border border-[#dfe6f0] bg-white p-7 shadow-[0_20px_70px_-40px_#234b43]"><Brand/><h1 className="mt-8 text-2xl font-bold">Criar nova senha</h1><p className="mt-2 text-sm leading-6 text-[#60758b]">Escolha uma senha para entrar no seu painel.</p>{done?<><div className="mt-5 rounded-lg bg-[#eaf2fc] p-3 text-xs text-[#205b9e]">Senha atualizada. Você já pode entrar no portal.</div><button onClick={()=>{window.history.replaceState({},document.title,window.location.pathname);window.location.reload();}} className="mt-4 h-11 rounded-lg bg-[#185aa9] px-4 text-xs font-bold text-white">Voltar ao painel</button></>:<form onSubmit={submit} className="mt-5 space-y-3"><input required minLength={8} autoComplete="new-password" type="password" value={password} onChange={(event)=>setPassword(event.target.value)} placeholder="Nova senha" className="h-11 w-full rounded-lg border border-[#d4deeb] px-3 text-sm outline-none focus:border-[#2b6cbb]"/><input required minLength={8} autoComplete="new-password" type="password" value={confirm} onChange={(event)=>setConfirm(event.target.value)} placeholder="Confirme a nova senha" className="h-11 w-full rounded-lg border border-[#d4deeb] px-3 text-sm outline-none focus:border-[#2b6cbb]"/>{error&&<p className="rounded-lg bg-[#fff4f0] p-3 text-xs text-[#a84a36]">{error}</p>}<button disabled={busy} className="h-11 w-full rounded-lg bg-[#185aa9] text-xs font-bold text-white disabled:opacity-55">{busy?"Salvando…":"Salvar nova senha"}</button></form>}</section></main>;
}

function InfluencerDashboard({ referrals, influencer, lastImportAt, search, setSearch, onlyUnlocked, setOnlyUnlocked }: {
  referrals: Referral[]; influencer: Influencer | null; lastImportAt: string | null; search: string; setSearch: (value: string) => void; onlyUnlocked: boolean; setOnlyUnlocked: (value: boolean) => void;
}) {
  const [visibleCount, setVisibleCount] = useState(30);
  useEffect(() => { setVisibleCount(30); }, [search, onlyUnlocked]);
  const totalRoutes = referrals.reduce((total, referral) => total + Number(referral.routes || 0), 0);
  const unlocked = referrals.filter((referral) => referral.prize_unlocked).length;
  const prizeTotal = referrals.filter((referral) => referral.prize_unlocked).reduce((sum, referral) => sum + referral.prize_cents, 0);
  const visible = referrals.filter((referral) => (!onlyUnlocked || referral.prize_unlocked) && `${referral.name} ${referral.region ?? ""} ${referral.uuid}`.toLocaleLowerCase("pt-BR").includes(search.toLocaleLowerCase("pt-BR")));
  return <>
    {influencer?.is_demo && <div className="mb-5 rounded-xl border border-[#e8d7a7] bg-[#fff9e9] px-4 py-3 text-sm font-medium text-[#785b1d]">Demonstração: os entregadores e as corridas desta tela são fictícios.</div>}
    <div className="dashboard-heading"><div><h1>Seus indicados</h1><p>Meta de {fmtNumber(influencer?.route_goal ?? 0)} corridas por entregador · {fmtMoney(influencer?.prize_cents ?? 0)} por prêmio</p></div><span>{influencer?.is_demo ? "Dados de demonstração" : lastImportAt ? `Última importação: ${new Date(lastImportAt).toLocaleString("pt-BR")}` : "Aguardando a primeira importação"}</span></div>
    <section className="referral-section">
      <div className="referral-heading"><div><h2>Progresso dos entregadores</h2><p>Corridas acumuladas até a próxima meta</p></div><div className="referral-controls"><label className="relative"><Search size={18} className="absolute left-3.5 top-1/2 -translate-y-1/2 text-[#8a9aaf]"/><input aria-label="Buscar entregador" value={search} onChange={(event) => setSearch(event.target.value)} className="h-11 w-full rounded-lg border border-[#dfe6f0] bg-white pl-10 pr-3 text-sm outline-none focus:border-[#2c67b2] sm:w-56" placeholder="Nome ou região"/></label><button onClick={() => setOnlyUnlocked(!onlyUnlocked)} aria-pressed={onlyUnlocked} className="filter-action">{onlyUnlocked ? "Limpar filtro" : "Prêmios conquistados"}</button></div></div>
      {visible.length === 0 ? <EmptyState title={referrals.length ? "Nenhum resultado encontrado" : "Ainda não há indicados"} detail={referrals.length ? "Tente outro nome ou limpe o filtro." : "Os entregadores aparecerão depois da próxima sincronização do Data Crazy."} /> : <div className="divide-y divide-[#e6ebf2]">{visible.slice(0, visibleCount).map((referral) => <ReferralRow key={referral.referral_id} referral={referral}/>)}</div>}
      {visible.length > visibleCount && <button className="load-more" onClick={() => setVisibleCount(visibleCount + 30)}>Mostrar mais {fmtNumber(Math.min(30, visible.length - visibleCount))} entregadores</button>}
      {visible.length > 0 && <div className="referral-footer">Mostrando {fmtNumber(Math.min(visibleCount, visible.length))} de {fmtNumber(visible.length)} {visible.length === 1 ? "entregador" : "entregadores"}</div>}
    </section>
    <div className="summary-grid">
      <StatCard label="Indicados" value={fmtNumber(referrals.length)} icon={<Users size={17}/>} sub="na lista atual" color="teal" />
      <StatCard label="Corridas" value={fmtNumber(totalRoutes)} icon={<BarChart3 size={17}/>} sub="acumuladas" color="blue" />
      <StatCard label="Prêmios conquistados" value={fmtNumber(unlocked)} icon={<Award size={17}/>} sub="um por entregador" color="gold" />
      <StatCard label="Valor dos prêmios" value={fmtMoney(prizeTotal)} icon={<Gift size={17}/>} sub="soma dos prêmios conquistados" color="plum" />
    </div>
  </>;
}

function StatCard({ label, value, icon, sub, color }: { label: string; value: string; icon: React.ReactNode; sub: string; color: "teal" | "blue" | "gold" | "plum" }) {
  const colors = { teal: "bg-[#eaf1fa] text-[#205b9e]", blue: "bg-[#eaf1fa] text-[#5375a1]", gold: "bg-[#fff5df] text-[#b17a20]", plum: "bg-[#f4eef9] text-[#8865a3]" };
  return <div className="rounded-2xl border border-[#dfe6f0] bg-white p-4.5 shadow-[0_5px_20px_-18px_#173f35]"><div className="flex items-start justify-between"><div className="text-xs font-semibold text-[#76888a]">{label}</div><div className={`flex size-8 items-center justify-center rounded-[11px] ${colors[color]}`}>{icon}</div></div><div className="mt-3 text-[25px] font-semibold tracking-[-.04em] text-[#213c41]">{value}</div><div className="mt-1 text-xs text-[#74889b]">{sub}</div></div>;
}

function ReferralRow({ referral }: { referral: Referral }) {
  const [expanded, setExpanded] = useState(false);
  const progress = referral.route_goal > 0 ? Math.min(100, Math.round(referral.routes / referral.route_goal * 100)) : 0;
  return <div className="px-4 py-4 sm:px-6"><button onClick={() => setExpanded(!expanded)} aria-expanded={expanded} className="grid min-h-14 w-full gap-4 text-left md:grid-cols-[minmax(180px,1.05fr)_minmax(190px,1.4fr)_145px_24px] md:items-center">
    <div className="flex min-w-0 items-center gap-3"><div className="flex size-10 shrink-0 items-center justify-center rounded-lg bg-[#eaf1fa] text-xs font-bold text-[#2b5d9c]">{(referral.name || "EN").split(/\s+/).slice(0, 2).map((part) => part[0]).join("").toUpperCase()}</div><div className="min-w-0 flex-1"><div className="truncate text-sm font-semibold text-[#223950]">{referral.name || "Nome indisponível"}</div><div className="mt-1 flex items-center gap-1 text-xs text-[#657b90]"><MapPin size={13}/>{referral.region || "Região não informada"}</div><div className="mt-1 flex items-center gap-1 text-xs text-[#74889b]"><CalendarDays size={13}/>Liberação: {fmtDate(referral.released_at)}</div></div><ChevronDown size={18} className={`shrink-0 text-[#5e7894] transition md:hidden ${expanded ? "rotate-180" : ""}`} /></div>
    <div><div className="mb-2 flex items-center justify-between text-xs"><span className="font-semibold text-[#294866]">{fmtNumber(referral.routes)} <span className="font-normal text-[#64798d]">de {fmtNumber(referral.route_goal)} corridas</span></span><span className="font-semibold text-[#245ca6]">{progress}%</span></div><div className="h-2 overflow-hidden rounded-full bg-[#e8eef7]"><div className="h-full rounded-full bg-[#2f6fc2] transition-all" style={{ width: `${progress}%` }}/></div></div>
    <div className="flex items-center justify-between gap-2 md:block md:text-right">{referral.prize_unlocked ? <span className="inline-flex items-center gap-1.5 rounded-full bg-[#eaf2fc] px-2.5 py-1.5 text-xs font-bold text-[#205b9e]"><CheckCircle2 size={12}/>Prêmio liberado</span> : <><span className="block text-[13px] font-semibold text-[#415b60]">Faltam {fmtNumber(referral.routes_remaining)}</span><span className="mt-0.5 block text-xs text-[#697f94]">para {fmtMoney(referral.prize_cents)}</span></>}</div><ChevronDown size={16} className={`hidden text-[#9aaaa8] transition md:block ${expanded ? "rotate-180" : ""}`} />
  </button>{expanded && <div className="mt-4 grid gap-3 rounded-xl bg-[#f7faff] p-3.5 text-[13px] sm:grid-cols-3"><Detail label="Telefone" value={referral.phone || "Indisponível"}/><Detail label="CPF" value={referral.cpf ? `${referral.cpf.slice(0, 3)}.${referral.cpf.slice(3, 6)}.${referral.cpf.slice(6, 9)}-${referral.cpf.slice(9)}` : "Não informado"}/><Detail label="UUID" value={referral.uuid}/></div>}</div>;
}

function Detail({ label, value }: { label: string; value: string }) { return <div><div className="text-xs font-bold uppercase tracking-[.08em] text-[#98a5a4]">{label}</div><div className="mt-1 break-all font-medium text-[#52686a]">{value}</div></div>; }

function EmptyState({ title, detail }: { title: string; detail: string }) { return <div className="grid min-h-56 place-items-center px-5 py-10 text-center"><div className="max-w-sm"><div className="mx-auto flex size-11 items-center justify-center rounded-[14px] bg-[#eaf1fa] text-[#245b9b]"><Users size={19}/></div><h3 className="mt-4 text-[14px] font-bold">{title}</h3><p className="mt-1.5 text-xs leading-5 text-[#60758b]">{detail}</p></div></div>; }

function AdminDashboard({ activeTab, overview, profile, refresh, onTab, onAdminNameSaved }: { activeTab: TabId; overview: AdminOverview | null; profile: Profile; refresh: () => Promise<void>; onTab: (tab: TabId) => void; onAdminNameSaved: (userId: string, displayName: string | null) => void }) {
  if (!overview) return <div className="grid min-h-64 place-items-center text-sm text-[#60758b]"><LoaderCircle className="mr-2 animate-spin" size={18}/>Carregando área administrativa…</div>;
  return <div>
    <div className="mb-7 flex flex-col justify-between gap-4 sm:flex-row sm:items-end"><div><h1 className="mt-2 text-[29px] font-semibold tracking-[-.03em] sm:text-[34px]">{adminTabs.find((tab) => tab.id === activeTab)?.label}</h1><p className="mt-1.5 text-[13px] text-[#60758b]">Sincronize indicados, importe corridas, revise atribuições e gerencie acessos.</p></div><button onClick={() => void refresh()} className="h-11 w-fit rounded-lg border border-[#d4deeb] bg-white px-3.5 text-[13px] font-semibold text-[#536d70] hover:bg-[#f7faff]">Atualizar dados</button></div>
    {activeTab === "dashboard" && <AdminHome overview={overview} onTab={onTab}/>}
    {activeTab === "referrals" && <AdminReferralsPanel influencers={overview.influencers}/>}
    {activeTab === "data-crazy" && <DataCrazySyncPanel refresh={refresh}/>}
    {activeTab === "performance" && <ImportPanel overview={overview} refresh={refresh}/>}
    {activeTab === "reviews" && <ReviewsPanel overview={overview} refresh={refresh}/>}
    {activeTab === "accounts" && <AccountsPanel overview={overview} refresh={refresh} onAdminNameSaved={onAdminNameSaved}/>}
    {activeTab === "profile" && <ProfileSettingsPanel profile={profile} onAdminNameSaved={onAdminNameSaved}/>}
    {activeTab === "imports" && <ImportHistoryPanel/>}
  </div>;
}

function AdminHome({ overview, onTab }: { overview: AdminOverview; onTab: (tab: TabId) => void }) {
  return <><div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4"><StatCard label="Entregadores ativos" value={fmtNumber(overview.referralCount)} icon={<Users size={17}/>} sub="na lista atual do Data Crazy" color="teal"/><StatCard label="Corridas acumuladas" value={fmtNumber(overview.contributionTotal)} icon={<BarChart3 size={17}/>} sub="soma do histórico importado" color="blue"/><StatCard label="Atribuições em revisão" value={fmtNumber(overview.reviewCount ?? overview.reviews.length)} icon={<ClipboardList size={17}/>} sub="UUIDs aguardando responsável" color="gold"/><StatCard label="Contas vinculadas" value={fmtNumber(overview.members.length)} icon={<ShieldCheck size={17}/>} sub="administração e influenciadores" color="plum"/></div>
    <section className="mt-7 rounded-2xl border border-[#dfe6f0] bg-white p-5 sm:p-6"><div><h2 className="text-[15px] font-bold">Próximas ações</h2><p className="mt-1 text-[13px] text-[#63788e]">Atualize os dados ou resolva atribuições pendentes.</p></div><div className="mt-5 grid gap-3 sm:grid-cols-2 xl:grid-cols-3"><ActionCard icon={<Users size={17}/>} title="Consultar indicados" text="Acompanhe a base completa por influenciador." onClick={() => onTab("referrals")}/><ActionCard icon={<CloudUpload size={17}/>} title="Sincronizar Data Crazy" text="Atualize a lista de indicados pela API." onClick={() => onTab("data-crazy")}/><ActionCard icon={<ArrowDownUp size={17}/>} title="Somar performance" text="Acrescente novas corridas ao acumulado da campanha." onClick={() => onTab("performance")}/><ActionCard icon={<ClipboardList size={17}/>} title={`Revisar atribuições · ${overview.reviewCount ?? overview.reviews.length}`} text="Resolva UUIDs sem um influenciador reconhecido." onClick={() => onTab("reviews")}/><ActionCard icon={<Users size={17}/>} title="Gerenciar acessos" text="Convide cada parceiro para sua própria conta." onClick={() => onTab("accounts")}/></div></section>
    <section className="mt-4 rounded-2xl border border-[#dfe6f0] bg-white p-5 sm:p-6"><div className="flex items-center justify-between"><div><h2 className="text-[15px] font-bold">Regras de premiação</h2><p className="mt-1 text-[13px] text-[#63788e]">Um prêmio por entregador ao alcançar a meta.</p></div><Gift size={18} className="text-[#b3822e]"/></div><div className="mt-4 grid gap-2 sm:grid-cols-2 xl:grid-cols-3">{overview.influencers.map((item) => <div key={item.id} className="flex items-center justify-between rounded-xl bg-[#f7faff] px-3.5 py-3"><span className="text-xs font-semibold">{item.name}</span><span className="text-xs font-semibold text-[#60758b]">{item.route_goal} corridas <span className="mx-1 text-[#a1b0c2]">·</span><strong className="text-[#205b9e]">{fmtMoney(item.prize_cents)}</strong></span></div>)}</div></section>
  </>;
}

function ActionCard({ icon, title, text, onClick }: { icon: React.ReactNode; title: string; text: string; onClick: () => void }) { return <button onClick={onClick} className="group flex gap-3 rounded-xl border border-[#e5ebf4] p-3.5 text-left transition hover:border-[#b8d1ed] hover:bg-[#f7faff]"><div className="flex size-9 shrink-0 items-center justify-center rounded-[11px] bg-[#eaf1fa] text-[#205b9e]">{icon}</div><div><div className="text-[13px] font-bold text-[#29435e]">{title}</div><div className="mt-1 text-xs leading-[17px] text-[#63788e]">{text}</div></div><ArrowRight size={14} className="ml-auto mt-1 shrink-0 text-[#a6b2b0] transition group-hover:translate-x-0.5 group-hover:text-[#205b9e]"/></button>; }

const syncPhaseLabels: Record<string, string> = {
  businesses: "Buscando negócios e pipelines",
  leads: "Consultando dados dos entregadores",
  ready: "Validando e preparando a lista",
  completed: "Lista atualizada",
  failed: "Sincronização interrompida",
};

function DataCrazySyncPanel({ refresh }: { refresh: () => Promise<void> }) {
  const [run, setRun] = useState<DataCrazySyncRun | null>(null);
  const [loading, setLoading] = useState(true);
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    let current = true;
    callDataCrazySync<DataCrazySyncRun | null>({ action: "status" })
      .then((next) => { if (current) setRun(next); })
      .catch((cause) => { if (current) setError(cause instanceof Error ? cause.message : "Não foi possível consultar a sincronização."); })
      .finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, []);

  useEffect(() => {
    if (run?.status !== "running") return;
    let current = true;
    const timer = window.setInterval(() => {
      callDataCrazySync<DataCrazySyncRun | null>({ action: "status", runId: run.id })
        .then((next) => {
          if (!current || !next) return;
          setRun(next);
          setError("");
          if (next.status === "completed") void refresh();
        })
        .catch((cause) => { if (current) setError(cause instanceof Error ? cause.message : "Não foi possível atualizar o andamento."); });
    }, 5000);
    return () => { current = false; window.clearInterval(timer); };
  }, [run?.id, run?.status, refresh]);

  async function startSync() {
    setStarting(true); setError("");
    try {
      const started = await callDataCrazySync<DataCrazySyncRun & { runId?: string }>({ action: "start" });
      const runId = started.runId ?? started.id;
      if (!runId) throw new Error("A Data Crazy não retornou o identificador da sincronização.");
      setRun({ id: runId, status: started.status, phase: started.phase, processed: started.processed ?? 0, total: started.total ?? 0, metrics: started.metrics ?? {}, windowMonth: started.windowMonth ?? null, errorMessage: started.errorMessage ?? null, startedAt: started.startedAt ?? new Date().toISOString(), completedAt: started.completedAt ?? null });
      try {
        const current = await callDataCrazySync<DataCrazySyncRun | null>({ action: "status", runId });
        if (current) {
          setRun(current);
          if (current.status === "completed") void refresh();
        }
      } catch {
        setError("Sincronização iniciada. O andamento será atualizado automaticamente.");
      }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Não foi possível iniciar a sincronização.");
    } finally { setStarting(false); }
  }

  const progress = run && run.total > 0 ? Math.min(100, Math.round(run.processed / run.total * 100)) : null;
  const statusLabel = run?.status === "running" ? "Em andamento" : run?.status === "completed" ? "Concluída" : "Falhou";
  const monthLabel = run?.status === "running" && run.windowMonth ? ` · ${run.windowMonth.slice(5, 7)}/${run.windowMonth.slice(0, 4)}` : "";

  return <div className="grid gap-4 xl:grid-cols-[minmax(0,1.25fr)_minmax(280px,.75fr)]">
    <section className="rounded-2xl border border-[#dfe6f0] bg-white p-5 sm:p-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="flex min-w-0 items-start gap-3"><div className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-[#eaf1fa] text-[#205b9e]"><CloudUpload size={19}/></div><div><h2 className="text-[16px] font-bold">Sincronizar Data Crazy</h2><p className="mt-1 max-w-[58ch] text-[13px] leading-5 text-[#60758b]">Busca os indicados pela API e atualiza a lista quando a coleta terminar.</p></div></div>
        <button type="button" onClick={() => void startSync()} disabled={loading || starting || run?.status === "running"} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-lg bg-[#185aa9] px-4 text-[13px] font-bold text-white hover:bg-[#114886] disabled:cursor-not-allowed disabled:opacity-55">{starting ? <LoaderCircle size={16} className="animate-spin"/> : <CloudUpload size={16}/>}Sincronizar agora</button>
      </div>

      {error && <p role="alert" className="mt-5 rounded-lg bg-[#fff3ef] px-3.5 py-3 text-[13px] leading-5 text-[#a94b37]">{error}</p>}
      {loading ? <div role="status" className="mt-6 flex items-center gap-2 text-[13px] text-[#60758b]"><LoaderCircle size={16} className="animate-spin"/>Consultando a última sincronização…</div> : !run ? <div className="mt-6 border-t border-[#e5ebf4] pt-5"><p className="text-[13px] font-semibold">Nenhuma sincronização registrada</p><p className="mt-1 text-[13px] leading-5 text-[#60758b]">Use “Sincronizar agora” para iniciar a primeira coleta.</p></div> : <div className="mt-6 border-t border-[#e5ebf4] pt-5" aria-live="polite">
        <div className="flex flex-wrap items-center justify-between gap-2"><div><p className="text-[13px] font-bold">Última sincronização</p><p className="mt-0.5 text-xs text-[#60758b]">Iniciada em {formatImportTime(run.startedAt)}{run.completedAt ? ` · finalizada em ${formatImportTime(run.completedAt)}` : ""}</p></div><span className={`inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-xs font-bold ${run.status === "completed" ? "bg-[#eaf2fc] text-[#205b9e]" : run.status === "failed" ? "bg-[#fff3ef] text-[#a94b37]" : "bg-[#fff8e8] text-[#795c2f]"}`}>{run.status === "running" ? <LoaderCircle size={14} className="animate-spin"/> : run.status === "completed" ? <CheckCircle2 size={14}/> : <CircleAlert size={14}/>} {statusLabel}</span></div>
        <div className="mt-5 flex flex-wrap items-baseline justify-between gap-2 text-[13px]"><span className="font-semibold text-[#29435e]">{syncPhaseLabels[run.phase] ?? "Processando dados"}{monthLabel}</span><span className="tabular-nums text-[#60758b]">{fmtNumber(run.processed)}{run.total > 0 ? ` de ${fmtNumber(run.total)}` : ""} registros</span></div>
        {run.status === "running" && <div className="mt-2 h-2 overflow-hidden rounded-full bg-[#e8eef7]" role="progressbar" aria-label="Andamento da sincronização" aria-valuenow={progress ?? undefined} aria-valuemin={0} aria-valuemax={100}><div className="h-full rounded-full bg-[#2f6fc2] transition-[width]" style={{ width: `${progress ?? 8}%` }}/></div>}
        {run.errorMessage && <p role="alert" className="mt-4 rounded-lg bg-[#fff3ef] px-3.5 py-3 text-[13px] leading-5 text-[#a94b37]">{run.errorMessage}</p>}
        {Object.keys(run.metrics ?? {}).length > 0 && <dl className="mt-5 grid grid-cols-2 gap-x-4 gap-y-3 border-t border-[#e5ebf4] pt-4 sm:grid-cols-3">{Object.entries(run.metrics).filter(([key, value]) => typeof value === "number" && !(key === "businessesReceived" && typeof run.metrics.businesses === "number") && !(key === "leadsReceived" && typeof run.metrics.leads === "number")).map(([key, value]) => <div key={key}><dt className="text-[11px] text-[#60758b]">{importMetricLabels[key] ?? key.replace(/([A-Z])/g, " $1")}</dt><dd className="mt-0.5 text-[15px] font-bold tabular-nums">{fmtNumber(value)}</dd></div>)}</dl>}
      </div>}
    </section>
    <section className="self-start rounded-2xl border border-[#dfe6f0] bg-white p-5 sm:p-6"><h3 className="text-[14px] font-bold">Como funciona</h3><ol className="mt-4 space-y-4 text-[13px] leading-5 text-[#60758b]"><li><strong className="text-[#29435e]">1. Atribuição.</strong> A pipeline de cada negócio define o influenciador.</li><li><strong className="text-[#29435e]">2. Vínculo.</strong> O campo “ID do Entregador” conecta os dados às corridas da Performance.</li><li><strong className="text-[#29435e]">3. Publicação.</strong> A lista anterior permanece disponível até a coleta completa ser validada e publicada.</li></ol><p className="mt-5 border-t border-[#e5ebf4] pt-4 text-xs leading-5 text-[#60758b]">A sincronização automática está programada para as 06:00, horário de Brasília. As corridas acumuladas permanecem no histórico.</p></section>
  </div>;
}

function ImportPanel({ overview, refresh }: { overview: AdminOverview; refresh: () => Promise<void> }) {
  const [preview, setPreview] = useState<ImportPreview<PerformanceImportRow> | null>(null);
  const [coverage, setCoverage] = useState<PerformanceCoverage | null>(null);
  const [coverageLoading, setCoverageLoading] = useState(true);
  const [coverageError, setCoverageError] = useState("");
  const [duplicate, setDuplicate] = useState(false);
  const [busy, setBusy] = useState(false);
  const [batchId, setBatchId] = useState("");
  const [progress, setProgress] = useState(0);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const lastSame = overview.imports.find((item) => item.kind === "performance");

  const loadCoverage = useCallback(async () => {
    setCoverageLoading(true);
    setCoverageError("");
    try { setCoverage(await callAdminApi<PerformanceCoverage>("performance-coverage", {})); }
    catch (cause) { setCoverageError(cause instanceof Error ? cause.message : "Não foi possível consultar o período dos dados."); }
    finally { setCoverageLoading(false); }
  }, []);

  useEffect(() => { void loadCoverage(); }, [loadCoverage, overview.imports]);

  async function chooseFile(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    if (batchId) await callAdminApi("import-cancel", { batchId }).catch(() => undefined);
    setPreview(null); setError(""); setMessage(""); setDuplicate(false); setBatchId(""); setBusy(true);
    try {
      if (!/\.(csv|xlsx|xls)$/i.test(file.name)) throw new Error("Escolha um arquivo .csv, .xlsx ou .xls.");
      const parsed = await parsePerformance(file);
      setPreview(parsed);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Não foi possível ler esse arquivo."); }
    finally { setBusy(false); }
  }

  async function importFile(allowDuplicate = false) {
    if (!preview) return;
    setBusy(true); setError(""); setMessage("");
    setProgress(0);
    let activeBatchId = batchId;
    try {
      if (!activeBatchId) {
        const started = await callAdminApi<{ batchId: string; duplicateFile: boolean }>("import-start", {
          kind: "performance", fileName: preview.fileName, fileHash: preview.fileHash, metrics: preview.metrics,
          totalRows: preview.rows.length, dataCoverage: preview.dataCoverage,
        });
        activeBatchId = started.batchId;
        setBatchId(activeBatchId);
        if (started.duplicateFile && !allowDuplicate) {
          setDuplicate(true); setBusy(false); return;
        }
      }
      const rows = preview.rows;
      const encoder = new TextEncoder();
      for (let offset = 0; offset < rows.length;) {
        let end = offset;
        let bytes = 2;
        while (end < rows.length && end - offset < 300) {
          const rowBytes = encoder.encode(JSON.stringify(rows[end])).length + 1;
          if (end > offset && bytes + rowBytes > 180_000) break;
          if (rowBytes > 180_000) throw new Error("Uma linha é grande demais para importar. Revise o arquivo.");
          bytes += rowBytes;
          end += 1;
        }
        await callAdminApi("import-chunk", {
          batchId: activeBatchId,
          rows: rows.slice(offset, end),
        });
        offset = end;
        setProgress(Math.round(offset / rows.length * 100));
      }
      await callAdminApi("import-complete", { batchId: activeBatchId });
      setMessage("Corridas adicionadas ao acumulado.");
      setPreview(null); setDuplicate(false); setBatchId(""); await refresh();
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : "A importação não foi concluída.";
      if (activeBatchId) await callAdminApi("import-fail", { batchId: activeBatchId, errorMessage: message })
        .catch(() => callAdminApi("import-cancel", { batchId: activeBatchId }).catch(() => undefined));
      setBatchId("");
      setError(message);
    }
    finally { setBusy(false); }
  }

  async function updateCoverageOnly() {
    if (!preview?.dataCoverage || !duplicate) return;
    setBusy(true); setError(""); setMessage("");
    try {
      if (batchId) await callAdminApi("import-cancel", { batchId });
      setBatchId("");
      const result = await callAdminApi<{ updatedImports: number }>("performance-coverage-update", {
        fileHash: preview.fileHash,
        dataCoverage: preview.dataCoverage,
      });
      setMessage(`Período dos dados atualizado em ${fmtNumber(result.updatedImports)} importação(ões), sem acrescentar corridas.`);
      setPreview(null); setDuplicate(false);
      await refresh();
      await loadCoverage();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Não foi possível atualizar o período desse arquivo.");
    } finally { setBusy(false); }
  }

  return <div><PerformanceCoveragePanel coverage={coverage} loading={coverageLoading} error={coverageError} onRetry={() => void loadCoverage()}/><div className="grid gap-4 xl:grid-cols-[minmax(0,1.25fr)_minmax(280px,.75fr)]"><section className="rounded-2xl border border-[#dfe6f0] bg-white p-5 sm:p-6"><div className="flex items-start gap-3"><div className="flex size-10 items-center justify-center rounded-xl bg-[#eaf1fa] text-[#205b9e]"><CloudUpload size={19}/></div><div><h2 className="text-[15px] font-bold">Importar Performance</h2><p className="mt-1 text-[13px] text-[#60758b]">Adiciona as corridas desta importação ao acumulado existente.</p></div></div>
    <label className="mt-6 flex min-h-40 cursor-pointer flex-col items-center justify-center rounded-2xl border border-dashed border-[#c7d5e6] bg-[#f8fbff] px-4 py-6 text-center transition hover:border-[#2b6cbb] hover:bg-[#f5f9fe]"><input className="sr-only" type="file" accept=".csv,.xlsx,.xls" onChange={(event) => void chooseFile(event)}/><div className="flex size-10 items-center justify-center rounded-[13px] bg-white text-[#245b9b] shadow-sm">{busy && !preview ? <LoaderCircle size={19} className="animate-spin"/> : <Download size={19}/>}</div><span className="mt-3 text-[13px] font-bold">Selecione um arquivo para conferir</span><span className="mt-1 text-xs text-[#697f94]">CSV, .xlsx ou .xls · até 25 MB e 100 mil linhas · confira antes de importar</span></label>
    {error && <p role="alert" className="mt-4 rounded-xl bg-[#fff3ef] px-3.5 py-3 text-xs text-[#a94b37]">{error}</p>}{message && <p role="status" className="mt-4 rounded-xl bg-[#eaf2fc] px-3.5 py-3 text-xs text-[#205b9e]">{message}</p>}
    {preview && <div className="mt-5 rounded-xl border border-[#e5ebf4] bg-white p-4"><div className="flex items-center justify-between gap-3"><div className="min-w-0"><div className="truncate text-[13px] font-bold">{preview.fileName}</div><div className="mt-1 text-xs text-[#60758b]">SHA-256 · {preview.fileHash.slice(0, 18)}…</div></div><span className="rounded-full bg-[#eaf1fa] px-2.5 py-1 text-xs font-bold text-[#205b9e]">Pronto para importar</span></div>{preview.dataCoverage && <div className="mt-4 flex flex-col gap-1 rounded-xl bg-[#f1f6fd] px-3.5 py-3 sm:flex-row sm:items-center sm:justify-between"><div><div className="text-[11px] font-semibold text-[#60758b]">Datas encontradas na planilha (coluna A)</div><div className="mt-1 text-sm font-bold tabular-nums text-[#203b58]">{fmtDateRange(preview.dataCoverage.firstDate, preview.dataCoverage.lastDate)}</div></div><div className="text-xs text-[#60758b]">{fmtNumber(preview.dataCoverage.cities.length)} cidades · {fmtNumber(preview.dataCoverage.rowCount)} linhas válidas</div></div>}<div className="mt-4 grid grid-cols-2 gap-2 sm:grid-cols-4">{Object.entries(preview.metrics).slice(0, 4).map(([label, value]) => <div key={label} className="rounded-lg bg-[#f7faff] px-3 py-2"><div className="text-xs text-[#697f94]">{label.replace(/[A-Z]/g, (letter) => ` ${letter.toLowerCase()}`)}</div><div className="mt-1 text-sm font-bold">{fmtNumber(value)}</div></div>)}</div>{preview.warnings.length > 0 && <div className="mt-4 space-y-1.5 rounded-lg bg-[#fff9ed] p-3 text-xs leading-4 text-[#8a6532]">{preview.warnings.map((warning) => <div key={warning} className="flex gap-2"><CircleAlert size={13} className="mt-0.5 shrink-0"/>{warning}</div>)}</div>}{duplicate && <div className="mt-4 rounded-lg border border-[#f1d9ae] bg-[#fff9ed] p-3 text-[13px] leading-5 text-[#795c2f]">Este arquivo já foi importado antes. Somar novamente pode duplicar corridas. Você pode atualizar somente o intervalo histórico, sem alterar o acumulado.</div>}{busy && <div className="mt-4 h-1.5 overflow-hidden rounded-full bg-[#e8eef7]"><div className="h-full rounded-full bg-[#2f6fc2] transition-all" style={{width:`${progress}%`}}/></div>}<div className="mt-4 flex flex-wrap items-center justify-end gap-2"><button onClick={() => { if (batchId) void callAdminApi("import-cancel", { batchId }).catch(() => undefined); setBatchId(""); setPreview(null); setDuplicate(false); }} disabled={busy} className="h-11 rounded-lg px-3 text-[13px] font-semibold text-[#60758b] hover:bg-[#f6f8f7]">Cancelar</button>{duplicate && <button onClick={() => void updateCoverageOnly()} disabled={busy} className="inline-flex h-11 items-center gap-2 rounded-lg border border-[#c7d5e6] bg-white px-4 text-[13px] font-bold text-[#205b9e] hover:bg-[#f5f9fe] disabled:opacity-55">{busy ? <LoaderCircle size={14} className="animate-spin"/> : <CalendarDays size={14}/>} Atualizar período sem somar</button>}<button onClick={() => void importFile(duplicate)} disabled={busy} className="inline-flex h-11 items-center gap-2 rounded-lg bg-[#185aa9] px-4 text-[13px] font-bold text-white hover:bg-[#114886] disabled:opacity-55">{busy ? <LoaderCircle size={14} className="animate-spin"/> : <Check size={14}/>} {duplicate ? "Somar corridas novamente" : "Adicionar ao acumulado"}</button></div></div>}
  </section><div className="space-y-4"><section className="rounded-2xl border border-[#dfe6f0] bg-white p-5"><h3 className="text-[13px] font-bold">Mapeamento automático</h3><div className="mt-4 space-y-3 text-[13px] text-[#60758b]">{[["Data do período", "A · Data do registro"], ["UUID", "F · Identificador"], ["Entregador", "G · Nome"], ["Praça", "H · Região"], ["Corridas", "R · Pedidos aceitos e concluídos"]].map(([a,b])=><div key={a} className="flex justify-between gap-3 border-b border-[#edf1f6] pb-2.5 last:border-0 last:pb-0"><span>{a}</span><span className="text-right font-semibold text-[#29435e]">{b}</span></div>)}</div></section><section className="rounded-2xl bg-[#eaf1fa] p-5"><div className="flex items-center gap-2 text-[13px] font-bold text-[#266a55]"><ShieldCheck size={15}/>Importação protegida</div><p className="mt-2 text-xs leading-[18px] text-[#60758b]">Cada UUID é somado dentro do arquivo e depois acrescido ao histórico. Reimportações intencionais somam novamente.</p>{lastSame && <div className="mt-3 border-t border-[#dce8f6] pt-3 text-xs text-[#60758b]">Último arquivo: <span className="font-semibold">{lastSame.file_name}</span></div>}</section></div></div></div>;
}

function PerformanceCoveragePanel({ coverage, loading, error, onRetry }: { coverage: PerformanceCoverage | null; loading: boolean; error: string; onRetry: () => void }) {
  return <section className="mb-4 rounded-2xl border border-[#dfe6f0] bg-white p-5 sm:p-6">
    <div className="flex items-start gap-3"><div className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-[#eaf1fa] text-[#205b9e]"><CalendarDays size={18}/></div><div><h2 className="text-base font-bold">Intervalo dos dados de Performance</h2><p className="mt-1 max-w-3xl text-sm leading-5 text-[#60758b]">Período registrado nos próprios dados da planilha (coluna A), com o intervalo de cada cidade.</p></div></div>
    {loading ? <div className="mt-5 flex items-center gap-2 text-sm text-[#60758b]" role="status"><LoaderCircle size={16} className="animate-spin"/>Consultando os períodos disponíveis…</div>
      : error ? <div className="mt-5 flex flex-wrap items-center justify-between gap-3 rounded-xl bg-[#fff3ef] px-4 py-3 text-sm text-[#a94b37]" role="alert"><span>{error}</span><button onClick={onRetry} className="min-h-10 rounded-lg border border-[#e6bdb4] px-3 font-semibold hover:bg-white">Tentar novamente</button></div>
      : !coverage || (coverage.importCount === 0 && coverage.uncapturedImportCount === 0) ? <p className="mt-5 rounded-xl bg-[#f7faff] px-4 py-4 text-sm text-[#60758b]">Ainda não há importações concluídas de Performance.</p>
      : <>
        {coverage.importCount > 0 && <div className="mt-5 flex flex-col gap-1 rounded-xl bg-[#f7faff] px-4 py-3.5 sm:flex-row sm:items-center sm:justify-between"><div><div className="text-xs font-semibold text-[#60758b]">Período geral dos dados</div><div className="mt-1 text-base font-bold tabular-nums text-[#203b58]">{fmtDateRange(coverage.firstDate, coverage.lastDate)}</div></div><div className="text-xs text-[#60758b]">{fmtNumber(coverage.importCount)} importações com datas reconhecidas · {fmtNumber(coverage.rowCount)} linhas válidas</div></div>}
        {coverage.uncapturedImportCount > 0 && <div className="mt-4 rounded-xl border border-[#f1d9ae] bg-[#fff9ed] px-4 py-3 text-[13px] leading-5 text-[#795c2f]">{fmtNumber(coverage.uncapturedImportCount)} importação(ões) antiga(s) ainda não têm o período de origem salvo. Selecione novamente o mesmo arquivo na área abaixo e use <strong>Atualizar período sem somar</strong> para recuperar as datas sem duplicar corridas.</div>}
        {coverage.importCount > 0 && <div className="mt-5"><div className="mb-1 flex flex-wrap items-baseline justify-between gap-2"><h3 className="text-sm font-bold">Período por cidade / praça</h3><span className="text-xs text-[#74889b]">Datas presentes nas planilhas</span></div><ul className="divide-y divide-[#e6ebf2]">{coverage.cities.map((item) => <li key={item.city} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center sm:justify-between"><div className="min-w-0"><div className="truncate text-sm font-semibold text-[#29435e]">{repairTextEncoding(item.city)}</div><div className="mt-0.5 text-xs text-[#74889b]">{fmtNumber(item.importCount)} importações · {fmtNumber(item.rowCount)} linhas válidas</div></div><div className="shrink-0 text-left sm:text-right"><div className="text-xs font-semibold text-[#74889b]">Intervalo dos dados</div><div className="mt-0.5 text-sm tabular-nums text-[#405b76]">{fmtDateRange(item.firstDate, item.lastDate)}</div></div></li>)}</ul></div>}
      </>}
  </section>;
}

const historyStatusLabels: Record<ImportHistoryEntry["status"], string> = {
  staging: "Em andamento", completed: "Concluída", failed: "Falhou", cancelled: "Cancelada",
};
const importMetricLabels: Record<string, string> = {
  total: "Linhas válidas", ambiguous: "Para revisar", ignored: "Ignoradas",
  invalidUuid: "UUID inválido", phoneUnavailable: "Telefone indisponível",
  invalidCpf: "CPF omitido", duplicateUuids: "UUID duplicado", invalidRoutes: "Corridas inválidas",
  invalidDataDate: "Data inválida", dataDateRows: "Linhas com data", sourceRows: "Linhas lidas",
  repeatedRows: "Linhas somadas", totalRoutes: "Corridas na carga",
  businessesReceived: "Negócios consultados", leadsReceived: "Leads consultados",
  businesses: "Negócios consultados", leads: "Leads consultados",
  referrals: "Indicados publicados", invalid_uuid: "Sem UUID válido",
};

const importActorLabel = (entry: { actor_display_name?: string | null; actor_email: string | null }) =>
  entry.actor_display_name?.trim() || entry.actor_email?.trim() || "Sistema";

function formatImportTime(value: string | null) {
  return value ? new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" }) : "—";
}

function formatImportDuration(seconds: number) {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ${seconds % 60}s`;
  return `${Math.floor(seconds / 3600)} h ${Math.floor((seconds % 3600) / 60)} min`;
}

function ImportHistoryPanel() {
  const [items, setItems] = useState<ImportHistoryEntry[]>([]);
  const [summary, setSummary] = useState<ImportHistorySummary>({ total: 0, staging: 0, completed: 0, failed: 0, cancelled: 0 });
  const [total, setTotal] = useState(0);
  const [status, setStatus] = useState("all");
  const [kind, setKind] = useState("all");
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState("");
  const [refreshKey, setRefreshKey] = useState(0);
  const [openBatch, setOpenBatch] = useState("");
  const [events, setEvents] = useState<Record<string, ImportEvent[]>>({});
  const [eventErrors, setEventErrors] = useState<Record<string, string>>({});
  const [loadingEvents, setLoadingEvents] = useState("");

  useEffect(() => {
    let current = true;
    setLoading(true); setError("");
    callAdminApi<ImportHistoryResult>("import-history", { limit: 25, offset: 0, status, kind })
      .then((result) => {
        if (!current) return;
        setItems(result.items ?? []); setTotal(result.total ?? 0);
        setSummary(result.summary ?? { total: 0, staging: 0, completed: 0, failed: 0, cancelled: 0 });
      })
      .catch((cause) => { if (current) setError(cause instanceof Error ? cause.message : "Não foi possível carregar o histórico."); })
      .finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [status, kind, refreshKey]);

  async function loadMore() {
    setLoadingMore(true); setError("");
    try {
      const result = await callAdminApi<ImportHistoryResult>("import-history", { limit: 25, offset: items.length, status, kind });
      setItems((current) => [...current, ...(result.items ?? [])]); setTotal(result.total ?? 0);
      setSummary(result.summary ?? summary);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Não foi possível carregar mais importações."); }
    finally { setLoadingMore(false); }
  }

  async function toggleEvents(batchId: string) {
    if (openBatch === batchId) { setOpenBatch(""); return; }
    setOpenBatch(batchId);
    if (events[batchId]) return;
    setLoadingEvents(batchId); setEventErrors((current) => ({ ...current, [batchId]: "" }));
    try {
      const rows = await callAdminApi<ImportEvent[]>("import-events", { batchId });
      setEvents((current) => ({ ...current, [batchId]: rows ?? [] }));
    } catch (cause) {
      setEventErrors((current) => ({ ...current, [batchId]: cause instanceof Error ? cause.message : "Não foi possível abrir as etapas." }));
    } finally { setLoadingEvents(""); }
  }

  return <div className="space-y-4">
    <section className="rounded-2xl border border-[#dfe6f0] bg-white p-5 sm:p-6">
      <div className="flex flex-col justify-between gap-4 sm:flex-row sm:items-start">
        <div><h2 className="text-[18px] font-bold tracking-[-.02em]">Log de importações</h2><p className="mt-1 text-[13px] text-[#60758b]">Todas as cargas de todas as contas administrativas, com etapas e responsáveis.</p></div>
        <button onClick={() => setRefreshKey((value) => value + 1)} disabled={loading} className="inline-flex h-11 w-fit items-center gap-2 rounded-lg border border-[#d4deeb] bg-white px-3.5 text-[13px] font-semibold text-[#536d70] hover:bg-[#f7faff] focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#2f6fc2] disabled:opacity-55"><History size={15}/>{loading ? "Atualizando…" : "Atualizar log"}</button>
      </div>
      <div className="mt-5 grid grid-cols-2 overflow-hidden rounded-xl border border-[#e5ebf4] sm:grid-cols-4">
        {([["Todas", summary.total], ["Concluídas", summary.completed], ["Em andamento", summary.staging], ["Falhas e canceladas", summary.failed + summary.cancelled]] as const).map(([label, value], index) => <div key={label} className={`px-3 py-3 ${index % 2 ? "border-l" : ""} ${index > 1 ? "border-t sm:border-t-0" : ""} ${index === 2 ? "sm:border-l" : ""} border-[#e5ebf4]`}><div className="text-[11px] font-semibold text-[#63788e]">{label}</div><div className="mt-1 text-lg font-bold tabular-nums text-[#203b58]">{fmtNumber(value)}</div></div>)}
      </div>
      <div className="mt-4 flex flex-col gap-2 sm:flex-row sm:items-center">
        <label className="flex flex-1 flex-col gap-1 text-[11px] font-semibold text-[#63788e]">Status<select value={status} onChange={(event) => setStatus(event.target.value)} className="h-11 rounded-lg border border-[#d4deeb] bg-white px-3 text-[13px] font-medium text-[#29435e] focus:border-[#2f6fc2] focus:outline-none focus:ring-2 focus:ring-[#d7e8fa]"><option value="all">Todos os status</option><option value="staging">Em andamento</option><option value="completed">Concluídas</option><option value="failed">Com falha</option><option value="cancelled">Canceladas</option></select></label>
        <label className="flex flex-1 flex-col gap-1 text-[11px] font-semibold text-[#63788e]">Origem<select value={kind} onChange={(event) => setKind(event.target.value)} className="h-11 rounded-lg border border-[#d4deeb] bg-white px-3 text-[13px] font-medium text-[#29435e] focus:border-[#2f6fc2] focus:outline-none focus:ring-2 focus:ring-[#d7e8fa]"><option value="all">Todas as origens</option><option value="data_crazy">Data Crazy</option><option value="performance">Performance</option></select></label>
      </div>
    </section>

    {error && <p role="alert" className="rounded-xl bg-[#fff3ef] px-4 py-3 text-[13px] text-[#a94b37]">{error}</p>}
    {loading && items.length === 0 ? <div className="rounded-xl border border-[#dfe6f0] bg-white px-5 py-12 text-center text-[13px] text-[#60758b]"><LoaderCircle className="mx-auto mb-3 animate-spin" size={19}/>Carregando as importações…</div> : items.length === 0 ? <div className="rounded-xl border border-[#dfe6f0] bg-white"><EmptyState title="Nenhuma importação encontrada" detail="Ajuste os filtros ou atualize o log para consultar as cargas feitas por qualquer administrador."/></div> : <div className="space-y-3">
      {items.map((item) => {
        const progress = item.expected_rows > 0 ? Math.min(100, Math.round(item.staged_rows / item.expected_rows * 100)) : 0;
        const open = openBatch === item.id;
        const badgeClass = item.status === "completed" ? "bg-[#eaf2fc] text-[#205b9e]" : item.status === "staging" ? "bg-[#fff8e8] text-[#8a6532]" : item.status === "failed" ? "bg-[#fff3ef] text-[#a94b37]" : "bg-[#f0f3f7] text-[#64758a]";
        return <article key={item.id} className="overflow-hidden rounded-xl border border-[#dfe6f0] bg-white">
          <div className="p-4 sm:p-5">
            <div className="flex flex-col justify-between gap-3 sm:flex-row sm:items-start">
              <div className="flex min-w-0 items-start gap-3"><div className="mt-0.5 flex size-9 shrink-0 items-center justify-center rounded-lg bg-[#eaf1fa] text-[#205b9e]"><FileSpreadsheet size={17}/></div><div className="min-w-0"><div className="break-all text-[13px] font-bold text-[#203b58]">{item.file_name}</div><div className="mt-1 text-xs text-[#60758b]">{item.kind === "data_crazy" ? "Data Crazy" : "Performance"} · por <span className="font-semibold text-[#405b76]">{importActorLabel(item)}</span></div></div></div>
              <span className={`inline-flex w-fit shrink-0 items-center gap-1.5 rounded-full px-2.5 py-1.5 text-[11px] font-bold ${badgeClass}`}>{item.status === "completed" ? <CheckCircle2 size={13}/> : item.status === "failed" ? <CircleAlert size={13}/> : item.status === "cancelled" ? <XCircle size={13}/> : <LoaderCircle size={13} className="animate-spin"/>}{historyStatusLabels[item.status]}</span>
            </div>
            <div className="mt-4 grid grid-cols-2 gap-y-3 border-t border-[#edf1f6] pt-3 text-[12px] sm:grid-cols-4 sm:gap-3">
              <div><div className="text-[10px] font-semibold uppercase tracking-[.07em] text-[#8191a2]">Iniciada</div><div className="mt-1 font-semibold text-[#405b76]">{formatImportTime(item.created_at)}</div></div>
              <div><div className="text-[10px] font-semibold uppercase tracking-[.07em] text-[#8191a2]">Duração</div><div className="mt-1 font-semibold text-[#405b76]">{formatImportDuration(item.duration_seconds)}</div></div>
              <div><div className="text-[10px] font-semibold uppercase tracking-[.07em] text-[#8191a2]">Linhas</div><div className="mt-1 font-semibold tabular-nums text-[#405b76]">{fmtNumber(item.staged_rows)} / {fmtNumber(item.expected_rows)}</div></div>
              <div><div className="text-[10px] font-semibold uppercase tracking-[.07em] text-[#8191a2]">Última etapa</div><div className="mt-1 line-clamp-1 font-semibold text-[#405b76]">{item.last_event_message || "Sem etapa registrada"}</div></div>
            </div>
            {item.status === "staging" && <div className="mt-3"><div className="mb-1 flex justify-between text-[11px] text-[#60758b]"><span>Recebimento dos dados</span><span className="font-bold tabular-nums">{progress}%</span></div><div className="h-1.5 overflow-hidden rounded-full bg-[#e8eef7]"><div className="h-full rounded-full bg-[#2f6fc2] transition-all" style={{ width: `${progress}%` }}/></div></div>}
            <div className="mt-3 flex justify-end"><button onClick={() => void toggleEvents(item.id)} aria-expanded={open} className="inline-flex min-h-10 items-center gap-1.5 rounded-lg px-2.5 text-[12px] font-bold text-[#205b9e] hover:bg-[#f2f7fd] focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#2f6fc2]">{open ? "Ocultar detalhes" : "Ver etapas e detalhes"}<ChevronDown size={14} className={`transition-transform ${open ? "rotate-180" : ""}`}/></button></div>
          </div>
          {open && <div className="border-t border-[#e5ebf4] bg-[#fbfcfe] px-4 py-4 sm:px-5">
            <div className="grid gap-3 sm:grid-cols-3">
              <div><div className="text-[10px] font-bold uppercase tracking-[.07em] text-[#8191a2]">{item.source === "api" ? "Origem" : "Arquivo · SHA-256"}</div><div className="mt-1 break-all text-xs font-semibold text-[#405b76]">{item.source === "api" ? "API Data Crazy" : `${item.file_hash_prefix}…`}</div></div>
              <div><div className="text-[10px] font-bold uppercase tracking-[.07em] text-[#8191a2]">Finalizada</div><div className="mt-1 text-xs font-semibold text-[#405b76]">{formatImportTime(item.finished_at || item.completed_at)}</div></div>
              <div><div className="text-[10px] font-bold uppercase tracking-[.07em] text-[#8191a2]">Lote</div><div className="mt-1 break-all text-xs text-[#60758b]">{item.id}</div></div>
            </div>
            {Object.entries(item.metrics ?? {}).some(([key, value]) => key !== "total" && value > 0) && <div className="mt-4 flex flex-wrap gap-2">{Object.entries(item.metrics).filter(([key, value]) => key !== "total" && value > 0).map(([key, value]) => <span key={key} className="rounded-lg bg-white px-2.5 py-1.5 text-[11px] text-[#536c84]"><strong className="tabular-nums text-[#29435e]">{fmtNumber(value)}</strong> {importMetricLabels[key] ?? key}</span>)}</div>}
            {item.error_message && <div className="mt-4 rounded-lg bg-[#fff3ef] px-3 py-2.5 text-[12px] leading-5 text-[#a94b37]"><strong>Erro registrado:</strong> {item.error_message}</div>}
            <div className="mt-4 border-t border-[#e5ebf4] pt-3">
              <div className="text-[11px] font-bold uppercase tracking-[.08em] text-[#63788e]">Linha do tempo</div>
              {loadingEvents === item.id ? <div className="mt-3 flex items-center gap-2 text-xs text-[#60758b]"><LoaderCircle size={14} className="animate-spin"/>Carregando etapas…</div> : eventErrors[item.id] ? <p role="alert" className="mt-3 text-xs text-[#a94b37]">{eventErrors[item.id]}</p> : <ol className="mt-3 space-y-3 border-l border-[#d7e1ec] pl-4">{(events[item.id] ?? []).map((event) => <li key={event.id} className="relative"><span className={`absolute -left-[20px] top-1.5 size-2 rounded-full ${event.event_type === "failed" ? "bg-[#c65e4c]" : event.event_type === "completed" ? "bg-[#2f6fc2]" : "bg-[#8fa3b8]"}`}/><div className="flex flex-col justify-between gap-1 sm:flex-row"><p className="text-[12px] leading-5 text-[#405b76]">{event.message}</p><time className="shrink-0 text-[10px] text-[#8191a2]">{formatImportTime(event.created_at)} · {importActorLabel(event)}</time></div></li>)}</ol>}
            </div>
          </div>}
        </article>;
      })}
    </div>}
    {items.length > 0 && items.length < total && <div className="flex justify-center"><button onClick={() => void loadMore()} disabled={loadingMore} className="inline-flex h-11 items-center gap-2 rounded-lg border border-[#d4deeb] bg-white px-4 text-[13px] font-semibold text-[#536d70] hover:bg-[#f7faff] focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#2f6fc2] disabled:opacity-55">{loadingMore ? <LoaderCircle size={14} className="animate-spin"/> : null}{loadingMore ? "Carregando…" : `Carregar mais · ${fmtNumber(items.length)} de ${fmtNumber(total)}`}</button></div>}
  </div>;
}

function ReviewsPanel({ overview, refresh }: { overview: AdminOverview; refresh: () => Promise<void> }) {
  const [reviews, setReviews] = useState<Review[]>(overview.reviews);
  const [error, setError] = useState("");
  const [busyId, setBusyId] = useState("");
  const [loadingMore, setLoadingMore] = useState(false);
  useEffect(() => { setReviews(overview.reviews); }, [overview.reviews]);

  async function loadMore() {
    const client = getSupabase();
    if (!client) return;
    setLoadingMore(true); setError("");
    const { data, error: queryError } = await client.schema(DATA_SCHEMA).from("attribution_reviews")
      .select("id,uuid,name,region,raw_influencer,status")
      .eq("status", "open").order("created_at").order("id")
      .range(reviews.length, reviews.length + 49);
    if (queryError) setError(queryError.message);
    else setReviews((current) => [...current, ...((data ?? []) as Review[])]);
    setLoadingMore(false);
  }

  async function assign(review: Review, influencerId: string) {
    if (!influencerId) return;
    setBusyId(review.id); setError("");
    try { await callAdminApi("review-assign", { reviewId: review.id, influencerId }); await refresh(); }
    catch (cause) { setError(cause instanceof Error ? cause.message : "A atribuição não foi atualizada."); }
    finally { setBusyId(""); }
  }

  return <section className="overflow-hidden rounded-xl border border-[#dfe6f0] bg-white">
    <div className="border-b border-[#e6ebf2] px-4 py-5 sm:px-6"><h2 className="text-base font-semibold">Atribuições para revisar</h2><p className="mt-1 text-sm text-[#60758b]">Escolha o responsável pelos UUIDs ainda sem influenciador.</p></div>
    {error && <p role="alert" className="m-4 form-error">{error}</p>}
    {reviews.length === 0 ? <EmptyState title="Tudo revisado" detail="Não há atribuições pendentes neste momento."/> : <div className="divide-y divide-[#e6ebf2]">{reviews.map((review) => <div key={review.id} className="grid gap-3 px-4 py-4 sm:grid-cols-[1fr_1fr_auto] sm:items-center sm:px-6">
      <div><div className="text-sm font-semibold">{review.name || "Nome não informado"}</div><div className="mt-1 break-all text-xs text-[#60758b]">UUID · {review.uuid}</div>{review.region && <div className="mt-1 text-xs text-[#60758b]">{review.region}</div>}</div>
      <div className="rounded-lg bg-[#fff9ed] px-3 py-2 text-sm text-[#795c2f]">Recebido: <strong>{review.raw_influencer || "vazio"}</strong></div>
      <select aria-label={`Atribuir ${review.name || review.uuid}`} defaultValue="" onChange={(event) => void assign(review, event.target.value)} disabled={busyId === review.id} className="h-11 rounded-lg border border-[#d4deeb] bg-white px-3 text-sm font-semibold text-[#29435e]"><option value="" disabled>Selecionar influenciador</option>{overview.influencers.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select>
    </div>)}</div>}
    {(overview.reviewCount ?? reviews.length) > reviews.length && <button disabled={loadingMore} onClick={() => void loadMore()} className="load-more">{loadingMore ? "Carregando…" : "Mostrar mais revisões"}</button>}
  </section>;
}

function AccountsPanel({ overview, refresh, onAdminNameSaved }: { overview: AdminOverview; refresh: () => Promise<void>; onAdminNameSaved: (userId: string, displayName: string | null) => void }) {
  const [email, setEmail] = useState(""); const [role, setRole] = useState<Role>("influencer"); const [influencerId, setInfluencerId] = useState(""); const [error, setError] = useState(""); const [notice, setNotice] = useState(""); const [busy, setBusy] = useState(false);
  const [issued, setIssued] = useState<{ email: string; role: Role; code: string; expiresAt: string } | null>(null);
  const [revoking, setRevoking] = useState("");
  async function invite(event: FormEvent) {
    event.preventDefault(); setBusy(true); setError(""); setNotice(""); setIssued(null);
    try {
      const invitedEmail = email.trim().toLowerCase();
      const result = await callAccessApi<{ code: string; expiresAt: string }>({
        action: role === "admin" ? "issue-admin" : "issue",
        email: invitedEmail,
        ...(role === "influencer" ? { influencerId } : {}),
      });
      setIssued({ email: invitedEmail, role, code: result.code, expiresAt: result.expiresAt });
      setNotice(role === "admin" ? "Convite de administrador preparado." : "Acesso preparado para o influenciador.");
      setEmail(""); await refresh();
    }
    catch (cause) { setError(cause instanceof Error ? cause.message : "Não foi possível liberar este acesso."); }
    finally { setBusy(false); }
  }
  async function revoke(invite: PendingInvite) {
    setRevoking(invite.id); setError("");
    try { await callAdminApi("revoke-invite", { inviteId: invite.id }); await refresh(); }
    catch (cause) { setError(cause instanceof Error ? cause.message : "Não foi possível cancelar o convite."); }
    finally { setRevoking(""); }
  }
  async function saveAdminName(userId: string, displayName: string | null) {
    const result = await callAdminApi<{ userId: string; displayName: string | null }>("account-name-set", { userId, displayName });
    onAdminNameSaved(userId, result.displayName);
    void refresh().catch(() => undefined);
    return result.displayName;
  }
  return <div className="grid gap-4 xl:grid-cols-[minmax(0,.82fr)_minmax(0,1.18fr)]">
    <section className="rounded-2xl border border-[#dfe6f0] bg-white p-5 sm:p-6">
      <div className="flex size-10 items-center justify-center rounded-xl bg-[#eaf1fa] text-[#205b9e]"><Users size={18}/></div>
      <h2 className="mt-4 text-[14px] font-bold">Liberar acesso</h2>
      <p className="mt-1 text-[13px] leading-5 text-[#63788e]">Escolha o e-mail e gere um código de uso único. A pessoa cria a senha no primeiro acesso, sem confirmação por e-mail.</p>
      <form onSubmit={invite} className="mt-5 space-y-3">
        <label className="block text-xs font-bold text-[#405b75]">E-mail do acesso<input type="email" required value={email} onChange={(event)=>setEmail(event.target.value)} className="mt-1.5 h-11 w-full rounded-lg border border-[#d4deeb] px-3 text-xs outline-none focus:border-[#2b6cbb]" placeholder="parceiro@email.com"/></label>
        <label className="block text-xs font-bold text-[#405b75]">Perfil de acesso<select value={role} onChange={(event)=>{const nextRole=event.target.value as Role;setRole(nextRole);if(nextRole==="admin")setInfluencerId("");}} className="mt-1.5 h-11 w-full rounded-lg border border-[#d4deeb] bg-white px-3 text-sm outline-none focus:border-[#2b6cbb]"><option value="influencer">Influenciador</option><option value="admin">Administrador</option></select></label>
        {role === "influencer" ? <label className="block text-xs font-bold text-[#405b75]">Influenciador<select required value={influencerId} onChange={(event)=>setInfluencerId(event.target.value)} className="mt-1.5 h-11 w-full rounded-lg border border-[#d4deeb] bg-white px-3 text-xs outline-none focus:border-[#2b6cbb]"><option value="">Selecione</option>{overview.availableInfluencers.map((item)=><option key={item.id} value={item.id}>{item.name}{item.is_demo ? " · demonstração" : ""}</option>)}</select></label> : <p className="rounded-lg bg-[#fff9e9] px-3 py-2.5 text-xs leading-5 text-[#785b1d]">Administradores podem importar planilhas, revisar atribuições e liberar outros acessos.</p>}
        {error&&<p className="rounded-lg bg-[#fff3ef] p-2.5 text-xs text-[#a94b37]">{error}</p>}{notice&&<p className="rounded-lg bg-[#eaf2fc] p-2.5 text-xs text-[#205b9e]">{notice}</p>}
        <button disabled={busy} className="flex h-11 items-center gap-2 rounded-lg bg-[#185aa9] px-3.5 text-[13px] font-bold text-white hover:bg-[#114886] disabled:opacity-55">{busy?<LoaderCircle size={14} className="animate-spin"/>:<Mail size={14}/>}Gerar código de {role === "admin" ? "administrador" : "acesso"}</button>
      </form>
      {issued && <div className="mt-5 rounded-lg border border-[#b9d3f0] bg-[#f7faff] p-4"><p className="text-sm font-semibold text-[#173b67]">Código de {issued.role === "admin" ? "administrador" : "influenciador"} para {issued.email}</p><p className="mt-1 text-[13px] leading-5 text-[#526981]">Mostrado apenas agora. Válido até {new Date(issued.expiresAt).toLocaleString("pt-BR")}. Envie por um canal de confiança.</p><code className="mt-3 block break-all rounded-md bg-white p-3 text-[13px] text-[#193b63]">{issued.code}</code><button type="button" onClick={() => void navigator.clipboard.writeText(issued.code).then(() => setNotice("Código copiado.")).catch(() => setError("Não foi possível copiar. Selecione o código acima."))} className="mt-3 min-h-11 rounded-lg border border-[#b9d3f0] bg-white px-4 text-sm font-semibold text-[#205b9e]">Copiar código</button></div>}
    </section>
    <section className="overflow-hidden rounded-2xl border border-[#dfe6f0] bg-white">
      <div className="border-b border-[#e6ebf2] px-5 py-5 sm:px-6"><h2 className="text-[14px] font-bold">Contas vinculadas</h2><p className="mt-1 text-[13px] text-[#63788e]">Uma conta por influenciador.</p></div>
      {overview.members.length===0?<div className="px-5 py-5 text-xs text-[#63788e]">Nenhuma conta foi ativada ainda.</div>:<div className="divide-y divide-[#e6ebf2]">{overview.members.map((member)=><div key={member.user_id} className="flex items-start gap-3 px-5 py-4 sm:px-6"><div className={`mt-0.5 flex size-9 shrink-0 items-center justify-center rounded-[12px] ${member.role==="admin"?"bg-[#fff5df] text-[#a67520]":"bg-[#eaf1fa] text-[#245b9b]"}`}>{member.role==="admin"?<ShieldCheck size={16}/>:<Users size={16}/>}</div><div className="min-w-0 flex-1"><div className="truncate text-[13px] font-semibold">{member.role === "admin" ? member.display_name || "Administrador" : member.influencer_name ?? "Influenciador"}</div><div className="mt-0.5 break-all text-xs text-[#60758b]">{member.email}</div>{member.role === "admin" && <AdminNameEditor member={member} onSave={saveAdminName}/>}</div><span className="mt-1 shrink-0 rounded-full bg-[#eaf2fc] px-2.5 py-1 text-xs font-bold text-[#205b9e]">Ativo</span></div>)}</div>}
      <div className="border-t border-[#e6ebf2] px-5 py-4 sm:px-6"><div className="text-xs font-bold uppercase tracking-[.1em] text-[#63788e]">Acessos aguardando ativação · {overview.invites.length}</div>{overview.invites.length===0?<p className="mt-2 text-xs text-[#74889b]">Nenhum acesso aguardando ativação.</p>:<div className="mt-2 divide-y divide-[#e6ebf2]">{overview.invites.map((invite)=><div key={invite.id} className="flex items-center gap-3 py-2.5"><div className="min-w-0 flex-1"><div className="truncate text-xs font-semibold">{invite.email}</div><div className="mt-0.5 text-xs text-[#74889b]">{invite.role === "admin" ? "Administrador" : invite.influencer_name ?? "Influenciador"} · aguardando primeiro acesso</div></div><button onClick={()=>void revoke(invite)} disabled={revoking===invite.id} className="min-h-11 px-2 text-[13px] font-semibold text-[#9a5c45] hover:underline disabled:opacity-50">{revoking===invite.id?"Cancelando…":"Cancelar"}</button></div>)}</div>}</div>
    </section>
  </div>;
}

function AdminNameEditor({ member, onSave }: { member: Member; onSave: (userId: string, displayName: string | null) => Promise<string | null> }) {
  const [value, setValue] = useState(member.display_name ?? "");
  const [busy, setBusy] = useState(false);
  const [feedback, setFeedback] = useState("");
  const [error, setError] = useState("");

  useEffect(() => setValue(member.display_name ?? ""), [member.display_name]);

  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true); setFeedback(""); setError("");
    try {
      const displayName = await onSave(member.user_id, value.trim() || null);
      setValue(displayName ?? "");
      setFeedback(displayName ? "Nome salvo." : "Nome removido.");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Não foi possível salvar o nome.");
    } finally { setBusy(false); }
  }

  return <div className="mt-2.5">
    <form onSubmit={submit} className="flex max-w-[420px] gap-2">
      <label className="sr-only" htmlFor={`admin-display-name-${member.user_id}`}>Nome para identificar esta conta administrativa</label>
      <input id={`admin-display-name-${member.user_id}`} value={value} onChange={(event) => setValue(event.target.value)} maxLength={80} placeholder="Nome para identificar esta conta" className="h-10 min-w-0 flex-1 rounded-lg border border-[#d4deeb] px-3 text-xs outline-none focus:border-[#2b6cbb] focus:ring-2 focus:ring-[#d7e8fa]" />
      <button type="submit" disabled={busy || value.trim() === (member.display_name ?? "")} className="inline-flex min-h-10 items-center gap-1.5 rounded-lg border border-[#b9d3f0] bg-[#f7faff] px-3 text-xs font-bold text-[#205b9e] hover:bg-[#eaf2fc] focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#2f6fc2] disabled:cursor-not-allowed disabled:opacity-50">{busy ? <LoaderCircle size={13} className="animate-spin"/> : null}{busy ? "Salvando…" : "Salvar nome"}</button>
    </form>
    {feedback && <p role="status" className="mt-1.5 text-xs text-[#2c7558]">{feedback}</p>}
    {error && <p role="alert" className="mt-1.5 text-xs text-[#a94b37]">{error}</p>}
  </div>;
}

function ProfileSettingsPanel({ profile, onAdminNameSaved }: { profile: Profile; onAdminNameSaved: (userId: string, displayName: string | null) => void }) {
  const [value, setValue] = useState(profile.display_name ?? "");
  const [busy, setBusy] = useState(false);
  const [feedback, setFeedback] = useState("");
  const [error, setError] = useState("");

  useEffect(() => setValue(profile.display_name ?? ""), [profile.display_name]);

  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true); setFeedback(""); setError("");
    try {
      const result = await callAdminApi<{ userId: string; displayName: string | null }>("account-name-set", {
        userId: profile.user_id,
        displayName: value.trim() || null,
      });
      setValue(result.displayName ?? "");
      onAdminNameSaved(profile.user_id, result.displayName);
      setFeedback(result.displayName ? "Seu nome foi atualizado." : "Seu nome foi removido.");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Não foi possível salvar seu nome.");
    } finally { setBusy(false); }
  }

  return <section className="max-w-2xl rounded-2xl border border-[#dfe6f0] bg-white p-5 sm:p-6">
    <div className="flex size-10 items-center justify-center rounded-xl bg-[#eaf1fa] text-[#205b9e]"><UserRound size={18}/></div>
    <h2 className="mt-4 text-[15px] font-bold">Seu nome de exibição</h2>
    <p className="mt-1 text-[13px] leading-5 text-[#63788e]">Este nome aparece no cabeçalho do portal e na lista de contas administrativas.</p>
    <form onSubmit={submit} className="mt-5 max-w-lg space-y-3">
      <label className="block text-xs font-bold text-[#405b75]">Nome<input value={value} onChange={(event) => setValue(event.target.value)} maxLength={80} className="mt-1.5 h-11 w-full rounded-lg border border-[#d4deeb] bg-white px-3 text-sm font-medium outline-none focus:border-[#2b6cbb]" placeholder="Como você quer ser identificado"/></label>
      <div className="text-xs text-[#60758b]">E-mail da conta: <strong className="font-semibold">{profile.email}</strong></div>
      {feedback && <p role="status" className="text-xs text-[#2c7558]">{feedback}</p>}
      {error && <p role="alert" className="text-xs text-[#a94b37]">{error}</p>}
      <button type="submit" disabled={busy || value.trim() === (profile.display_name ?? "")} className="inline-flex min-h-11 items-center gap-2 rounded-lg bg-[#185aa9] px-4 text-[13px] font-bold text-white hover:bg-[#114886] disabled:cursor-not-allowed disabled:opacity-55">{busy ? <LoaderCircle size={15} className="animate-spin"/> : <Check size={15}/>}Salvar meu nome</button>
    </form>
  </section>;
}

function AdminReferralsPanel({ influencers }: { influencers: Influencer[] }) {
  const pageSize = 50;
  const [filterId, setFilterId] = useState("all");
  const [search, setSearch] = useState("");
  const [page, setPage] = useState(0);
  const [refreshKey, setRefreshKey] = useState(0);
  const [result, setResult] = useState<AdminReferralsResult | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    let cancelled = false;
    const timeout = window.setTimeout(async () => {
      setLoading(true); setError("");
      try {
        const pageResult = await callAdminApi<AdminReferralsResult>("admin-referrals", {
          limit: pageSize,
          offset: page * pageSize,
          influencerId: filterId,
          search: search.trim(),
        });
        if (!cancelled) setResult({
          ...pageResult,
          items: pageResult.items.map((item) => ({
            ...item,
            name: repairTextEncoding(item.name),
            region: item.region ? repairTextEncoding(item.region) : null,
          })),
        });
      } catch (cause) {
        if (!cancelled) setError(cause instanceof Error ? cause.message : "Não foi possível carregar os indicados.");
      } finally {
        if (!cancelled) setLoading(false);
      }
    }, search.trim() ? 250 : 0);
    return () => { cancelled = true; window.clearTimeout(timeout); };
  }, [filterId, page, refreshKey, search]);

  const firstItem = result && result.total > 0 ? page * pageSize + 1 : 0;
  const lastItem = result ? Math.min((page + 1) * pageSize, result.total) : 0;

  function changeFilter(value: string) {
    setFilterId(value);
    setPage(0);
  }

  function changeSearch(value: string) {
    setSearch(value);
    setPage(0);
  }

  return <div className="space-y-4">
    <section className="rounded-2xl border border-[#dfe6f0] bg-white p-5 sm:p-6">
      <div className="flex flex-col justify-between gap-4 sm:flex-row sm:items-start">
        <div><h2 className="text-[18px] font-bold tracking-[-.02em]">Todos os indicados</h2><p className="mt-1 text-[13px] text-[#60758b]">Consulte os entregadores, corridas e metas de cada influenciador.</p></div>
        <button type="button" onClick={() => setRefreshKey((value) => value + 1)} disabled={loading} className="inline-flex h-11 w-fit items-center gap-2 rounded-lg border border-[#d4deeb] bg-white px-3.5 text-[13px] font-semibold text-[#536d70] hover:bg-[#f7faff] focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#2f6fc2] disabled:opacity-55"><History size={15}/>{loading ? "Atualizando…" : "Atualizar lista"}</button>
      </div>
      <div className="mt-5 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard label="Indicados no filtro" value={fmtNumber(result?.total ?? 0)} icon={<Users size={17}/>} sub="entregadores atribuídos" color="teal"/>
        <StatCard label="Corridas acumuladas" value={fmtNumber(result?.totalRoutes ?? 0)} icon={<BarChart3 size={17}/>} sub="somadas por UUID" color="blue"/>
        <StatCard label="Prêmios liberados" value={fmtNumber(result?.unlockedCount ?? 0)} icon={<CheckCircle2 size={17}/>} sub="um por entregador ao atingir a meta" color="gold"/>
        <StatCard label="Valor dos prêmios" value={fmtMoney(result?.unlockedPrizeCents ?? 0)} icon={<Award size={17}/>} sub="total liberado, sem controle de pagamento" color="plum"/>
      </div>
      <div className="mt-4 space-y-3">
        <label className="relative block text-xs font-semibold text-[#63788e]"><span className="sr-only">Buscar indicado</span><Search size={16} className="pointer-events-none absolute left-3 top-[13px] text-[#8091a4]"/><input type="search" value={search} onChange={(event) => changeSearch(event.target.value)} placeholder="Buscar nome, UUID, telefone ou CPF" className="h-11 w-full rounded-lg border border-[#d4deeb] bg-white pl-9 pr-3 text-[13px] font-medium text-[#29435e] outline-none focus:border-[#2f6fc2] focus:ring-2 focus:ring-[#d7e8fa]" /></label>
        <div role="group" aria-label="Filtrar indicados por influenciador" className="flex flex-wrap gap-2">
          {[{ id: "all", name: "Todos" }, ...influencers].map((item) => <button key={item.id} type="button" onClick={() => changeFilter(item.id)} aria-pressed={filterId === item.id} className={`min-h-10 rounded-full border px-3.5 text-xs font-semibold transition focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#2f6fc2] ${filterId === item.id ? "border-[#185aa9] bg-[#185aa9] text-white" : "border-[#d4deeb] bg-white text-[#536d70] hover:bg-[#f7faff]"}`}>{item.name}</button>)}
        </div>
      </div>
    </section>

    {error && <p role="alert" className="rounded-xl bg-[#fff3ef] px-4 py-3 text-[13px] text-[#a94b37]">{error}</p>}
    {loading && !result ? <div className="grid min-h-56 place-items-center rounded-xl border border-[#dfe6f0] bg-white text-sm text-[#60758b]"><LoaderCircle className="mr-2 animate-spin" size={18}/>Carregando indicados…</div> : result?.items.length === 0 ? <div className="rounded-xl border border-[#dfe6f0] bg-white"><EmptyState title="Nenhum indicado encontrado" detail={search || filterId !== "all" ? "Ajuste o filtro ou a busca para ver outros resultados." : "Os indicados atribuídos aparecerão depois da importação do Data Crazy."}/></div> : result ? <>
      <div className="overflow-hidden rounded-xl border border-[#dfe6f0] bg-white md:hidden" aria-busy={loading}>
        <div className="divide-y divide-[#e6ebf2]">{result.items.map((item) => {
          const progress = Math.min(100, Math.round(Number(item.routes) / item.route_goal * 100));
          return <article key={item.uuid} className="p-4">
            <div className="flex items-start justify-between gap-3"><div className="min-w-0"><div className="break-words text-[13px] font-bold text-[#203b58]">{item.name || "Nome não informado"}</div><div className="mt-1 break-all text-xs text-[#8191a2]">UUID · {item.uuid}</div></div><span className="shrink-0 rounded-full bg-[#eaf1fa] px-2.5 py-1 text-xs font-bold text-[#205b9e]">{item.influencer_name}</span></div>
            <div className="mt-3 text-xs text-[#405b76]">{item.region || "Região não informada"}</div>
            <div className="mt-1 flex items-center gap-1 text-xs text-[#60758b]"><CalendarDays size={13}/>Liberação: {fmtDate(item.released_at)}</div>
            <div className="mt-1 break-words text-xs text-[#60758b]">Telefone · {item.phone || "indisponível"}<span className="px-1.5 text-[#bdc8d4]">·</span>CPF · {item.cpf || "indisponível"}</div>
            <div className="mt-3"><div className="flex items-center justify-between gap-3 text-xs"><span className="font-semibold tabular-nums text-[#29435e]">{fmtNumber(Number(item.routes))} / {fmtNumber(item.route_goal)} corridas</span><span className="font-bold tabular-nums text-[#205b9e]">{progress}%</span></div><div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-[#e8eef7]"><div className="h-full rounded-full bg-[#2f6fc2]" style={{ width: `${progress}%` }}/></div></div>
            <div className="mt-3 flex items-center justify-between gap-2"><span className={`text-xs font-bold ${item.prize_unlocked ? "text-[#267353]" : "text-[#60758b]"}`}>{item.prize_unlocked ? "Prêmio liberado" : `Faltam ${fmtNumber(item.routes_remaining)} corridas`}</span><span className="text-xs font-bold text-[#29435e]">{fmtMoney(item.prize_cents)}</span></div>
          </article>;
        })}</div>
      </div>

      <div className="hidden overflow-hidden rounded-xl border border-[#dfe6f0] bg-white md:block" aria-busy={loading}>
        <div className="overflow-x-auto"><table className="w-full min-w-[1040px] border-collapse text-left">
          <thead className="bg-[#f7faff] text-xs font-bold uppercase tracking-[.08em] text-[#71859b]"><tr><th className="px-4 py-3">Entregador</th><th className="px-4 py-3">Influenciador</th><th className="px-4 py-3">Contato</th><th className="px-4 py-3">Corridas e progresso</th><th className="px-4 py-3">Prêmio</th></tr></thead>
          <tbody className="divide-y divide-[#edf1f6]">{result.items.map((item) => {
            const progress = Math.min(100, Math.round(Number(item.routes) / item.route_goal * 100));
            return <tr key={item.uuid} className="align-top hover:bg-[#fbfcfe]"><td className="max-w-[250px] px-4 py-3.5"><div className="text-[13px] font-semibold text-[#203b58]">{item.name || "Nome não informado"}</div><div className="mt-1 break-all text-xs text-[#8191a2]">{item.uuid}</div><div className="mt-1 text-xs text-[#60758b]">{item.region || "Região não informada"}</div><div className="mt-1 text-xs text-[#60758b]">Liberação: {fmtDate(item.released_at)}</div></td><td className="px-4 py-3.5 text-xs font-semibold text-[#405b76]">{item.influencer_name}</td><td className="px-4 py-3.5 text-xs leading-5 text-[#536c84]">{item.phone || "Telefone indisponível"}<div>{item.cpf ? `CPF ${item.cpf}` : "CPF indisponível"}</div></td><td className="w-[240px] px-4 py-3.5"><div className="flex justify-between gap-3 text-xs"><span className="font-semibold tabular-nums text-[#29435e]">{fmtNumber(Number(item.routes))} / {fmtNumber(item.route_goal)}</span><span className="font-bold tabular-nums text-[#205b9e]">{progress}%</span></div><div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-[#e8eef7]"><div className="h-full rounded-full bg-[#2f6fc2]" style={{ width: `${progress}%` }}/></div><div className="mt-1 text-xs text-[#60758b]">{item.prize_unlocked ? "Meta atingida" : `Faltam ${fmtNumber(item.routes_remaining)} corridas`}</div></td><td className="px-4 py-3.5"><div className="text-xs font-bold text-[#29435e]">{fmtMoney(item.prize_cents)}</div><div className={`mt-1 text-xs font-semibold ${item.prize_unlocked ? "text-[#267353]" : "text-[#8191a2]"}`}>{item.prize_unlocked ? "Liberado" : "Em progresso"}</div></td></tr>;
          })}</tbody>
        </table></div>
      </div>
      <div className="flex flex-col justify-between gap-3 text-xs text-[#60758b] sm:flex-row sm:items-center"><span>{loading ? "Atualizando resultados… · " : ""}{fmtNumber(firstItem)}–{fmtNumber(lastItem)} de {fmtNumber(result.total)} indicados</span><div className="flex gap-2"><button type="button" onClick={() => setPage((value) => Math.max(0, value - 1))} disabled={page === 0 || loading} className="min-h-10 rounded-lg border border-[#d4deeb] bg-white px-3 font-semibold text-[#536d70] hover:bg-[#f7faff] disabled:cursor-not-allowed disabled:opacity-50">Anterior</button><button type="button" onClick={() => setPage((value) => value + 1)} disabled={(page + 1) * pageSize >= result.total || loading} className="min-h-10 rounded-lg border border-[#d4deeb] bg-white px-3 font-semibold text-[#536d70] hover:bg-[#f7faff] disabled:cursor-not-allowed disabled:opacity-50">Próxima</button></div></div>
    </> : null}
  </div>;
}
