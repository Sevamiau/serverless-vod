// Header background on scroll
const header = document.querySelector('.js-header');
const onScroll = () => header.classList.toggle('is-scrolled', window.scrollY > 10);
window.addEventListener('scroll', onScroll, { passive: true });
onScroll();

// Hamburger / full-screen menu
const hamburger = document.querySelector('.js-hamburger-menu');
const menu = document.querySelector('.js-header-menu-container');
const logo = document.querySelector('.js-header-logo');

function setMenu(open) {
    hamburger.classList.toggle('toggled', open);
    menu.classList.toggle('is-open', open);
    logo.classList.toggle('is-open', open);
    hamburger.setAttribute('aria-expanded', String(open));
    document.body.style.overflow = open ? 'hidden' : '';
}

hamburger.addEventListener('click', () => setMenu(!menu.classList.contains('is-open')));
document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && menu.classList.contains('is-open')) setMenu(false);
});

// Mark the current page in the menu
const currentPage = location.pathname.split('/').pop() || 'index.html';
menu.querySelectorAll('.header__menu > a').forEach((a) => {
    if (a.getAttribute('href') === currentPage) a.classList.add('is-active');
});

// FAQ accordion: close the others when one opens
document.querySelectorAll('.faqs__item').forEach((item) =>
    item.addEventListener('toggle', () => {
        if (!item.open) return;
        document.querySelectorAll('.faqs__item[open]').forEach((other) => {
            if (other !== item) other.open = false;
        });
    })
);
