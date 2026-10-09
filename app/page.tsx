"use client";

import { useCallback, useEffect, useMemo, useState, useSyncExternalStore, type ChangeEvent, type FormEvent } from "react";
import type { Session } from "@supabase/supabase-js";
import {
  ArrowDownUp, ArrowRight, Award, BarChart3, Check, CheckCircle2, ChevronDown,
  CircleAlert, ClipboardList, CloudUpload, Download, Eye, EyeOff, FileSpreadsheet,
  Gift, LoaderCircle, LogOut, Mail, MapPin, Menu, Search, ShieldCheck, Users,
} from "lucide-react";
import { callAccessApi, callAdminApi, DATA_SCHEMA, getSupabase } from "@/lib/supabase";
import {
  parseDataCrazy, parsePerformance, type ImportPreview, type PerformanceImportRow,
  type ReferralImportRow,
} from "@/lib/importers";

type Role = "admin" | "influencer";
type Profile = { role: Role; influencer_id: string | null; email: string };
type Influencer = { id: string; name: string; route_goal: number; prize_cents: number };
type Referral = {
  referral_id: string;
  uuid: string;
  name: string;
  region: string | null;
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
type Review = { id: string; uuid: string; name: string; region: string | null; raw_influencer: string; status: string };
type Member = { user_id: string; email: string; role: Role; influencer_id: string | null; influencer_name: string | null };
type PendingInvite = { id: string; email: string; influencer_name: string | null; created_at: string };
type AdminOverview = { influencers: Influencer[]; imports: ImportSummary[]; reviews: Review[]; reviewCount: number; members: Member[]; invites: PendingInvite[]; referralCount: number; contributionTotal: number };
type TabId = "dashboard" | "data-crazy" | "performance" | "reviews" | "accounts";

const fmtMoney = (cents: number) => new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" }).format(cents / 100);
const fmtNumber = (number: number) => new Intl.NumberFormat("pt-BR").format(number);
const subscribeRecovery = (callback: () => void) => {
  window.addEventListener("hashchange", callback);
  window.addEventListener("popstate", callback);
  return () => { window.removeEventListener("hashchange", callback); window.removeEventListener("popstate", callback); };
};
const getRecoverySnapshot = () => typeof window !== "undefined" && (window.location.hash.includes("type=recovery") || window.location.search.includes("type=recovery"));
const getRecoveryServerSnapshot = () => false;
const adminTabs: { id: TabId; label: string; icon: typeof BarChart3 }[] = [
  { id: "dashboard", label: "Visão geral", icon: BarChart3 },
  { id: "data-crazy", label: "Data Crazy", icon: FileSpreadsheet },
  { id: "performance", label: "Performance", icon: ArrowDownUp },
  { id: "reviews", label: "Revisões", icon: ClipboardList },
  { id: "accounts", label: "Acessos", icon: Users },
];

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
  const [mobileMenu, setMobileMenu] = useState(false);
  const [search, setSearch] = useState("");
  const [onlyUnlocked, setOnlyUnlocked] = useState(false);

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
        setActiveTab("dashboard");
      } else {
        const [{ data: influencerData, error: influencerError }, referralData, { data: importDate, error: importDateError }] = await Promise.all([
          supabase!.schema(DATA_SCHEMA).from("influencers").select("id,name,route_goal,prize_cents").eq("id", nextProfile.influencer_id).single(),
          (async () => {
            const all: Referral[] = [];
            for (let offset = 0; ; offset += 500) {
              const { data, error } = await supabase!.schema(DATA_SCHEMA).from("referral_progress")
                .select("referral_id,uuid,name,region,phone,cpf,routes,route_goal,prize_cents,prize_unlocked,routes_remaining,influencer_name")
                .order("prize_unlocked", { ascending: false }).order("routes", { ascending: false }).order("uuid")
                .range(offset, offset + 499);
              if (error) throw error;
              all.push(...((data ?? []) as Referral[]));
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
  const visibleTabs = isAdmin ? adminTabs : adminTabs.slice(0, 1);
  const title = isAdmin ? "Administração" : `Indicações de ${influencer?.name ?? "você"}`;
  const subtitle = isAdmin ? "Bases, revisões e acessos" : "Corridas e prêmios por entregador";

  return (
    <main className="min-h-screen bg-[#f6f8fc] text-[#172a40]">
      <div className="mx-auto flex min-h-screen max-w-[1600px]">
        <aside className="hidden w-[250px] shrink-0 flex-col border-r border-[#dfe6f0] bg-white px-5 py-7 lg:flex">
          <Brand />
          <div className="mt-12 text-xs font-bold uppercase tracking-[.18em] text-[#63788e]">Menu</div>
          <nav className="mt-3 space-y-1.5">
            {visibleTabs.map((tab) => <NavButton key={tab.id} tab={tab} active={activeTab === tab.id} onClick={() => setActiveTab(tab.id)} />)}
          </nav>
          <div className="mt-auto rounded-2xl bg-[#eff5fc] p-4">
            <div className="flex size-9 items-center justify-center rounded-xl bg-white text-[#1f61af]"><ShieldCheck size={18} /></div>
            <p className="mt-3 text-sm font-semibold">Acesso individual</p>
            <p className="mt-1 text-xs leading-5 text-[#63777b]">Cada conta acompanha somente seus próprios indicados.</p>
          </div>
        </aside>

        <section className="min-w-0 flex-1">
          <header className="sticky top-0 z-20 flex h-[76px] items-center justify-between border-b border-[#dfe6f0] bg-white/95 px-5 backdrop-blur-md sm:px-8 lg:px-10">
            <div className="flex min-w-0 items-center gap-3">
              {isAdmin && <button onClick={() => setMobileMenu(!mobileMenu)} className="flex size-11 items-center justify-center rounded-lg text-[#526981] hover:bg-[#f0f4f9] lg:hidden" aria-label={mobileMenu ? "Fechar menu" : "Abrir menu"} aria-expanded={mobileMenu}><Menu size={21} /></button>}
              <div className="min-w-0"><div className="truncate text-sm font-semibold sm:text-[15px]">{title}</div><div className="mt-0.5 hidden text-xs text-[#7a8b8e] sm:block">{subtitle}</div></div>
            </div>
            <div className="flex items-center gap-3">
              <div className="hidden text-right sm:block"><div className="text-xs font-semibold">{isAdmin ? "Administrador" : influencer?.name}</div><div className="mt-0.5 max-w-44 truncate text-[13px] text-[#87979a]">{profile.email}</div></div>
              <div className="flex size-10 items-center justify-center rounded-full bg-[#eaf1fa] text-sm font-bold text-[#1f61af]">{(isAdmin ? "AD" : influencer?.name?.slice(0, 2) ?? "IG").toUpperCase()}</div>
              <button onClick={() => void supabase.auth.signOut()} className="flex size-11 items-center justify-center rounded-lg text-[#60758b] hover:bg-[#f0f4f9]" title="Sair" aria-label="Sair"><LogOut size={19} /></button>
            </div>
          </header>

          {mobileMenu && <><button className="fixed inset-0 z-20 bg-[#112e53]/20 lg:hidden" aria-label="Fechar menu" onClick={() => setMobileMenu(false)}/><div className="fixed inset-x-0 top-[76px] z-30 border-b border-[#dfe6f0] bg-white px-4 py-3 shadow-lg lg:hidden">{visibleTabs.map((tab) => <NavButton key={tab.id} tab={tab} active={activeTab === tab.id} onClick={() => { setActiveTab(tab.id); setMobileMenu(false); }} />)}</div></>}
          <div className="mx-auto max-w-[1320px] px-4 pb-12 pt-7 sm:px-8 sm:pt-9 lg:px-10">
            {loadError && <div className="mb-5 flex items-start gap-3 rounded-xl border border-[#f2d8bd] bg-[#fffaf4] p-4 text-sm text-[#84572f]"><CircleAlert size={18} className="mt-0.5 shrink-0" />{loadError}</div>}
            {!isAdmin ? <InfluencerDashboard referrals={referrals} influencer={influencer} lastImportAt={lastImportAt} search={search} setSearch={setSearch} onlyUnlocked={onlyUnlocked} setOnlyUnlocked={setOnlyUnlocked} /> : (
              <AdminDashboard activeTab={activeTab} overview={overview} refresh={refreshAdmin} onTab={setActiveTab} />
            )}
          </div>
        </section>
      </div>
    </main>
  );
}

function Brand() {
  return <div className="brand-lockup"><div className="brand-mark" aria-hidden="true"><span className="brand-mark-line"/><span className="brand-mark-dot"/></div><div><div className="brand-name">Indique <span>e Ganhe</span></div><div className="brand-description">Indicações e recompensas</div></div></div>;
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
        <p className="login-data-note">Os números são atualizados quando a administração importa novas planilhas.</p>
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
      <p className="login-privacy">Cada influenciador vê somente os seus indicados.</p>
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
    <div className="dashboard-heading"><div><h1>Seus indicados</h1><p>Meta de {fmtNumber(influencer?.route_goal ?? 0)} corridas por entregador · {fmtMoney(influencer?.prize_cents ?? 0)} por prêmio</p></div><span>{lastImportAt ? `Última importação: ${new Date(lastImportAt).toLocaleString("pt-BR")}` : "Aguardando a primeira importação"}</span></div>
    <section className="referral-section">
      <div className="referral-heading"><div><h2>Progresso dos entregadores</h2><p>Corridas acumuladas até a próxima meta</p></div><div className="referral-controls"><label className="relative"><Search size={18} className="absolute left-3.5 top-1/2 -translate-y-1/2 text-[#8a9aaf]"/><input aria-label="Buscar entregador" value={search} onChange={(event) => setSearch(event.target.value)} className="h-11 w-full rounded-lg border border-[#dfe6f0] bg-white pl-10 pr-3 text-sm outline-none focus:border-[#2c67b2] sm:w-56" placeholder="Nome ou região"/></label><button onClick={() => setOnlyUnlocked(!onlyUnlocked)} aria-pressed={onlyUnlocked} className="filter-action">{onlyUnlocked ? "Limpar filtro" : "Prêmios conquistados"}</button></div></div>
      {visible.length === 0 ? <EmptyState title={referrals.length ? "Nenhum resultado encontrado" : "Ainda não há indicados"} detail={referrals.length ? "Tente outro nome ou limpe o filtro." : "Os entregadores aparecerão depois da próxima importação do Data Crazy."} /> : <div className="divide-y divide-[#e6ebf2]">{visible.slice(0, visibleCount).map((referral) => <ReferralRow key={referral.referral_id} referral={referral}/>)}</div>}
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
    <div className="flex min-w-0 items-center gap-3"><div className="flex size-10 shrink-0 items-center justify-center rounded-lg bg-[#eaf1fa] text-xs font-bold text-[#2b5d9c]">{(referral.name || "EN").split(/\s+/).slice(0, 2).map((part) => part[0]).join("").toUpperCase()}</div><div className="min-w-0 flex-1"><div className="truncate text-sm font-semibold text-[#223950]">{referral.name || "Nome indisponível"}</div><div className="mt-1 flex items-center gap-1 text-xs text-[#657b90]"><MapPin size={13}/>{referral.region || "Região não informada"}</div></div><ChevronDown size={18} className={`shrink-0 text-[#5e7894] transition md:hidden ${expanded ? "rotate-180" : ""}`} /></div>
    <div><div className="mb-2 flex items-center justify-between text-xs"><span className="font-semibold text-[#294866]">{fmtNumber(referral.routes)} <span className="font-normal text-[#64798d]">de {fmtNumber(referral.route_goal)} corridas</span></span><span className="font-semibold text-[#245ca6]">{progress}%</span></div><div className="h-2 overflow-hidden rounded-full bg-[#e8eef7]"><div className="h-full rounded-full bg-[#2f6fc2] transition-all" style={{ width: `${progress}%` }}/></div></div>
    <div className="flex items-center justify-between gap-2 md:block md:text-right">{referral.prize_unlocked ? <span className="inline-flex items-center gap-1.5 rounded-full bg-[#eaf2fc] px-2.5 py-1.5 text-xs font-bold text-[#205b9e]"><CheckCircle2 size={12}/>Prêmio liberado</span> : <><span className="block text-[13px] font-semibold text-[#415b60]">Faltam {fmtNumber(referral.routes_remaining)}</span><span className="mt-0.5 block text-xs text-[#697f94]">para {fmtMoney(referral.prize_cents)}</span></>}</div><ChevronDown size={16} className={`hidden text-[#9aaaa8] transition md:block ${expanded ? "rotate-180" : ""}`} />
  </button>{expanded && <div className="mt-4 grid gap-3 rounded-xl bg-[#f7faff] p-3.5 text-[13px] sm:grid-cols-3"><Detail label="Telefone" value={referral.phone || "Indisponível"}/><Detail label="CPF" value={referral.cpf ? `${referral.cpf.slice(0, 3)}.${referral.cpf.slice(3, 6)}.${referral.cpf.slice(6, 9)}-${referral.cpf.slice(9)}` : "Não informado"}/><Detail label="UUID" value={referral.uuid}/></div>}</div>;
}

function Detail({ label, value }: { label: string; value: string }) { return <div><div className="text-xs font-bold uppercase tracking-[.08em] text-[#98a5a4]">{label}</div><div className="mt-1 break-all font-medium text-[#52686a]">{value}</div></div>; }

function EmptyState({ title, detail }: { title: string; detail: string }) { return <div className="grid min-h-56 place-items-center px-5 py-10 text-center"><div className="max-w-sm"><div className="mx-auto flex size-11 items-center justify-center rounded-[14px] bg-[#eaf1fa] text-[#245b9b]"><Users size={19}/></div><h3 className="mt-4 text-[14px] font-bold">{title}</h3><p className="mt-1.5 text-xs leading-5 text-[#60758b]">{detail}</p></div></div>; }

function AdminDashboard({ activeTab, overview, refresh, onTab }: { activeTab: TabId; overview: AdminOverview | null; refresh: () => Promise<void>; onTab: (tab: TabId) => void }) {
  if (!overview) return <div className="grid min-h-64 place-items-center text-sm text-[#60758b]"><LoaderCircle className="mr-2 animate-spin" size={18}/>Carregando área administrativa…</div>;
  return <div>
    <div className="mb-7 flex flex-col justify-between gap-4 sm:flex-row sm:items-end"><div><h1 className="mt-2 text-[29px] font-semibold tracking-[-.045em] sm:text-[34px]">{adminTabs.find((tab) => tab.id === activeTab)?.label}</h1><p className="mt-1.5 text-[13px] text-[#60758b]">Importe planilhas, revise UUIDs sem responsável e libere contas.</p></div><button onClick={() => void refresh()} className="h-11 w-fit rounded-lg border border-[#d4deeb] bg-white px-3.5 text-[13px] font-semibold text-[#536d70] hover:bg-[#f7faff]">Atualizar dados</button></div>
    {activeTab === "dashboard" && <AdminHome overview={overview} onTab={onTab}/>}
    {activeTab === "data-crazy" && <ImportPanel kind="data_crazy" title="Data Crazy" subtitle="Substitui a lista atual de indicados em uma operação atômica." overview={overview} refresh={refresh}/>}
    {activeTab === "performance" && <ImportPanel kind="performance" title="Performance" subtitle="Adiciona as corridas desta importação ao acumulado existente." overview={overview} refresh={refresh}/>}
    {activeTab === "reviews" && <ReviewsPanel overview={overview} refresh={refresh}/>}
    {activeTab === "accounts" && <AccountsPanel overview={overview} refresh={refresh}/>}
  </div>;
}

function AdminHome({ overview, onTab }: { overview: AdminOverview; onTab: (tab: TabId) => void }) {
  const latest = overview.imports[0];
  return <><div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4"><StatCard label="Entregadores ativos" value={fmtNumber(overview.referralCount)} icon={<Users size={17}/>} sub="na lista atual do Data Crazy" color="teal"/><StatCard label="Corridas acumuladas" value={fmtNumber(overview.contributionTotal)} icon={<BarChart3 size={17}/>} sub="soma do histórico importado" color="blue"/><StatCard label="Atribuições em revisão" value={fmtNumber(overview.reviewCount ?? overview.reviews.length)} icon={<ClipboardList size={17}/>} sub="UUIDs aguardando responsável" color="gold"/><StatCard label="Contas vinculadas" value={fmtNumber(overview.members.length)} icon={<ShieldCheck size={17}/>} sub="administração e influenciadores" color="plum"/></div>
    <div className="mt-7 grid gap-4 xl:grid-cols-[1.15fr_.85fr]"><section className="rounded-2xl border border-[#dfe6f0] bg-white p-5 sm:p-6"><div className="flex items-start justify-between"><div><h2 className="text-[15px] font-bold">Próximas ações</h2><p className="mt-1 text-[13px] text-[#63788e]">Importe novas bases ou resolva atribuições pendentes.</p></div></div><div className="mt-5 grid gap-3 sm:grid-cols-2"><ActionCard icon={<CloudUpload size={17}/>} title="Atualizar indicados" text="Troque a lista atual com o novo arquivo Data Crazy." onClick={() => onTab("data-crazy")}/><ActionCard icon={<ArrowDownUp size={17}/>} title="Somar performance" text="Acrescente novas corridas ao acumulado da campanha." onClick={() => onTab("performance")}/><ActionCard icon={<ClipboardList size={17}/>} title={`Revisar atribuições · ${overview.reviewCount ?? overview.reviews.length}`} text="Resolva UUIDs sem um influenciador reconhecido." onClick={() => onTab("reviews")}/><ActionCard icon={<Users size={17}/>} title="Gerenciar acessos" text="Convide cada parceiro para sua própria conta." onClick={() => onTab("accounts")}/></div></section>
      <section className="rounded-2xl border border-[#dfe6f0] bg-white p-5 sm:p-6"><div className="flex items-start justify-between"><div><h2 className="text-[15px] font-bold">Última importação</h2><p className="mt-1 text-[13px] text-[#63788e]">Registro de processamento</p></div><FileSpreadsheet size={18} className="text-[#6b8f83]"/></div>{latest ? <><div className="mt-6 inline-flex items-center gap-1.5 rounded-full bg-[#eaf2fc] px-2.5 py-1 text-xs font-bold text-[#277957]"><Check size={12}/>{latest.status === "completed" ? "Concluída" : latest.status}</div><div className="mt-3 truncate text-sm font-semibold text-[#29435e]">{latest.file_name}</div><div className="mt-1 text-[13px] text-[#60758b]">{latest.kind === "data_crazy" ? "Data Crazy" : "Performance"} · {new Date(latest.created_at).toLocaleString("pt-BR")}</div><div className="mt-4 border-t border-[#e6ebf2] pt-3 text-xs text-[#63788e]">{fmtNumber(latest.metrics?.total ?? 0)} registros na última carga</div></> : <p className="mt-7 rounded-xl bg-[#f7faff] px-4 py-5 text-xs leading-5 text-[#63788e]">Ainda não há importações. Os arquivos de exemplo foram usados apenas para validar o leitor; nenhum dado foi carregado.</p>}</section></div>
    <section className="mt-4 rounded-2xl border border-[#dfe6f0] bg-white p-5 sm:p-6"><div className="flex items-center justify-between"><div><h2 className="text-[15px] font-bold">Regras de premiação</h2><p className="mt-1 text-[13px] text-[#63788e]">Um prêmio por entregador ao alcançar a meta.</p></div><Gift size={18} className="text-[#b3822e]"/></div><div className="mt-4 grid gap-2 sm:grid-cols-2 xl:grid-cols-3">{overview.influencers.map((item) => <div key={item.id} className="flex items-center justify-between rounded-xl bg-[#f7faff] px-3.5 py-3"><span className="text-xs font-semibold">{item.name}</span><span className="text-xs font-semibold text-[#60758b]">{item.route_goal} corridas <span className="mx-1 text-[#c0c9c7">·</span><strong className="text-[#205b9e]">{fmtMoney(item.prize_cents)}</strong></span></div>)}</div></section>
  </>;
}

function ActionCard({ icon, title, text, onClick }: { icon: React.ReactNode; title: string; text: string; onClick: () => void }) { return <button onClick={onClick} className="group flex gap-3 rounded-xl border border-[#e5ebf4] p-3.5 text-left transition hover:border-[#b8d1ed] hover:bg-[#f7faff]"><div className="flex size-9 shrink-0 items-center justify-center rounded-[11px] bg-[#eaf1fa] text-[#205b9e]">{icon}</div><div><div className="text-[13px] font-bold text-[#29435e]">{title}</div><div className="mt-1 text-xs leading-[17px] text-[#63788e]">{text}</div></div><ArrowRight size={14} className="ml-auto mt-1 shrink-0 text-[#a6b2b0] transition group-hover:translate-x-0.5 group-hover:text-[#205b9e]"/></button>; }

function ImportPanel({ kind, title, subtitle, overview, refresh }: { kind: "data_crazy" | "performance"; title: string; subtitle: string; overview: AdminOverview; refresh: () => Promise<void> }) {
  const [preview, setPreview] = useState<ImportPreview<ReferralImportRow | PerformanceImportRow> | null>(null);
  const [duplicate, setDuplicate] = useState(false);
  const [busy, setBusy] = useState(false);
  const [batchId, setBatchId] = useState("");
  const [progress, setProgress] = useState(0);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const lastSame = overview.imports.find((item) => item.kind === kind);

  async function chooseFile(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    if (batchId) await callAdminApi("import-cancel", { batchId }).catch(() => undefined);
    setPreview(null); setError(""); setMessage(""); setDuplicate(false); setBatchId(""); setBusy(true);
    try {
      if (!/\.(csv|xlsx|xls)$/i.test(file.name)) throw new Error("Escolha um arquivo .csv, .xlsx ou .xls.");
      const parsed = kind === "data_crazy" ? await parseDataCrazy(file) : await parsePerformance(file);
      setPreview(parsed as ImportPreview<ReferralImportRow | PerformanceImportRow>);
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
          kind, fileName: preview.fileName, fileHash: preview.fileHash, metrics: preview.metrics, totalRows: preview.rows.length,
        });
        activeBatchId = started.batchId;
        setBatchId(activeBatchId);
        if (kind === "performance" && started.duplicateFile && !allowDuplicate) {
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
      setMessage(kind === "data_crazy" ? "Lista Data Crazy substituída com sucesso." : "Corridas adicionadas ao acumulado.");
      setPreview(null); setDuplicate(false); setBatchId(""); await refresh();
    } catch (cause) {
      if (activeBatchId) await callAdminApi("import-cancel", { batchId: activeBatchId }).catch(() => undefined);
      setBatchId("");
      setError(cause instanceof Error ? cause.message : "A importação não foi concluída.");
    }
    finally { setBusy(false); }
  }

  return <div className="grid gap-4 xl:grid-cols-[minmax(0,1.25fr)_minmax(280px,.75fr)]"><section className="rounded-2xl border border-[#dfe6f0] bg-white p-5 sm:p-6"><div className="flex items-start gap-3"><div className="flex size-10 items-center justify-center rounded-xl bg-[#eaf1fa] text-[#205b9e]"><CloudUpload size={19}/></div><div><h2 className="text-[15px] font-bold">Importar {title}</h2><p className="mt-1 text-[13px] text-[#7d8d90]">{subtitle}</p></div></div>
    <label className="mt-6 flex min-h-40 cursor-pointer flex-col items-center justify-center rounded-2xl border border-dashed border-[#c7d5e6] bg-[#f8fbff] px-4 py-6 text-center transition hover:border-[#2b6cbb] hover:bg-[#f5f9fe]"><input className="sr-only" type="file" accept=".csv,.xlsx,.xls" onChange={(event) => void chooseFile(event)}/><div className="flex size-10 items-center justify-center rounded-[13px] bg-white text-[#245b9b] shadow-sm">{busy && !preview ? <LoaderCircle size={19} className="animate-spin"/> : <Download size={19}/>}</div><span className="mt-3 text-[13px] font-bold">Selecione um arquivo para conferir</span><span className="mt-1 text-xs text-[#697f94]">CSV, .xlsx ou .xls · até 25 MB e 100 mil linhas · confira antes de importar</span></label>
    {error && <p role="alert" className="mt-4 rounded-xl bg-[#fff3ef] px-3.5 py-3 text-xs text-[#a94b37]">{error}</p>}{message && <p role="status" className="mt-4 rounded-xl bg-[#eaf2fc] px-3.5 py-3 text-xs text-[#205b9e]">{message}</p>}
    {preview && <div className="mt-5 rounded-xl border border-[#e5ebf4] bg-white p-4"><div className="flex items-center justify-between gap-3"><div className="min-w-0"><div className="truncate text-[13px] font-bold">{preview.fileName}</div><div className="mt-1 text-xs text-[#60758b]">SHA-256 · {preview.fileHash.slice(0, 18)}…</div></div><span className="rounded-full bg-[#eaf1fa] px-2.5 py-1 text-xs font-bold text-[#205b9e]">Pronto para importar</span></div><div className="mt-4 grid grid-cols-2 gap-2 sm:grid-cols-4">{Object.entries(preview.metrics).slice(0, 4).map(([label, value]) => <div key={label} className="rounded-lg bg-[#f7faff] px-3 py-2"><div className="text-xs text-[#697f94]">{label.replace(/[A-Z]/g, (letter) => ` ${letter.toLowerCase()}`)}</div><div className="mt-1 text-sm font-bold">{fmtNumber(value)}</div></div>)}</div>{preview.warnings.length > 0 && <div className="mt-4 space-y-1.5 rounded-lg bg-[#fff9ed] p-3 text-xs leading-4 text-[#8a6532]">{preview.warnings.map((warning) => <div key={warning} className="flex gap-2"><CircleAlert size={13} className="mt-0.5 shrink-0"/>{warning}</div>)}</div>}{duplicate && <div className="mt-4 rounded-lg border border-[#f1d9ae] bg-[#fff9ed] p-3 text-[13px] leading-5 text-[#795c2f]">Este arquivo já foi importado antes. A Performance soma a importação novamente e pode duplicar corridas. Deseja continuar mesmo assim?</div>}{busy && <div className="mt-4 h-1.5 overflow-hidden rounded-full bg-[#e8eef7]"><div className="h-full rounded-full bg-[#2f6fc2] transition-all" style={{width:`${progress}%`}}/></div>}<div className="mt-4 flex flex-wrap items-center justify-end gap-2"><button onClick={() => { if (batchId) void callAdminApi("import-cancel", { batchId }).catch(() => undefined); setBatchId(""); setPreview(null); setDuplicate(false); }} disabled={busy} className="h-11 rounded-lg px-3 text-[13px] font-semibold text-[#60758b] hover:bg-[#f6f8f7]">Cancelar</button><button onClick={() => void importFile(duplicate)} disabled={busy} className="inline-flex h-11 items-center gap-2 rounded-lg bg-[#185aa9] px-4 text-[13px] font-bold text-white hover:bg-[#114886] disabled:opacity-55">{busy ? <LoaderCircle size={14} className="animate-spin"/> : <Check size={14}/>} {duplicate ? "Continuar e somar novamente" : kind === "data_crazy" ? "Substituir lista atual" : "Adicionar ao acumulado"}</button></div></div>}
  </section><div className="space-y-4"><section className="rounded-2xl border border-[#dfe6f0] bg-white p-5"><h3 className="text-[13px] font-bold">Mapeamento automático</h3><div className="mt-4 space-y-3 text-[13px] text-[#60758b]">{(kind === "data_crazy" ? [["Entregador", "B · Nome"], ["UUID", "AH · Identificador"], ["Influenciador", "AI · Indicação"], ["Região", "AN · Praça"], ["Contato", "D · Telefone · K · CPF"]] : [["UUID", "F · Identificador"], ["Entregador", "G · Nome"], ["Praça", "H · Região"], ["Corridas", "R · Pedidos aceitos e concluídos"]]).map(([a,b])=><div key={a} className="flex justify-between gap-3 border-b border-[#edf1f6] pb-2.5 last:border-0 last:pb-0"><span>{a}</span><span className="text-right font-semibold text-[#29435e]">{b}</span></div>)}</div></section><section className="rounded-2xl bg-[#eaf1fa] p-5"><div className="flex items-center gap-2 text-[13px] font-bold text-[#266a55]"><ShieldCheck size={15}/>Importação protegida</div><p className="mt-2 text-xs leading-[18px] text-[#60758b]">{kind === "data_crazy" ? "A nova lista só entra depois de validar o arquivo. A substituição é atômica: se algo falhar, a lista anterior continua intacta." : "Cada UUID é somado dentro do arquivo e depois acrescido ao histórico. Reimportações intencionais somam novamente."}</p>{lastSame && <div className="mt-3 border-t border-[#dce8f6] pt-3 text-xs text-[#60758b]">Último arquivo: <span className="font-semibold">{lastSame.file_name}</span></div>}</section></div></div>;
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

function AccountsPanel({ overview, refresh }: { overview: AdminOverview; refresh: () => Promise<void> }) {
  const [email, setEmail] = useState(""); const [influencerId, setInfluencerId] = useState(""); const [error, setError] = useState(""); const [notice, setNotice] = useState(""); const [busy, setBusy] = useState(false);
  const [issued, setIssued] = useState<{ email: string; code: string; expiresAt: string } | null>(null);
  const [revoking, setRevoking] = useState("");
  async function invite(event: FormEvent) {
    event.preventDefault(); setBusy(true); setError(""); setNotice(""); setIssued(null);
    try {
      const invitedEmail = email.trim().toLowerCase();
      const result = await callAccessApi<{ code: string; expiresAt: string } >({ action: "issue", email: invitedEmail, influencerId });
      setIssued({ email: invitedEmail, code: result.code, expiresAt: result.expiresAt });
      setNotice("Acesso preparado. Envie o código ao influenciador por um canal de confiança.");
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
  return <div className="grid gap-4 xl:grid-cols-[minmax(0,.82fr)_minmax(0,1.18fr)]">
    <section className="rounded-2xl border border-[#dfe6f0] bg-white p-5 sm:p-6">
      <div className="flex size-10 items-center justify-center rounded-xl bg-[#eaf1fa] text-[#205b9e]"><Users size={18}/></div>
      <h2 className="mt-4 text-[14px] font-bold">Liberar acesso</h2>
      <p className="mt-1 text-[13px] leading-5 text-[#63788e]">Escolha o e-mail e gere um código de uso único. A pessoa cria a senha no primeiro acesso, sem confirmação por e-mail.</p>
      <form onSubmit={invite} className="mt-5 space-y-3">
        <label className="block text-xs font-bold text-[#405b75]">E-mail do acesso<input type="email" required value={email} onChange={(event)=>setEmail(event.target.value)} className="mt-1.5 h-11 w-full rounded-lg border border-[#d4deeb] px-3 text-xs outline-none focus:border-[#2b6cbb]" placeholder="parceiro@email.com"/></label>
        <label className="block text-xs font-bold text-[#405b75]">Influenciador<select required value={influencerId} onChange={(event)=>setInfluencerId(event.target.value)} className="mt-1.5 h-11 w-full rounded-lg border border-[#d4deeb] bg-white px-3 text-xs outline-none focus:border-[#2b6cbb]"><option value="">Selecione</option>{overview.influencers.map((item)=><option key={item.id} value={item.id}>{item.name}</option>)}</select></label>
        {error&&<p className="rounded-lg bg-[#fff3ef] p-2.5 text-xs text-[#a94b37]">{error}</p>}{notice&&<p className="rounded-lg bg-[#eaf2fc] p-2.5 text-xs text-[#205b9e]">{notice}</p>}
        <button disabled={busy} className="flex h-11 items-center gap-2 rounded-lg bg-[#185aa9] px-3.5 text-[13px] font-bold text-white hover:bg-[#114886] disabled:opacity-55">{busy?<LoaderCircle size={14} className="animate-spin"/>:<Mail size={14}/>}Gerar código de acesso</button>
      </form>
      {issued && <div className="mt-5 rounded-lg border border-[#b9d3f0] bg-[#f7faff] p-4"><p className="text-sm font-semibold text-[#173b67]">Código para {issued.email}</p><p className="mt-1 text-[13px] leading-5 text-[#526981]">Mostrado apenas agora. Válido até {new Date(issued.expiresAt).toLocaleString("pt-BR")}. Envie por um canal de confiança.</p><code className="mt-3 block break-all rounded-md bg-white p-3 text-[13px] text-[#193b63]">{issued.code}</code><button type="button" onClick={() => void navigator.clipboard.writeText(issued.code).then(() => setNotice("Código copiado.")).catch(() => setError("Não foi possível copiar. Selecione o código acima."))} className="mt-3 min-h-11 rounded-lg border border-[#b9d3f0] bg-white px-4 text-sm font-semibold text-[#205b9e]">Copiar código</button></div>}
    </section>
    <section className="overflow-hidden rounded-2xl border border-[#dfe6f0] bg-white">
      <div className="border-b border-[#e6ebf2] px-5 py-5 sm:px-6"><h2 className="text-[14px] font-bold">Contas vinculadas</h2><p className="mt-1 text-[13px] text-[#63788e]">Uma conta por influenciador.</p></div>
      {overview.members.length===0?<div className="px-5 py-5 text-xs text-[#63788e]">Nenhuma conta foi ativada ainda.</div>:<div className="divide-y divide-[#e6ebf2]">{overview.members.map((member)=><div key={member.user_id} className="flex items-center gap-3 px-5 py-3.5 sm:px-6"><div className={`flex size-9 items-center justify-center rounded-[12px] ${member.role==="admin"?"bg-[#fff5df] text-[#a67520]":"bg-[#eaf1fa] text-[#245b9b]"}`}>{member.role==="admin"?<ShieldCheck size={16}/>:<Users size={16}/>}</div><div className="min-w-0 flex-1"><div className="truncate text-[13px] font-semibold">{member.email}</div><div className="mt-0.5 text-xs text-[#60758b]">{member.role==="admin"?"Administrador":member.influencer_name??"Influenciador"}</div></div><span className="rounded-full bg-[#eaf2fc] px-2.5 py-1 text-xs font-bold text-[#205b9e]">Ativo</span></div>)}</div>}
      <div className="border-t border-[#e6ebf2] px-5 py-4 sm:px-6"><div className="text-xs font-bold uppercase tracking-[.1em] text-[#63788e]">E-mails liberados · {overview.invites.length}</div>{overview.invites.length===0?<p className="mt-2 text-xs text-[#74889b]">Nenhum acesso aguardando ativação.</p>:<div className="mt-2 divide-y divide-[#e6ebf2]">{overview.invites.map((invite)=><div key={invite.id} className="flex items-center gap-3 py-2.5"><div className="min-w-0 flex-1"><div className="truncate text-xs font-semibold">{invite.email}</div><div className="mt-0.5 text-xs text-[#74889b]">{invite.influencer_name??"Influenciador"} · aguardando primeiro acesso</div></div><button onClick={()=>void revoke(invite)} disabled={revoking===invite.id} className="min-h-11 px-2 text-[13px] font-semibold text-[#9a5c45] hover:underline disabled:opacity-50">{revoking===invite.id?"Cancelando…":"Cancelar"}</button></div>)}</div>}</div>
    </section>
  </div>;
}
