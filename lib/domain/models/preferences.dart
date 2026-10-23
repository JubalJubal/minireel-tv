import 'remote_key_map.dart';

enum AppAppearance { system, light, dark }

enum RailSide { right, left }

enum GestureSensitivity { low, medium, high }

const playbackSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

final class Preferences {
  const Preferences({
    this.appearance = AppAppearance.system,
    this.speed = 1,
    this.quality = '自动',
    this.autoNext = true,
    this.rememberProgress = true,
    this.railSide = RailSide.right,
    this.sensitivity = GestureSensitivity.medium,
    this.largeText = false,
    this.haptics = true,
    this.gestureHintSeen = false,
    this.pauseWhenMinimized = true,
    this.desktopVolume = .75,
    this.prefetchNextEpisode = true,
    this.remoteKeyMap,
    this.controlsAutoHideSeconds = 5,
    this.videoFitMode = 'contain',
    this.seekStepSeconds = 10,
    this.skipIntroSeconds = 0,
    this.skipOutroSeconds = 0,
    this.autoCheckUpdate = true,
    this.accentColorKey = 'default',
    this.hardwareDecoding = 'auto',
    this.playerBufferSizeMb = 16,
    this.audioBoost = 0,
    this.playerGlassEffect = true,
    this.tvColumns = 0,
    this.tvFocusSound = true,
    this.longPressSpeed = 2.0,
    this.danmakuEnabled = true,
    this.danmakuSpeedFactor = 1.0,
    this.danmakuFontSize = 18,
    this.danmakuOpacity = 0.9,
    this.danmakuAreaRatio = 0.4,
    this.watchReminderEnabled = false,
    this.watchDailyLimitMinutes = 240,
    this.bedtimeReminderEnabled = false,
    this.bedtimeMinute = 23 * 60,
    this.watchUsageDate = '',
    this.watchUsageMinutes = 0,
  });

  final AppAppearance appearance;
  final double speed;
  final String quality;
  final bool autoNext;
  final bool rememberProgress;
  final RailSide railSide;
  final GestureSensitivity sensitivity;
  final bool largeText;
  final bool haptics;
  final bool gestureHintSeen;
  final bool pauseWhenMinimized;
  final double desktopVolume;
  final bool prefetchNextEpisode;
  /// 遥控器按键映射。null 表示用默认映射（未自定义）。
  final RemoteKeyMap? remoteKeyMap;
  /// 播放控制栏自动隐藏时间（秒），0 表示从不自动隐藏。
  final int controlsAutoHideSeconds;
  /// 视频画面填充比例：'contain' (原始比例含黑边), 'cover' (撑满裁切沉浸), 'fill' (拉伸铺满全屏)
  final String videoFitMode;
  /// 遥控器方向键左右快进/快退步长（秒）
  final int seekStepSeconds;
  /// 自动跳过片头时长（秒），0 表示不跳过
  final int skipIntroSeconds;
  /// 自动跳过片尾时长（秒），0 表示不跳过
  final int skipOutroSeconds;
  /// 启动时是否自动检查新版本
  final bool autoCheckUpdate;
  /// 界面强调色主题：'default'(经典玫红), 'orange'(活力橙), 'blue'(极客蓝), 'green'(翡翠绿), 'purple'(优雅紫)
  final String accentColorKey;
  /// 硬件解码：'auto' (自动硬解·推荐), 'mediacodec' (强制硬解), 'no' (兼容软解)
  final String hardwareDecoding;
  /// 播放缓冲区大小（MB）：8, 16, 32, 64
  final int playerBufferSizeMb;
  /// 音量与人声增强（百分比）：0 (原始), 25 (+25%), 50 (+50%), 100 (+100%)
  final int audioBoost;
  /// 播放界面毛玻璃高斯模糊（关闭可大幅提升低端设备帧率）
  final bool playerGlassEffect;
  /// TV 剧库网格列数：0 (自适应), 4 (大图沉浸), 5 (标准), 6 (紧凑)
  final int tvColumns;
  /// 遥控器焦点按键音效反馈
  final bool tvFocusSound;
  /// 长按快进倍速：1.5, 2.0, 3.0
  final double longPressSpeed;
  /// 弹幕开关（播放页控制栏也可临时切换）
  final bool danmakuEnabled;
  /// 弹幕速度系数：0.7 慢 / 1.0 标准 / 1.4 快
  final double danmakuSpeedFactor;
  /// 弹幕字号：14 小 / 18 标准 / 22 大 / 26 特大
  final double danmakuFontSize;
  /// 弹幕不透明度：0.4 / 0.6 / 0.8 / 1.0
  final double danmakuOpacity;
  /// 弹幕占用屏幕高度比例：0.25 / 0.4 / 0.55 / 0.7
  final double danmakuAreaRatio;

