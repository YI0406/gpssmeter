import 'package:flutter/material.dart';
import 'purchase_service.dart';
import 'ad.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

class SettingsData {
  final double maxKmh;
  final Color themeColor;
  final bool enableBootAnimation;
  final bool enableMockRoute;
  final bool useMiles; // false=公里, true=英里
  final String language; // 'zh-TW' 或 'en'
  const SettingsData({
    required this.maxKmh,
    required this.themeColor,
    required this.enableBootAnimation,
    required this.enableMockRoute,
    this.useMiles = false,
    this.language = 'zh-TW',
  });
}

/// Global runtime settings (lightweight). Persisting handled elsewhere.
class Setting {
  Setting._();
  static final Setting instance = Setting._();
  static const String _kUseMph = 'useMph';
  static const String _kLanguage = 'language';

  /// Load persisted settings once (call on app boot if needed)
  static Future<void> loadFromPrefs() async {
    final sp = await SharedPreferences.getInstance();
    instance.useMph = sp.getBool(_kUseMph) ?? instance.useMph;
    final lang = sp.getString(_kLanguage);
    if (lang != null && instance.language.value != lang) {
      instance.language.value = lang;
    }
  }

  /// Persist current settings
  static Future<void> saveToPrefs() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kUseMph, instance.useMph);
    await sp.setString(_kLanguage, instance.language.value);
  }

  /// true = mph, false = km/h
  bool useMph = false;

  /// current app language: 'zh-TW' | 'zh-CN' | 'en'
  final ValueNotifier<String> language = ValueNotifier<String>('zh-TW');
  void setLanguage(String lang) {
    if (language.value == lang) return;
    language.value = lang;
  }

  /// app theme seed color (so pages can react immediately when user taps a color)
  final ValueNotifier<Color> themeSeed = ValueNotifier<Color>(Colors.green);
  void setThemeSeed(Color c) {
    if (themeSeed.value == c) return;
    themeSeed.value = c;
  }

  /// background recording preference live notifier (so main.dart can react immediately)
  final ValueNotifier<bool> backgroundRecording = ValueNotifier<bool>(true);
}

/// Lightweight in-app localization without intl for now.
class L10n {
  static const List<String> supported = ['zh-TW', 'zh-CN', 'en'];

