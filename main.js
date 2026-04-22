document.addEventListener('DOMContentLoaded', () => {
    console.log('KG7AJM Blog Initialized');

    const searchInput = document.getElementById('video-search');
    const sortSelect = document.getElementById('video-sort');
    const postGrid = document.getElementById('post-grid');
    
    if (!postGrid) return;
    
    const cards = Array.from(document.querySelectorAll('.post-card'));

    // --- Search Logic ---
    if (searchInput) {
        searchInput.addEventListener('input', (e) => {
            const term = e.target.value.toLowerCase();
            cards.forEach(card => {
                const title = card.getAttribute('data-title');
                if (title.includes(term)) {
                    card.style.display = 'flex';
                } else {
                    card.style.display = 'none';
                }
            });
        });
    }

    // --- Sort Logic ---
    if (sortSelect) {
        sortSelect.addEventListener('change', (e) => {
            const val = e.target.value;
            const sortedCards = [...cards].sort((a, b) => {
                if (val === 'newest') {
                    return b.getAttribute('data-date') - a.getAttribute('data-date');
                } else if (val === 'oldest') {
                    return a.getAttribute('data-date') - b.getAttribute('data-date');
                } else if (val === 'most-views') {
                    return b.getAttribute('data-views') - a.getAttribute('data-views');
                } else if (val === 'least-views') {
                    return a.getAttribute('data-views') - b.getAttribute('data-views');
                }
                return 0;
            });

            // Re-append cards in new order
            sortedCards.forEach(card => postGrid.appendChild(card));
        });
    }

    // --- 3D Tilt Effect ---
    cards.forEach(card => {
        card.addEventListener('mousemove', (e) => {
            const rect = card.getBoundingClientRect();
            const x = e.clientX - rect.left;
            const y = e.clientY - rect.top;

            const centerX = rect.width / 2;
            const centerY = rect.height / 2;

            const rotateX = (y - centerY) / 20;
            const rotateY = (centerX - x) / 20;

            card.style.transform = `perspective(1000px) rotateX(${rotateX}deg) rotateY(${rotateY}deg) translateY(-10px)`;
        });

        card.addEventListener('mouseleave', () => {
            card.style.transform = 'perspective(1000px) rotateX(0) rotateY(0) translateY(0)';
        });
    });
});