  /// 观看提醒（移植自参考实现）：每日累计观看时长提醒 + 睡觉时间提醒。
  final bool watchReminderEnabled;
  final int watchDailyLimitMinutes;
  final bool bedtimeReminderEnabled;
  final int bedtimeMinute;

  /// 今日已观看分钟数与日期键（yyyyMMdd），跨会话累计。
  final String watchUsageDate;
  final int watchUsageMinutes;

  Preferences copyWith({
    AppAppearance? appearance,
    double? speed,
    String? quality,
    bool? autoNext,
    bool? rememberProgress,
    RailSide? railSide,
    GestureSensitivity? sensitivity,
    bool? largeText,
    bool? haptics,
    bool? gestureHintSeen,
    bool? pauseWhenMinimized,
    double? desktopVolume,
    bool? prefetchNextEpisode,
    RemoteKeyMap? remoteKeyMap,
    int? controlsAutoHideSeconds,
    String? videoFitMode,
    int? seekStepSeconds,
    int? skipIntroSeconds,
    int? skipOutroSeconds,
    bool? autoCheckUpdate,
    String? accentColorKey,
    String? hardwareDecoding,
    int? playerBufferSizeMb,
    int? audioBoost,
    bool? playerGlassEffect,
    int? tvColumns,
    bool? tvFocusSound,
    double? longPressSpeed,
    bool? danmakuEnabled,
    double? danmakuSpeedFactor,
    double? danmakuFontSize,
    double? danmakuOpacity,
    double? danmakuAreaRatio,
    bool? watchReminderEnabled,
    int? watchDailyLimitMinutes,
    bool? bedtimeReminderEnabled,
    int? bedtimeMinute,
    String? watchUsageDate,
    int? watchUsageMinutes,
  }) => Preferences(
    appearance: appearance ?? this.appearance,
    speed: speed ?? this.speed,
    quality: quality ?? this.quality,
    autoNext: autoNext ?? this.autoNext,
    rememberProgress: rememberProgress ?? this.rememberProgress,
    railSide: railSide ?? this.railSide,
    sensitivity: sensitivity ?? this.sensitivity,
    largeText: largeText ?? this.largeText,
    haptics: haptics ?? this.haptics,
    gestureHintSeen: gestureHintSeen ?? this.gestureHintSeen,
    pauseWhenMinimized: pauseWhenMinimized ?? this.pauseWhenMinimized,
    desktopVolume: desktopVolume ?? this.desktopVolume,
    prefetchNextEpisode: prefetchNextEpisode ?? this.prefetchNextEpisode,
    remoteKeyMap: remoteKeyMap ?? this.remoteKeyMap,
    controlsAutoHideSeconds: controlsAutoHideSeconds ?? this.controlsAutoHideSeconds,
    videoFitMode: videoFitMode ?? this.videoFitMode,
    seekStepSeconds: seekStepSeconds ?? this.seekStepSeconds,
    skipIntroSeconds: skipIntroSeconds ?? this.skipIntroSeconds,
    skipOutroSeconds: skipOutroSeconds ?? this.skipOutroSeconds,
    autoCheckUpdate: autoCheckUpdate ?? this.autoCheckUpdate,
    accentColorKey: accentColorKey ?? this.accentColorKey,
    hardwareDecoding: hardwareDecoding ?? this.hardwareDecoding,
    playerBufferSizeMb: playerBufferSizeMb ?? this.playerBufferSizeMb,
    audioBoost: audioBoost ?? this.audioBoost,
    playerGlassEffect: playerGlassEffect ?? this.playerGlassEffect,
    tvColumns: tvColumns ?? this.tvColumns,
    tvFocusSound: tvFocusSound ?? this.tvFocusSound,
    longPressSpeed: longPressSpeed ?? this.longPressSpeed,
    danmakuEnabled: danmakuEnabled ?? this.danmakuEnabled,
    danmakuSpeedFactor: danmakuSpeedFactor ?? this.danmakuSpeedFactor,
    danmakuFontSize: danmakuFontSize ?? this.danmakuFontSize,
    danmakuOpacity: danmakuOpacity ?? this.danmakuOpacity,
    danmakuAreaRatio: danmakuAreaRatio ?? this.danmakuAreaRatio,
    watchReminderEnabled: watchReminderEnabled ?? this.watchReminderEnabled,
    watchDailyLimitMinutes: watchDailyLimitMinutes ?? this.watchDailyLimitMinutes,
    bedtimeReminderEnabled: bedtimeReminderEnabled ?? this.bedtimeReminderEnabled,
    bedtimeMinute: bedtimeMinute ?? this.bedtimeMinute,
    watchUsageDate: watchUsageDate ?? this.watchUsageDate,
    watchUsageMinutes: watchUsageMinutes ?? this.watchUsageMinutes,
  );

