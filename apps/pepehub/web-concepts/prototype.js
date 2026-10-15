(() => {
  const tabs = [...document.querySelectorAll('.concept-tab')];
  const screens = [...document.querySelectorAll('.concept-screen')];

  function activateConcept(name, focus = false) {
    tabs.forEach((tab) => {
      const active = tab.dataset.concept === name;
      tab.classList.toggle('is-active', active);
      tab.setAttribute('aria-selected', String(active));
      tab.tabIndex = active ? 0 : -1;
      if (active && focus) tab.focus();
    });
    screens.forEach((screen) => {
      const active = screen.id === `concept-${name}`;
      screen.classList.toggle('is-visible', active);
      screen.hidden = !active;
    });
    document.body.dataset.concept = name;
  }

  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => activateConcept(tab.dataset.concept));
    tab.addEventListener('keydown', (event) => {
      if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
      event.preventDefault();
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : (index + (event.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length;
      activateConcept(tabs[next].dataset.concept, true);
    });
  });

  activateConcept('library');

  const toast = (message) => {
    document.querySelector('.prototype-toast')?.remove();
    const node = document.createElement('div');
    node.className = 'prototype-toast';
    node.setAttribute('role', 'status');
    node.textContent = message;
    document.body.append(node);
    window.setTimeout(() => node.remove(), 2600);
  };
  document.querySelector('.flow-yellow-button')?.addEventListener('click', () => toast('Новая запись — следующий шаг концепта.'));
})();
