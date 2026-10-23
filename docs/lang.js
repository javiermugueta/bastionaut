// Idioma: ?lang=es|en, lo último elegido, o el del navegador.
(function () {
  var stored = null;
  try { stored = localStorage.getItem("lang"); } catch (e) {}
  var param = new URLSearchParams(location.search).get("lang");
  var lang = param || stored || ((navigator.language || "en").toLowerCase().indexOf("es") === 0 ? "es" : "en");
  function apply(value) {
    document.documentElement.lang = value;
    document.querySelectorAll(".lang button").forEach(function (b) {
      b.setAttribute("aria-pressed", String(b.dataset.lang === value));
    });
    var title = document.querySelector("title[data-" + value + "]");
    if (title) document.title = title.getAttribute("data-" + value);
  }
  apply(lang === "es" ? "es" : "en");
  document.addEventListener("click", function (event) {
    var button = event.target.closest(".lang button");
    if (!button) return;
    try { localStorage.setItem("lang", button.dataset.lang); } catch (e) {}
    apply(button.dataset.lang);
  });
})();
