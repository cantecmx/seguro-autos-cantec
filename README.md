# Dashboard GNP Seguros · Auto — Reporte Directivo (Grupo Cantec)

Dashboard ejecutivo de la campaña de generación de prospectos de **Seguro de Auto GNP**
operada por Grupo Cantec en Meta Ads. Datos de Windsor.ai (cuenta 993894886753623).

## Estructura
```
.
├── index.html               # Dashboard (lee data.json y dibuja todo con Chart.js)
├── data.json                # Datos de la campaña (lo genera el script desde Windsor)
├── scripts/
│   └── update-data.ps1      # Consulta Windsor y regenera data.json
├── .github/workflows/
│   └── update-data.yml       # Auto-refresh semanal (GitHub Action)
└── img/                      # Artes (3) + logos CANTEC y Intermediario GNP
```

## Cómo funciona la actualización
- `index.html` **no tiene datos fijos**: al cargar lee `data.json`. El botón
  **"Actualizar datos"** vuelve a leer `data.json` sin recargar toda la página.
- `scripts/update-data.ps1` consulta la API REST de Windsor, calcula las métricas
  y reescribe `data.json`. Usa la variable de entorno `WINDSOR_API_KEY`.
- El **GitHub Action** (`update-data.yml`) corre el script cada lunes (y a demanda),
  hace commit de `data.json` si cambió, y Netlify redespliega solo.

### Activar el auto-refresh (una sola vez)
En GitHub → repo → **Settings → Secrets and variables → Actions → New repository secret**:
- Name: `WINDSOR_API_KEY`
- Value: *(tu API key de windsor.ai)*

Luego, en la pestaña **Actions**, puedes correr "Actualizar datos GNP (Windsor)"
manualmente con **Run workflow** para probarlo.

## Despliegue (Netlify)
Sitio estático. **Build command:** *(vacío)* · **Publish directory:** `.`
Cada `git push` redespliega. Dominio sin "GNP" (manual de marca GNP).

## Actualizar a mano (alternativa)
```powershell
$env:WINDSOR_API_KEY="..."; ./scripts/update-data.ps1   # regenera data.json
```
Luego commit + push.
