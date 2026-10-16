import 'package:flutter_test/flutter_test.dart';
import 'package:minireel/core/services/app_update_service.dart';

/// Release 里同时存在 phone 与 tv 两种 flavor 的 APK 时，
/// 必须只挑与当前安装形态一致的那一个。
void main() {
  Map<String, dynamic> asset(String name) => {
    'name': name,
    'browser_download_url': 'https://example.invalid/$name',
    'size': 1024,
  };

  final both = [
    asset('MiniReel-0.3.2-android-arm64-v8a.apk'),
    asset('MiniReel-0.3.2-android-armeabi-v7a.apk'),
    asset('MiniReel-0.3.2-android-tv-arm64-v8a.apk'),
    asset('MiniReel-0.3.2-android-tv-armeabi-v7a.apk'),
    asset('MiniReel-0.3.2-windows-x64-setup.exe'),
  ];

  test('tv 设备挑 tv 版，不受 phone 版影响', () {
    final picked = AppUpdateService.selectAssetForDevice(
      both,
      'arm64-v8a',
      isTv: true,
    );
    expect(picked?['name'], 'MiniReel-0.3.2-android-tv-arm64-v8a.apk');

    final picked32 = AppUpdateService.selectAssetForDevice(
      both,
      'armeabi-v7a',
      isTv: true,
    );
    expect(picked32?['name'], 'MiniReel-0.3.2-android-tv-armeabi-v7a.apk');
  });

  test('phone 设备挑 phone 版', () {
    final picked = AppUpdateService.selectAssetForDevice(
      both,
      'arm64-v8a',
      isTv: false,
    );
    expect(picked?['name'], 'MiniReel-0.3.2-android-arm64-v8a.apk');
  });

  test('只有 phone 版时 tv 设备判定为无可用更新', () {
    final phoneOnly = [
      asset('MiniReel-0.3.2-android-arm64-v8a.apk'),
      asset('MiniReel-0.3.2-android-armeabi-v7a.apk'),
    ];
    expect(
      AppUpdateService.selectAssetForDevice(phoneOnly, 'arm64-v8a', isTv: true),
      isNull,
    );
    expect(
      AppUpdateService.selectAssetForDevice(phoneOnly, 'arm64-v8a', isTv: false)
          ?['name'],
      'MiniReel-0.3.2-android-arm64-v8a.apk',
    );
  });

  test('只有 tv 版（本次发布形态）时正常挑到', () {
    final tvOnly = [
      asset('MiniReel-0.3.2-android-tv-arm64-v8a.apk'),
      asset('MiniReel-0.3.2-android-tv-x86_64.apk'),
    ];
    expect(
      AppUpdateService.selectAssetForDevice(tvOnly, 'arm64-v8a', isTv: true)
          ?['name'],
      'MiniReel-0.3.2-android-tv-arm64-v8a.apk',
    );
    expect(
      AppUpdateService.selectAssetForDevice(tvOnly, 'x86_64', isTv: true)
          ?['name'],
      'MiniReel-0.3.2-android-tv-x86_64.apk',
    );
  });

  test('空资源列表返回 null', () {
    expect(
      AppUpdateService.selectAssetForDevice(
        const [],
        'arm64-v8a',
        isTv: true,
      ),
      isNull,
    );
  });
}
