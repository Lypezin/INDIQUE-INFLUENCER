"use client";

import { useCallback, useEffect, useMemo, useState, useSyncExternalStore, type ChangeEvent, type FormEvent } from "react";
import type { Session } from "@supabase/supabase-js";
import {
  ArrowDownUp, ArrowRight, Award, BarChart3, Check, CheckCircle2, ChevronDown,
  CircleAlert, ClipboardList, CloudUpload, Download, Eye, EyeOff, FileSpreadsheet,
  Gift, LoaderCircle, LogOut, Mail, MapPin, Menu, Search, ShieldCheck, Sparkles,
  Users,
} from "lucide-react";
import { callAdminApi, DATA_SCHEMA, getSupabase } from "@/lib/supabase";
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
type AdminOverview = { influencers: Influencer[]; imports: ImportSummary[]; reviews: Review[]; members: Member[]; invites: PendingInvite[]; referralCount: number; contributionTotal: number };
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
        setActiveTab("dashboard");
      } else {
        const [{ data: influencerData, error: influencerError }, { data: referralData, error: referralError }] = await Promise.all([
          supabase!.schema(DATA_SCHEMA).from("influencers").select("id,name,route_goal,prize_cents").eq("id", nextProfile.influencer_id).single(),
          supabase!.schema(DATA_SCHEMA).from("referral_progress").select("referral_id,uuid,name,region,phone,cpf,routes,route_goal,prize_cents,prize_unlocked,routes_remaining,influencer_name").order("prize_unlocked", { ascending: false }).order("routes", { ascending: false }),
        ]);
        if (influencerError) throw influencerError;
        if (referralError) throw referralError;
        setInfluencer(influencerData as Influencer);
        setReferrals((referralData ?? []) as Referral[]);
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
  const title = isAdmin ? "Painel administrativo" : `Olá, ${influencer?.name ?? "influenciador"}`;
  const subtitle = isAdmin ? "Importações e acessos da campanha" : "Veja como suas indicações estão avançando";

  return (
    <main className="min-h-screen bg-[#f5f7f7] text-[#172b32]">
      <div className="mx-auto flex min-h-screen max-w-[1600px]">
        <aside className="hidden w-[250px] shrink-0 flex-col border-r border-[#e2e9e7] bg-white px-5 py-7 lg:flex">
          <Brand />
          <div className="mt-12 text-[10px] font-bold uppercase tracking-[.18em] text-[#829398]">Menu</div>
          <nav className="mt-3 space-y-1.5">
            {visibleTabs.map((tab) => <NavButton key={tab.id} tab={tab} active={activeTab === tab.id} onClick={() => setActiveTab(tab.id)} />)}
          </nav>
          <div className="mt-auto rounded-2xl bg-[#f3f8f6] p-4">
            <div className="flex size-9 items-center justify-center rounded-xl bg-white text-[#167e68]"><ShieldCheck size={18} /></div>
            <p className="mt-3 text-sm font-semibold">Acesso individual</p>
            <p className="mt-1 text-xs leading-5 text-[#63777b]">Cada conta acompanha somente seus próprios indicados.</p>
          </div>
        </aside>

        <section className="min-w-0 flex-1">
          <header className="sticky top-0 z-20 flex h-[76px] items-center justify-between border-b border-[#e2e9e7] bg-white/95 px-5 backdrop-blur-md sm:px-8 lg:px-10">
            <div className="flex items-center gap-3">
              <button onClick={() => setMobileMenu(!mobileMenu)} className="rounded-lg p-2 text-[#52696f] hover:bg-[#f1f5f4] lg:hidden" aria-label="Abrir menu"><Menu size={20} /></button>
              <div><div className="text-sm font-semibold sm:text-[15px]">{title}</div><div className="mt-0.5 hidden text-xs text-[#7a8b8e] sm:block">{subtitle}</div></div>
            </div>
            <div className="flex items-center gap-3">
              <div className="hidden text-right sm:block"><div className="text-xs font-semibold">{isAdmin ? "Administrador" : influencer?.name}</div><div className="mt-0.5 max-w-44 truncate text-[11px] text-[#87979a]">{profile.email}</div></div>
              <div className="flex size-10 items-center justify-center rounded-full bg-[#e8f3ee] text-sm font-bold text-[#167e68]">{(isAdmin ? "AD" : influencer?.name?.slice(0, 2) ?? "IG").toUpperCase()}</div>
              <button onClick={() => void supabase.auth.signOut()} className="rounded-lg p-2 text-[#728488] hover:bg-[#f1f5f4]" title="Sair"><LogOut size={18} /></button>
            </div>
          </header>

          {mobileMenu && <div className="fixed inset-x-0 top-[76px] z-30 border-b border-[#e2e9e7] bg-white px-4 py-3 shadow-lg lg:hidden">{visibleTabs.map((tab) => <NavButton key={tab.id} tab={tab} active={activeTab === tab.id} onClick={() => { setActiveTab(tab.id); setMobileMenu(false); }} />)}</div>}
          <div className="mx-auto max-w-[1320px] px-4 pb-12 pt-7 sm:px-8 sm:pt-9 lg:px-10">
            {loadError && <div className="mb-5 flex items-start gap-3 rounded-xl border border-[#f2d8bd] bg-[#fffaf4] p-4 text-sm text-[#84572f]"><CircleAlert size={18} className="mt-0.5 shrink-0" />{loadError}</div>}
            {!isAdmin ? <InfluencerDashboard referrals={referrals} influencer={influencer} search={search} setSearch={setSearch} onlyUnlocked={onlyUnlocked} setOnlyUnlocked={setOnlyUnlocked} /> : (
              <AdminDashboard activeTab={activeTab} overview={overview} refresh={refreshAdmin} onTab={setActiveTab} />
            )}
          </div>
        </section>
      </div>
    </main>
  );
}

function Brand() {
  return <div className="flex items-center gap-3"><div className="relative flex size-11 items-center justify-center rounded-[15px] bg-[#0f4f48] text-[#d9f28d]"><Gift size={21} strokeWidth={2.2} /><span className="absolute -right-1 -top-1 size-3 rounded-full border-2 border-white bg-[#f3bb56]" /></div><div><div className="text-[14px] font-extrabold tracking-[-.035em]">indique<span className="text-[#167e68]">&ganhe</span></div><div className="mt-0.5 text-[9px] font-bold uppercase tracking-[.17em] text-[#91a1a1]">entregas que valem</div></div></div>;
}

