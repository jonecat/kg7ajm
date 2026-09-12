document.addEventListener('DOMContentLoaded', () => {
    // ---------------------------------------------------------------- theme
    // The initial attribute is set by the inline script in _layouts/default.html
    // (before first paint); this only mirrors it into the toggle's label and the
    // browser chrome colour, and flips it on click.
    const themeToggle = document.getElementById('theme-toggle');
    const themeColorMeta = document.getElementById('theme-color-meta');
    const THEME_COLORS = { dark: '#0B0F19', light: '#F8FAFC' };

    const syncThemeUi = (theme) => {
        if (themeColorMeta) themeColorMeta.setAttribute('content', THEME_COLORS[theme] || THEME_COLORS.dark);
        if (themeToggle) {
            themeToggle.setAttribute(
                'aria-label',
                theme === 'light' ? 'Switch to dark theme' : 'Switch to light theme'
            );
        }
    };

    const currentTheme = () =>
        document.documentElement.getAttribute('data-theme') === 'light' ? 'light' : 'dark';

    syncThemeUi(currentTheme());

    if (themeToggle) {
        themeToggle.addEventListener('click', () => {
            const next = currentTheme() === 'light' ? 'dark' : 'light';
            document.documentElement.setAttribute('data-theme', next);
            try { localStorage.setItem('theme', next); } catch (e) { /* storage blocked */ }
            syncThemeUi(next);
        });
    }

    // Follow the system only while the visitor has expressed no preference.
    if (window.matchMedia) {
        window.matchMedia('(prefers-color-scheme: light)').addEventListener('change', (e) => {
            let saved = null;
            try { saved = localStorage.getItem('theme'); } catch (err) { /* storage blocked */ }
            if (saved === 'light' || saved === 'dark') return;
            const next = e.matches ? 'light' : 'dark';
            document.documentElement.setAttribute('data-theme', next);
            syncThemeUi(next);
        });
    }

    // ---------------------------------------------------- filter and sort
    const searchInput = document.getElementById('video-search');
    const sortSelect = document.getElementById('video-sort');
    const postGrid = document.getElementById('post-grid');
    const countPill = document.getElementById('video-count');
    const emptyState = document.getElementById('video-empty');

    if (!postGrid) return;

    const cards = Array.from(postGrid.querySelectorAll('.post-card'));
    const total = cards.length;

    const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

    const updateCount = (visible) => {
        if (!countPill) return;
        countPill.textContent = visible === total
            ? plural(total, 'video')
            : `${visible} of ${plural(total, 'video')}`;
    };

    updateCount(total);

    const applyFilter = () => {
        const term = (searchInput ? searchInput.value : '').trim().toLowerCase();
        let visible = 0;

        cards.forEach((card) => {
            const title = card.getAttribute('data-title') || '';
            const matches = title.includes(term);
            card.style.display = matches ? 'flex' : 'none';
            if (matches) visible += 1;
        });

        updateCount(visible);
        if (emptyState) emptyState.hidden = visible !== 0;
    };

    if (searchInput) {
        searchInput.addEventListener('input', applyFilter);
    }

    if (sortSelect) {
        sortSelect.addEventListener('change', () => {
            const value = sortSelect.value;
            const readNum = (card, attr) => Number(card.getAttribute(attr)) || 0;

            const sorted = [...cards].sort((a, b) => {
                switch (value) {
                    case 'oldest': return readNum(a, 'data-date') - readNum(b, 'data-date');
                    case 'most-views': return readNum(b, 'data-views') - readNum(a, 'data-views');
                    case 'least-views': return readNum(a, 'data-views') - readNum(b, 'data-views');
                    case 'newest':
                    default: return readNum(b, 'data-date') - readNum(a, 'data-date');
                }
            });

            sorted.forEach((card) => postGrid.appendChild(card));
        });
    }
});
