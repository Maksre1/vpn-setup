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
