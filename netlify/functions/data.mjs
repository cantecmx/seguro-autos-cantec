// Netlify Function: consulta Windsor.ai EN VIVO y devuelve el bloque del mes pedido.
// Endpoint: /.netlify/functions/data?month=2026-07
// Requiere variable de entorno en Netlify: WINDSOR_API_KEY
const API = process.env.WINDSOR_API_KEY;
const ACCOUNT = "993894886753623";
const CAMPAIGN_FROM = "2026-05-21";
const CONVF = "actions_onsite_conversion_messaging_conversation_started_7d";
const AD_MAP = {
  "Nuevo anuncio de Clientes potenciales": "nuevo",
  "Auto Chocado 1Prueba": "chocado1",
  "Auto Chocado 2Prueba": "chocado2",
  "Anuncio Impulsado 01 Llaves": "llaves",
  "Anuncio Motos": "motos",
};
const AGES = ["18-24","25-34","35-44","45-54","55-64","65+"];
const MONTHS = [
  { key:"2026-06", label:"Junio", from:CAMPAIGN_FROM },
  { key:"2026-07", label:"Julio", from:"2026-07-01" },
  { key:"2026-08", label:"Agosto", from:"2026-08-01" },
  { key:"2026-09", label:"Septiembre", from:"2026-09-01" },
  { key:"2026-10", label:"Octubre", from:"2026-10-01" },
  { key:"2026-11", label:"Noviembre", from:"2026-11-01" },
  { key:"2026-12", label:"Diciembre", from:"2026-12-01" },
];

const N = v => (v == null ? 0 : Number(v));
const sum = (rows, f) => rows.reduce((s, r) => s + N(r[f]), 0);
const round = (v, d = 0) => { const p = Math.pow(10, d); return Math.round(v * p) / p; };

async function getW(fields, from, to) {
  const url = `https://connectors.windsor.ai/facebook?api_key=${API}&date_from=${from}&date_to=${to}&fields=${encodeURIComponent(fields)}`;
  let lastErr;
  for (let a = 0; a < 3; a++) {
    try {
      const r = await fetch(url);
      if (!r.ok) throw new Error("HTTP " + r.status);
      const j = await r.json();
      return (j.data || []).filter(x => String(x.account_id) === ACCOUNT);
    } catch (e) { lastErr = e; await new Promise(res => setTimeout(res, 2500)); }
  }
  throw lastErr;
}

function groupBy(rows, key) {
  const m = new Map();
  for (const r of rows) { const k = r[key]; if (!m.has(k)) m.set(k, []); m.get(k).push(r); }
  return m;
}

