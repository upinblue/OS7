/* Applies a stored theme choice before first paint. Loaded synchronously in the
   <head> of every page; kept in a file rather than inline so that the Content
   Security Policy can forbid inline script outright. */
try {
	var t = localStorage.getItem('os7-theme');
	if (t === 'dark' || t === 'light') document.documentElement.setAttribute('data-theme', t);
} catch (e) { /* storage disabled — the system preference still applies */ }