  Map<String, dynamic> toJson() => {
    'appearance': appearance.name,
    'speed': speed,
    'quality': quality,
    'autoNext': autoNext,
    'rememberProgress': rememberProgress,
    'railSide': railSide.name,
    'sensitivity': sensitivity.name,
    'largeText': largeText,
    'haptics': haptics,
    'gestureHintSeen': gestureHintSeen,
    'pauseWhenMinimized': pauseWhenMinimized,
    'desktopVolume': desktopVolume,
    'prefetchNextEpisode': prefetchNextEpisode,
    if (remoteKeyMap != null) 'remoteKeyMap': remoteKeyMap!.toJson(),
    'controlsAutoHideSeconds': controlsAutoHideSeconds,
    'videoFitMode': videoFitMode,
    'seekStepSeconds': seekStepSeconds,
    'skipIntroSeconds': skipIntroSeconds,
    'skipOutroSeconds': skipOutroSeconds,
    'autoCheckUpdate': autoCheckUpdate,
    'accentColorKey': accentColorKey,
    'hardwareDecoding': hardwareDecoding,
    'playerBufferSizeMb': playerBufferSizeMb,
    'audioBoost': audioBoost,
    'playerGlassEffect': playerGlassEffect,
    'tvColumns': tvColumns,
    'tvFocusSound': tvFocusSound,
    'longPressSpeed': longPressSpeed,
    'danmakuEnabled': danmakuEnabled,
    'danmakuSpeedFactor': danmakuSpeedFactor,
    'danmakuFontSize': danmakuFontSize,
    'danmakuOpacity': danmakuOpacity,
    'danmakuAreaRatio': danmakuAreaRatio,
    'watchReminderEnabled': watchReminderEnabled,
    'watchDailyLimitMinutes': watchDailyLimitMinutes,
    'bedtimeReminderEnabled': bedtimeReminderEnabled,
    'bedtimeMinute': bedtimeMinute,
    'watchUsageDate': watchUsageDate,
    'watchUsageMinutes': watchUsageMinutes,
  };