async function computeBlock(from, to) {
  const [tot, daily, ag, reg, ads] = await Promise.all([
    getW("account_id,campaign,campaign_objective,spend,impressions,reach,clicks,link_clicks,actions_lead," + CONVF, from, to),
    getW("account_id,date,spend,impressions,actions_lead", from, to),
    getW("account_id,age,gender,spend,link_clicks,actions_lead", from, to),
    getW("account_id,region,spend", from, to),
    getW("account_id,ad_name,spend,impressions,clicks,link_clicks,actions_lead," + CONVF, from, to),
  ]);

  const spend = sum(tot,"spend"), impr = sum(tot,"impressions"), reach = sum(tot,"reach");
  const clicks = sum(tot,"clicks"), lclicks = sum(tot,"link_clicks");
  const leads = sum(tot,"actions_lead"), msgs = sum(tot,CONVF);
  const days = Math.round((new Date(to) - new Date(from)) / 86400000) + 1;
  const leadRows = tot.filter(r => r.campaign_objective === "OUTCOME_LEADS");
  const convRows = tot.filter(r => r.campaign_objective !== "OUTCOME_LEADS");
  const leadSpend = sum(leadRows,"spend"), convSpend = sum(convRows,"spend");
  const convConv = Math.round(sum(convRows, CONVF));

  const kpis = {
    leads: Math.round(leads),
    cpl: leads ? round(leadSpend/leads,2) : 0,
    costPerConv: convConv ? round(convSpend/convConv,2) : null,
    leadSpend: round(leadSpend), convSpend: round(convSpend), convConversations: convConv,
    spend: round(spend), reach: Math.round(reach),
    frequency: reach ? round(impr/reach,2) : 0,
    impressions: Math.round(impr),
    cpm: impr ? round(spend/impr*1000) : 0,
    linkClicks: Math.round(lclicks),
    ctr: impr ? round(clicks/impr*100,2) : 0,
    cpc: lclicks ? round(spend/lclicks,1) : 0,
    convRate: lclicks ? round(leads/lclicks*100,1) : 0,
    conversations: Math.round(msgs),
    leadsPerDay: days ? round(leads/days,1) : 0,
    spendPerDay: days ? round(spend/days) : 0,
    days,
  };

  const dailyArr = [...groupBy(daily,"date").entries()].sort((a,b)=> a[0] < b[0] ? -1 : 1).map(([date,g]) => {
    const sp = sum(g,"spend"), im = sum(g,"impressions"), ld = Math.round(sum(g,"actions_lead"));
    return { date, spend: round(sp,2), leads: ld, cpm: im ? round(sp/im*1000) : 0, cpl: ld ? round(sp/ld,2) : null };
  });

  const male = AGES.map(a => Math.round(sum(ag.filter(r => r.age===a && r.gender==="male"), "actions_lead")));
  const female = AGES.map(a => Math.round(sum(ag.filter(r => r.age===a && r.gender==="female"), "actions_lead")));
  let segments = [];
  for (const a of AGES) {
    const g = ag.filter(r => r.age===a && r.gender==="male");
    const sl = Math.round(sum(g,"actions_lead")), ss = sum(g,"spend");
    if (sl > 0) segments.push({ label:"Hombres "+a, spend: round(ss), leads: sl, cpl: round(ss/sl,1) });
  }
  const fem = ag.filter(r => r.gender==="female"); const fl = Math.round(sum(fem,"actions_lead")), fs = sum(fem,"spend");
  if (fl > 0) segments.push({ label:"Mujeres (todas)", spend: round(fs), leads: fl, cpl: round(fs/fl,1) });
  segments.sort((a,b) => b.leads - a.leads);
  if (segments.length) { const best = [...segments].sort((a,b)=>a.cpl-b.cpl)[0].label; segments.forEach(s => s.tier = s.label===best ? "best" : ""); }

  let regG = [...groupBy(reg,"region").entries()].map(([region,g]) => ({ region, spend: round(sum(g,"spend")) })).sort((a,b)=>b.spend-a.spend);
  let regions = regG.slice(0,7);
  const rest = regG.slice(7).reduce((s,r)=>s+r.spend,0);
  if (rest > 0) regions.push({ region:"__RESTO__", spend: round(rest) });

  let artes = [...groupBy(ads,"ad_name").entries()].map(([name,g]) => {
    const sp = sum(g,"spend"), im = sum(g,"impressions"), cl = sum(g,"clicks");
    const ld = Math.round(sum(g,"actions_lead")), cv = Math.round(sum(g,CONVF));
    return {
      id: AD_MAP[name] || name.replace(/\W/g,'').toLowerCase(),
      adName: name, leads: ld, spend: round(sp),
      cpl: ld ? round(sp/ld,2) : 0,
      cpConv: cv ? round(sp/cv,2) : null,
      ctr: im ? round(cl/im*100,2) : 0,
      conversations: cv,
      pct: leads ? round(ld/leads*100) : 0,
    };
  });
  artes.sort((a,b) => (b.leads - a.leads) || (b.conversations - a.conversations));
  artes.forEach((x,i) => {
    x.rankNum = i + 1;
    if (x.leads > 0) x.tier = i===0 ? "win" : (x.leads <= 2 ? "low" : "mid");
    else x.tier = x.conversations > 0 ? "conv" : "low";
  });

  return { periodFrom: from, periodTo: to, kpis, daily: dailyArr, demo: { ages: AGES, male, female }, segments, regions, artes };
}

export default async (req) => {
  try {
    if (!API) throw new Error("Falta WINDSOR_API_KEY en Netlify");
    const now = new Date();
    const today = now.toISOString().slice(0,10);
    let key = (new URL(req.url)).searchParams.get("month") || today.slice(0,7);
    const mdef = MONTHS.find(m => m.key === key) || MONTHS[0];
    const y = +mdef.key.slice(0,4), mo = +mdef.key.slice(5,7);
    const monthEnd = new Date(Date.UTC(y, mo, 0));
    const to = now < monthEnd ? today : monthEnd.toISOString().slice(0,10);
    const data = await computeBlock(mdef.from, to);
    return new Response(JSON.stringify({ key: mdef.key, label: mdef.label, updatedAt: today, data }), {
      headers: { "content-type":"application/json", "cache-control":"no-store", "access-control-allow-origin":"*" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e && e.message || e) }), {
      status: 500, headers: { "content-type":"application/json" },
    });
  }
};
