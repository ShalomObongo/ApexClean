document.documentElement.classList.add("js");

const header = document.querySelector("[data-header]");
const navToggle = document.querySelector("[data-nav-toggle]");
const navLinks = document.querySelector("[data-nav-links]");
const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

const setHeaderState = () => {
  header?.classList.toggle("is-scrolled", window.scrollY > 12);
};

setHeaderState();
window.addEventListener("scroll", setHeaderState, { passive: true });

navToggle?.addEventListener("click", () => {
  const open = navToggle.getAttribute("aria-expanded") === "true";
  navToggle.setAttribute("aria-expanded", String(!open));
  navLinks?.classList.toggle("is-open", !open);
});

navLinks?.querySelectorAll("a").forEach((link) => {
  link.addEventListener("click", () => {
    navToggle?.setAttribute("aria-expanded", "false");
    navLinks.classList.remove("is-open");
  });
});

const revealElements = document.querySelectorAll(".reveal");
if ("IntersectionObserver" in window && !prefersReducedMotion.matches) {
  const observer = new IntersectionObserver(
    (entries, currentObserver) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
        currentObserver.unobserve(entry.target);
      });
    },
    { threshold: 0.12, rootMargin: "0px 0px -40px" },
  );
  revealElements.forEach((element) => observer.observe(element));
} else {
  revealElements.forEach((element) => element.classList.add("is-visible"));
}

const tourButtons = document.querySelectorAll(".tour-tab");
const tourImage = document.querySelector("[data-tour-image]");
const tourTitle = document.querySelector("#tour-title");
const tourCopy = document.querySelector("#tour-copy");
const tourLabel = document.querySelector("[data-tour-label]");

tourButtons.forEach((button) => {
  const source = button.dataset.image;
  if (source) {
    const preload = new Image();
    preload.src = source;
  }

  button.addEventListener("click", () => {
    if (button.classList.contains("is-active") || !tourImage) return;

    tourButtons.forEach((item) => {
      const active = item === button;
      item.classList.toggle("is-active", active);
      item.setAttribute("aria-pressed", String(active));
    });

    tourImage.classList.add("is-changing");
    window.setTimeout(() => {
      tourImage.src = button.dataset.image;
      tourImage.alt = `ApexClean ${button.textContent.trim()} interface`;
      if (tourTitle) tourTitle.textContent = button.dataset.title;
      if (tourCopy) tourCopy.textContent = button.dataset.copy;
      if (tourLabel) tourLabel.textContent = button.textContent.trim().replace(/^\d+\s*/, "");
      tourImage.classList.remove("is-changing");
    }, 150);
  });
});

const parallax = document.querySelector("[data-parallax]");
if (parallax && !prefersReducedMotion.matches && window.matchMedia("(pointer: fine)").matches) {
  parallax.addEventListener("pointermove", (event) => {
    const bounds = parallax.getBoundingClientRect();
    const x = (event.clientX - bounds.left) / bounds.width - 0.5;
    const y = (event.clientY - bounds.top) / bounds.height - 0.5;
    parallax.style.setProperty("--parallax-x", `${x * 10}px`);
    parallax.style.setProperty("--parallax-y", `${y * 8}px`);
  });

  parallax.addEventListener("pointerleave", () => {
    parallax.style.setProperty("--parallax-x", "0px");
    parallax.style.setProperty("--parallax-y", "0px");
  });
}

document.querySelectorAll("[data-year]").forEach((node) => {
  node.textContent = new Date().getFullYear();
});