  factory Preferences.fromJson(Map<String, dynamic> json) => Preferences(
    appearance: AppAppearance.values.firstWhere(
      (value) => value.name == json['appearance'],
      orElse: () => AppAppearance.system,
    ),
    speed: playbackSpeeds.contains(json['speed'])
        ? (json['speed'] as num).toDouble()
        : 1,
    quality: json['quality'] as String? ?? '自动',
    autoNext: json['autoNext'] != false,
    rememberProgress: json['rememberProgress'] != false,
    railSide: json['railSide'] == 'left' ? RailSide.left : RailSide.right,
    sensitivity: GestureSensitivity.values.firstWhere(
      (value) => value.name == json['sensitivity'],
      orElse: () => GestureSensitivity.medium,
    ),
    largeText: json['largeText'] == true,
    haptics: json['haptics'] != false,
    gestureHintSeen: json['gestureHintSeen'] == true,
    pauseWhenMinimized: json['pauseWhenMinimized'] != false,
    desktopVolume:
        json['desktopVolume'] is num && (json['desktopVolume'] as num).isFinite
        ? (json['desktopVolume'] as num).toDouble().clamp(0, 1)
        : .75,
    prefetchNextEpisode: json['prefetchNextEpisode'] != false,
    remoteKeyMap: json['remoteKeyMap'] is Map
        ? RemoteKeyMap.fromJson(json['remoteKeyMap'] as Map<String, dynamic>)
        : null,
    controlsAutoHideSeconds: json['controlsAutoHideSeconds'] is num
        ? (json['controlsAutoHideSeconds'] as num).toInt()
        : 5,
    videoFitMode: json['videoFitMode'] as String? ?? 'contain',
    seekStepSeconds: json['seekStepSeconds'] is num
        ? (json['seekStepSeconds'] as num).toInt()
        : 10,
    skipIntroSeconds: json['skipIntroSeconds'] is num
        ? (json['skipIntroSeconds'] as num).toInt()
        : 0,
    skipOutroSeconds: json['skipOutroSeconds'] is num
        ? (json['skipOutroSeconds'] as num).toInt()
        : 0,
    autoCheckUpdate: json['autoCheckUpdate'] != false,
    accentColorKey: json['accentColorKey'] as String? ?? 'default',
    hardwareDecoding: json['hardwareDecoding'] as String? ?? 'auto',
    playerBufferSizeMb: json['playerBufferSizeMb'] is num
        ? (json['playerBufferSizeMb'] as num).toInt()
        : 16,
    audioBoost: json['audioBoost'] is num
        ? (json['audioBoost'] as num).toInt()
        : 0,
    playerGlassEffect: json['playerGlassEffect'] != false,
    tvColumns: json['tvColumns'] is num
        ? (json['tvColumns'] as num).toInt()
        : 0,
    tvFocusSound: json['tvFocusSound'] != false,
    longPressSpeed: json['longPressSpeed'] is num
        ? (json['longPressSpeed'] as num).toDouble()
        : 2.0,
    danmakuEnabled: json['danmakuEnabled'] != false,
    danmakuSpeedFactor: json['danmakuSpeedFactor'] is num
        ? (json['danmakuSpeedFactor'] as num).toDouble().clamp(0.5, 2.0)
        : 1.0,
    danmakuFontSize: json['danmakuFontSize'] is num
        ? (json['danmakuFontSize'] as num).toDouble().clamp(12, 32)
        : 18,
    danmakuOpacity: json['danmakuOpacity'] is num
        ? (json['danmakuOpacity'] as num).toDouble().clamp(0.2, 1.0)
        : 0.9,
    danmakuAreaRatio: json['danmakuAreaRatio'] is num
        ? (json['danmakuAreaRatio'] as num).toDouble().clamp(0.15, 0.8)
        : 0.4,
    watchReminderEnabled: json['watchReminderEnabled'] == true,
    watchDailyLimitMinutes: json['watchDailyLimitMinutes'] is int
        ? (json['watchDailyLimitMinutes'] as int).clamp(10, 1440)
        : 240,
    bedtimeReminderEnabled: json['bedtimeReminderEnabled'] == true,
    bedtimeMinute: json['bedtimeMinute'] is int
        ? (json['bedtimeMinute'] as int).clamp(0, 1439)
        : 23 * 60,
    watchUsageDate: json['watchUsageDate'] is String
        ? json['watchUsageDate'] as String
        : '',
    watchUsageMinutes: json['watchUsageMinutes'] is int
        ? (json['watchUsageMinutes'] as int).clamp(0, 1440)
        : 0,
  );
}
