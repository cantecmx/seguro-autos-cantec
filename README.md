# Dashboard GNP Seguros · Auto — Reporte Directivo (Grupo Cantec)

Dashboard ejecutivo de la campaña de generación de prospectos de **Seguro de Auto GNP**
operada por Grupo Cantec en Meta Ads. Datos de Windsor.ai.

## Estructura
```
.
├── index.html        # El dashboard (HTML + Chart.js por CDN)
└── img/
    ├── arte-nuevo.png      # Arte ganadora (asistencia/emergencia)
    ├── arte-chocado1.png   # "¿Solo fue un lleguecito?"
    ├── arte-chocado2.png   # "Un instante cambia todo"
    ├── logo-cantec.png     # Logo CANTEC
    └── logo-gnp.jpg        # Logo Intermediario GNP
```

## Desplegar en Vercel
1. Sube este repositorio a GitHub.
2. En **vercel.com → Add New → Project**, importa el repo.
3. Framework Preset: **Other** (es un sitio estático). Root Directory: `/`.
4. Deploy. Vercel publica el `index.html` automáticamente.
5. **Dominio:** usa un nombre SIN "GNP" (p. ej. `reportes-cantec`) — el Manual de
   Marca GNP prohíbe usar "GNP" en dominios.
6. **Privacidad:** en *Settings → Deployment Protection* activa contraseña.

Cada `git push` a la rama principal vuelve a desplegar el sitio automáticamente.

## Actualizar los datos
Hoy los datos están escritos en `index.html`. Para refrescarlos desde Windsor:
- **Manual asistido:** pídele al agente "actualiza el dashboard GNP" → regenera el
  archivo con los datos más recientes y haces `git push`.
- **Automático (pendiente):** GitHub Action semanal que consulta la API de Windsor
  y actualiza el sitio solo. Requiere agregar tu `WINDSOR_API_KEY` como secret.

## Periodo del último corte
21 may – 14 jun 2026 · Cuenta Meta 993894886753623
