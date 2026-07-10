/* VPN Panel — Client JS */

function copyLink(inputId) {
    const input = document.getElementById(inputId);
    if (!input) return;
    navigator.clipboard.writeText(input.value).then(() => {
        // Показать тост
        const toast = document.createElement('div');
        toast.className = 'position-fixed bottom-0 end-0 p-3';
        toast.style.zIndex = '9999';
        toast.innerHTML = `
            <div class="toast show" role="alert">
                <div class="toast-body bg-success text-white">
                    <i class="bi bi-check-circle"></i> Скопировано!
                </div>
            </div>`;
        document.body.appendChild(toast);
        setTimeout(() => toast.remove(), 2000);
    });
}

// CSRF для форм
document.querySelectorAll('form').forEach(form => {
    // Flask-WTF автоматически добавляет csrf_token через meta
});
