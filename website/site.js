/* Neyam Vaani — scroll reveal.
   Adds .reveal to page sections and reveals them as they enter the
   viewport. Without this script (or with reduced motion) nothing is
   ever hidden — the styles only apply to elements this file touches. */
(function () {
  "use strict";

  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  if (!("IntersectionObserver" in window)) return;

  var sections = document.querySelectorAll("main > section");
  if (!sections.length) return;

  var io = new IntersectionObserver(
    function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("revealed");
          io.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.08, rootMargin: "0px 0px -6% 0px" }
  );

  sections.forEach(function (section) {
    /* The intro owns its own entrance animation. */
    if (section.classList.contains("intro")) return;
    /* Anything already on screen reveals immediately on load. */
    var seen = section.getBoundingClientRect().top < window.innerHeight;
    if (seen) return;
    section.classList.add("reveal");
    io.observe(section);
  });
})();
