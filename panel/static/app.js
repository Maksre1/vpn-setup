function copyUri(btn) {
    var row = btn.closest('.uri-row');
    var val = row.querySelector('.uri-value').textContent;
    navigator.clipboard.writeText(val).then(function() {
        var icon = btn.querySelector('i');
        icon.className = 'bi bi-check';
        btn.classList.add('copied');
        setTimeout(function() { icon.className = 'bi bi-clipboard'; btn.classList.remove('copied'); }, 1500);
    });
}

// Show floating toast notification
function showToast(message, type = 'success') {
    const oldToast = document.querySelector('.floating-toast');
    if (oldToast) oldToast.remove();

    const toast = document.createElement('div');
    toast.className = `flash flash-${type} floating-toast`;
    toast.style.position = 'fixed';
    toast.style.top = '16px';
    toast.style.right = '16px';
    toast.style.zIndex = '9999';
    toast.style.margin = '0';
    toast.style.minWidth = '260px';
    toast.style.boxShadow = '0 4px 12px rgba(0,0,0,0.5)';
    toast.style.transition = 'opacity 0.3s ease';
    toast.textContent = message;

    document.body.appendChild(toast);

    setTimeout(() => {
        toast.style.opacity = '0';
        setTimeout(() => toast.remove(), 300);
    }, 3000);
}
