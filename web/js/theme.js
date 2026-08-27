/* Theme toggle. The <head> of every page carries a three-line inline version of
   the first half of this, so the stored choice is applied before first paint;
   this file only wires the button up. No storage is written unless the visitor
   actually clicks it. */
(function () {
	var btn = document.querySelector('.theme-toggle');
	if (!btn) return;

	// Dark is the design, not a preference: with no attribute set the page IS
	// dark, whatever the system asks for. The switch is an override, and the
	// only thing that ever writes storage.
	function current() {
		return document.documentElement.getAttribute('data-theme') === 'light' ? 'light' : 'dark';
	}

	function label() {
		btn.setAttribute('aria-label',
			current() === 'dark' ? 'Switch to the light theme' : 'Switch to the dark theme');
	}

	btn.addEventListener('click', function () {
		var next = current() === 'dark' ? 'light' : 'dark';
		document.documentElement.setAttribute('data-theme', next);
		try { localStorage.setItem('os7-theme', next); } catch (e) { /* private mode */ }
		label();
	});

	label();
})();
