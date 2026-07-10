/* VPN Panel — Client JS */

// Sidebar toggle (mobile)
function toggleSidebar() {
    document.getElementById('sidebar').classList.toggle('open');
}

// Close sidebar on outside click (mobile)
document.addEventListener('click', (e) => {
    const sidebar = document.getElementById('sidebar');
    const toggle = document.querySelector('.sidebar-toggle');
    if (sidebar && sidebar.classList.contains('open') &&
        !sidebar.contains(e.target) && !toggle.contains(e.target)) {
        sidebar.classList.remove('open');
    }
});

// Copy to clipboard
function copyText(btn) {
    const uriBox = btn.closest('.uri-box');
    const valueEl = uriBox.querySelector('.uri-value');
    navigator.clipboard.writeText(valueEl.textContent).then(() => {
        const icon = btn.querySelector('i');
        icon.className = 'bi bi-check-lg';
        btn.style.color = 'var(--success)';
        setTimeout(() => {
            icon.className = 'bi bi-clipboard';
            btn.style.color = '';
        }, 2000);
    });
}

// Clock
function updateClock() {
    const el = document.getElementById('topbarTime');
    if (el) {
        const now = new Date();
        el.textContent = now.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
    }
}
updateClock();
setInterval(updateClock, 30000);
