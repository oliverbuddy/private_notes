/// 作品权属标记（可复核、低调）。
///
/// 这类本地优先的工具最容易被整包改名后商用，事后很难证明「是谁写的」。
/// 这里把「创作者标识 + 项目 + 起始年份」编码成一个固定指纹，同时放在
/// 源码常量与「关于」页的极小字构建标识里：举证时可以说明它和公开提交
/// 历史同源，属于创作期留下的常量，而不是事后补的。
///
/// 指纹是 base64 的可读文本，不是加密 —— 任何人可还原，这正是它能被
/// 当作证据的原因：可解释、可复核、可和 git 记录对上。
library;

/// 创作者 / 仓库标识。
const String xiaojiOwner = 'oliverbuddy';

/// 项目仓库名。
const String xiaojiProject = 'private_notes';

/// 项目起始年份（版权起算年）。
const String xiaojiProjectStartYear = '2026';

/// 权属指纹：`owner/project|bundleId|startYear` 的 base64。
///
/// 刻意不加注释说明如何解码 —— 需要举证时按同样的规则还原即可。
const String xiaojiCopyrightFingerprint =
    'b2xpdmVyYnVkZHkvcHJpdmF0ZV9ub3Rlc3xjb20ueGlhb2ppLnhpYW9qaXwyMDI2';

/// 「关于」页展示的构建标识：取指纹前 10 位，足够对照又不打扰阅读。
final String xiaojiBuildTag =
    'jX-${xiaojiCopyrightFingerprint.substring(0, 10)}';

/// 供「关于」页/日志使用的一句话版权声明。
const String xiaojiCopyrightNotice =
    '小记 · © $xiaojiProjectStartYear $xiaojiOwner';
