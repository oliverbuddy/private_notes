// 落地页的少量动态信息：最新版本号、大小、日期与各平台直链。
// 拿不到 GitHub API（离线 / 限流）时保持 HTML 里的静态兜底文案。
(function () {
  'use strict';

  var REPO = 'oliverbuddy/private_notes';

  document.querySelectorAll('[data-year]').forEach(function (el) {
    el.textContent = String(new Date().getFullYear());
  });

  function formatSize(bytes) {
    if (!bytes || bytes < 1024) {
      return null;
    }
    return (bytes / 1024 / 1024).toFixed(1) + ' MB';
  }

  function formatDate(iso) {
    if (!iso) {
      return null;
    }
    var date = new Date(iso);
    if (isNaN(date.getTime())) {
      return null;
    }
    var pad = function (n) {
      return n < 10 ? '0' + n : String(n);
    };
    return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate());
  }

  function fill(selector, text) {
    if (!text) {
      return;
    }
    document.querySelectorAll(selector).forEach(function (el) {
      el.textContent = text;
    });
  }

  function link(selector, url) {
    if (!url) {
      return;
    }
    document.querySelectorAll(selector).forEach(function (el) {
      el.setAttribute('href', url);
    });
  }

  function findAsset(assets, pattern) {
    for (var i = 0; i < assets.length; i++) {
      if (pattern.test(assets[i].name)) {
        return assets[i];
      }
    }
    return null;
  }

  fetch('https://api.github.com/repos/' + REPO + '/releases/latest', {
    headers: { Accept: 'application/vnd.github+json' },
  })
    .then(function (res) {
      if (!res.ok) {
        throw new Error('HTTP ' + res.status);
      }
      return res.json();
    })
    .then(function (release) {
      var assets = release.assets || [];
      var apks = assets.filter(function (asset) {
        return /\.apk$/i.test(asset.name);
      });
      // 按 ABI 拆包后优先指向 arm64（绝大多数设备），老设备在 Release 页
      // 里手动选 armeabi-v7a。
      var apk = apks.filter(function (asset) {
        return /arm64-v8a\.apk$/i.test(asset.name);
      })[0] || apks[0];

      fill('[data-latest-version]', release.tag_name || release.name);
      fill('[data-latest-date]', formatDate(release.published_at));
      if (apk) {
        fill('[data-latest-size]', formatSize(apk.size));
        link('[data-download-link]', apk.browser_download_url);
      }

      // 桌面端：macOS 通用包、Windows x64 包。缺失时保持指向 Releases 页。
      var mac = findAsset(assets, /-macos-universal\.zip$/i);
      var win = findAsset(assets, /-windows-x64\.zip$/i);
      link('[data-macos-download]', mac && mac.browser_download_url);
      link('[data-windows-download]', win && win.browser_download_url);
    })
    .catch(function () {
      // 保持静态兜底：链接仍指向 releases/latest 页面。
    });
})();
