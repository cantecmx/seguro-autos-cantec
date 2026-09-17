/**
 * GNP · Seguimiento operativo — Web App (Google Apps Script)
 * --------------------------------------------------------------
 * Se ejecuta DENTRO del Google Sheet privado y publica SOLO números
 * agregados (contactos, ventas, cotizaciones, pagos, tipificación).
 * NUNCA expone nombres, teléfonos ni datos personales de clientes.
 *
 * Cómo desplegar (una sola vez):
 *   1. Abre el Sheet → menú Extensiones → Apps Script.
 *   2. Borra lo que haya y pega TODO este archivo. Guarda (💾).
 *   3. Implementar → Nueva implementación → tipo "Aplicación web".
 *        - Ejecutar como:  Yo (tu cuenta)
 *        - Quién tiene acceso:  Cualquier usuario
 *      Implementar → autoriza los permisos → copia la "URL de la aplicación web".
 *   4. Pásale esa URL a Claude (o pégala en Netlify como variable
 *      de entorno SHEET_APPS_SCRIPT_URL).
 *
 * El Sheet sigue 100% privado; esta URL solo entrega el resumen numérico.
 */

var SHEET_ID = '1OLbIlOWz8WLmq9Wskge8OrEZR9OI24wJrzpmxdn1QqI';
var TAB      = 'GNP - Registros'; // nombre de la pestaña; si cambia, ajústalo aquí

function doGet(e) {
  var data = buildSeguimiento();
  return ContentService
    .createTextOutput(JSON.stringify(data))
    .setMimeType(ContentService.MimeType.JSON);
}

function norm(s) { return (s == null ? '' : String(s)).trim().toUpperCase(); }
function isSi(s) { var t = norm(s); return t.length > 0 && t.charAt(0) === 'S'; }
function pad(n)  { return (n < 10 ? '0' : '') + n; }

// Columnas (0-based): 0 fecha · 14 estatus · 15 cotización · 16 comentario
//                     17 ¿póliza? · 19 etapa · 23 ¿pagó?
function estatus(r) {
  var e = norm(r[14]);
  if (e.indexOf('VENTA') >= 0) return 'VENTA';
  if (norm(r[19]) === 'VENTA' && isSi(r[17])) return 'VENTA';   // respaldo: estatus vacío pero con póliza
  if (e.indexOf('VENCIDA') >= 0) return 'VENTA';
  if (e.indexOf('EN PROCESO') >= 0) return 'EN PROCESO';
  if (e.indexOf('NO LE INTERESA') >= 0) return 'NO LE INTERESA';
  if (e.indexOf('NO SALE EN SISTEMA') >= 0) return 'NO SALE EN SISTEMA';
  if (e === '') return '(vacio)';
  return e;
}

function motivo(r, est) {
  var c = norm(r[16]);
  if (/FALTAN DATOS|NO CONTESTA|NO SE CONTACTARON/.test(c)) return 'Faltan datos / no contesta';
  if (est === 'NO SALE EN SISTEMA' || /NO ESTA EN EL SISTEMA|NACIONALIZADO/.test(c)) return 'Vehículo no asegurable';
  if (/GNP|BBVA|OTRO SEGURO|YA CONTRATO|REALIZO LA CONTRATACION|CONTRATO SEGURO/.test(c)) return 'Contrató otro / GNP directo';
  if (/COTIZ/.test(c) && /NO CONTESTO|NO RESPON|NO HUBO|NO OBTUVIMOS|RSPUESTA|RESPUETSA/.test(c)) return 'Cotizó pero no responde';
  if (est === 'EN PROCESO') return 'En proceso (abierto)';
  return 'Otro';
}

function parseFecha(v, coment) {
  var d, m, y;
  if (Object.prototype.toString.call(v) === '[object Date]') {
    d = v.getDate(); m = v.getMonth() + 1; y = v.getFullYear();
  } else {
    var p = String(v).trim().split('/');
    if (p.length < 3) return null;
    d = parseInt(p[0], 10); m = parseInt(p[1], 10); y = parseInt(p[2], 10);
  }
  // errata conocida: 4/3/2026 con código CIANNE2608 => 4 de agosto
  if (y === 2026 && m === 3 && /CIANNE2608/.test(String(coment))) m = 8;
  if (y !== 2026 || m < 1 || m > 12 || !d) return null;
  return { key: y + '-' + pad(m), date: y + '-' + pad(m) + '-' + pad(d) };
}

function groupCount(arr, keyfn) {
  var m = {};
  arr.forEach(function (x) { var k = keyfn(x); m[k] = (m[k] || 0) + 1; });
  return Object.keys(m)
    .map(function (k) { return { label: k, count: m[k] }; })
    .sort(function (a, b) { return b.count - a.count; });
}

function buildSeguimiento() {
  var ss = SpreadsheetApp.openById(SHEET_ID);
  var sh = ss.getSheetByName(TAB) || ss.getSheets()[0];
  var v  = sh.getDataRange().getValues();

  var rows = [];
  for (var i = 1; i < v.length; i++) {   // fila 0 = encabezado
    var r = v[i];
    if (r[0] === '' || r[0] == null) continue;
    var pf = parseFecha(r[0], r[16]);
    if (!pf) continue;
    var est = estatus(r);
    rows.push({ key: pf.key, date: pf.date, est: est, cot: isSi(r[15]), pago: isSi(r[23]), mot: motivo(r, est) });
  }

  var keys = {}; rows.forEach(function (x) { keys[x.key] = 1; });
  var mk = Object.keys(keys).sort();

  var months = {};
  mk.forEach(function (k) {
    var mr    = rows.filter(function (x) { return x.key === k; });
    var venta = mr.filter(function (x) { return x.est === 'VENTA'; }).length;
    var ep    = mr.filter(function (x) { return x.est === 'EN PROCESO'; }).length;
    var nonV  = mr.filter(function (x) { return x.est !== 'VENTA'; });

    var dmap = {};
    mr.forEach(function (x) {
      if (!dmap[x.date]) dmap[x.date] = { date: x.date, contactos: 0, cotizaciones: 0, ventas: 0, pagadas: 0 };
      dmap[x.date].contactos++;
      if (x.cot)  dmap[x.date].cotizaciones++;
      if (x.est === 'VENTA') dmap[x.date].ventas++;
      if (x.pago) dmap[x.date].pagadas++;
    });
    var daily = Object.keys(dmap).sort().map(function (d) { return dmap[d]; });

    months[k] = {
      total:          mr.length,
      venta:          venta,
      polizasPagadas: mr.filter(function (x) { return x.pago; }).length,
      gestionables:   ep,
      noGestionables: (mr.length - venta - ep),
      cotizaciones:   mr.filter(function (x) { return x.cot; }).length,
      tipificacion:   groupCount(mr,   function (x) { return x.est; }),
      motivos:        groupCount(nonV, function (x) { return x.mot; }),
      daily:          daily
    };
  });

  var today = Utilities.formatDate(new Date(), 'America/Mexico_City', 'yyyy-MM-dd');
  return { updatedAt: today, months: months };
}
