document.addEventListener('DOMContentLoaded', () => {
    const heading = document.getElementById('main-heading');
    const button = document.getElementById('get-started');
    const badge = document.getElementById('status-badge');

    // Add a subtle magnetic effect to the CTA button
    button.addEventListener('mousemove', (e) => {
        const rect = button.getBoundingClientRect();
        const x = e.clientX - rect.left;
        const y = e.clientY - rect.top;
        
        const centerX = rect.width / 2;
        const centerY = rect.height / 2;
        
        const deltaX = (x - centerX) / 10;
        const deltaY = (y - centerY) / 10;
        
        button.style.transform = `translate(${deltaX}px, ${deltaY}px)`;
    });

    button.addEventListener('mouseleave', () => {
        button.style.transform = 'translate(0, 0)';
    });

    // Animate badge text after a delay
    setTimeout(() => {
        badge.textContent = 'Ready for Launch';
        badge.style.color = '#a855f7';
        badge.style.transition = 'all 0.5s ease';
    }, 2000);

    console.log('Project initialized. Happy coding!');
});
