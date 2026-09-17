// Netlify Function: lee el Apps Script (privado) que publica SOLO los
// agregados del Google Sheet de operaciones y los devuelve al dashboard.
// El botón "Actualizar" llama esta función para traer las ventas EN VIVO.
// Requiere variable de entorno en Netlify: SHEET_APPS_SCRIPT_URL
//   (la "URL de la aplicación web" que da Apps Script al implementar).
// URL por defecto del Apps Script (solo agregados, sin PII). Se puede
// sobreescribir con la variable de entorno SHEET_APPS_SCRIPT_URL en Netlify.
const DEFAULT_URL = "https://script.google.com/macros/s/AKfycbxu3OV2rE_Gf6DMBmctcllyOkbPuCl3izKGVHaeWABOMaPjyIUTsDFBC9miJwax0Tq1/exec";

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
    return new Response(JSON.stringify(data), { headers });
  } catch (e) {
    return new Response(JSON.stringify({ error: String((e && e.message) || e) }), { status: 502, headers });
  }
};
