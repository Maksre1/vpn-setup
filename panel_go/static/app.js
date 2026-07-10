// PJAX Router for smooth SPA-like page transitions
document.addEventListener('click', function(e) {
    const link = e.target.closest('a');
    if (!link) return;
    
    const href = link.getAttribute('href');
    if (!href || href.startsWith('#') || href.startsWith('javascript:') || link.getAttribute('target') === '_blank') return;
    
    // Check if it is internal
    if (link.hostname !== window.location.hostname) return;
    
    // Skip logout
    if (href === '/logout') return;
    
    e.preventDefault();
    loadPage(href);
});

function loadPage(url) {
    showToast('Загрузка...', 'warning');
    
    fetch(url, {
        headers: { 'X-PJAX': 'true' }
    })
    .then(response => {
        if (response.redirected) {
            // Handle redirects (e.g. session timeout redirect to login)
            window.location.href = response.url;
            return;
        }
        return response.text();
    })
    .then(html => {
        if (!html) return;
        
        const parser = new DOMParser();
        const doc = parser.parseFromString(html, 'text/html');
        
        // 1. Update main content area
        const newContent = doc.querySelector('.content') || doc.body;
        const mainContent = document.querySelector('.content');
        if (mainContent && newContent) {
            mainContent.innerHTML = newContent.innerHTML;
        }
        
        // 2. Update document title
        const newTitle = doc.querySelector('#pjax-title');
        if (newTitle) {
            document.title = newTitle.textContent;
        }
        
        // 3. Update topbar title
        const newTopbar = doc.querySelector('#pjax-topbar');
        const mainTopbar = document.querySelector('.topbar-title');
        if (mainTopbar && newTopbar) {
            mainTopbar.innerHTML = newTopbar.innerHTML;
        }
        
        // 4. Update sidebar links active status
        const currentPath = new URL(url, window.location.origin).pathname;
        document.querySelectorAll('.sidebar-link').forEach(l => {
            const linkPath = new URL(l.getAttribute('href'), window.location.origin).pathname;
            if (linkPath === currentPath) {
                l.classList.add('active');
            } else {
                l.classList.remove('active');
            }
        });
        
        // 5. Update history
        history.pushState(null, '', url);
        
        // 6. Execute scripts in the loaded content
        if (mainContent) {
            const scripts = doc.querySelectorAll('script');
            scripts.forEach(oldScript => {
                const newScript = document.createElement('script');
                Array.from(oldScript.attributes).forEach(attr => newScript.setAttribute(attr.name, attr.value));
                newScript.appendChild(document.createTextNode(oldScript.innerHTML));
                mainContent.appendChild(newScript);
            });
        }
        
        showToast('Готово', 'success');
    })
    .catch(err => {
        console.error(err);
        showToast('Ошибка загрузки страницы', 'danger');
    });
}

// Handle browser back/forward buttons
window.addEventListener('popstate', function() {
    fetch(window.location.href, {
        headers: { 'X-PJAX': 'true' }
    })
    .then(r => r.text())
    .then(html => {
        const parser = new DOMParser();
        const doc = parser.parseFromString(html, 'text/html');
        const mainContent = document.querySelector('.content');
        const newContent = doc.querySelector('.content') || doc.body;
        if (mainContent && newContent) {
            mainContent.innerHTML = newContent.innerHTML;
        }
        const newTitle = doc.querySelector('#pjax-title');
        if (newTitle) document.title = newTitle.textContent;
        const newTopbar = doc.querySelector('#pjax-topbar');
        const mainTopbar = document.querySelector('.topbar-title');
        if (mainTopbar && newTopbar) mainTopbar.innerHTML = newTopbar.innerHTML;
        
        const currentPath = window.location.pathname;
        document.querySelectorAll('.sidebar-link').forEach(l => {
            const linkPath = new URL(l.getAttribute('href'), window.location.origin).pathname;
            if (linkPath === currentPath) {
                l.classList.add('active');
            } else {
                l.classList.remove('active');
            }
        });
        
        if (mainContent) {
            const scripts = doc.querySelectorAll('script');
            scripts.forEach(oldScript => {
                const newScript = document.createElement('script');
                Array.from(oldScript.attributes).forEach(attr => newScript.setAttribute(attr.name, attr.value));
                newScript.appendChild(document.createTextNode(oldScript.innerHTML));
                mainContent.appendChild(newScript);
            });
        }
    });
});

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

// Global service restart action (shared by dashboard & settings)
function restartService(displayName, serviceName) {
    if (!confirm('Вы уверены, что хотите перезапустить ' + displayName + '? Это временно прервет активные VPN-подключения.')) {
        return;
    }
    showToast('Перезапуск ' + displayName + '...', 'warning');
    
    fetch('/api/restart', {
        method: 'POST',
        headers: { 
            'Content-Type': 'application/json',
            'X-CSRFToken': document.querySelector('meta[name="csrf-token"]').getAttribute('content')
        },
        body: JSON.stringify({ service: serviceName })
    })
    .then(r => r.json())
    .then(data => {
        if (data.ok) {
            showToast(displayName + ': успешно перезапущен', 'success');
            // If we have updateServicesUI on dashboard page, refresh statuses after 2s
            if (typeof updateServicesUI === 'function') {
                setTimeout(() => {
                    fetch('/api/status')
                        .then(r => r.json())
                        .then(statuses => updateServicesUI(statuses));
                }, 2000);
            }
        } else {
            showToast(displayName + ': ' + data.msg, 'danger');
        }
    })
    .catch(() => {
        showToast('Ошибка при перезапуске ' + displayName, 'danger');
    });
}

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
