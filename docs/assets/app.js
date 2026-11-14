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
      // 按 ABI 拆包后优先指向 arm64（绝大多数设备），老设备在 Release 页
      // 里手动选 armeabi-v7a。
      var apk = apks.filter(function (asset) {
        return /arm64-v8a\.apk$/i.test(asset.name);
      })[0] || apks[0];

      // 桌面端：macOS 通用 DMG、Windows x64 安装器。缺失时保持指向 Releases 页。
      var mac = findAsset(assets, /-macos-universal\.dmg$/i);
      var win = findAsset(assets, /-windows-x64-setup\.exe$/i);

      // 主按钮按访问平台给对应安装包，文案同步成「下载 macOS 版」等。
      // iOS / Linux 没有对应包：按钮改为「查看全部版本」，避免误下 APK。
      var platform = detectPlatform();
      var primary = null;
      var label = '下载最新版';
      if (platform === 'android') {
        primary = apk;
        label = '下载 Android APK';
      } else if (platform === 'macos') {
        primary = mac;
        label = '下载 macOS 版';
      } else if (platform === 'windows') {
        primary = win;
        label = '下载 Windows 版';
      } else if (platform === 'ios' || platform === 'linux') {
        label = '查看全部版本';
      } else if (apk) {
        // 无法识别的系统：保留原来的 APK 兜底。
        primary = apk;
        label = '下载 Android APK';
      }

      fill('[data-latest-version]', release.tag_name || release.name);
      fill('[data-latest-date]', formatDate(release.published_at));
      if (primary) {
        fill('[data-latest-size]', formatSize(primary.size));
        link('[data-download-link]', primary.browser_download_url);
      } else if (platform === 'ios' || platform === 'linux') {
        link(
          '[data-download-link]',
          'https://github.com/' + REPO + '/releases/latest'
        );
      }
      fill('[data-download-label]', label);

      link('[data-macos-download]', mac && mac.browser_download_url);
      link('[data-windows-download]', win && win.browser_download_url);
    })
    .catch(function () {
      // 保持静态兜底：链接仍指向 releases/latest 页面。
    });
})();