  static const Map<String, Map<String, String>> _d = {
    'official_website': {
      'zh-TW': '官方網站',
      'zh-CN': '官方网站',
      'en': 'Official Website',
    },
    'settings': {
      'zh-TW': '系統設定',
      'zh-CN': '系统设置',
      'en': 'Settings',
    },

    'speed_limit': {
      'zh-TW': '儀表上限',
      'zh-CN': '仪表上限',
      'en': 'Speed limit',
    },
    'theme_color': {
      'zh-TW': '主題色',
      'zh-CN': '主题色',
      'en': 'Theme color',
    },
    'boot_anim': {
      'zh-TW': '啟用開機自檢動畫',
      'zh-CN': '启用开机自检动画',
      'en': 'Enable boot animation',
    },
    'mock_mode': {
      'zh-TW': '模擬模式（測試用）',
      'zh-CN': '模拟模式（测试用）',
      'en': 'Mock mode (for testing)',
    },
    'unit_mph_title': {
      'zh-TW': '單位：英里（mph）',
      'zh-CN': '单位：英里（mph）',
      'en': 'Units: Miles (mph)',
    },
    'unit_mph_sub': {
      'zh-TW': '關閉為公里（km/h、km）',
      'zh-CN': '关闭为公里（km/h、km）',
      'en': 'Off = kilometers (km/h, km)',
    },
    'bg_rec_title': {
      'zh-TW': '背景持續記錄',
      'zh-CN': '后台持续记录',
      'en': 'Background Trip Recording',
    },
    'bg_rec_sub': {
      'zh-TW': '開啟後：App 於背景持續使用定位，記錄地圖軌跡與旅程（較耗電）',
      'zh-CN': '开启后：App 在后台持续使用定位，记录地图轨迹与旅程（较耗电）',
      'en':
          'When ON: uses location in background to record track and trips (more battery usage)',
    },
    'bg_rec_enable_title': {
      'zh-TW': '啟用背景持續記錄？',
      'zh-CN': '启用后台持续记录？',
      'en': 'Enable background recording?',
    },
    'bg_rec_enable_msg': {
      'zh-TW':
          '此功能會在 App 退到背景或鎖屏時，持續使用定位來記錄旅程與軌跡，並可能增加電量消耗。若尚未授予定位權限，請前往 iOS 設定開啟。',
      'zh-CN':
          '此功能会在 App 退到后台或锁屏时，持续使用定位来记录旅程与轨迹，并可能增加电量消耗。若尚未授予定位权限，请前往 iOS 设置开启。',
      'en':
          'When enabled, the app will continue using location in the background or when the screen is locked to record trips and routes. This may increase battery usage. If location permission has not been granted, please enable it in iOS Settings.',
    },
    'bg_rec_open_settings': {
      'zh-TW': '前往設定',
      'zh-CN': '前往设置',
      'en': 'Open Settings',
    },
    'bg_rec_cancel': {
      'zh-TW': '先不要',
      'zh-CN': '先不要',
      'en': 'Not now',
    },
    'bg_rec_enabled_tip': {
      'zh-TW': '已啟用背景持續記錄',
      'zh-CN': '已启用后台持续记录',
      'en': 'Background recording enabled',
    },
    'bg_rec_disabled_tip': {
      'zh-TW': '已關閉背景持續記錄',
      'zh-CN': '已关闭后台持续记录',
      'en': 'Background recording disabled',
    },
    'language': {
      'zh-TW': '語言',
      'zh-CN': '语言',
      'en': 'Language',
    },
    'save': {
      'zh-TW': '儲存',
      'zh-CN': '保存',
      'en': 'Save',
    },
    'opt_zhTW': {
      'zh-TW': '繁體中文',
      'zh-CN': '繁体中文',
      'en': 'Traditional Chinese',
    },
    'opt_zhCN': {
      'zh-TW': '簡體中文',
      'zh-CN': '简体中文',
      'en': 'Simplified Chinese',
    },
    'opt_en': {
      'zh-TW': '英文',
      'zh-CN': '英语',
      'en': 'English',
    },
    'dark_mode': {
      'zh-TW': '暗夜模式',
      'zh-CN': '夜间模式',
      'en': 'Dark mode',
    },
    'light_mode': {
      'zh-TW': '白天模式',
      'zh-CN': '日间模式',
      'en': 'Light mode',
    },
    'switch_to_dark': {
      'zh-TW': '切換為黑背景',
      'zh-CN': '切换为黑背景',
      'en': 'Switch to dark background',
    },
    'switch_to_light': {
      'zh-TW': '切換為白背景',
      'zh-CN': '切换为白背景',
      'en': 'Switch to light background',
    },
    'resume': {
      'zh-TW': '繼續',
      'zh-CN': '继续',
      'en': 'Resume',
    },
    'manual_start': {
      'zh-TW': '手動開始',
      'zh-CN': '手动开始',
      'en': 'Start manually',
    },
    'manual_start_sub': {
      'zh-TW': '立即開始計時與記錄',
      'zh-CN': '立即开始计时与记录',
      'en': 'Start timing and recording now',
    },
    'pause': {
      'zh-TW': '暫停',
      'zh-CN': '暂停',
      'en': 'Pause',
    },
    'start': {
      'zh-TW': '開始',
      'zh-CN': '开始',
      'en': 'Start',
    },
    'start_sub': {
      'zh-TW': '開始計時與記錄旅程',
      'zh-CN': '开始计时与记录旅程',
      'en': 'Start timing and recording the trip',
    },
    'map_mode': {
      'zh-TW': '地圖模式',
      'zh-CN': '地图模式',
      'en': 'Map mode',
    },
    'map_mode_sub': {
      'zh-TW': '只顯示時速＋地圖＋軌跡線',
      'zh-CN': '只显示时速＋地图＋轨迹线',
      'en': 'Show only speed + map + track',
    },
    'accel_test': {
      'zh-TW': '加速測試',
      'zh-CN': '加速测试',
      'en': 'Acceleration test',
    },
    'record_mode': {
      'zh-TW': '錄影模式',
      'zh-CN': '录影模式',
      'en': 'Recording mode',
    },
    'trip_list': {
      'zh-TW': '旅程列表',
      'zh-CN': '旅程列表',
      'en': 'Trips',
    },
    'end_trip': {
      'zh-TW': '結束旅程',
      'zh-CN': '结束旅程',
      'en': 'End trip',
    },
    'paused': {
      'zh-TW': '暫停中',
      'zh-CN': '暂停中',
      'en': 'Paused',
    },
    'moving': {
      'zh-TW': '移動中',
      'zh-CN': '移动中',
      'en': 'Moving',
    },
    'auto_paused': {
      'zh-TW': '自動暫停中',
      'zh-CN': '自动暂停中',
      'en': 'Auto paused',
    },
    'distance': {'zh-TW': '距離', 'zh-CN': '距离', 'en': 'Distance'},
    'altitude': {'zh-TW': '海拔', 'zh-CN': '海拔', 'en': 'Altitude'},
    'stopped_time': {'zh-TW': '停止時間', 'zh-CN': '停止时间', 'en': 'Stopped time'},
    'max_speed': {'zh-TW': '最高速', 'zh-CN': '最高速', 'en': 'Max speed'},
    'avg_speed': {'zh-TW': '平均速', 'zh-CN': '平均速', 'en': 'Avg speed'},
    'total_time': {'zh-TW': '總時間', 'zh-CN': '总时间', 'en': 'Total time'},
    'name_this_trip': {
      'zh-TW': '命名本次旅程',
      'zh-CN': '为本次旅程命名',
      'en': 'Name this trip',
    },
    'cancel': {
      'zh-TW': '取消',
      'zh-CN': '取消',
      'en': 'Cancel',
    },
    'start_failed': {
      'zh-TW': '啟動失敗',
      'zh-CN': '启动失败',
      'en': 'Failed to start',
    },
    'back_home': {'zh-TW': '返回主頁', 'zh-CN': '返回主页', 'en': 'Back to Home'},
    'start_recording': {
      'zh-TW': '開始記錄',
      'zh-CN': '开始记录',
      'en': 'Start Recording'
    },
    'pause_recording': {
      'zh-TW': '暫停記錄',
      'zh-CN': '暂停记录',
      'en': 'Pause Recording'
    },
    'end_and_save': {
      'zh-TW': '結束旅程並儲存',
      'zh-CN': '结束旅程并保存',
      'en': 'End and Save Trip'
    },
    'end_trip_sub': {
      'zh-TW': '結束旅程並儲存',
      'zh-CN': '结束旅程并保存',
      'en': 'End and Save Trip'
    },
    'save_condition_not_met': {
      'zh-TW': '未達保存條件（移動太短），本次旅程未儲存。',
      'zh-CN': '未达保存条件（移动太短），本次旅程未保存。',
      'en': 'Trip not saved due to insufficient movement.'
    },
    'save_not_wired': {
      'zh-TW': '尚未接上保存邏輯，請在主頁傳入 onStopAndSave 或 onStopAndSaveResult 回呼',
      'zh-CN': '尚未接上保存逻辑，请在主页传入 onStopAndSave 或 onStopAndSaveResult 回调',
      'en':
          'Save logic not connected. Provide onStopAndSave or onStopAndSaveResult on homepage.'
    },
    // Accel page keys
    'accel_records': {
      'zh-TW': '加速紀錄',
      'zh-CN': '加速记录',
      'en': 'Acceleration Records',
    },

    'ready': {
      'zh-TW': 'READY',
      'zh-CN': 'READY',
      'en': 'READY',
    },
    'mode_0_60': {
      'zh-TW': '0–60 km/h',
      'zh-CN': '0–60 km/h',
      'en': '0–60 km/h',
    },
    'mode_0_100': {
      'zh-TW': '0–100 km/h',
      'zh-CN': '0–100 km/h',
      'en': '0–100 km/h',
    },
    'mode_0_400m': {
      'zh-TW': '0–400 m',
      'zh-CN': '0–400 m',
      'en': '0–400 m',
    },
    'mode_100_200': {
      'zh-TW': '100–200 km/h',
      'zh-CN': '100–200 km/h',
      'en': '100–200 km/h',
    },

    'search_name_or_date': {
      'zh-TW': '搜尋名稱或日期',
      'zh-CN': '搜索名称或日期',
      'en': 'Search name or date',
    },
    'rename_record': {
      'zh-TW': '重新命名',
      'zh-CN': '重新命名',
      'en': 'Rename',
    },
    'delete_record': {
      'zh-TW': '刪除紀錄',
      'zh-CN': '删除记录',
      'en': 'Delete Record',
    },
    'confirm_delete_name': {
      'zh-TW': '確定刪除「%s」嗎？',
      'zh-CN': '确定删除「%s」吗？',
      'en': 'Delete “%s”?',
    },
    'rename': {
      'zh-TW': '重新命名',
      'zh-CN': '重新命名',
      'en': 'Rename',
    },
    'delete': {
      'zh-TW': '刪除',
      'zh-CN': '删除',
      'en': 'Delete',
    },

    'confirm': {
      'zh-TW': '確定',
      'zh-CN': '确定',
      'en': 'OK',
    },
    'recording': {
      'zh-TW': '紀錄中',
      'zh-CN': '纪录中',
      'en': 'recording',
    },
    // Camera / Recording page
    'camera_init_failed': {
      'zh-TW': '相機初始化失敗',
      'zh-CN': '相机初始化失败',
      'en': 'Camera init failed',
    },
    'camera_restore_failed': {
      'zh-TW': '相機恢復失敗',
      'zh-CN': '相机恢复失败',
      'en': 'Camera restore failed',
    },
    'recording_started': {
      'zh-TW': '開始錄影',
      'zh-CN': '开始录影',
      'en': 'Recording started',
    },
    'recording_start_failed': {
      'zh-TW': '開始錄影失敗',
      'zh-CN': '开始录影失败',
      'en': 'Failed to start recording',
    },
    'recording_stopped': {
      'zh-TW': '已停止錄影',
      'zh-CN': '已停止录影',
      'en': 'Recording stopped',
    },
    'recording_stop_failed': {
      'zh-TW': '停止錄影失敗',
      'zh-CN': '停止录影失败',
      'en': 'Failed to stop recording',
    },
    'recording_error': {
      'zh-TW': '錄影錯誤',
      'zh-CN': '录影错误',
      'en': 'Recording error',
    },
    'recording_saved_gallery': {
      'zh-TW': '影片已儲存到相簿',
      'zh-CN': '影片已储存到相簿',
      'en': 'Video saved to Photos',
    },
    'recording_save_failed': {
      'zh-TW': '儲存影片失敗',
      'zh-CN': '储存影片失败',
      'en': 'Failed to save video',
    },
    'photo_permission_needed': {
      'zh-TW': '需要相簿權限才能儲存錄影，請在設定中開啟。',
      'zh-CN': '需要相册权限才能储存录像，请在设置中开启。',
      'en': 'Photos permission is required to save the recording. Please enable it in Settings.',
    },
    'photo_permission_needed_title': {
      'zh-TW': '需要相簿權限',
      'zh-CN': '需要相册权限',
      'en': 'Photos Permission Needed',
    },
    'photo_permission_open_settings': {
      'zh-TW': '前往設定',
      'zh-CN': '前往设置',
      'en': 'Open Settings',
    },
    'photo_permission_cancel': {
      'zh-TW': '稍後',
      'zh-CN': '稍后',
      'en': 'Later',
    },
    'share_recording_prompt': {
      'zh-TW': '錄影完成，選擇要分享或儲存的方式',
      'zh-CN': '录影完成，选择要分享或储存的方式',
      'en': 'Recording finished — choose how to share or save',
    },
    'share_failed': {
      'zh-TW': '分享失敗',
      'zh-CN': '分享失败',
      'en': 'Share failed',
    },
    'start_recording_camera': {
      'zh-TW': '開始錄影',
      'zh-CN': '开始录影',
      'en': 'Start Recording',
    },
    'stop_recording': {
      'zh-TW': '停止錄影',
      'zh-CN': '停止录影',
      'en': 'Stop Recording',
    },
    //旅程清單
    'trips_search_hint': {
      'zh-TW': '搜尋旅程（名稱、日期、時間、距離）',
      'zh-CN': '搜索旅程（名称、日期、时间、距离）',
      'en': 'Search trips (name, date, time, distance)',
    },
    'trips_empty': {
      'zh-TW': '沒有符合的旅程',
      'zh-CN': '没有符合的旅程',
      'en': 'No trips found',
    },
    'clear_search': {
      'zh-TW': '清除搜尋',
      'zh-CN': '清除搜索',
      'en': 'Clear search',
    },
    'import': {
      'zh-TW': '匯入',
      'zh-CN': '导入',
      'en': 'Import',
    },
    'import_done_file': {
      'zh-TW': '已匯入檔案',
      'zh-CN': '已导入文件',
      'en': 'File imported',
    },
    'import_done': {
      'zh-TW': '匯入完成',
      'zh-CN': '导入完成',
      'en': 'Import completed',
    },
    'import_failed': {
      'zh-TW': '匯入失敗：{error}',
      'zh-CN': '导入失败：{error}',
      'en': 'Import failed: {error}',
    },
    'trip_delete_title': {
      'zh-TW': '刪除旅程',
      'zh-CN': '删除旅程',
      'en': 'Delete Trip',
    },
    'trip_delete_confirm': {
      'zh-TW': '確定要刪除「{name}」嗎？此動作無法復原。',
      'zh-CN': '确定要删除“{name}”吗？此操作无法恢复。',
      'en': 'Are you sure you want to delete "{name}"? This cannot be undone.',
    },

    'trip_deleted': {
      'zh-TW': '已刪除旅程',
      'zh-CN': '已删除旅程',
      'en': 'Trip deleted',
    },
    'delete_failed': {
      'zh-TW': '刪除失敗',
      'zh-CN': '删除失败',
      'en': 'Delete failed',
    },
    //旅程詳細頁
    'trip_load_failed': {
      'zh-TW': '無法載入旅程',
      'zh-CN': '无法载入旅程',
      'en': 'Failed to load trip',
    },
    'trip_detail_title': {
      'zh-TW': '旅程詳情',
      'zh-CN': '旅程详情',
      'en': 'Trip details',
    },
    'export_share': {
      'zh-TW': '匯出/分享',
      'zh-CN': '导出/分享',
      'en': 'Export/Share',
    },
    'export_failed': {
      'zh-TW': '匯出失敗：{error}',
      'zh-CN': '导出失败：{error}',
      'en': 'Export failed: {error}',
    },
    'edit_title': {
      'zh-TW': '編輯標題',
      'zh-CN': '编辑标题',
      'en': 'Edit title',
    },
    'title_updated': {
      'zh-TW': '已更新標題',
      'zh-CN': '已更新标题',
      'en': 'Title updated',
    },
    'update_failed': {
      'zh-TW': '更新失敗',
      'zh-CN': '更新失败',
      'en': 'Update failed',
    },

    'timestamp': {
      'zh-TW': '時間戳',
      'zh-CN': '时间戳',
      'en': 'Timestamp',
    },
    'speed': {
      'zh-TW': '速度',
      'zh-CN': '速度',
      'en': 'Speed',
    },

    'moving_time': {
      'zh-TW': '移動時間',
      'zh-CN': '移动时间',
      'en': 'Moving time',
    },

    'temperature': {
      'zh-TW': '溫度',
      'zh-CN': '温度',
      'en': 'Temperature',
    },
    'elevation_gain': {
      'zh-TW': '爬升',
      'zh-CN': '爬升',
      'en': 'Elevation gain',
    },
    'no_altitude_recorded': {
      'zh-TW': '此旅程未記錄海拔',
      'zh-CN': '此旅程未记录海拔',
      'en': 'No altitude recorded for this trip',
    },
    'about': {
      'zh-TW': '關於',
      'zh-CN': '关于',
      'en': 'About',
    },
    'about_author': {
      'zh-TW': '作者：tzuyi0406',
      'zh-CN': '作者：tzuyi0406',
      'en': 'Author: tzuyi0406',
    },
    'about_contact': {
      'zh-TW': '聯絡我們：tzuyichan0406@gmail.com',
      'zh-CN': '联系我们：tzuyichan0406@gmail.com',
      'en': 'Contact us: tzuyichan0406@gmail.com',
    },
    //旅程列表多語言
    // Trips list – selection / stats
    'stats_select': {
      'zh-TW': '選取統計',
      'zh-CN': '选择统计',
      'en': 'Select for stats',
    },
    'stats_cancel': {
      'zh-TW': '取消選取',
      'zh-CN': '取消选择',
      'en': 'Cancel selection',
    },
    'select_all': {
      'zh-TW': '全選',
      'zh-CN': '全选',
      'en': 'Select all',
    },
    'clear': {
      'zh-TW': '清除',
      'zh-CN': '清除',
      'en': 'Clear',
    },
    'stats_confirm': {
      'zh-TW': '統計',
      'zh-CN': '统计',
      'en': 'Stats',
    },
    'please_select_items': {
      'zh-TW': '請先選擇旅程',
      'zh-CN': '请先选择旅程',
      'en': 'Please select trips first',
    },
    'stats_result_title': {
      'zh-TW': '統計結果（{n}筆）',
      'zh-CN': '统计结果（{n}条）',
      'en': 'Statistics ({n})',
    },
    'total_distance': {
      'zh-TW': '總距離',
      'zh-CN': '总距离',
      'en': 'Total distance',
    },
    'total_moving': {
      'zh-TW': '總移動時間',
      'zh-CN': '总移动时间',
      'en': 'Total moving time',
    },
    'trip_count': {
      'zh-TW': '行程數',
      'zh-CN': '行程数',
      'en': 'Trips',
    },

    'ok': {
      'zh-TW': '好的',
      'zh-CN': '好的',
      'en': 'OK',
    },
    'ok_copy_link': {
      'zh-TW': '好的，複製連結',
      'zh-CN': '好的，复制链接',
      'en': 'OK, copy link',
    },
    'copied_link': {
      'zh-TW': '已複製 {link}',
      'zh-CN': '已复制 {link}',
      'en': 'Copied {link}',
    },
    // Stats range switcher
    'stats_tab_31d': {
      'zh-TW': '近31天',
      'zh-CN': '近31天',
      'en': 'Last 31 days',
    },
    'stats_tab_month': {
      'zh-TW': '月',
      'zh-CN': '月',
      'en': 'Month',
    },
    'stats_tab_year': {
      'zh-TW': '年',
      'zh-CN': '年',
      'en': 'Year',
    },
    // ===== Keys used by main.dart (added) =====
    'upgrade_paywall_title': {
      'zh-TW': '升級解鎖完整功能',
      'zh-CN': '升级解锁完整功能',
      'en': 'Upgrade to Unlock Everything',
    },
    'upgrade_paywall_message': {
      'zh-TW': '免費版僅能保存 1 筆旅程。升級為高級版即可移除限制、去除廣告，享受完整功能與更順暢的體驗。',
      'zh-CN': '免费版仅能保存 1 条旅程。升级为高级版即可移除限制、去除广告，享受完整功能与更流畅的体验。',
      'en':
          'Free version can save only 1 trip. Upgrade to Premium to remove this limit, skip ads, and enjoy the full experience.',
    },
    'upgrade_buy': {
      'zh-TW': '購買',
      'zh-CN': '购买',
      'en': 'Buy',
    },
    'thanks_for_upgrading_saved_now': {
      'zh-TW': '已保存旅程',
      'zh-CN': '已保存旅程',
      'en': 'The trip has been saved.',
    },
    'save_failed_try_again': {
      'zh-TW': '保存失敗，請再試一次',
      'zh-CN': '保存失败，请再试一次',
      'en': 'Save failed, please try again',
    },

    'upgrade_later': {
      'zh-TW': '下次再說',
      'zh-CN': '下次再说',
      'en': 'Maybe Later',
    },
    'purchase_failed_prefix': {
      'zh-TW': '購買失敗：',
      'zh-CN': '购买失败：',
      'en': 'Purchase failed: ',
    },
    'free_limit_one_unlock_vip': {
      'zh-TW': '免費版僅能保存 1 筆旅程。解鎖 VIP 後可不限筆並移除廣告。',
      'zh-CN': '免费版仅能保存 1 条旅程。解锁 VIP 后可不限条并移除广告。',
      'en':
          'Free version can save only 1 trip. Unlock VIP to save unlimited trips and remove ads.',
    },
    'trip_too_short_not_saved': {
      'zh-TW': '旅程太短，未保存',
      'zh-CN': '旅程太短，未保存',
      'en': 'Trip too short, not saved',
    },
    'moved_only': {
      'zh-TW': '移動僅',
      'zh-CN': '移动仅',
      'en': 'moved only',
    },
    'settings_menu': {
      'zh-TW': '系統設定',
      'zh-CN': '系统设置',
      'en': 'Settings',
    },
    'sec_abbr': {
      'zh-TW': '秒',
      'zh-CN': '秒',
      'en': 's',
    },
    'start_failed_prefix': {
      'zh-TW': '啟動失敗：',
      'zh-CN': '启动失败：',
      'en': 'Start failed: ',
    },
    'saved': {
      'zh-TW': '已保存',
      'zh-CN': '已保存',
      'en': 'Saved',
    },
    'saved_named_prefix': {
      'zh-TW': '已保存',
      'zh-CN': '已保存',
      'en': 'Saved',
    },
    'need_location_service_title': {
      'zh-TW': '需要定位服務',
      'zh-CN': '需要定位服务',
      'en': 'Location Services Required',
    },
    'need_location_service_msg': {
      'zh-TW': '請在「設定 > 隱私權與安全性 > 定位服務」中開啟定位，否則無法讀取速度與軌跡。',
      'zh-CN': '请在「设置 > 隐私与安全性 > 定位服务」中开启定位，否则无法读取速度与轨迹。',
      'en':
          'Please enable Location in Settings ▸ Privacy & Security ▸ Location Services, otherwise speed and track cannot be read.',
    },
    'need_location_permission_title': {
      'zh-TW': '需要定位權限',
      'zh-CN': '需要定位权限',
      'en': 'Location Permission Needed',
    },
    'need_location_permission_msg': {
      'zh-TW': '每次開啟都會再次提醒。請授予定位權限（建議「使用 App 期間」），才能顯示速度與地圖。',
      'zh-CN': '每次开启都会再次提醒。请授予定位权限（建议“使用 App 期间”），才能显示速度与地图。',
      'en':
          "You'll be reminded each time until granted. Please allow location (recommended: While Using the App) to show speed and map.",
    },
    'later': {
      'zh-TW': '稍後再說',
      'zh-CN': '稍后再说',
      'en': 'Later',
    },
    'go_settings': {
      'zh-TW': '前往設定',
      'zh-CN': '前往设置',
      'en': 'Open Settings',
    },
    // ===== Keys used by purchase_service.dart =====
    'purchase_stream_error_prefix': {
      'zh-TW': '購買事件串流錯誤：',
      'zh-CN': '购买事件流错误：',
      'en': 'Purchase stream error: ',
    },
    'iap_unavailable': {
      'zh-TW': '此裝置不支援內購。',
      'zh-CN': '此设备不支持内购。',
      'en': 'In-app purchases are not available on this device.',
    },
    'iap_query_failed_prefix': {
      'zh-TW': '產品查詢失敗：',
      'zh-CN': '产品查询失败：',
      'en': 'Product query failed: ',
    },
    'iap_product_not_found': {
      'zh-TW': '找不到產品，請檢查 App Store Connect / Play Console ID。',
      'zh-CN': '找不到产品，请检查 App Store Connect / Play Console 的 ID。',
      'en': 'Product not found. Check IDs in App Store Connect / Play Console.',
    },
    'iap_init_error_prefix': {
      'zh-TW': '內購初始化錯誤：',
      'zh-CN': '内购初始化错误：',
      'en': 'IAP init error: ',
    },
    'vip_not_ready': {
      'zh-TW': 'VIP 產品尚未就緒。',
      'zh-CN': 'VIP 产品尚未就绪。',
      'en': 'VIP product is not ready yet.',
    },
    'purchase_not_started': {
      'zh-TW': '未能啟動購買流程。',
      'zh-CN': '未能启动购买流程。',
      'en': 'Purchase flow not started.',
    },
    'purchase_start_failed_prefix': {
      'zh-TW': '啟動購買失敗：',
      'zh-CN': '启动购买失败：',
      'en': 'Failed to start purchase: ',
    },
    'restore_failed_prefix': {
      'zh-TW': '還原失敗：',
      'zh-CN': '恢复失败：',
      'en': 'Restore failed: ',
    },
    'purchase_error_unknown': {
      'zh-TW': '發生未知的購買錯誤',
      'zh-CN': '发生未知的购买错误',
      'en': 'Unknown purchase error',
    },
    'purchase_canceled': {
      'zh-TW': '已取消購買',
      'zh-CN': '已取消购买',
      'en': 'Purchase canceled',
    },
    'grant_vip_failed_prefix': {
      'zh-TW': '授予 VIP 失敗：',
      'zh-CN': '授予 VIP 失败：',
      'en': 'Failed to grant VIP: ',
    },
    'buy_vip_full': {
      'zh-TW': '購買高級功能（永久去除廣告、無限制旅程）',
      'zh-CN': '购买高级功能（永久去除广告、无限制旅程）',
      'en': 'Buy VIP (remove ads forever, unlimited trips)'
    },
    'restore_purchases_full': {
      'zh-TW': '還原購買（還原購買紀錄）',
      'zh-CN': '恢复购买（恢复购买记录）',
      'en': 'Restore purchases (restore purchase history)'
    },
    'qa_map_track': {
      'zh-TW': '地圖軌跡',
      'zh-CN': '地图轨迹',
      'en': 'Map Track',
    },
    'qa_accel_mode': {
      'zh-TW': '加速模式',
      'zh-CN': '加速模式',
      'en': 'Accel Mode',
    },
    'shortcut_hint': {
      'zh-TW': '捷徑小提示',
      'zh-CN': '快捷方式小提示',
      'en': 'Shortcuts tip',
    },
    'shortcut_hint_title': {
      'zh-TW': 'iOS 捷徑設定',
      'zh-CN': 'iOS 快捷方式设置',
      'en': 'iOS Shortcuts Setup',
    },
    'shortcut_hint_message': {
      'zh-TW':
          '在「捷徑」App 建立快速動作：\n1）新增動作：打開 URL\n2）輸入：gpssmeter://maptrack\n3）儲存為「地圖軌跡」，即可一鍵開啟地圖模式。\n\n進階：也可在「自動化」中新增「個人自動化」，選擇觸發條件後加入「打開 URL」，同樣填入上方連結。',
      'zh-CN':
          '在「快捷指令」App 里建立快速操作：\n1）新增动作：打开 URL\n2）输入：gpssmeter://maptrack\n3）保存为「地图轨迹」，即可一键打开地图模式。\n\n进阶：也可在「自动化」中新建「个人自动化」，选择触发条件后加入「打开 URL」，同样填入上述链接。',
      'en':
          'Create a quick action in the Shortcuts app:\n1) Add action: Open URL\n2) Enter: gpssmeter://maptrack\n3) Save as “Map Track” to open map mode in one tap.\n\nAdvanced: You can also create a Personal Automation, then add “Open URL” with the same link.',
    },
    'shortcut_fallback': {
      'zh-TW': '若取得捷徑連結失效，請前往 官方網站 點此',
      'zh-CN': '若获取捷径链接失效，请前往 官方网站 点击此处',
      'en':
          'If the shortcut link expires, please go to Official Website (tap here)',
    },
    'advanced': {
      'zh-TW': '進階設定',
      'zh-CN': '进阶设置',
      'en': 'Advanced',
    },
    'premium': {
      'zh-TW': '高級功能',
      'zh-CN': '高级功能',
      'en': 'Premium',
    },
    // 動作：匯出
    'export': {
      'zh-TW': '匯出',
      'zh-CN': '导出',
      'en': 'Export',
    },

// 匯出完成提示
    'export_done': {
      'zh-TW': '已匯出 {count} 個檔案',
      'zh-CN': '已导出 {count} 个文件',
      'en': 'Exported {count} file(s)',
    },

    'delete_selected_confirm': {
      'zh-TW': '確定要刪除 {count} 筆旅程？',
      'zh-CN': '确定要删除 {count} 条旅程？',
      'en': 'Delete {count} trip(s)?',
    },
    'delete_done': {
      'zh-TW': '已刪除 {count} 筆旅程',
      'zh-CN': '已删除 {count} 条旅程',
      'en': 'Deleted {count} trip(s)',
    },
    'restore_nothing': {
      'zh-TW': '沒有可還原的購買紀錄',
      'zh-CN': '没有可恢复的购买记录',
      'en': 'No purchases to restore',
    },
    'restoring_in_progress_hint': {
      'zh-TW': '正在還原中，請稍候…',
      'zh-CN': '正在恢复中，请稍候…',
      'en': 'Restoring… please wait',
    },
    'restoring_wait': {
      'zh-TW': '正在還原購買，請稍候…',
      'zh-CN': '正在恢复购买，请稍候…',
      'en': 'Restoring purchases… please wait',
    },
    'restore_success': {
      'zh-TW': '已恢復購買：高級功能已啟用',
      'zh-CN': '已恢复购买：高级功能已启用',
      'en': 'Purchases restored: Premium unlocked',
    },
    //加速頁面
    'select_mode': {'zh-TW': '選擇模式', 'zh-CN': '选择模式', 'en': 'Select'},

    'select_something_first': {
      'zh-TW': '請先選擇項目',
      'zh-CN': '请先选择项目',
      'en': 'Please select items first'
    },
    'enter_select_mode_hint': {
      'zh-TW': '已進入選擇模式',
      'zh-CN': '已进入选择模式',
      'en': 'Selection mode enabled'
    },
    'delete_hint_bottom': {
      'zh-TW': '選取要刪除的記錄，然後按下方「刪除」',
      'zh-CN': '选择要删除的记录，然后点下面的“删除”',
      'en': 'Select items to delete, then tap the Delete button below.'
    },
    'use_bottom_delete_button': {
      'zh-TW': '請使用下方刪除按鈕',
      'zh-CN': '请使用下方删除按钮',
      'en': 'Please use the Delete button at the bottom.'
    },

    'import_not_available': {
      'zh-TW': '匯入功能尚未安裝（需 file_picker）',
      'zh-CN': '导入功能尚未安装（需 file_picker）',
      'en': 'Import not available (needs file_picker)'
    },

    'export_success_prefix': {
      'zh-TW': '已匯出：',
      'zh-CN': '已导出：',
      'en': 'Exported: '
    },
    'export_failed_prefix': {
      'zh-TW': '匯出失敗：',
      'zh-CN': '导出失败：',
      'en': 'Export failed: '
    },

    'import_done_count': {
      'zh-TW': '已匯入 %d 筆',
      'zh-CN': '已导入 %d 条',
      'en': 'Imported %d items'
    },
    'import_failed_prefix': {
      'zh-TW': '匯入失敗：',
      'zh-CN': '导入失败：',
      'en': 'Import failed: '
    },
    'export_hint_bottom': {
      'zh-TW': '選取項目後，點下方「匯出」',
      'zh-CN': '选择项目后，点下方“匯出”',
      'en': 'Select items, then tap the Export button below'
    },
    'get_shortcut': {
      'zh-TW': '取得捷徑',
      'zh-CN': '获取捷径',
      'en': 'Get Shortcut',
    },
  };

