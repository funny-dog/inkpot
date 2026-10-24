// Inkpot 官站脚本：中英文切换、版本信息拉取与页面动效

(function () {
  "use strict";

  // 导航栏滚动状态
  var nav = document.querySelector(".nav");
  var onScroll = function () {
    nav.classList.toggle("is-scrolled", window.scrollY > 8);
  };
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // 中英文切换：默认中文，可翻译元素用 data-en 携带英文文案，aria-label 用 data-en-label
  var languageButton = document.querySelector("#language");
  var locale = "zh-CN";
  var translatedElements = Array.prototype.map.call(document.querySelectorAll("[data-en]"), function (element) {
    return { element: element, chinese: element.innerHTML, english: element.getAttribute("data-en") };
  });
  var translatedLabels = Array.prototype.map.call(document.querySelectorAll("[data-en-label]"), function (element) {
    return { element: element, chinese: element.getAttribute("aria-label"), english: element.getAttribute("data-en-label") };
  });
  var i18nMeta = {
    "zh-CN": {
      title: "Inkpot · 为 macOS 打造的轻量 Markdown 编辑器",
      description: "Inkpot 是一款轻盈的 macOS Markdown 编辑器：实时预览、文件树与全文搜索、公式与图表、专注与打字机模式，一切开箱即用。开源免费，基于 MarkEdit。",
      ogTitle: "Inkpot · 让写作回到写作本身",
      ogDescription: "轻盈的 macOS Markdown 编辑器：实时预览、文件树、公式图表、专注模式，开箱即用。开源免费。"
    },
    en: {
      title: "Inkpot · A lightweight Markdown editor for macOS",
      description: "Inkpot is a featherlight Markdown editor for macOS: live preview, file tree and full-text search, math and diagrams, focus and typewriter modes — everything out of the box. Free and open source, built on MarkEdit.",
      ogTitle: "Inkpot · Writing, back to itself",
      ogDescription: "Featherlight macOS Markdown editor: live preview, file tree, math & diagrams, focus mode — out of the box. Free and open source."
    }
  };

  function applyLocale(next) {
    locale = next;
    var english = locale === "en";
    document.documentElement.lang = locale;
    translatedElements.forEach(function (entry) {
      // data-en 是本页面作者写死的静态文案，作为 HTML 渲染是安全的
      entry.element.innerHTML = english ? entry.english : entry.chinese;
    });
    translatedLabels.forEach(function (entry) {
      entry.element.setAttribute("aria-label", english ? entry.english : entry.chinese);
    });
    var meta = i18nMeta[locale];
    document.title = meta.title;
    document.querySelector('meta[name="description"]').content = meta.description;
    document.querySelector('meta[property="og:title"]').content = meta.ogTitle;
    document.querySelector('meta[property="og:description"]').content = meta.ogDescription;
    languageButton.innerHTML = (english ? "中文" : "EN") + ' <span aria-hidden="true">↔</span>';
    languageButton.setAttribute("aria-label", english ? "切换到中文" : "Switch to English");
    if (brewCopy) brewCopy.textContent = english ? "Copy" : "复制";
    // 切换后动态填充的版本号与日期会随 innerHTML 一起被替换，重新按当前语言填一遍
    if (lastRelease) applyRelease(lastRelease);
  }

  if (languageButton) {
    languageButton.hidden = false;
    languageButton.addEventListener("click", function () {
      applyLocale(locale === "zh-CN" ? "en" : "zh-CN");
    });
  }

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
  var lastRelease = null;

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
      var tag = locale === "en" ? "en-US" : "zh-CN";
      return new Intl.DateTimeFormat(tag, { year: "numeric", month: "long", day: "numeric" }).format(new Date(iso));
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
        brewCopy.textContent = locale === "en" ? "Copy" : "复制";
        brewCopy.classList.remove("is-copied");
      }, 1600);
    };
    var markCopied = function () {
      brewCopy.textContent = locale === "en" ? "Copied" : "已复制";
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
    .then(function (data) {
      if (data && data.tag_name) { lastRelease = data; applyRelease(data); } else { hideVersionMeta(); }
    })
    .catch(function () { hideVersionMeta(); });
})();
