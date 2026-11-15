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

  // 访问设备识别：主下载按钮按平台直接给对应安装包（主流官网做法）。
  //
  // 顺序很重要：Android UA 里含 Linux；iPadOS 13+ 的 Safari 会伪装成
  // MacIntel，只能靠 maxTouchPoints 区分。
  function detectPlatform() {
    var ua = navigator.userAgent || '';
    var platform = '';
    if (navigator.userAgentData && navigator.userAgentData.platform) {
      platform = navigator.userAgentData.platform;
    } else if (navigator.platform) {
      platform = navigator.platform;
    }
    if (/Android/i.test(ua)) {
      return 'android';
    }
    if (/iPhone|iPad|iPod/i.test(ua)) {
      return 'ios';
    }
    if (/Mac/i.test(platform) && navigator.maxTouchPoints > 1) {
      return 'ios';
    }
    if (/Win/i.test(platform) || /Windows/i.test(ua)) {
      return 'windows';
    }
    if (/Mac/i.test(platform) || /Mac OS X/i.test(ua)) {
      return 'macos';
    }
    if (/Linux/i.test(platform) || /Linux/i.test(ua)) {
      return 'linux';
    }
    return 'unknown';
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
      // 只发布 Android：其它平台没有对应安装包，按钮改为「查看全部版本」。
      var apk = apks.filter(function (asset) {
        return /arm64-v8a\.apk$/i.test(asset.name);
      })[0] || apks[0];

      var platform = detectPlatform();
      var primary = apk;
      var label = '下载 Android APK';
      if (platform === 'ios' || platform === 'linux' || platform === 'macos' || platform === 'windows') {
        primary = null;
        label = '查看全部版本';
      }

      fill('[data-latest-version]', release.tag_name || release.name);
      fill('[data-latest-date]', formatDate(release.published_at));
      if (primary) {
        fill('[data-latest-size]', formatSize(primary.size));
        link('[data-download-link]', primary.browser_download_url);
      } else {
        link(
          '[data-download-link]',
          'https://github.com/' + REPO + '/releases/latest'
        );
      }
      fill('[data-download-label]', label);
    })
    .catch(function () {
      // 保持静态兜底：链接仍指向 releases/latest 页面。
    });
})();
