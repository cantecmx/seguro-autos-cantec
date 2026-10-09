// Netlify Function: lee el Apps Script (privado) que publica SOLO los
// agregados del Google Sheet de operaciones y los devuelve al dashboard.
// El botón "Actualizar" llama esta función para traer las ventas EN VIVO.
// Requiere variable de entorno en Netlify: SHEET_APPS_SCRIPT_URL
//   (la "URL de la aplicación web" que da Apps Script al implementar).
// URL por defecto del Apps Script (solo agregados, sin PII). Se puede
// sobreescribir con la variable de entorno SHEET_APPS_SCRIPT_URL en Netlify.
const DEFAULT_URL = "https://script.google.com/macros/s/AKfycbxu3OV2rE_Gf6DMBmctcllyOkbPuCl3izKGVHaeWABOMaPjyIUTsDFBC9miJwax0Tq1/exec";

// Estatus de "en gestión" (gestionables): operaciones migró de "EN PROCESO"
// a "COTIZACION" / "PROCESO PENDIENTE" (oct-2026). Recalculamos gestionables y
// noGestionables desde la tipificación para que el KPI no dependa del nombre exacto.
function isGest(label) {
  const u = (label || "").toUpperCase();
  return u.indexOf("PROCESO") >= 0 || u.indexOf("COTIZ") >= 0;
}
function patchGestionables(data) {
  if (!data || !data.months) return data;
  for (const k of Object.keys(data.months)) {
    const m = data.months[k];
    if (Array.isArray(m.tipificacion)) {
      const g = m.tipificacion.filter(t => isGest(t.label)).reduce((s, t) => s + (t.count || 0), 0);
      m.gestionables = g;
      m.noGestionables = (m.total || 0) - (m.venta || 0) - g;
    }
  }
  return data;
}

export default async (req) => {
  const url = process.env.SHEET_APPS_SCRIPT_URL || DEFAULT_URL;
  const headers = {
    "content-type": "application/json",
    "cache-control": "no-store",
    "access-control-allow-origin": "*",
  };
  if (!url) {
    return new Response(JSON.stringify({ error: "Falta SHEET_APPS_SCRIPT_URL en Netlify" }), { status: 500, headers });
  }
  try {
    const r = await fetch(url, { redirect: "follow" });
    if (!r.ok) throw new Error("HTTP " + r.status);
    const data = await r.json();
    if (!data || !data.months) throw new Error("Respuesta sin datos");
    patchGestionables(data);
    return new Response(JSON.stringify(data), { headers });
  } catch (e) {
    return new Response(JSON.stringify({ error: String((e && e.message) || e) }), { status: 502, headers });
  }
};