function NavButton({ tab, active, onClick }: { tab: { id: TabId; label: string; icon: typeof BarChart3 }; active: boolean; onClick: () => void }) {
  const Icon = tab.icon;
  return <button onClick={onClick} className={`flex w-full items-center gap-3 rounded-xl px-3.5 py-3 text-left text-[13px] font-semibold transition ${active ? "bg-[#edf6f2] text-[#137761]" : "text-[#65787c] hover:bg-[#f5f8f7] hover:text-[#24444a]"}`}><Icon size={17} strokeWidth={1.8} />{tab.label}{active && <span className="ml-auto size-1.5 rounded-full bg-[#27a17e]" />}</button>;
}

function Splash() {
  return <main className="grid min-h-screen place-items-center bg-[#f5f7f7]"><div className="flex items-center gap-3 rounded-2xl border border-[#e5ecea] bg-white px-5 py-4 text-sm text-[#52696f] shadow-sm"><LoaderCircle className="animate-spin text-[#167e68]" size={19} />Abrindo seu painel…</div></main>;
}

function ConfigurationNotice() {
  return <main className="grid min-h-screen place-items-center bg-[#f4f7f5] p-6"><div className="max-w-lg rounded-3xl border border-[#e2e9e6] bg-white p-8 shadow-[0_20px_70px_-40px_#234b43]"><Brand /><div className="mt-8 flex size-11 items-center justify-center rounded-2xl bg-[#fff4e2] text-[#b17922]"><CircleAlert size={20} /></div><h1 className="mt-4 text-xl font-bold">Conexão pendente</h1><p className="mt-2 text-sm leading-6 text-[#65787c]">O portal está pronto para conectar ao Supabase. Falta configurar a URL e a chave publicável do projeto antes de habilitar o login.</p></div></main>;
}