  /// Translate a key using current app language or an override language.
  /// Usage: L10n.t('key', lang: 'zh-TW', params: {'name': 'Alice'})
  static String t(String key, {String? lang, Map<String, String>? params}) {
    final l = lang ?? Setting.instance.language.value;
    var out = _d[key]?[l] ?? _d[key]?['zh-TW'] ?? key;
    if (params != null && params.isNotEmpty) {
      params.forEach((k, v) {
        out = out.replaceAll('{$k}', v);
      });
    }
    return out;
  }
}

class SettingsPage extends StatefulWidget {
  final double initialMaxKmh;
  final Color initialThemeColor;
  final bool initialEnableBootAnimation;
  final bool initialEnableMockRoute;
  final bool initialUseMiles; // 新增：初始單位旗標
  final String initialLanguage; // 預設語言
  const SettingsPage({
    super.key,
    required this.initialMaxKmh,
    required this.initialThemeColor,
    required this.initialEnableBootAnimation,
    required this.initialEnableMockRoute,
    this.initialUseMiles = false,
    this.initialLanguage = 'zh-TW',
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late double _maxKmh;
  late Color _themeColor;
  late bool _enableBootAnimation;
  late bool _enableMockRoute;
  late bool _useMiles;
  late String _language;
  int? _lastStepDisplay; // 依據顯示單位，每移動一格(5)就震動
  bool _iapBusy = false; // 本地鎖，避免重複點擊購買
  bool _restoring = false; // 本地還原中的顯示狀態
  bool _enableBackgroundRecording = true; // 背景持續記錄（預設開啟）

  String get _unitLabel => _useMiles ? 'mph' : 'km/h';
  double _kmhToMph(double v) => v * 0.621371;
  double _mphToKmh(double v) => v / 0.621371;

  @override
  void initState() {
    super.initState();
    _maxKmh = widget.initialMaxKmh.clamp(60, 360);
    _themeColor = widget.initialThemeColor;
    _enableBootAnimation = widget.initialEnableBootAnimation;
    _enableMockRoute = widget.initialEnableMockRoute;
    _useMiles = widget.initialUseMiles;
    _language = widget.initialLanguage;
    // ignore: avoid_print
    print('SETTINGS[init] initialUseMiles=$_useMiles');
    // 初始化 haptic step
    final _displayNow = _useMiles ? _kmhToMph(_maxKmh) : _maxKmh;
    _lastStepDisplay = ((_displayNow / 5).round() * 5).toInt();
    // IAP 購買/還原完成後刷新畫面
    PurchaseService().onPurchaseUpdated = () {
      if (mounted) setState(() {});
    };
    // 讀取背景記錄偏好
    () async {
      final sp = await SharedPreferences.getInstance();
      if (!mounted) return;
      bool? stored = sp.getBool('enable_bg_recording');
      final v = stored ?? true; // 預設開啟
      // 首次啟動若沒有值，寫入預設 true 以持久化
      if (stored == null) {
        await sp.setBool('enable_bg_recording', true);
      }
      setState(() {
        _enableBackgroundRecording = v;
      });
      // propagate to global Setting so other pages可即時收到
      Setting.instance.backgroundRecording.value = v;
    }();
  }

  Future<void> _setBgRecording(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('enable_bg_recording', v);
    if (!mounted) return;
    setState(() => _enableBackgroundRecording = v);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          duration: const Duration(milliseconds: 500),
          content: Text(L10n.t(v ? 'bg_rec_enabled_tip' : 'bg_rec_disabled_tip',
              lang: _language))),
    );
    // 即時通知全域（由 main.dart 監聽並控制 TrackingService）
    Setting.instance.backgroundRecording.value = v;
  }

