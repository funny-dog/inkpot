// Inkpot 官站脚本：版本信息拉取与页面动效

(function () {
  "use strict";

  // 导航栏滚动状态
  var nav = document.querySelector(".nav");
  var onScroll = function () {
    nav.classList.toggle("is-scrolled", window.scrollY > 8);
  };
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // 进场动画
  var revealTargets = document.querySelectorAll(".card, .stat, .window, .dl");
  if ("IntersectionObserver" in window && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    revealTargets.forEach(function (el) { el.classList.add("reveal"); });
    var observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.12 }
    );
    revealTargets.forEach(function (el) { observer.observe(el); });
  }

  // 拉取最新发布信息；仓库私有或接口不可用时隐藏版本占位
  function hideVersionMeta() {
    document
      .querySelectorAll(".js-version-wrap, .js-version-sep, .dl__meta")
      .forEach(function (el) { el.style.display = "none"; });
  }

  function formatSize(bytes) {
    var mb = bytes / 1024 / 1024;
    return mb >= 100 ? Math.round(mb) + " MB" : mb.toFixed(1) + " MB";
  }

  function formatDate(iso) {
    try {
      return new Intl.DateTimeFormat("zh-CN", { year: "numeric", month: "long", day: "numeric" }).format(new Date(iso));
    } catch (err) {
      return "";
    }
  }

  function applyRelease(release) {
    var version = (release.tag_name || "").replace(/^v/, "");
    document.querySelectorAll(".js-version").forEach(function (el) {
      el.textContent = version ? "v" + version : "—";
    });
    var published = release.published_at ? formatDate(release.published_at) : "";
    document.querySelectorAll(".js-published").forEach(function (el) {
      el.textContent = published || "—";
    });
    document.querySelectorAll(".js-size").forEach(function (el) {
      el.textContent = release.asset_size ? formatSize(release.asset_size) : "—";
    });
  }

  // 复制 Homebrew 安装命令
  var brewCopy = document.querySelector(".dl__copy");
  if (brewCopy) {
    var resetCopy = function () {
      setTimeout(function () {
        brewCopy.textContent = "复制";
        brewCopy.classList.remove("is-copied");
      }, 1600);
    };
    var markCopied = function () {
      brewCopy.textContent = "已复制";
      brewCopy.classList.add("is-copied");
      resetCopy();
    };
    var fallbackCopy = function () {
      var textarea = document.createElement("textarea");
      textarea.value = brewCopy.parentElement.querySelector("code").textContent;
      textarea.setAttribute("readonly", "");
      textarea.style.position = "fixed";
      textarea.style.opacity = "0";
      document.body.appendChild(textarea);
      textarea.select();
      try {
        if (document.execCommand("copy")) { markCopied(); } else { textarea.setSelectionRange(0, textarea.value.length); }
      } catch (err) {
        textarea.setSelectionRange(0, textarea.value.length);
      }
      document.body.removeChild(textarea);
    };
    brewCopy.addEventListener("click", function () {
      var command = brewCopy.parentElement.querySelector("code").textContent;
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(command).then(markCopied, fallbackCopy);
      } else {
        fallbackCopy();
      }
    });
  }

  fetch("/api/release", { headers: { Accept: "application/json" } })
    .then(function (resp) { return resp.ok ? resp.json() : null; })
    .then(function (data) { if (data && data.tag_name) applyRelease(data); else hideVersionMeta(); })
    .catch(function () { hideVersionMeta(); });
})();