function Login({ supabase, initialError = "" }: { supabase: NonNullable<ReturnType<typeof getSupabase>>; initialError?: string }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [mode, setMode] = useState<"login" | "signup" | "reset">("login");
  const [showPassword, setShowPassword] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(initialError);
  const [notice, setNotice] = useState("");

  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true); setError(""); setNotice("");
    try {
      if (mode === "signup") {
        const { error: signupError } = await supabase.auth.signUp({
          email: email.trim(),
          password,
          options: { emailRedirectTo: window.location.origin },
        });
        if (signupError) throw signupError;
        setNotice("Cadastro iniciado. Confirme seu e-mail se o Supabase solicitar e entre para ativar seu convite.");
        setMode("login");
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

  return <main className="grid min-h-screen bg-[#f4f7f5] lg:grid-cols-[1.04fr_.96fr]">
    <section className="relative hidden min-h-screen overflow-hidden bg-[#103f3b] px-12 py-11 text-white lg:flex lg:flex-col xl:px-20">
      <div className="absolute -right-40 -top-32 size-[520px] rounded-full border border-white/[.08]" /><div className="absolute -right-14 -top-8 size-[340px] rounded-full border border-white/[.08]" /><div className="absolute -bottom-56 -left-36 size-[520px] rounded-full bg-[#1a6256]/50 blur-2xl" />
      <div className="relative z-10"><Brand /></div>
      <div className="relative z-10 my-auto max-w-xl pb-12 pt-16">
        <div className="mb-6 inline-flex items-center gap-2 rounded-full border border-[#cfe982]/20 bg-[#cfe982]/10 px-3 py-1.5 text-[11px] font-bold uppercase tracking-[.14em] text-[#d8f28f]"><Sparkles size={13} /> Sua parceria em movimento</div>
        <h1 className="max-w-lg text-[48px] font-semibold leading-[1.08] tracking-[-.055em] xl:text-[58px]">Cada indicação pode virar <span className="text-[#cfe982]">conquista.</span></h1>
        <p className="mt-6 max-w-md text-[15px] leading-7 text-[#c3d7d2]">Acompanhe seus entregadores, veja as corridas avançarem e descubra quanto falta para liberar seu prêmio.</p>
        <div className="mt-12 flex items-center gap-4"><div className="flex -space-x-2">{["J", "F", "S", "V"].map((letter, i) => <span key={letter} className={`flex size-9 items-center justify-center rounded-full border-2 border-[#103f3b] text-xs font-bold text-[#184b42] ${["bg-[#cfe982]", "bg-[#f1c874]", "bg-[#a9d6c8]", "bg-[#e6a98a]"][i]}`}>{letter}</span>)}</div><div><div className="text-xs font-semibold text-white">Acompanhe em tempo real</div><div className="mt-0.5 text-[11px] text-[#a9c4be]">Seu painel, suas indicações</div></div></div>
      </div>
      <div className="relative z-10 flex items-center justify-between border-t border-white/10 pt-5 text-[10px] text-[#9dbab4]"><span>INDIQUE E GANHE · PORTAL DO PARCEIRO</span><span>ACESSO PROTEGIDO</span></div>
    </section>
    <section className="flex min-h-screen flex-col items-center justify-center px-5 py-10 sm:px-10">
      <div className="mb-9 lg:hidden"><Brand /></div>
      <div className="w-full max-w-[410px] rounded-[26px] border border-[#e3ebe7] bg-white px-6 py-8 shadow-[0_22px_65px_-45px_#254b40] sm:px-9 sm:py-9">
        <div className="mb-7 flex size-12 items-center justify-center rounded-[16px] bg-[#eaf5ef] text-[#167e68]"><ShieldCheck size={21} /></div>
        <p className="text-[10px] font-bold uppercase tracking-[.17em] text-[#178066]">PORTAL DO INFLUENCIADOR</p>
        <h2 className="mt-2 text-[27px] font-semibold tracking-[-.04em]">{mode === "login" ? "Que bom ter você." : mode === "signup" ? "Ative seu acesso." : "Recupere seu acesso."}</h2>
        <p className="mt-2 text-[13px] leading-5 text-[#718286]">{mode === "signup" ? "Use o e-mail convidado pelo administrador." : mode === "reset" ? "Enviaremos as instruções para o seu e-mail." : "Entre para acompanhar suas indicações e prêmios."}</p>
        <form onSubmit={submit} className="mt-7 space-y-4">
          <label className="block"><span className="mb-1.5 block text-[11px] font-bold text-[#42595e]">E-mail</span><span className="relative block"><Mail size={16} className="absolute left-3.5 top-1/2 -translate-y-1/2 text-[#98a7a8]"/><input className="h-12 w-full rounded-xl border border-[#dfe8e5] bg-[#fbfcfc] pl-10 pr-3 text-[13px] outline-none transition focus:border-[#55a78d] focus:ring-4 focus:ring-[#16866c]/10" autoComplete="email" type="email" required value={email} onChange={(event) => setEmail(event.target.value)} placeholder="voce@empresa.com" /></span></label>
          {mode !== "reset" && <label className="block"><span className="mb-1.5 block text-[11px] font-bold text-[#42595e]">Senha</span><span className="relative block"><input className="h-12 w-full rounded-xl border border-[#dfe8e5] bg-[#fbfcfc] px-3 pr-11 text-[13px] outline-none transition focus:border-[#55a78d] focus:ring-4 focus:ring-[#16866c]/10" autoComplete={mode === "signup" ? "new-password" : "current-password"} type={showPassword ? "text" : "password"} minLength={6} required value={password} onChange={(event) => setPassword(event.target.value)} placeholder="Mínimo de 6 caracteres"/><button type="button" onClick={() => setShowPassword(!showPassword)} className="absolute right-3 top-1/2 -translate-y-1/2 rounded-md p-1 text-[#98a7a8] hover:text-[#40585d]" aria-label={showPassword ? "Ocultar senha" : "Mostrar senha"}>{showPassword ? <EyeOff size={17}/> : <Eye size={17}/>}</button></span></label>}
          {error && <p role="alert" className="rounded-lg bg-[#fff4f0] px-3 py-2.5 text-xs leading-5 text-[#a84a36]">{error}</p>}
          {notice && <p role="status" className="rounded-lg bg-[#edf8f1] px-3 py-2.5 text-xs leading-5 text-[#237352]">{notice}</p>}
          <button disabled={busy} className="flex h-12 w-full items-center justify-center gap-2 rounded-xl bg-[#13594d] text-[13px] font-bold text-white shadow-[0_7px_16px_-9px_#13594d] transition hover:bg-[#0d4a40] disabled:opacity-55">{busy ? <LoaderCircle size={16} className="animate-spin"/> : <>{mode === "login" ? "Entrar no painel" : mode === "signup" ? "Criar acesso" : "Enviar instruções"}<ArrowRight size={16}/></>}</button>
        </form>
        <div className="mt-5 flex flex-col items-center gap-3 text-[11px] font-semibold text-[#6c7e80] sm:flex-row sm:justify-between">
          {mode === "login" ? <><button className="hover:text-[#167e68]" onClick={() => { setMode("reset"); setError(""); setNotice(""); }}>Esqueci minha senha</button><button className="hover:text-[#167e68]" onClick={() => { setMode("signup"); setError(""); setNotice(""); }}>Primeiro acesso / convite</button></> : <button className="hover:text-[#167e68]" onClick={() => { setMode("login"); setError(""); setNotice(""); }}>Voltar para entrar</button>}
        </div>
      </div>
      <p className="mt-5 text-center text-[10px] text-[#9ba8a7]">Seus dados pessoais são visíveis somente para você e para a administração.</p>
    </section>
  </main>;
}

function AccessPending({ email, error, onSignOut }: { email: string; error: string; onSignOut: () => void }) {
  return <main className="grid min-h-screen place-items-center bg-[#f4f7f5] p-5"><div className="w-full max-w-md rounded-3xl border border-[#e2e9e6] bg-white p-7 shadow-[0_20px_70px_-40px_#234b43]"><Brand/><div className="mt-8 flex size-11 items-center justify-center rounded-2xl bg-[#fff4e2] text-[#b17922]"><CircleAlert size={20}/></div><h1 className="mt-4 text-xl font-bold">Acesso ainda não vinculado</h1><p className="mt-2 text-sm leading-6 text-[#65787c]">A conta <strong>{email}</strong> ainda não tem um convite confirmado para este portal. Peça ao administrador para liberar seu e-mail e tente novamente.</p>{error&&<p className="mt-3 rounded-lg bg-[#fff4f0] p-3 text-xs text-[#a84a36]">{error}</p>}<button onClick={onSignOut} className="mt-5 h-10 rounded-lg bg-[#165d4e] px-4 text-xs font-bold text-white hover:bg-[#0e4e42]">Sair desta conta</button></div></main>;
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
  return <main className="grid min-h-screen place-items-center bg-[#f4f7f5] p-5"><section className="w-full max-w-[410px] rounded-3xl border border-[#e2e9e6] bg-white p-7 shadow-[0_20px_70px_-40px_#234b43]"><Brand/><h1 className="mt-8 text-2xl font-bold">Criar nova senha</h1><p className="mt-2 text-sm leading-6 text-[#65787c]">Escolha uma senha para entrar no seu painel.</p>{done?<><div className="mt-5 rounded-lg bg-[#edf8f1] p-3 text-xs text-[#247352]">Senha atualizada. Você já pode entrar no portal.</div><button onClick={()=>{window.history.replaceState({},document.title,window.location.pathname);window.location.reload();}} className="mt-4 h-10 rounded-lg bg-[#165d4e] px-4 text-xs font-bold text-white">Voltar ao painel</button></>:<form onSubmit={submit} className="mt-5 space-y-3"><input required minLength={6} autoComplete="new-password" type="password" value={password} onChange={(event)=>setPassword(event.target.value)} placeholder="Nova senha" className="h-11 w-full rounded-lg border border-[#dfe8e5] px-3 text-sm outline-none focus:border-[#5ba58e]"/><input required minLength={6} autoComplete="new-password" type="password" value={confirm} onChange={(event)=>setConfirm(event.target.value)} placeholder="Confirme a nova senha" className="h-11 w-full rounded-lg border border-[#dfe8e5] px-3 text-sm outline-none focus:border-[#5ba58e]"/>{error&&<p className="rounded-lg bg-[#fff4f0] p-3 text-xs text-[#a84a36]">{error}</p>}<button disabled={busy} className="h-11 w-full rounded-lg bg-[#165d4e] text-xs font-bold text-white disabled:opacity-55">{busy?"Salvando…":"Salvar nova senha"}</button></form>}</section></main>;
}

function InfluencerDashboard({ referrals, influencer, search, setSearch, onlyUnlocked, setOnlyUnlocked }: {
  referrals: Referral[]; influencer: Influencer | null; search: string; setSearch: (value: string) => void; onlyUnlocked: boolean; setOnlyUnlocked: (value: boolean) => void;
}) {
  const totalRoutes = referrals.reduce((total, referral) => total + Number(referral.routes || 0), 0);
  const unlocked = referrals.filter((referral) => referral.prize_unlocked).length;
  const prizeTotal = referrals.filter((referral) => referral.prize_unlocked).reduce((sum, referral) => sum + referral.prize_cents, 0);
  const visible = referrals.filter((referral) => (!onlyUnlocked || referral.prize_unlocked) && `${referral.name} ${referral.region ?? ""} ${referral.uuid}`.toLocaleLowerCase("pt-BR").includes(search.toLocaleLowerCase("pt-BR")));
  return <>
    <div className="flex flex-col justify-between gap-5 sm:flex-row sm:items-end"><div><p className="text-[10px] font-bold uppercase tracking-[.17em] text-[#18816a]">ACOMPANHAMENTO DA CAMPANHA</p><h1 className="mt-2 text-[29px] font-semibold tracking-[-.045em] sm:text-[34px]">Suas indicações</h1><p className="mt-1.5 text-[13px] text-[#78898b]">Cada entregador tem uma meta de <strong className="font-semibold text-[#3b565b]">{influencer?.route_goal ?? 0} corridas</strong> para liberar {fmtMoney(influencer?.prize_cents ?? 0)}.</p></div><div className="inline-flex w-fit items-center gap-2 rounded-full border border-[#dcebe4] bg-white px-3 py-2 text-[11px] font-semibold text-[#5c7675]"><span className="size-2 rounded-full bg-[#35aa7e]"/>Dados atualizados por importação</div></div>
    <div className="mt-7 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
      <StatCard label="Entregadores indicados" value={fmtNumber(referrals.length)} icon={<Users size={17}/>} sub="com UUID válido" color="teal" />
      <StatCard label="Corridas acumuladas" value={fmtNumber(totalRoutes)} icon={<BarChart3 size={17}/>} sub="em todos os indicados" color="blue" />
      <StatCard label="Prêmios liberados" value={fmtNumber(unlocked)} icon={<Award size={17}/>} sub="um prêmio por entregador" color="gold" />
      <StatCard label="Valor liberado" value={fmtMoney(prizeTotal)} icon={<Gift size={17}/>} sub="sem controle de pagamento" color="plum" />
    </div>
    <section className="mt-8 overflow-hidden rounded-2xl border border-[#e1e9e6] bg-white shadow-[0_4px_20px_-17px_#193c34]">
      <div className="flex flex-col gap-4 border-b border-[#edf1ef] px-5 py-5 sm:flex-row sm:items-center sm:justify-between sm:px-6"><div><h2 className="text-[15px] font-bold tracking-[-.02em]">Entregadores</h2><p className="mt-1 text-[11px] text-[#819093]">O progresso soma todas as importações de Performance.</p></div><div className="flex flex-wrap gap-2"><label className="relative"><Search size={15} className="absolute left-3 top-1/2 -translate-y-1/2 text-[#9aa8a8]"/><input aria-label="Buscar entregador" value={search} onChange={(event) => setSearch(event.target.value)} className="h-9 w-full rounded-lg border border-[#e1e9e6] bg-[#fcfdfd] pl-9 pr-3 text-xs outline-none focus:border-[#5ba58e] sm:w-52" placeholder="Buscar nome ou região"/></label><button onClick={() => setOnlyUnlocked(!onlyUnlocked)} className={`h-9 rounded-lg border px-3 text-xs font-semibold ${onlyUnlocked ? "border-[#b9dfcf] bg-[#edf8f2] text-[#1b7b5e]" : "border-[#e1e9e6] text-[#667b7e] hover:bg-[#f7faf8]"}`}>{onlyUnlocked ? "Prêmios liberados" : "Todos os prêmios"}</button></div></div>
      {visible.length === 0 ? <EmptyState title={referrals.length ? "Nenhum resultado encontrado" : "Sua campanha começa em breve"} detail={referrals.length ? "Experimente mudar a busca ou o filtro." : "Quando o administrador importar a base Data Crazy, seus entregadores aparecerão aqui."} /> : <div className="divide-y divide-[#edf1ef]">{visible.map((referral) => <ReferralRow key={referral.referral_id} referral={referral}/>)}</div>}
      {visible.length > 0 && <div className="flex justify-between border-t border-[#edf1ef] bg-[#fcfdfc] px-5 py-3 text-[10px] text-[#899799] sm:px-6"><span>Exibindo {fmtNumber(visible.length)} de {fmtNumber(referrals.length)} entregadores</span><span>Privacidade protegida por acesso individual</span></div>}
    </section>
  </>;
}

function StatCard({ label, value, icon, sub, color }: { label: string; value: string; icon: React.ReactNode; sub: string; color: "teal" | "blue" | "gold" | "plum" }) {
  const colors = { teal: "bg-[#e9f5ef] text-[#167d65]", blue: "bg-[#eaf1fa] text-[#5375a1]", gold: "bg-[#fff5df] text-[#b17a20]", plum: "bg-[#f4eef9] text-[#8865a3]" };
  return <div className="rounded-2xl border border-[#e1e9e6] bg-white p-4.5 shadow-[0_5px_20px_-18px_#173f35]"><div className="flex items-start justify-between"><div className="text-[10px] font-semibold text-[#76888a]">{label}</div><div className={`flex size-8 items-center justify-center rounded-[11px] ${colors[color]}`}>{icon}</div></div><div className="mt-3 text-[25px] font-semibold tracking-[-.04em] text-[#213c41]">{value}</div><div className="mt-1 text-[10px] text-[#9aa7a7]">{sub}</div></div>;
}

function ReferralRow({ referral }: { referral: Referral }) {
  const [expanded, setExpanded] = useState(false);
  const progress = referral.route_goal > 0 ? Math.min(100, Math.round(referral.routes / referral.route_goal * 100)) : 0;
  return <div className="px-5 py-4.5 sm:px-6"><button onClick={() => setExpanded(!expanded)} className="grid w-full gap-4 text-left md:grid-cols-[minmax(180px,1.05fr)_minmax(190px,1.4fr)_145px_24px] md:items-center">
    <div className="flex min-w-0 items-center gap-3"><div className="flex size-10 shrink-0 items-center justify-center rounded-[13px] bg-[#edf4f1] text-[12px] font-bold text-[#508476]">{(referral.name || "EN").split(/\s+/).slice(0, 2).map((part) => part[0]).join("").toUpperCase()}</div><div className="min-w-0"><div className="truncate text-[13px] font-semibold text-[#314b50]">{referral.name || "Nome indisponível"}</div><div className="mt-1 flex items-center gap-1 text-[10px] text-[#879698]"><MapPin size={11}/>{referral.region || "Região não informada"}</div></div></div>
    <div><div className="mb-2 flex items-center justify-between text-[10px]"><span className="font-semibold text-[#476166]">{fmtNumber(referral.routes)} <span className="font-normal text-[#96a3a3">/ {fmtNumber(referral.route_goal)} corridas</span></span><span className={`font-bold ${referral.prize_unlocked ? "text-[#21805f]" : "text-[#829193]"}`}>{progress}%</span></div><div className="h-[7px] overflow-hidden rounded-full bg-[#edf1ef]"><div className={`h-full rounded-full transition-all ${referral.prize_unlocked ? "bg-[#42a77d]" : "bg-[#7abb9e]"}`} style={{ width: `${progress}%` }}/></div></div>
    <div className="flex items-center justify-between gap-2 md:block md:text-right">{referral.prize_unlocked ? <span className="inline-flex items-center gap-1.5 rounded-full bg-[#eaf7ef] px-2.5 py-1.5 text-[10px] font-bold text-[#247b59]"><CheckCircle2 size={12}/>Prêmio liberado</span> : <><span className="block text-[11px] font-semibold text-[#415b60]">Faltam {fmtNumber(referral.routes_remaining)}</span><span className="mt-0.5 block text-[10px] text-[#8b999a]">para {fmtMoney(referral.prize_cents)}</span></>}</div><ChevronDown size={16} className={`hidden text-[#9aaaa8] transition md:block ${expanded ? "rotate-180" : ""}`} />
  </button>{expanded && <div className="mt-4 grid gap-3 rounded-xl bg-[#f8faf9] p-3.5 text-[11px] sm:grid-cols-3"><Detail label="Telefone" value={referral.phone || "Indisponível"}/><Detail label="CPF" value={referral.cpf ? `${referral.cpf.slice(0, 3)}.${referral.cpf.slice(3, 6)}.${referral.cpf.slice(6, 9)}-${referral.cpf.slice(9)}` : "Não informado"}/><Detail label="UUID" value={referral.uuid}/></div>}</div>;
}

function Detail({ label, value }: { label: string; value: string }) { return <div><div className="text-[9px] font-bold uppercase tracking-[.08em] text-[#98a5a4]">{label}</div><div className="mt-1 break-all font-medium text-[#52686a]">{value}</div></div>; }

function EmptyState({ title, detail }: { title: string; detail: string }) { return <div className="grid min-h-56 place-items-center px-5 py-10 text-center"><div className="max-w-sm"><div className="mx-auto flex size-11 items-center justify-center rounded-[14px] bg-[#edf6f1] text-[#45856f]"><Users size={19}/></div><h3 className="mt-4 text-[14px] font-bold">{title}</h3><p className="mt-1.5 text-xs leading-5 text-[#859395]">{detail}</p></div></div>; }

function AdminDashboard({ activeTab, overview, refresh, onTab }: { activeTab: TabId; overview: AdminOverview | null; refresh: () => Promise<void>; onTab: (tab: TabId) => void }) {
  if (!overview) return <div className="grid min-h-64 place-items-center text-sm text-[#728488]"><LoaderCircle className="mr-2 animate-spin" size={18}/>Carregando área administrativa…</div>;
  return <div>
    <div className="mb-7 flex flex-col justify-between gap-4 sm:flex-row sm:items-end"><div><p className="text-[10px] font-bold uppercase tracking-[.17em] text-[#18816a]">GESTÃO DA CAMPANHA</p><h1 className="mt-2 text-[29px] font-semibold tracking-[-.045em] sm:text-[34px]">{adminTabs.find((tab) => tab.id === activeTab)?.label}</h1><p className="mt-1.5 text-[13px] text-[#78898b]">Controle as bases, atribuições e contas dos parceiros.</p></div><button onClick={() => void refresh()} className="h-9 w-fit rounded-lg border border-[#dfe8e5] bg-white px-3.5 text-[11px] font-semibold text-[#536d70] hover:bg-[#f8faf9]">Atualizar dados</button></div>
    {activeTab === "dashboard" && <AdminHome overview={overview} onTab={onTab}/>}
    {activeTab === "data-crazy" && <ImportPanel kind="data_crazy" title="Data Crazy" subtitle="Substitui a lista atual de indicados em uma operação atômica." overview={overview} refresh={refresh}/>}
    {activeTab === "performance" && <ImportPanel kind="performance" title="Performance" subtitle="Adiciona as corridas desta importação ao acumulado existente." overview={overview} refresh={refresh}/>}
    {activeTab === "reviews" && <ReviewsPanel overview={overview} refresh={refresh}/>}
    {activeTab === "accounts" && <AccountsPanel overview={overview} refresh={refresh}/>}
  </div>;
}

function AdminHome({ overview, onTab }: { overview: AdminOverview; onTab: (tab: TabId) => void }) {
  const latest = overview.imports[0];
  return <><div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4"><StatCard label="Entregadores ativos" value={fmtNumber(overview.referralCount)} icon={<Users size={17}/>} sub="na lista atual do Data Crazy" color="teal"/><StatCard label="Corridas acumuladas" value={fmtNumber(overview.contributionTotal)} icon={<BarChart3 size={17}/>} sub="soma do histórico importado" color="blue"/><StatCard label="Atribuições em revisão" value={fmtNumber(overview.reviews.length)} icon={<ClipboardList size={17}/>} sub="UUIDs aguardando responsável" color="gold"/><StatCard label="Contas vinculadas" value={fmtNumber(overview.members.length)} icon={<ShieldCheck size={17}/>} sub="administração e influenciadores" color="plum"/></div>
    <div className="mt-7 grid gap-4 xl:grid-cols-[1.15fr_.85fr]"><section className="rounded-2xl border border-[#e1e9e6] bg-white p-5 sm:p-6"><div className="flex items-start justify-between"><div><h2 className="text-[15px] font-bold">Próximas ações</h2><p className="mt-1 text-[11px] text-[#829193]">Mantenha os dados da campanha atualizados.</p></div><Sparkles size={17} className="text-[#c58e35]"/></div><div className="mt-5 grid gap-3 sm:grid-cols-2"><ActionCard icon={<CloudUpload size={17}/>} title="Atualizar indicados" text="Troque a lista atual com o novo arquivo Data Crazy." onClick={() => onTab("data-crazy")}/><ActionCard icon={<ArrowDownUp size={17}/>} title="Somar performance" text="Acrescente novas corridas ao acumulado da campanha." onClick={() => onTab("performance")}/><ActionCard icon={<ClipboardList size={17}/>} title={`Revisar atribuições · ${overview.reviews.length}`} text="Resolva UUIDs sem um influenciador reconhecido." onClick={() => onTab("reviews")}/><ActionCard icon={<Users size={17}/>} title="Gerenciar acessos" text="Convide cada parceiro para sua própria conta." onClick={() => onTab("accounts")}/></div></section>
      <section className="rounded-2xl border border-[#e1e9e6] bg-white p-5 sm:p-6"><div className="flex items-start justify-between"><div><h2 className="text-[15px] font-bold">Última importação</h2><p className="mt-1 text-[11px] text-[#829193]">Registro de processamento</p></div><FileSpreadsheet size={18} className="text-[#6b8f83]"/></div>{latest ? <><div className="mt-6 inline-flex items-center gap-1.5 rounded-full bg-[#eaf7ef] px-2.5 py-1 text-[10px] font-bold text-[#277957]"><Check size={12}/>{latest.status === "completed" ? "Concluída" : latest.status}</div><div className="mt-3 truncate text-sm font-semibold text-[#385359]">{latest.file_name}</div><div className="mt-1 text-[11px] text-[#899799]">{latest.kind === "data_crazy" ? "Data Crazy" : "Performance"} · {new Date(latest.created_at).toLocaleString("pt-BR")}</div><div className="mt-4 border-t border-[#edf1ef] pt-3 text-[10px] text-[#829193]">{fmtNumber(latest.metrics?.total ?? 0)} registros na última carga</div></> : <p className="mt-7 rounded-xl bg-[#f7faf8] px-4 py-5 text-xs leading-5 text-[#829193]">Ainda não há importações. Os arquivos de exemplo foram usados apenas para validar o leitor; nenhum dado foi carregado.</p>}</section></div>
    <section className="mt-4 rounded-2xl border border-[#e1e9e6] bg-white p-5 sm:p-6"><div className="flex items-center justify-between"><div><h2 className="text-[15px] font-bold">Regras de premiação</h2><p className="mt-1 text-[11px] text-[#829193]">Um prêmio por entregador ao alcançar a meta.</p></div><Gift size={18} className="text-[#b3822e]"/></div><div className="mt-4 grid gap-2 sm:grid-cols-2 xl:grid-cols-3">{overview.influencers.map((item) => <div key={item.id} className="flex items-center justify-between rounded-xl bg-[#f8faf9] px-3.5 py-3"><span className="text-xs font-semibold">{item.name}</span><span className="text-[10px] font-semibold text-[#738588]">{item.route_goal} corridas <span className="mx-1 text-[#c0c9c7">·</span><strong className="text-[#287b5f]">{fmtMoney(item.prize_cents)}</strong></span></div>)}</div></section>
  </>;
}

function ActionCard({ icon, title, text, onClick }: { icon: React.ReactNode; title: string; text: string; onClick: () => void }) { return <button onClick={onClick} className="group flex gap-3 rounded-xl border border-[#e8eeeb] p-3.5 text-left transition hover:border-[#b8dbcc] hover:bg-[#f7fbf8]"><div className="flex size-9 shrink-0 items-center justify-center rounded-[11px] bg-[#edf6f1] text-[#287d62]">{icon}</div><div><div className="text-[11px] font-bold text-[#3e595d]">{title}</div><div className="mt-1 text-[10px] leading-[17px] text-[#829193]">{text}</div></div><ArrowRight size={14} className="ml-auto mt-1 shrink-0 text-[#a6b2b0] transition group-hover:translate-x-0.5 group-hover:text-[#287d62]"/></button>; }

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
      const chunkSize = 300;
      for (let offset = 0; offset < rows.length; offset += chunkSize) {
        await callAdminApi("import-chunk", {
          batchId: activeBatchId,
          rows: rows.slice(offset, offset + chunkSize),
        });
        setProgress(Math.round(Math.min(rows.length, offset + chunkSize) / rows.length * 100));
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

  return <div className="grid gap-4 xl:grid-cols-[minmax(0,1.25fr)_minmax(280px,.75fr)]"><section className="rounded-2xl border border-[#e1e9e6] bg-white p-5 sm:p-6"><div className="flex items-start gap-3"><div className="flex size-10 items-center justify-center rounded-xl bg-[#edf6f1] text-[#267c62]"><CloudUpload size={19}/></div><div><h2 className="text-[15px] font-bold">Importar {title}</h2><p className="mt-1 text-[11px] text-[#7d8d90]">{subtitle}</p></div></div>
    <label className="mt-6 flex min-h-40 cursor-pointer flex-col items-center justify-center rounded-2xl border border-dashed border-[#cddbd5] bg-[#f9fbfa] px-4 py-6 text-center transition hover:border-[#65ad91] hover:bg-[#f5faf7]"><input className="sr-only" type="file" accept=".csv,.xlsx,.xls" onChange={(event) => void chooseFile(event)}/><div className="flex size-10 items-center justify-center rounded-[13px] bg-white text-[#397d68] shadow-sm">{busy && !preview ? <LoaderCircle size={19} className="animate-spin"/> : <Download size={19}/>}</div><span className="mt-3 text-[12px] font-bold">Selecione um arquivo para conferir</span><span className="mt-1 text-[10px] text-[#8b999a]">CSV, Excel .xlsx ou Excel .xls · os dados só serão gravados após confirmar</span></label>
    {error && <p role="alert" className="mt-4 rounded-xl bg-[#fff3ef] px-3.5 py-3 text-xs text-[#a94b37]">{error}</p>}{message && <p role="status" className="mt-4 rounded-xl bg-[#edf8f1] px-3.5 py-3 text-xs text-[#247352]">{message}</p>}
    {preview && <div className="mt-5 rounded-xl border border-[#e5ece8] bg-white p-4"><div className="flex items-center justify-between gap-3"><div className="min-w-0"><div className="truncate text-[12px] font-bold">{preview.fileName}</div><div className="mt-1 text-[10px] text-[#899698]">SHA-256 · {preview.fileHash.slice(0, 18)}…</div></div><span className="rounded-full bg-[#edf6f1] px-2.5 py-1 text-[10px] font-bold text-[#25775e]">Pronto para importar</span></div><div className="mt-4 grid grid-cols-2 gap-2 sm:grid-cols-4">{Object.entries(preview.metrics).slice(0, 4).map(([label, value]) => <div key={label} className="rounded-lg bg-[#f7faf8] px-3 py-2"><div className="text-[9px] text-[#8b999a]">{label.replace(/[A-Z]/g, (letter) => ` ${letter.toLowerCase()}`)}</div><div className="mt-1 text-sm font-bold">{fmtNumber(value)}</div></div>)}</div>{preview.warnings.length > 0 && <div className="mt-4 space-y-1.5 rounded-lg bg-[#fff9ed] p-3 text-[10px] leading-4 text-[#8a6532]">{preview.warnings.map((warning) => <div key={warning} className="flex gap-2"><CircleAlert size={13} className="mt-0.5 shrink-0"/>{warning}</div>)}</div>}{duplicate && <div className="mt-4 rounded-lg border border-[#f1d9ae] bg-[#fff9ed] p-3 text-[11px] leading-5 text-[#795c2f]">Este arquivo já foi importado antes. A Performance soma a importação novamente e pode duplicar corridas. Deseja continuar mesmo assim?</div>}{busy && <div className="mt-4 h-1.5 overflow-hidden rounded-full bg-[#eaf0ed]"><div className="h-full rounded-full bg-[#44a681] transition-all" style={{width:`${progress}%`}}/></div>}<div className="mt-4 flex flex-wrap items-center justify-end gap-2"><button onClick={() => { if (batchId) void callAdminApi("import-cancel", { batchId }).catch(() => undefined); setBatchId(""); setPreview(null); setDuplicate(false); }} disabled={busy} className="h-9 rounded-lg px-3 text-[11px] font-semibold text-[#738588] hover:bg-[#f6f8f7]">Cancelar</button><button onClick={() => void importFile(duplicate)} disabled={busy} className="inline-flex h-9 items-center gap-2 rounded-lg bg-[#165d4e] px-4 text-[11px] font-bold text-white hover:bg-[#0e4e42] disabled:opacity-55">{busy ? <LoaderCircle size={14} className="animate-spin"/> : <Check size={14}/>} {duplicate ? "Continuar e somar novamente" : kind === "data_crazy" ? "Substituir lista atual" : "Adicionar ao acumulado"}</button></div></div>}
  </section><div className="space-y-4"><section className="rounded-2xl border border-[#e1e9e6] bg-white p-5"><h3 className="text-[12px] font-bold">Mapeamento automático</h3><div className="mt-4 space-y-3 text-[11px] text-[#607578]">{(kind === "data_crazy" ? [["Entregador", "B · Nome"], ["UUID", "AH · Identificador"], ["Influenciador", "AI · Indicação"], ["Região", "AN · Praça"], ["Contato", "D · Telefone · K · CPF"]] : [["UUID", "F · Identificador"], ["Entregador", "G · Nome"], ["Praça", "H · Região"], ["Corridas", "R · Pedidos aceitos e concluídos"]]).map(([a,b])=><div key={a} className="flex justify-between gap-3 border-b border-[#eff3f1] pb-2.5 last:border-0 last:pb-0"><span>{a}</span><span className="text-right font-semibold text-[#455f63]">{b}</span></div>)}</div></section><section className="rounded-2xl bg-[#edf5f1] p-5"><div className="flex items-center gap-2 text-[11px] font-bold text-[#266a55]"><ShieldCheck size={15}/>Importação protegida</div><p className="mt-2 text-[10px] leading-[18px] text-[#6e8780]">{kind === "data_crazy" ? "A nova lista só entra depois de validar o arquivo. A substituição é atômica: se algo falhar, a lista anterior continua intacta." : "Cada UUID é somado dentro do arquivo e depois acrescido ao histórico. Reimportações intencionais somam novamente."}</p>{lastSame && <div className="mt-3 border-t border-[#dce9e2] pt-3 text-[9px] text-[#779088]">Último arquivo: <span className="font-semibold">{lastSame.file_name}</span></div>}</section></div></div>;
}

function ReviewsPanel({ overview, refresh }: { overview: AdminOverview; refresh: () => Promise<void> }) {
  const [error, setError] = useState(""); const [busyId, setBusyId] = useState("");
  async function assign(review: Review, influencerId: string) {
    if (!influencerId) return;
    setBusyId(review.id); setError("");
    try { await callAdminApi("review-assign", { reviewId: review.id, influencerId }); await refresh(); }
    catch (cause) { setError(cause instanceof Error ? cause.message : "A atribuição não foi atualizada."); }
    finally { setBusyId(""); }
  }
  return <section className="overflow-hidden rounded-2xl border border-[#e1e9e6] bg-white"><div className="border-b border-[#edf1ef] px-5 py-5 sm:px-6"><h2 className="text-[14px] font-bold">Atribuições que precisam de revisão</h2><p className="mt-1 text-[11px] text-[#829193]">UUIDs mantidos na lista atual até que você escolha o influenciador.</p></div>{error && <p className="m-5 rounded-lg bg-[#fff3ef] p-3 text-xs text-[#a94b37]">{error}</p>}{overview.reviews.length === 0 ? <EmptyState title="Tudo revisado" detail="Não há atribuições pendentes neste momento."/> : <div className="divide-y divide-[#edf1ef]">{overview.reviews.map((review) => <div key={review.id} className="grid gap-3 px-5 py-4 sm:grid-cols-[1fr_1fr_auto] sm:items-center sm:px-6"><div><div className="text-xs font-semibold">{review.name || "Nome não informado"}</div><div className="mt-1 break-all text-[10px] text-[#859395]">UUID · {review.uuid}</div>{review.region && <div className="mt-1 text-[10px] text-[#829193]">{review.region}</div>}</div><div className="rounded-lg bg-[#fff9ed] px-3 py-2 text-[10px] text-[#886536]">Valor recebido: <strong>{review.raw_influencer || "vazio"}</strong></div><select aria-label="Atribuir influenciador" defaultValue="" onChange={(event) => void assign(review, event.target.value)} disabled={busyId === review.id} className="h-9 rounded-lg border border-[#dfe8e5] bg-white px-2.5 text-[11px] font-semibold text-[#425d60]"><option value="" disabled>Selecionar influenciador</option>{overview.influencers.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></div>)}</div>}</section>;
}

function AccountsPanel({ overview, refresh }: { overview: AdminOverview; refresh: () => Promise<void> }) {
  const [email, setEmail] = useState(""); const [influencerId, setInfluencerId] = useState(""); const [error, setError] = useState(""); const [notice, setNotice] = useState(""); const [busy, setBusy] = useState(false);
  const [revoking, setRevoking] = useState("");
  async function invite(event: FormEvent) {
    event.preventDefault(); setBusy(true); setError(""); setNotice("");
    try { await callAdminApi("invite-account", { email: email.trim().toLowerCase(), influencerId }); setNotice("E-mail liberado. Avise o parceiro para escolher “Primeiro acesso / convite” na tela de login e confirmar o endereço."); setEmail(""); await refresh(); }
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
    <section className="rounded-2xl border border-[#e1e9e6] bg-white p-5 sm:p-6">
      <div className="flex size-10 items-center justify-center rounded-xl bg-[#edf6f1] text-[#267c62]"><Users size={18}/></div>
      <h2 className="mt-4 text-[14px] font-bold">Liberar acesso</h2>
      <p className="mt-1 text-[11px] leading-5 text-[#829193]">Vincule um e-mail a um único influenciador. O portal não envia e-mail automático.</p>
      <form onSubmit={invite} className="mt-5 space-y-3">
        <label className="block text-[10px] font-bold text-[#566d70]">E-mail do acesso<input type="email" required value={email} onChange={(event)=>setEmail(event.target.value)} className="mt-1.5 h-10 w-full rounded-lg border border-[#dfe8e5] px-3 text-xs outline-none focus:border-[#5ba58e]" placeholder="parceiro@email.com"/></label>
        <label className="block text-[10px] font-bold text-[#566d70]">Influenciador<select required value={influencerId} onChange={(event)=>setInfluencerId(event.target.value)} className="mt-1.5 h-10 w-full rounded-lg border border-[#dfe8e5] bg-white px-3 text-xs outline-none focus:border-[#5ba58e]"><option value="">Selecione</option>{overview.influencers.map((item)=><option key={item.id} value={item.id}>{item.name}</option>)}</select></label>
        {error&&<p className="rounded-lg bg-[#fff3ef] p-2.5 text-[10px] text-[#a94b37]">{error}</p>}{notice&&<p className="rounded-lg bg-[#edf8f1] p-2.5 text-[10px] text-[#247352]">{notice}</p>}
        <button disabled={busy} className="flex h-10 items-center gap-2 rounded-lg bg-[#165d4e] px-3.5 text-[11px] font-bold text-white hover:bg-[#0e4e42] disabled:opacity-55">{busy?<LoaderCircle size={14} className="animate-spin"/>:<Mail size={14}/>}Liberar e-mail</button>
      </form>
    </section>
    <section className="overflow-hidden rounded-2xl border border-[#e1e9e6] bg-white">
      <div className="border-b border-[#edf1ef] px-5 py-5 sm:px-6"><h2 className="text-[14px] font-bold">Contas vinculadas</h2><p className="mt-1 text-[11px] text-[#829193]">Uma conta por influenciador.</p></div>
      {overview.members.length===0?<div className="px-5 py-5 text-xs text-[#829193]">Nenhuma conta foi ativada ainda.</div>:<div className="divide-y divide-[#edf1ef]">{overview.members.map((member)=><div key={member.user_id} className="flex items-center gap-3 px-5 py-3.5 sm:px-6"><div className={`flex size-9 items-center justify-center rounded-[12px] ${member.role==="admin"?"bg-[#fff5df] text-[#a67520]":"bg-[#edf5f1] text-[#397b65]"}`}>{member.role==="admin"?<ShieldCheck size={16}/>:<Users size={16}/>}</div><div className="min-w-0 flex-1"><div className="truncate text-[11px] font-semibold">{member.email}</div><div className="mt-0.5 text-[10px] text-[#879698]">{member.role==="admin"?"Administrador":member.influencer_name??"Influenciador"}</div></div><span className="rounded-full bg-[#edf8f1] px-2.5 py-1 text-[9px] font-bold text-[#247352]">Ativo</span></div>)}</div>}
      <div className="border-t border-[#edf1ef] px-5 py-4 sm:px-6"><div className="text-[10px] font-bold uppercase tracking-[.1em] text-[#829193]">E-mails liberados · {overview.invites.length}</div>{overview.invites.length===0?<p className="mt-2 text-[10px] text-[#9aa6a6]">Nenhum acesso aguardando ativação.</p>:<div className="mt-2 divide-y divide-[#edf1ef]">{overview.invites.map((invite)=><div key={invite.id} className="flex items-center gap-3 py-2.5"><div className="min-w-0 flex-1"><div className="truncate text-[10px] font-semibold">{invite.email}</div><div className="mt-0.5 text-[9px] text-[#8a999a]">{invite.influencer_name??"Influenciador"} · aguardando primeiro acesso</div></div><button onClick={()=>void revoke(invite)} disabled={revoking===invite.id} className="text-[9px] font-semibold text-[#9a5c45] hover:underline disabled:opacity-50">{revoking===invite.id?"Cancelando…":"Cancelar"}</button></div>)}</div>}</div>
    </section>
  </div>;
}
