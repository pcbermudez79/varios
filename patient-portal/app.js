/* =============================================================
   +Life EPS/IPS · Patient Portal — vanilla JS interactions
   Pure ES2020; no build step. Safe to drop into a PHP page.
   ============================================================= */
(function () {
  'use strict';

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

  /* ---------- Sidebar toggle (mobile drawer + desktop rail) ---------- */
  const shell = $('#appShell');
  const toggle = $('#sidebarToggle');
  const backdrop = $('#sidebarBackdrop');

  const isDesktop = () => window.matchMedia('(min-width: 992px)').matches;

  toggle?.addEventListener('click', () => {
    if (isDesktop()) {
      shell.classList.toggle('is-collapsed');
      localStorage.setItem('pp:sidebar', shell.classList.contains('is-collapsed') ? 'rail' : 'open');
    } else {
      shell.classList.toggle('is-open');
    }
  });

  backdrop?.addEventListener('click', () => shell.classList.remove('is-open'));

  // Close drawer on nav click (mobile only)
  $$('.side-nav-item').forEach(a =>
    a.addEventListener('click', () => { if (!isDesktop()) shell.classList.remove('is-open'); })
  );

  // Restore sidebar preference on load (desktop)
  if (isDesktop() && localStorage.getItem('pp:sidebar') === 'rail') {
    shell.classList.add('is-collapsed');
  }

  /* ---------- Active nav item ---------- */
  $$('.side-nav-item').forEach(a => {
    a.addEventListener('click', e => {
      e.preventDefault();
      $$('.side-nav-item').forEach(i => i.classList.remove('is-active'));
      a.classList.add('is-active');
    });
  });

  /* ---------- Theme toggle (light / dark, persisted) ---------- */
  const themeBtn = $('#themeToggle');
  const html = document.documentElement;

  const setTheme = (mode) => {
    html.setAttribute('data-bs-theme', mode);
    localStorage.setItem('pp:theme', mode);
    const icon = themeBtn?.querySelector('i');
    if (icon) icon.className = mode === 'dark' ? 'bi bi-sun' : 'bi bi-moon-stars';
    updateChartTheme();
  };

  themeBtn?.addEventListener('click', () => {
    setTheme(html.getAttribute('data-bs-theme') === 'dark' ? 'light' : 'dark');
  });

  const saved = localStorage.getItem('pp:theme');
  if (saved) {
    setTheme(saved);
  } else if (window.matchMedia('(prefers-color-scheme: dark)').matches) {
    setTheme('dark');
  }

  /* ---------- Tabs (Próximas atenciones) ---------- */
  $$('.tab').forEach(tab => {
    tab.addEventListener('click', () => {
      const group = tab.closest('.card');
      const target = tab.dataset.tab;

      $$('.tab', group).forEach(t => {
        const active = t === tab;
        t.classList.toggle('is-active', active);
        t.setAttribute('aria-selected', active ? 'true' : 'false');
      });

      $$('.tab-panel', group).forEach(p => {
        p.hidden = p.dataset.panel !== target;
        p.classList.toggle('is-active', p.dataset.panel === target);
      });
    });
  });

  /* ---------- Smooth scroll for CTA ---------- */
  $$('[data-scroll-to]').forEach(btn => {
    btn.addEventListener('click', () => {
      const target = document.querySelector(btn.dataset.scrollTo);
      target?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    });
  });

  /* ---------- ⌘K / Ctrl+K focuses search ---------- */
  const searchInput = $('.topbar-search input');
  document.addEventListener('keydown', (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
      e.preventDefault();
      searchInput?.focus();
    }
    if (e.key === 'Escape' && document.activeElement === searchInput) {
      searchInput.blur();
    }
  });

  /* ---------- Chart.js donut with theme awareness ---------- */
  let attendanceChart;

  const chartColors = () => {
    const styles = getComputedStyle(document.documentElement);
    return {
      primary: styles.getPropertyValue('--c-primary').trim() || '#14b8a6',
      muted:   styles.getPropertyValue('--c-border-strong').trim() || '#d1d5db',
      surface: styles.getPropertyValue('--c-surface').trim() || '#ffffff',
      text:    styles.getPropertyValue('--c-text-2').trim() || '#475569',
    };
  };

  function renderAttendanceChart() {
    const el = $('#attendanceChart');
    if (!el || typeof Chart === 'undefined') return;
    const c = chartColors();

    attendanceChart = new Chart(el, {
      type: 'doughnut',
      data: {
        labels: ['Cumplidas', 'Incumplidas'],
        datasets: [{
          data: [27, 4],
          backgroundColor: [c.primary, c.muted],
          borderColor: c.surface,
          borderWidth: 3,
          hoverOffset: 6,
        }],
      },
      options: {
        cutout: '72%',
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: false },
          tooltip: {
            backgroundColor: '#0f172a',
            padding: 10,
            titleFont: { family: 'Inter', weight: '600' },
            bodyFont: { family: 'Inter' },
            cornerRadius: 8,
            callbacks: {
              label: (ctx) => ` ${ctx.label}: ${ctx.parsed} citas`
            }
          },
        },
      },
    });
  }

  function updateChartTheme() {
    if (!attendanceChart) return;
    const c = chartColors();
    attendanceChart.data.datasets[0].backgroundColor = [c.primary, c.muted];
    attendanceChart.data.datasets[0].borderColor = c.surface;
    attendanceChart.update('none');
  }

  renderAttendanceChart();

  /* ---------- Nice-to-have: relative time in footer ---------- */
  // Placeholder for a real sync timestamp; kept as static copy for now.

  /* ---------- Reset drawer state on resize to desktop ---------- */
  window.addEventListener('resize', () => {
    if (isDesktop()) shell.classList.remove('is-open');
  });

})();