  void _confirmEnableBgRecording() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.t('bg_rec_enable_title', lang: _language)),
        content: Text(L10n.t('bg_rec_enable_msg', lang: _language)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(L10n.t('bg_rec_cancel', lang: _language)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _setBgRecording(true);
            },
            child: Text(L10n.t('confirm', lang: _language)),
          ),
        ],
      ),
    );
  }

  Future<void> _saveAndPop() async {
    // Update runtime singletons
    Setting.instance.useMph = _useMiles;
    Setting.instance.setLanguage(_language);
    // Persist to SharedPreferences so cold-start pages can read it
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(Setting._kUseMph, _useMiles);
      await sp.setString(Setting._kLanguage, _language);
      await sp.setDouble('max_kmh', _maxKmh);
      // ignore: avoid_print
      print(
          'SETTINGS[persist] useMph=$_useMiles language=$_language maxKmh=$_maxKmh');
    } catch (e) {
      // ignore: avoid_print
      print('SETTINGS[persist] failed: $e');
    }
    if (!mounted) return;
    Navigator.of(context).pop(SettingsData(
      maxKmh: _maxKmh,
      themeColor: _themeColor,
      enableBootAnimation: _enableBootAnimation,
      enableMockRoute: _enableMockRoute,
      useMiles: _useMiles,
      language: _language,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        await _saveAndPop();
        return false; // we handled pop
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(L10n.t('settings', lang: _language)),
          actions: [
            IconButton(
              tooltip: L10n.t('about', lang: _language),
              icon: const Icon(Icons.info_outline),
              onPressed: _showAboutDialog,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('${L10n.t('speed_limit', lang: _language)}（$_unitLabel）',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    min: _useMiles ? _kmhToMph(60) : 60,
                    max: _useMiles ? _kmhToMph(360) : 360,
                    divisions: ((_useMiles
                                ? (_kmhToMph(360) - _kmhToMph(60))
                                : (360 - 60)) /
                            5)
                        .round(),
                    value: _useMiles ? _kmhToMph(_maxKmh) : _maxKmh,
                    label: (_useMiles ? _kmhToMph(_maxKmh) : _maxKmh)
                        .round()
                        .toString(),
                    onChanged: (v) {
                      final roundedDisplay =
                          (v / 5).round() * 5; // 以顯示單位每 5 為一格
                      // 轉回 km/h 儲存
                      final kmh = _useMiles
                          ? _mphToKmh(roundedDisplay.toDouble())
                          : roundedDisplay.toDouble();
                      setState(() => _maxKmh = kmh.clamp(60, 360));

                      // 只有跨過一格(5)時才震動
                      if (_lastStepDisplay != roundedDisplay) {
                        _lastStepDisplay = roundedDisplay;
                        HapticFeedback.selectionClick();
                      }
                    },
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: Text(
                      (_useMiles ? _kmhToMph(_maxKmh) : _maxKmh)
                          .round()
                          .toString(),
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(L10n.t('theme_color', lang: _language),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SizedBox(
              height: 56,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  const SizedBox(width: 4),
                  _buildColorOption(Colors.green),
                  _buildColorOption(Colors.blue),
                  _buildColorOption(Colors.red),
                  _buildColorOption(Colors.orange),
                  _buildColorOption(Colors.purple),
                  _buildColorOption(Colors.yellow),
                  _buildColorOption(Colors.redAccent),
                  _buildColorOption(Colors.orangeAccent),
                  _buildColorOption(Colors.blueAccent),
                  _buildColorOption(Colors.pinkAccent),
                  _buildColorOption(Colors.purpleAccent),
                  _buildColorOption(Colors.pink),
                  _buildColorOption(Colors.teal),
                  _buildColorOption(Colors.amber),
                  _buildColorOption(Colors.brown),
                  _buildColorOption(Colors.cyan),
                  _buildColorOption(Colors.indigo),
                  _buildColorOption(Colors.lime),
                  _buildColorOption(Colors.deepOrange),
                  _buildColorOption(Colors.deepPurple),
                  _buildColorOption(Colors.lightBlue),
                  _buildColorOption(Colors.lightGreen),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            const SizedBox(height: 24),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(L10n.t('advanced', lang: _language),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              children: [
                SwitchListTile(
                  title: Text(L10n.t('boot_anim', lang: _language)),
                  value: _enableBootAnimation,
                  onChanged: (v) => setState(() => _enableBootAnimation = v),
                ),
                SwitchListTile(
                  title: Text(L10n.t('mock_mode', lang: _language)),
                  value: _enableMockRoute,
                  onChanged: (v) => setState(() => _enableMockRoute = v),
                ),
              ],
            ),
            SwitchListTile(
              title: Text(L10n.t('unit_mph_title', lang: _language)),
              subtitle: Text(L10n.t('unit_mph_sub', lang: _language)),
              value: _useMiles,
              onChanged: (v) => setState(() => _useMiles = v),
            ),
            SwitchListTile(
              title: Text(L10n.t('bg_rec_title', lang: _language)),
              subtitle: Text(L10n.t('bg_rec_sub', lang: _language)),
              value: _enableBackgroundRecording,
              onChanged: (v) {
                if (v) {
                  _confirmEnableBgRecording();
                } else {
                  _setBgRecording(false);
                }
              },
            ),
            const SizedBox(height: 24),
            Text(L10n.t('language', lang: _language),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.language),
              title: Text(
                _language == 'zh-TW'
                    ? L10n.t('opt_zhTW', lang: _language)
                    : _language == 'zh-CN'
                        ? L10n.t('opt_zhCN', lang: _language)
                        : L10n.t('opt_en', lang: _language),
              ),
              trailing: DropdownButton<String>(
                value: _language,
                onChanged: (v) => setState(() => _language = v ?? 'zh-TW'),
                items: [
                  DropdownMenuItem(
                      value: 'zh-TW',
                      child: Text(L10n.t('opt_zhTW', lang: _language))),
                  DropdownMenuItem(
                      value: 'zh-CN',
                      child: Text(L10n.t('opt_zhCN', lang: _language))),
                  DropdownMenuItem(
                      value: 'en',
                      child: Text(L10n.t('opt_en', lang: _language))),
                ],
              ),
            ),
            const SizedBox(height: 24),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lightbulb_outline),
              title: Text(L10n.t('shortcut_hint', lang: _language)),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showShortcutHint,
            ),
            Text(L10n.t('premium', lang: _language),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Builder(builder: (context) {
              final vip = PurchaseService().isPremiumUnlocked;
              final busy = _iapBusy;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: (vip || busy)
                        ? null
                        : () async {
                            setState(() => _iapBusy = true);
                            try {
                              final ok =
                                  await PurchaseService().buyPremium(context);
                              if (!ok && context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      duration:
                                          const Duration(milliseconds: 500),
                                      content: Text(L10n.t(
                                          'purchase_not_started',
                                          lang: _language))),
                                );
                              }
                            } catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    duration: const Duration(milliseconds: 500),
                                    content: Text(
                                        '${L10n.t('purchase_start_failed_prefix', lang: _language)}$e')),
                              );
                            } finally {
                              if (mounted) setState(() => _iapBusy = false);
                            }
                          },
                    icon: const Icon(Icons.workspace_premium_outlined),
                    label: Text(L10n.t('buy_vip_full', lang: _language)),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: (busy || _restoring)
                        ? null
                        : () async {
                            setState(() => _restoring = true);
                            try {
                              await PurchaseService().restore();
                              // 與轉盤 App 一致：成功才隱藏廣告 + 顯示感謝視窗
                              if (PurchaseService().isPremiumUnlocked) {
                                try {
                                  // 若你的 AdService 沒有這個方法，請改為你現有的隱藏/銷毀 Banner 實作
                                  AdService.instance.hideBannerAd();
                                } catch (_) {}
                                if (mounted) _showThankYouDialog();
                              } else {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        duration:
                                            const Duration(milliseconds: 500),
                                        content: Text(L10n.t('restore_nothing',
                                            lang: _language))),
                                  );
                                }
                              }
                            } catch (e) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  duration: const Duration(milliseconds: 500),
                                  content: Text(
                                    '${L10n.t('restore_failed_prefix', lang: _language)}$e',
                                  ),
                                ),
                              );
                            } finally {
                              if (mounted) setState(() => _restoring = false);
                            }
                          },
                    icon: const Icon(Icons.restore_outlined),
                    label:
                        Text(L10n.t('restore_purchases_full', lang: _language)),
                  ),
                  if (_restoring) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          L10n.t('restoring_in_progress_hint', lang: _language),
                          style: const TextStyle(
                              fontSize: 12, fontStyle: FontStyle.italic),
                        ),
                      ],
                    ),
                  ],
                  if (vip) ...[
                    const SizedBox(height: 8),
                    Text(
                      L10n.t('saved', lang: _language),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 12, fontStyle: FontStyle.italic),
                    ),
                  ],
                ],
              );
            }),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () async => await _saveAndPop(),
              icon: const Icon(Icons.check),
              label: Text(L10n.t('save', lang: _language)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildColorOption(Color c) {
    return GestureDetector(
      onTap: () {
        setState(() => _themeColor = c);
        // 立即套用到全域主題（主程式應監聽 Setting.instance.themeSeed）
        try {
          Setting.instance.setThemeSeed(c);
        } catch (_) {}
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(
            color: _themeColor == c ? Colors.white : Colors.transparent,
            width: 2,
          ),
        ),
      ),
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.t('about', lang: _language)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(L10n.t('about_author', lang: _language)),
            const SizedBox(height: 8),
            Text(L10n.t('about_contact', lang: _language)),
          ],
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.language),
            label: Text(L10n.t('official_website', lang: _language)),
            onPressed: () async {
              const url = 'https://yi0406.github.io/tzuyiwebs/index.html';
              await launchUrl(Uri.parse(url),
                  mode: LaunchMode.externalApplication);
            },
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(L10n.t('confirm', lang: _language)),
          ),
        ],
      ),
    );
  }

  Future<void> _openShortcutLink() async {
    const url =
        'https://www.icloud.com/shortcuts/76f72ab8b12049d9960038645f5c3d26';
    final uri = Uri.parse(url);
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (_) {
      // ignore
    }
  }

  void _showShortcutHint() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.t('shortcut_hint_title', lang: _language)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(L10n.t('shortcut_hint_message', lang: _language)),
            const SizedBox(height: 12),
            InkWell(
              onTap: () async {
                const url = 'https://yi0406.github.io/tzuyiwebs/gps.html';
                await launchUrl(Uri.parse(url),
                    mode: LaunchMode.externalApplication);
              },
              child: Text(
                L10n.t('shortcut_fallback', lang: _language),
                style: const TextStyle(
                  color: Colors.blue,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton.icon(
            onPressed: _openShortcutLink,
            icon: const Icon(Icons.link),
            label: Text(L10n.t('get_shortcut', lang: _language)),
          ),
          TextButton(
            onPressed: () async {
              const link = 'gpssmeter://maptrack';
              await Clipboard.setData(const ClipboardData(text: link));
              if (context.mounted) {
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    duration: const Duration(milliseconds: 500),
                    content: Text(
                      L10n.t('copied_link',
                          lang: _language, params: {'link': link}),
                    ),
                  ),
                );
              }
            },
            child: Text(L10n.t('ok_copy_link', lang: _language)),
          ),
        ],
      ),
    );
  }

  void _showThankYouDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.t('premium', lang: _language)),
        content: Text(L10n.t('restore_success', lang: _language)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(L10n.t('ok', lang: _language)),
          ),
        ],
      ),
    );
  }
}
