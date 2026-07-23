# Portal del Paciente — Mockup modernizado

Rediseño del panel del paciente `+Life EPS/IPS` sobre el modelo antiguo de
Inspinia. Tres archivos independientes, listos para integrar a un proyecto
PHP + PostgreSQL + Bootstrap:

```
mockups/patient-dashboard/
├── index.html   Marcado semántico (Bootstrap 5.3 + Bootstrap Icons)
├── styles.css   Sistema de diseño (tokens CSS, temas claro/oscuro)
└── app.js       Interacciones vanilla (sidebar, tabs, tema, Chart.js)
```

## Ver el mockup
Abrir `index.html` en el navegador. No requiere build.

## Integrar en PHP
1. Copiar `styles.css` y `app.js` a `public/assets/patient/` (o donde sirvas
   estáticos).
2. En tu layout PHP incluir en `<head>`:
   ```html
   <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
   <link href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css" rel="stylesheet">
   <link href="/assets/patient/styles.css" rel="stylesheet">
   ```
3. Antes de `</body>`:
   ```html
   <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
   <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.3/dist/chart.umd.min.js"></script>
   <script src="/assets/patient/app.js"></script>
   ```
4. Copiar el marcado del `<body>` de `index.html` y reemplazar los valores
   estáticos por variables PHP (`<?= htmlspecialchars($patient['nombre']) ?>`, etc.).

## Personalización rápida
Todo el look & feel vive en el bloque `:root` de `styles.css`:

- `--c-primary` cambia el color de marca (verde teal de +Life).
- `--sidebar-w` / `--topbar-h` ajustan el layout.
- `[data-bs-theme="dark"]` sobrescribe para modo oscuro; el toggle del
  header alterna y persiste la preferencia en `localStorage`.

## Qué mejora respecto al diseño anterior
- Jerarquía visual clara (título de página, KPIs, contenido).
- Sidebar colapsable con rail (76 px) y drawer móvil con backdrop.
- Tarjetas con espacio, badges accesibles y sombras sutiles.
- Formulario de asignación con stepper y control segmentado.
- Próximas atenciones en tabs con contador.
- Gráfico donut con Chart.js, tema-aware.
- Modo oscuro completo.
- Accesibilidad: contraste AA, roles ARIA, foco visible, `prefers-reduced-motion`.
