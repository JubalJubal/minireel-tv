/// 站源播放线路的稳定标识。
///
/// 这些字符串会被写入本地存储（红果使用 key `hongguo:routes`），
/// 不要随意改名，否则用户已保存的线路设置会失效。
abstract final class SourceRouteIds {
  static const app = 'app';
  static const web = 'web';
  static const api = 'api';

  /// 首选线路为「自动」：完全按默认顺序尝试。
  static const auto = 'auto';
}

/// 单条线路的静态信息（名称、说明、默认顺序）。
///
/// 顺序即默认证线路尝试顺序，与 [SourceRouteSettings.routes] 的排列一致。
final class SourceRouteInfo {
  const SourceRouteInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.order,
    required this.qualityHint,
  });

  final String id;
  final String name;
  final String description;

  /// 默认尝试顺序，从 0 开始。
  final int order;

  /// 该线路通常能拿到的最高画质，用于 UI 展示与测速结果提示。
  final String qualityHint;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'order': order,
    'qualityHint': qualityHint,
  };
}

/// 红果站源的线路偏好设置：站点开关、启用集合、首选线路。
///
/// 设计目标：
/// - 三条线路默认全部启用，首选「自动」（App → 网页 → 备用）；
/// - 持久化数据损坏或缺失时整体回退默认值，绝不因脏数据导致无法播放；
/// - 无论怎么配置，至少保留一条启用线路，避免用户把自己锁死。
final class SourceRouteSettings {
  const SourceRouteSettings({
    this.sourceEnabled = true,
    this.enabledRoutes = defaultEnabledRoutes,
    this.preferredRoute = SourceRouteIds.auto,
  });

  /// 默认三条线路全部启用。
  static const Set<String> defaultEnabledRoutes = {
    SourceRouteIds.app,
    SourceRouteIds.web,
    SourceRouteIds.api,
  };

  /// 默认顺序：App 接口 → 网页直链 → 备用接口。
  /// 列表顺序即 [attemptOrder] 中除首选线路外的顺序。
  static const List<SourceRouteInfo> routes = [
    SourceRouteInfo(
      id: SourceRouteIds.app,
      name: 'App 接口',
      description: '官方 App 播放接口，通常提供 1080P 完整片源（CENC 加密），画质最好但依赖设备身份。',
      order: 0,
      qualityHint: '1080P',
    ),
    SourceRouteInfo(
      id: SourceRouteIds.web,
      name: '网页直链',
      description: '网页播放页公开的 360P 直链，无需签名、解析最直接，但清晰度较低。',
      order: 1,
      qualityHint: '360P',
    ),
    SourceRouteInfo(
      id: SourceRouteIds.api,
      name: '备用接口',
      description: '第三方备用解析接口（djapi），作为最后兜底，可能不稳定或缺少部分剧集。',
      order: 2,
      qualityHint: '兜底',
    ),
  ];

  /// 出厂默认值。
  static const SourceRouteSettings defaults = SourceRouteSettings();

  /// 站点总开关：关闭后该站源不再参与播放（浏览仍可用）。
  final bool sourceEnabled;

  /// 启用线路集合，始终非空。
  final Set<String> enabledRoutes;

  /// 首选线路 id，或 [SourceRouteIds.auto] 表示按默认顺序。
  final String preferredRoute;

  /// 按 id 查线路静态信息，未知 id 返回 null。
  static SourceRouteInfo? routeInfoOf(String id) {
    for (final route in routes) {
      if (route.id == id) return route;
    }
    return null;
  }

  /// 线路显示名（未知 id 原样返回，便于错误文案定位）。
  static String labelOf(String id) => routeInfoOf(id)?.name ?? id;

  bool isEnabled(String id) => enabledRoutes.contains(id);

  bool get hasEnabledRoute => attemptOrder.isNotEmpty;

  /// 实际尝试顺序：首选线路（非自动且已启用）优先，其余按默认顺序。
  List<String> get attemptOrder {
    final order = <String>[];
    if (preferredRoute != SourceRouteIds.auto &&
        isEnabled(preferredRoute)) {
      order.add(preferredRoute);
    }
    for (final route in routes) {
      if (isEnabled(route.id) && !order.contains(route.id)) {
        order.add(route.id);
      }
    }
    return order;
  }

  SourceRouteSettings copyWith({
    bool? sourceEnabled,
    Set<String>? enabledRoutes,
    String? preferredRoute,
  }) => SourceRouteSettings(
    sourceEnabled: sourceEnabled ?? this.sourceEnabled,
    enabledRoutes: enabledRoutes ?? this.enabledRoutes,
    preferredRoute: preferredRoute ?? this.preferredRoute,
  );

  /// 切换某条线路的启用状态。
  ///
  /// 若会关闭最后一条启用线路则保持原状（[enabledRoutes] 非空不变量）。
  SourceRouteSettings withRouteEnabled(String id, bool enabled) {
    if (routeInfoOf(id) == null) return this;
    final next = {...enabledRoutes};
    if (enabled) {
      next.add(id);
    } else {
      next.remove(id);
    }
    if (next.isEmpty) return this;
    return copyWith(enabledRoutes: next);
  }

  /// 切换站点总开关。
  SourceRouteSettings withSourceEnabled(bool enabled) =>
      copyWith(sourceEnabled: enabled);

  /// 设置首选线路（[SourceRouteIds.auto] 表示自动顺序）。
  SourceRouteSettings withPreferred(String id) {
    if (id != SourceRouteIds.auto && routeInfoOf(id) == null) return this;
    return copyWith(preferredRoute: id);
  }

  Map<String, dynamic> toJson() => {
    'sourceEnabled': sourceEnabled,
    // 按默认顺序输出，方便人工排查与稳定 diff。
    'enabled': [
      for (final route in routes)
        if (enabledRoutes.contains(route.id)) route.id,
    ],
    'preferred': preferredRoute,
  };

  /// 解析持久化数据；任何字段损坏都回退到对应默认值。
  factory SourceRouteSettings.fromJson(Object? json) {
    if (json is! Map) return defaults;
    final enabled = <String>{};
    final rawEnabled = json['enabled'];
    if (rawEnabled is List) {
      for (final item in rawEnabled) {
        if (item is String && routeInfoOf(item) != null) enabled.add(item);
      }
    }
    final rawPreferred = json['preferred'];
    final preferred =
        rawPreferred is String &&
            (rawPreferred == SourceRouteIds.auto ||
                routeInfoOf(rawPreferred) != null)
        ? rawPreferred
        : SourceRouteIds.auto;
    final rawSourceEnabled = json['sourceEnabled'];
    return SourceRouteSettings(
      sourceEnabled: rawSourceEnabled is bool ? rawSourceEnabled : true,
      enabledRoutes: enabled.isEmpty ? defaultEnabledRoutes : enabled,
      preferredRoute: preferred,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SourceRouteSettings &&
      other.sourceEnabled == sourceEnabled &&
      other.preferredRoute == preferredRoute &&
      other.enabledRoutes.length == enabledRoutes.length &&
      other.enabledRoutes.containsAll(enabledRoutes);

  @override
  int get hashCode => Object.hash(
    sourceEnabled,
    preferredRoute,
    Object.hashAllUnordered(enabledRoutes),
  );

  @override
  String toString() =>
      'SourceRouteSettings(sourceEnabled: $sourceEnabled, '
      'enabled: $enabledRoutes, preferred: $preferredRoute)';
}
