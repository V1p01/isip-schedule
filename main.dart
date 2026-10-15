import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Единственный источник данных расписания (Яндекс 360 Документы)
const String kScheduleUrl =
    'https://docs.360.yandex.ru/view/d/eSjfjNM06Zcyzwqv5124yiPegnqahzm72s0qoIz-cKg6Y1haOWRpYXFSZw';

/// Целевая учебная группа (жёсткий фильтр)
const String kTargetGroup = 'ИСИП-25-4';

/// Ключи локального кэша
const String kCacheKeyScheduleJson = 'cached_schedule_isip_25_4_v3';
const String kCacheKeyUpdatedAt = 'cached_schedule_updated_at_v3';
const String kCacheKeyThemeMode = 'cached_theme_mode_v3';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru_RU', null);
  runApp(const IsipScheduleApp());
}

/// Корневой виджет приложения с поддержкой светлой и тёмной темы
class IsipScheduleApp extends StatefulWidget {
  const IsipScheduleApp({super.key});

  @override
  State<IsipScheduleApp> createState() => _IsipScheduleAppState();
}

class _IsipScheduleAppState extends State<IsipScheduleApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadThemePreference();
  }

  Future<void> _loadThemePreference() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(kCacheKeyThemeMode);
    if (!mounted || saved == null) return;
    setState(() {
      if (saved == 'light') {
        _themeMode = ThemeMode.light;
      } else if (saved == 'dark') {
        _themeMode = ThemeMode.dark;
      } else {
        _themeMode = ThemeMode.system;
      }
    });
  }

  Future<void> _toggleTheme() async {
    final brightness = MediaQuery.platformBrightnessOf(context);
    final isCurrentlyDark = _themeMode == ThemeMode.dark ||
        (_themeMode == ThemeMode.system && brightness == Brightness.dark);
    final nextMode = isCurrentlyDark ? ThemeMode.light : ThemeMode.dark;

    setState(() {
      _themeMode = nextMode;
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      kCacheKeyThemeMode,
      nextMode == ThemeMode.dark ? 'dark' : 'light',
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ИСИП-25-4 Расписание',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: ScheduleHomeScreen(
        themeMode: _themeMode,
        onToggleTheme: _toggleTheme,
      ),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0F141C) : const Color(0xFFF6F8FB);
    final cardColor = isDark ? const Color(0xFF18202C) : Colors.white;
    final primaryColor =
        isDark ? const Color(0xFF5B9BFF) : const Color(0xFF1A56DB);

    final colorScheme = ColorScheme.fromSeed(
      seedColor: primaryColor,
      brightness: brightness,
      primary: primaryColor,
      surface: cardColor,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: bgColor,
      colorScheme: colorScheme,
      cardTheme: CardTheme(
        color: cardColor,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isDark
                ? Colors.white.withOpacity(0.08)
                : const Color(0xFFE2E8F0),
            width: 1,
          ),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bgColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: isDark ? Colors.white : const Color(0xFF0F172A),
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.4,
        ),
      ),
    );
  }
}

/// Модель одной учебной пары
class LessonItem {
  final int lessonNumber;
  final String timeRange;
  final String subject;
  final String classroom;
  final String teacher;

  const LessonItem({
    required this.lessonNumber,
    required this.timeRange,
    required this.subject,
    required this.classroom,
    required this.teacher,
  });

  Map<String, dynamic> toJson() => {
        'lessonNumber': lessonNumber,
        'timeRange': timeRange,
        'subject': subject,
        'classroom': classroom,
        'teacher': teacher,
      };

  factory LessonItem.fromJson(Map<String, dynamic> json) {
    return LessonItem(
      lessonNumber: (json['lessonNumber'] as num?)?.toInt() ?? 1,
      timeRange: (json['timeRange'] as String?) ?? '',
      subject: (json['subject'] as String?) ?? '',
      classroom: (json['classroom'] as String?) ?? '',
      teacher: (json['teacher'] as String?) ?? '',
    );
  }
}

/// Модель расписания на все найденные в документе даты
class ScheduleDataBundle {
  /// Карта: ключ даты 'YYYY-MM-DD' -> список пар для группы ИСИП-25-4
  final Map<String, List<LessonItem>> lessonsByIsoDate;

  /// Пары, привязанные к дню недели (1 = Пн .. 7 = Вс), если в таблице указан только день недели
  final Map<int, List<LessonItem>> lessonsByWeekday;

  /// Пары без явной даты (если в документе выложена таблица на один текущий день без заголовка даты)
  final List<LessonItem> undatedLessons;

  /// Время последнего успешного обновления
  final DateTime fetchedAt;

  /// Краткая диагностическая сводка парсинга
  final String parserDiagnostic;

  const ScheduleDataBundle({
    required this.lessonsByIsoDate,
    this.lessonsByWeekday = const {},
    this.undatedLessons = const [],
    required this.fetchedAt,
    this.parserDiagnostic = '',
  });

  /// Возвращает список пар для конкретной даты с учётом точной даты, дня недели или единой таблицы
  List<LessonItem> lessonsForDate(DateTime date, {required bool isTodayTab}) {
    final iso = Yandex360ScheduleParser.isoKey(date);
    final exact = lessonsByIsoDate[iso];
    if (exact != null && exact.isNotEmpty) {
      return exact;
    }
    final byWd = lessonsByWeekday[date.weekday];
    if (byWd != null && byWd.isNotEmpty) {
      return byWd;
    }
    if (isTodayTab &&
        lessonsByIsoDate.values.every((l) => l.isEmpty) &&
        lessonsByWeekday.values.every((l) => l.isEmpty) &&
        undatedLessons.isNotEmpty) {
      return undatedLessons;
    }
    return const [];
  }

  bool get hasAnyLessons =>
      lessonsByIsoDate.values.any((l) => l.isNotEmpty) ||
      lessonsByWeekday.values.any((l) => l.isNotEmpty) ||
      undatedLessons.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'fetchedAt': fetchedAt.toIso8601String(),
        'parserDiagnostic': parserDiagnostic,
        'lessonsByIsoDate': lessonsByIsoDate.map(
          (key, value) => MapEntry(
            key,
            value.map((e) => e.toJson()).toList(),
          ),
        ),
        'lessonsByWeekday': lessonsByWeekday.map(
          (key, value) => MapEntry(
            key.toString(),
            value.map((e) => e.toJson()).toList(),
          ),
        ),
        'undatedLessons': undatedLessons.map((e) => e.toJson()).toList(),
      };

  factory ScheduleDataBundle.fromJson(Map<String, dynamic> json) {
    final rawMap =
        (json['lessonsByIsoDate'] as Map<String, dynamic>?) ?? const {};
    final parsedMap = <String, List<LessonItem>>{};
    for (final entry in rawMap.entries) {
      final list = (entry.value as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(LessonItem.fromJson)
          .toList();
      parsedMap[entry.key] = list;
    }

    final rawWdMap =
        (json['lessonsByWeekday'] as Map<String, dynamic>?) ?? const {};
    final parsedWdMap = <int, List<LessonItem>>{};
    for (final entry in rawWdMap.entries) {
      final wd = int.tryParse(entry.key);
      if (wd != null) {
        final list = (entry.value as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(LessonItem.fromJson)
            .toList();
        parsedWdMap[wd] = list;
      }
    }

    final undated = (json['undatedLessons'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(LessonItem.fromJson)
        .toList();

    return ScheduleDataBundle(
      lessonsByIsoDate: parsedMap,
      lessonsByWeekday: parsedWdMap,
      undatedLessons: undated,
      fetchedAt: DateTime.tryParse((json['fetchedAt'] as String?) ?? '') ??
          DateTime.now(),
      parserDiagnostic: (json['parserDiagnostic'] as String?) ?? '',
    );
  }
}

/// Главный экран приложения расписания для группы ИСИП-25-4
class ScheduleHomeScreen extends StatefulWidget {
  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;

  const ScheduleHomeScreen({
    super.key,
    required this.themeMode,
    required this.onToggleTheme,
  });

  @override
  State<ScheduleHomeScreen> createState() => _ScheduleHomeScreenState();
}

class _ScheduleHomeScreenState extends State<ScheduleHomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;

  /// Базовая системная дата («Сегодня»), усечённая до полуночи
  DateTime _anchorToday = _stripTime(DateTime.now());

  /// Таймеры автоматического сдвига дат после 00:00
  Timer? _midnightTimer;
  Timer? _periodicDateCheckTimer;

  /// Состояние загрузки и кэша
  bool _isLoading = false;
  bool _isOfflineFallback = false;
  bool _needsCaptchaVerification = false;
  bool _isDocumentSheetOpen = false;
  String? _statusMessage;
  String _loadingProgressText = 'Подключение к Яндекс 360...';
  ScheduleDataBundle? _scheduleBundle;

  /// Встроенный контроллер WebView (смонтирован в дереве виджетов для полноценного рендеринга JS-таблиц)
  late final WebViewController _webViewController;
  bool _isWebViewPageFinished = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });

    _initMountedWebView();
    _scheduleMidnightRollover();
    _loadCachedThenFetchFresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _midnightTimer?.cancel();
    _periodicDateCheckTimer?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAndApplyDateRollover(forceRefreshOnNewDay: true);
    }
  }

  static DateTime _stripTime(DateTime dt) =>
      DateTime(dt.year, dt.month, dt.day);

  void _scheduleMidnightRollover() {
    _midnightTimer?.cancel();
    _periodicDateCheckTimer?.cancel();

    final now = DateTime.now();
    final nextMidnight =
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    final durationUntilMidnight =
        nextMidnight.difference(now) + const Duration(seconds: 1);

    _midnightTimer = Timer(durationUntilMidnight, () {
      _checkAndApplyDateRollover(forceRefreshOnNewDay: true);
      _scheduleMidnightRollover();
    });

    _periodicDateCheckTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _checkAndApplyDateRollover(forceRefreshOnNewDay: true),
    );
  }

  void _checkAndApplyDateRollover({bool forceRefreshOnNewDay = false}) {
    final currentSystemDay = _stripTime(DateTime.now());
    if (currentSystemDay != _anchorToday) {
      setState(() {
        _anchorToday = currentSystemDay;
      });
      if (forceRefreshOnNewDay) {
        _fetchAndParseSchedule();
      }
    }
  }

  /// Инициализируем WebView с десктопным User-Agent, чтобы Яндекс 360 отрисовывал всю таблицу целиком
  void _initMountedWebView() {
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            _isWebViewPageFinished = false;
          },
          onPageFinished: (_) {
            _isWebViewPageFinished = true;
          },
        ),
      );
  }

  Future<void> _loadCachedThenFetchFresh() async {
    await _loadFromCache();
    await _fetchAndParseSchedule();
  }

  Future<void> _loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedJson = prefs.getString(kCacheKeyScheduleJson);
      if (cachedJson != null && cachedJson.isNotEmpty) {
        final decoded = jsonDecode(cachedJson) as Map<String, dynamic>;
        final bundle = ScheduleDataBundle.fromJson(decoded);
        if (mounted && bundle.hasAnyLessons) {
          setState(() {
            _scheduleBundle = bundle;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _saveToCache(ScheduleDataBundle bundle) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      kCacheKeyScheduleJson,
      jsonEncode(bundle.toJson()),
    );
    await prefs.setString(
      kCacheKeyUpdatedAt,
      bundle.fetchedAt.toIso8601String(),
    );
  }

  /// Основной цикл загрузки и парсинга расписания из Яндекс 360
  Future<void> _fetchAndParseSchedule() async {
    _checkAndApplyDateRollover(forceRefreshOnNewDay: false);

    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _statusMessage = null;
      _needsCaptchaVerification = false;
      _loadingProgressText = 'Загрузка документа из Яндекс 360...';
    });

    final targetDates = <DateTime>[
      _anchorToday,
      _anchorToday.add(const Duration(days: 1)),
      _anchorToday.add(const Duration(days: 2)),
    ];

    try {
      ScheduleDataBundle? parsedBundle;
      bool captchaDetected = false;

      // Этап 1: Загружаем страницу в смонтированный WebView и опрашиваем DOM по мере отрисовки
      final webViewBundle = await _pollWebViewAndExtractSchedule(targetDates);
      if (webViewBundle.isCaptcha) {
        captchaDetected = true;
      } else if (webViewBundle.bundle != null &&
          webViewBundle.bundle!.hasAnyLessons) {
        parsedBundle = webViewBundle.bundle;
      }

      // Этап 2: Если в WebView нашли прямую ссылку на скачивание файла (.xlsx / .docx),
      // скачиваем и разбираем бинарный архив документа
      if (parsedBundle == null || !parsedBundle.hasAnyLessons) {
        try {
          final directUrl = webViewBundle.downloadUrl;
          if (directUrl != null && directUrl.startsWith('http')) {
            final fileResp = await http
                .get(Uri.parse(directUrl))
                .timeout(const Duration(seconds: 12));
            if (fileResp.statusCode == 200 &&
                fileResp.bodyBytes.length > 4 &&
                fileResp.bodyBytes[0] == 0x50 &&
                fileResp.bodyBytes[1] == 0x4B) {
              parsedBundle = Yandex360ScheduleParser.parseOfficeArchiveBytes(
                fileResp.bodyBytes,
                targetDates: targetDates,
              );
            }
          }
        } catch (_) {}
      }

      if (captchaDetected &&
          (parsedBundle == null || !parsedBundle.hasAnyLessons)) {
        setState(() {
          _isLoading = false;
          _isOfflineFallback = _scheduleBundle != null;
          _needsCaptchaVerification = true;
          _statusMessage =
              'Яндекс запросил подтверждение (SmartCaptcha). '
              'Нажмите «Открыть документ», отметьте галочку «Я не робот» и нажмите «Считать».';
        });
        return;
      }

      final effectiveBundle = parsedBundle ?? webViewBundle.bundle;
      if (effectiveBundle != null) {
        if (effectiveBundle.hasAnyLessons) {
          await _saveToCache(effectiveBundle);
        }
        if (mounted) {
          setState(() {
            if (effectiveBundle.hasAnyLessons || _scheduleBundle == null) {
              _scheduleBundle = effectiveBundle;
            }
            _isLoading = false;
            _isOfflineFallback = false;
            _needsCaptchaVerification = false;
            _statusMessage = effectiveBundle.hasAnyLessons
                ? null
                : 'В документе не удалось автоматически распознать пары для «ИСИП-25-4». '
                    'Нажмите «Открыть документ» вверху справа, дождитесь загрузки таблицы и нажмите «Считать».';
          });
        }
      } else {
        throw Exception('Пустой ответ от сервера');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isOfflineFallback = true;
        _statusMessage = _scheduleBundle != null
            ? 'Нет связи с сервером. Показано сохранённое расписание из памяти устройства.'
            : 'Не удалось загрузить расписание. Проверьте интернет или нажмите «Открыть документ» вверху.';
      });
    }
  }

  /// Загружает документ в смонтированный WebView, ждёт завершения JS-рендеринга Яндекс 360,
  /// прокручивает страницы и извлекает как HTML-таблицы, так и пространственную сетку координат
  Future<_WebViewExtractionResult> _pollWebViewAndExtractSchedule(
    List<DateTime> targetDates,
  ) async {
    try {
      _isWebViewPageFinished = false;
      await _webViewController.loadRequest(Uri.parse(kScheduleUrl));

      ScheduleDataBundle? bestBundle;
      String? discoveredDownloadUrl;

      // Опрашиваем DOM до 18 раз (каждые 900 мс), пока Яндекс Документы рендерят страницы
      for (int attempt = 1; attempt <= 18; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
        if (!mounted) break;

        if (attempt >= 3) {
          setState(() {
            _loadingProgressText =
                'Чтение таблиц расписания ИСИП-25-4 (шаг $attempt)...';
          });
        }

        final rawJson = await _runJsDomAndSpatialExtractor(
          scrollStep: attempt,
        );
        if (rawJson.isEmpty) continue;

        Map<String, dynamic> payload;
        try {
          payload = jsonDecode(rawJson) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }

        if (payload['isCaptcha'] == true) {
          return const _WebViewExtractionResult(isCaptcha: true);
        }

        final dlUrl = payload['downloadUrl'] as String?;
        if (dlUrl != null && dlUrl.isNotEmpty) {
          discoveredDownloadUrl = dlUrl;
        }

        final hasTargetText = payload['hasTargetGroupText'] == true;
        final isStillLoading = payload['isStillLoading'] == true;

        final candidateBundle = Yandex360ScheduleParser.parseExtractedPayload(
          payload: payload,
          targetDates: targetDates,
        );

        if (candidateBundle.hasAnyLessons) {
          bestBundle = candidateBundle;
          if (attempt >= 4 && !isStillLoading) {
            return _WebViewExtractionResult(
              isCaptcha: false,
              bundle: bestBundle,
              downloadUrl: discoveredDownloadUrl,
            );
          }
        } else {
          bestBundle ??= candidateBundle;
        }

        if (_isWebViewPageFinished &&
            !isStillLoading &&
            attempt >= 8 &&
            hasTargetText) {
          break;
        }
      }

      return _WebViewExtractionResult(
        isCaptcha: false,
        bundle: bestBundle,
        downloadUrl: discoveredDownloadUrl,
      );
    } catch (_) {
      return const _WebViewExtractionResult(isCaptcha: false);
    }
  }

  /// JS-экстрактор: прокручивает документ, извлекает HTML-таблицы с заголовками над ними,
  /// а также строит пространственную 2D-таблицу по координатам getBoundingClientRect()
  Future<String> _runJsDomAndSpatialExtractor({required int scrollStep}) async {
    final jsCode = '''
      (function() {
        try {
          var href = window.location.href || '';
          var title = document.title || '';
          var bodyText = (document.body && document.body.innerText) ? document.body.innerText : '';

          var isCaptcha = !!(
            document.querySelector('.CheckboxCaptcha') ||
            document.querySelector('#captcha-form') ||
            href.indexOf('showcaptcha') !== -1 ||
            title.indexOf('Ой!') !== -1 ||
            title.indexOf('Captcha') !== -1
          );

          // Плавная прокрутка контейнеров документа для подгрузки ленивых страниц Яндекс 360
          var scrollContainers = document.querySelectorAll('.pages, .doc-viewer, .b-doc-viewer, .spreadsheet-container, [role="grid"], .ya-scroll-container');
          for (var sc = 0; sc < scrollContainers.length; sc++) {
            scrollContainers[sc].scrollTop = (${scrollStep - 1} % 5) * 500;
          }
          window.scrollTo(0, (${scrollStep - 1} % 5) * 500);

          var loaders = document.querySelectorAll('.spin2, .loader, .doc-loader, .b-spin, [class*="loading"], [class*="spinner"]');
          var visibleLoader = false;
          for (var l = 0; l < loaders.length; l++) {
            var r = loaders[l].getBoundingClientRect();
            if (r.width > 5 && r.height > 5) {
              visibleLoader = true;
              break;
            }
          }

          var roots = [document];
          var iframes = document.querySelectorAll('iframe');
          for (var f = 0; f < iframes.length; f++) {
            try {
              var idoc = iframes[f].contentDocument || (iframes[f].contentWindow && iframes[f].contentWindow.document);
              if (idoc && idoc.body) {
                roots.push(idoc);
                bodyText += '\\n' + (idoc.body.innerText || '');
              }
            } catch (e) {}
          }

          var downloadUrl = '';
          var links = document.querySelectorAll('a[href], button[data-url]');
          for (var a = 0; a < links.length; a++) {
            var h = links[a].getAttribute('href') || links[a].getAttribute('data-url') || '';
            if (h.indexOf('download') !== -1 || h.indexOf('cloud-api.yandex') !== -1 || h.indexOf('downloader.disk.yandex') !== -1) {
              downloadUrl = h;
              break;
            }
          }

          // 1. Извлекаем все <table> вместе с предшествующими им заголовками дат (<p>, <h1>..<h4>, <div>)
          var extractedTables = [];
          for (var d = 0; d < roots.length; d++) {
            var docRoot = roots[d];
            var tables = docRoot.querySelectorAll('table');
            for (var t = 0; t < tables.length; t++) {
              var tbl = tables[t];
              var contextBefore = [];
              var prev = tbl.previousElementSibling;
              var hops = 0;
              while (prev && hops < 6) {
                if (prev.tagName && prev.tagName.toLowerCase() === 'table') break;
                var pt = (prev.innerText || prev.textContent || '').trim();
                if (pt) contextBefore.unshift(pt);
                prev = prev.previousElementSibling;
                hops++;
              }
              if (contextBefore.length === 0 && tbl.parentElement) {
                var pPrev = tbl.parentElement.previousElementSibling;
                var pHops = 0;
                while (pPrev && pHops < 4) {
                  var ppt = (pPrev.innerText || pPrev.textContent || '').trim();
                  if (ppt && ppt.length < 300) contextBefore.unshift(ppt);
                  pPrev = pPrev.previousElementSibling;
                  pHops++;
                }
              }
              extractedTables.push({
                headingBefore: contextBefore.join('\\n'),
                tableHtml: tbl.outerHTML
              });
            }
          }

          // 2. Пространственная реконструкция таблиц по координатам getBoundingClientRect()
          var spatialItems = [];
          for (var rIdx = 0; rIdx < roots.length; rIdx++) {
            var allEls = roots[rIdx].querySelectorAll('span, div, p, td, th, [role="gridcell"], [role="columnheader"]');
            for (var i = 0; i < allEls.length; i++) {
              var el = allEls[i];
              if (el.children.length > 0 && el.tagName !== 'TD' && el.tagName !== 'TH') continue;
              var txt = (el.innerText || el.textContent || '').trim();
              if (!txt || txt.length > 220) continue;
              var rect = el.getBoundingClientRect();
              if (rect.width < 4 || rect.height < 4) continue;
              spatialItems.push({
                t: txt,
                x: Math.round(rect.left + window.scrollX),
                r: Math.round(rect.right + window.scrollX),
                y: Math.round(rect.top + window.scrollY)
              });
            }
          }

          spatialItems.sort(function(a, b) {
            if (Math.abs(a.y - b.y) <= 10) return a.x - b.x;
            return a.y - b.y;
          });

          var spatialRows = [];
          var currentRow = [];
          var currentRowY = null;
          for (var k = 0; k < spatialItems.length; k++) {
            var item = spatialItems[k];
            if (currentRowY === null || Math.abs(item.y - currentRowY) <= 10) {
              var isDup = false;
              for (var m = 0; m < currentRow.length; m++) {
                if (Math.abs(currentRow[m].x - item.x) <= 6 && currentRow[m].t === item.t) {
                  isDup = true;
                  break;
                }
              }
              if (!isDup) {
                currentRow.push(item);
                if (currentRowY === null) currentRowY = item.y;
              }
            } else {
              currentRow.sort(function(a, b) { return a.x - b.x; });
              spatialRows.push(currentRow);
              currentRow = [item];
              currentRowY = item.y;
            }
          }
          if (currentRow.length > 0) {
            currentRow.sort(function(a, b) { return a.x - b.x; });
            spatialRows.push(currentRow);
          }

          var upperBody = bodyText.toUpperCase();
          var hasTargetGroupText = upperBody.indexOf('ИСИП') !== -1 || upperBody.indexOf('25-4') !== -1;

          return JSON.stringify({
            url: href,
            title: title,
            isCaptcha: isCaptcha,
            isStillLoading: visibleLoader && !hasTargetGroupText,
            hasTargetGroupText: hasTargetGroupText,
            downloadUrl: downloadUrl,
            extractedTables: extractedTables,
            spatialRows: spatialRows.slice(0, 600),
            fullText: bodyText.slice(0, 120000)
          });
        } catch (err) {
          return JSON.stringify({ error: err.toString() });
        }
      })();
    ''';

    final res = await _webViewController.runJavaScriptReturningResult(jsCode);
    if (res is String) {
      if (res.startsWith('"') && res.endsWith('"')) {
        try {
          return jsonDecode(res) as String;
        } catch (_) {
          return res;
        }
      }
      return res;
    }
    return res.toString();
  }

  /// Открывает интерактивное окно с исходным документом Яндекс 360:
  /// позволяет пройти SmartCaptcha, прокрутить листы и сразу считать расписание с экрана
  Future<void> _openInteractiveDocumentViewer() async {
    setState(() {
      _isDocumentSheetOpen = true;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return FractionallySizedBox(
          heightFactor: 0.9,
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Документ расписания (Яндекс 360)',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            'Дождитесь отображения таблицы и нажмите «Считать»',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Считать'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: WebViewWidget(controller: _webViewController),
              ),
            ],
          ),
        );
      },
    );

    if (mounted) {
      setState(() {
        _isDocumentSheetOpen = false;
        _isLoading = true;
        _loadingProgressText = 'Анализ открытого документа...';
      });
    }

    try {
      final targetDates = <DateTime>[
        _anchorToday,
        _anchorToday.add(const Duration(days: 1)),
        _anchorToday.add(const Duration(days: 2)),
      ];
      final rawJson = await _runJsDomAndSpatialExtractor(scrollStep: 1);
      if (rawJson.isNotEmpty) {
        final payload = jsonDecode(rawJson) as Map<String, dynamic>;
        final bundle = Yandex360ScheduleParser.parseExtractedPayload(
          payload: payload,
          targetDates: targetDates,
        );
        if (bundle.hasAnyLessons) {
          await _saveToCache(bundle);
        }
        if (mounted) {
          setState(() {
            _scheduleBundle = bundle;
            _isLoading = false;
            _isOfflineFallback = false;
            _needsCaptchaVerification = false;
            _statusMessage = bundle.hasAnyLessons
                ? null
                : 'Таблица ИСИП-25-4 не найдена на видимой части страницы. '
                    'Прокрутите документ до группы ИСИП-25-4 и нажмите «Считать».';
          });
          return;
        }
      }
    } catch (_) {}

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  String _formatTabSubtitle(DateTime date) {
    const weekdaysShort = <int, String>{
      DateTime.monday: 'Пн',
      DateTime.tuesday: 'Вт',
      DateTime.wednesday: 'Ср',
      DateTime.thursday: 'Чт',
      DateTime.friday: 'Пт',
      DateTime.saturday: 'Сб',
      DateTime.sunday: 'Вс',
    };
    const monthsShort = <int, String>{
      1: 'янв',
      2: 'фев',
      3: 'мар',
      4: 'апр',
      5: 'мая',
      6: 'июн',
      7: 'июл',
      8: 'авг',
      9: 'сен',
      10: 'окт',
      11: 'ноя',
      12: 'дек',
    };
    final wd = weekdaysShort[date.weekday] ?? '';
    final m = monthsShort[date.month] ?? '';
    return '$wd, ${date.day} $m';
  }

  String _formatFullDayHeader(DateTime date) {
    const weekdaysFull = <int, String>{
      DateTime.monday: 'Понедельник',
      DateTime.tuesday: 'Вторник',
      DateTime.wednesday: 'Среда',
      DateTime.thursday: 'Четверг',
      DateTime.friday: 'Пятница',
      DateTime.saturday: 'Суббота',
      DateTime.sunday: 'Воскресенье',
    };
    const monthsGenitive = <int, String>{
      1: 'января',
      2: 'февраля',
      3: 'марта',
      4: 'апреля',
      5: 'мая',
      6: 'июня',
      7: 'июля',
      8: 'августа',
      9: 'сентября',
      10: 'октября',
      11: 'ноября',
      12: 'декабря',
    };
    final wd = weekdaysFull[date.weekday] ?? '';
    final m = monthsGenitive[date.month] ?? '';
    return '$wd, ${date.day} $m ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final today = _anchorToday;
    final tomorrow = today.add(const Duration(days: 1));
    final dayAfterTomorrow = today.add(const Duration(days: 2));
    final days = [today, tomorrow, dayAfterTomorrow];
    final tabTitles = ['Сегодня', 'Завтра', 'Послезавтра'];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              decoration: BoxDecoration(
                color:
                    theme.colorScheme.primary.withOpacity(isDark ? 0.2 : 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: theme.colorScheme.primary.withOpacity(0.35),
                ),
              ),
              child: Text(
                kTargetGroup,
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Расписание',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                  ),
                  if (_scheduleBundle != null)
                    Text(
                      'Обновлено в ${DateFormat('HH:mm').format(_scheduleBundle!.fetchedAt)}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color:
                            isDark ? Colors.white60 : const Color(0xFF64748B),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Открыть документ Яндекс 360',
            onPressed: _openInteractiveDocumentViewer,
            icon: const Icon(Icons.table_chart_outlined),
          ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
            )
          else
            IconButton(
              tooltip: 'Обновить расписание',
              onPressed: _fetchAndParseSchedule,
              icon: const Icon(Icons.refresh_rounded),
            ),
          IconButton(
            tooltip: isDark ? 'Светлая тема' : 'Тёмная тема',
            onPressed: widget.onToggleTheme,
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            ),
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(66),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Container(
              height: 52,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF18202C)
                    : const Color(0xFFE2E8F0).withOpacity(0.75),
                borderRadius: BorderRadius.circular(14),
              ),
              child: TabBar(
                controller: _tabController,
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                indicator: BoxDecoration(
                  color: isDark ? const Color(0xFF263347) : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: isDark
                      ? null
                      : [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.06),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                ),
                labelColor: isDark ? Colors.white : const Color(0xFF0F172A),
                unselectedLabelColor:
                    isDark ? Colors.white60 : const Color(0xFF64748B),
                labelPadding: EdgeInsets.zero,
                tabs: List.generate(3, (index) {
                  return Tab(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          tabTitles[index],
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            height: 1.15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _formatTabSubtitle(days[index]),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            height: 1.1,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          // Фоновый смонтированный WebView с десктопным разрешением (1200x2000),
          // чтобы Яндекс 360 гарантированно рендерил таблицы и страницы в DOM
          if (!_isDocumentSheetOpen)
            Positioned(
              left: 0,
              top: 0,
              width: 360,
              height: 640,
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0.01,
                  child: FittedBox(
                    fit: BoxFit.fill,
                    child: SizedBox(
                      width: 1200,
                      height: 2000,
                      child: WebViewWidget(controller: _webViewController),
                    ),
                  ),
                ),
              ),
            ),
          // Основной интерфейс приложения
          Column(
            children: [
              if (_statusMessage != null) _buildStatusBanner(context, isDark),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: List.generate(3, (index) {
                    final date = days[index];
                    final lessons = _scheduleBundle?.lessonsForDate(
                          date,
                          isTodayTab: index == 0,
                        ) ??
                        const [];
                    return _buildDaySchedulePage(
                      context: context,
                      date: date,
                      lessons: lessons,
                      isDark: isDark,
                    );
                  }),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner(BuildContext context, bool isDark) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _needsCaptchaVerification
            ? Colors.amber.withOpacity(isDark ? 0.18 : 0.14)
            : (isDark ? const Color(0xFF1E293B) : const Color(0xFFEFF6FF)),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _needsCaptchaVerification
              ? Colors.amber.withOpacity(0.5)
              : theme.colorScheme.primary.withOpacity(0.25),
        ),
      ),
      child: Row(
        children: [
          Icon(
            _needsCaptchaVerification
                ? Icons.verified_user_outlined
                : (_isOfflineFallback
                    ? Icons.cloud_off_rounded
                    : Icons.info_outline_rounded),
            size: 18,
            color: _needsCaptchaVerification
                ? Colors.amber.shade700
                : theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _statusMessage!,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.3,
                color: isDark ? Colors.white70 : const Color(0xFF334155),
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _openInteractiveDocumentViewer,
            child: const Text('Открыть документ'),
          ),
        ],
      ),
    );
  }

  Widget _buildDaySchedulePage({
    required BuildContext context,
    required DateTime date,
    required List<LessonItem> lessons,
    required bool isDark,
  }) {
    return RefreshIndicator(
      onRefresh: _fetchAndParseSchedule,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _formatFullDayHeader(date),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color:
                            isDark ? Colors.white60 : const Color(0xFF64748B),
                      ),
                    ),
                  ),
                  if (lessons.isNotEmpty)
                    Text(
                      'Пар: ${lessons.length}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color:
                            isDark ? Colors.white54 : const Color(0xFF64748B),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_isLoading &&
              (_scheduleBundle == null || !_scheduleBundle!.hasAnyLessons))
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      _loadingProgressText,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color:
                            isDark ? Colors.white70 : const Color(0xFF475569),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (lessons.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _buildEmptyDayPlaceholder(context, isDark),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
              sliver: SliverList.separated(
                itemCount: lessons.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, idx) {
                  return LessonCard(
                    lesson: lessons[idx],
                    isDark: isDark,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  /// Аккуратная заглушка для пустых или ещё не выложенных дней
  /// + быстрые чипсы других дат, если в документе выложено расписание на другие числа
  Widget _buildEmptyDayPlaceholder(BuildContext context, bool isDark) {
    final otherDatesWithLessons = <String, List<LessonItem>>{};
    if (_scheduleBundle != null) {
      for (final entry in _scheduleBundle!.lessonsByIsoDate.entries) {
        if (entry.value.isNotEmpty) {
          otherDatesWithLessons[entry.key] = entry.value;
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withOpacity(0.05)
                  : const Color(0xFFE2E8F0).withOpacity(0.6),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.event_available_outlined,
              size: 32,
              color: isDark ? Colors.white54 : const Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'На этот день расписания пока нет или пар не запланировано',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              height: 1.4,
              color: isDark ? Colors.white70 : const Color(0xFF334155),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Потяните экран вниз для обновления или откройте документ для проверки',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white38 : const Color(0xFF94A3B8),
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _openInteractiveDocumentViewer,
            icon: const Icon(Icons.table_chart_outlined, size: 18),
            label: const Text('Открыть документ Яндекс 360'),
          ),
          if (otherDatesWithLessons.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              'В документе найдено расписание ИСИП-25-4 на другие даты:',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white60 : const Color(0xFF475569),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: otherDatesWithLessons.entries.map((entry) {
                return ActionChip(
                  avatar: const Icon(Icons.calendar_today_rounded, size: 14),
                  label: Text('${entry.key} (${entry.value.length} пар)'),
                  onPressed: () => _showOtherDateModal(
                    context,
                    entry.key,
                    entry.value,
                    isDark,
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  void _showOtherDateModal(
    BuildContext context,
    String isoDate,
    List<LessonItem> lessons,
    bool isDark,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return FractionallySizedBox(
          heightFactor: 0.8,
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'ИСИП-25-4 • Расписание на $isoDate',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: lessons.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, i) => LessonCard(
                    lesson: lessons[i],
                    isDark: isDark,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Карточка одной пары в строгом минималистичном стиле
class LessonCard extends StatelessWidget {
  final LessonItem lesson;
  final bool isDark;

  const LessonCard({
    super.key,
    required this.lesson,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withOpacity(0.07)
                        : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${lesson.lessonNumber} пара',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color:
                              isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                      ),
                      if (lesson.timeRange.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(
                            '•',
                            style: TextStyle(
                              color: isDark
                                  ? Colors.white38
                                  : const Color(0xFF94A3B8),
                            ),
                          ),
                        ),
                        Icon(
                          Icons.schedule_rounded,
                          size: 14,
                          color: isDark
                              ? Colors.white60
                              : const Color(0xFF475569),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          lesson.timeRange,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? Colors.white70
                                : const Color(0xFF475569),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const Spacer(),
                if (lesson.classroom.isNotEmpty)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                    decoration: BoxDecoration(
                      color: primaryColor.withOpacity(isDark ? 0.22 : 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: primaryColor.withOpacity(0.4),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.meeting_room_outlined,
                          size: 14,
                          color: primaryColor,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          lesson.classroom,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: primaryColor,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              lesson.subject,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                height: 1.3,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
            if (lesson.teacher.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    Icons.person_outline_rounded,
                    size: 16,
                    color: isDark ? Colors.white60 : const Color(0xFF64748B),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      lesson.teacher,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color:
                            isDark ? Colors.white70 : const Color(0xFF475569),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WebViewExtractionResult {
  final bool isCaptcha;
  final ScheduleDataBundle? bundle;
  final String? downloadUrl;

  const _WebViewExtractionResult({
    required this.isCaptcha,
    this.bundle,
    this.downloadUrl,
  });
}

/// Ячейка с пространственными координатами X для реконструкции таблиц из div/span в Яндекс Документах
class _SpatialCell {
  final String text;
  final int x;
  final int right;

  const _SpatialCell({
    required this.text,
    required this.x,
    required this.right,
  });
}

/// Универсальный парсер расписания из документа Яндекс 360 со строгой фильтрацией «ИСИП-25-4»
class Yandex360ScheduleParser {
  /// Регулярное выражение для точного поиска ТОЛЬКО группы «ИСИП-25-4»
  /// Учитывает кириллицу и возможные латинские символы-двойники (C/С, P/П, I/И)
  static final RegExp _targetGroupRegex = RegExp(
    r'(?<![А-ЯЁа-яёA-Za-z0-9])[ИIі][СCcс][ИIі][ПPpп]\s*[-–—/_ ]*\s*25\s*[-–—/_ ]*\s*4(?![0-9])',
    caseSensitive: false,
    unicode: true,
  );

  /// Регулярное выражение для распознавания заголовка ЛЮБОЙ другой учебной группы
  static final RegExp _anyGroupHeaderRegex = RegExp(
    r'(?<![А-ЯЁа-яёA-Za-z0-9])[А-ЯЁA-Z]{2,6}\s*[-–—]\s*\d{1,2}(?:\s*[-–—/]\s*\d{1,2})?(?![0-9])',
    caseSensitive: false,
    unicode: true,
  );

  /// Стандартное расписание звонков колледжа
  static const Map<int, String> _defaultBellSchedule = {
    1: '08:30 – 10:00',
    2: '10:10 – 11:40',
    3: '12:10 – 13:40',
    4: '13:50 – 15:20',
    5: '15:30 – 17:00',
    6: '17:10 – 18:40',
    7: '18:50 – 20:20',
  };

  /// Парсит комбинированный JSON-снимок из WebView (HTML-таблицы с заголовками + пространственные строки + текст)
  static ScheduleDataBundle parseExtractedPayload({
    required Map<String, dynamic> payload,
    required List<DateTime> targetDates,
  }) {
    final lessonsByIsoDate = <String, List<LessonItem>>{
      for (final d in targetDates) isoKey(d): <LessonItem>[],
    };
    final lessonsByWeekday = <int, List<LessonItem>>{};
    final undatedLessons = <LessonItem>[];
    final refYear = targetDates.first.year;
    final refMonth = targetDates.first.month;

    final fullText = (payload['fullText'] as String?) ?? '';
    final globalDocDate = _extractDateFromText(
      fullText,
      referenceYear: refYear,
      referenceMonth: refMonth,
    );
    final globalDocWeekday = _extractWeekdayFromText(fullText);

    // 1. Парсим извлечённые HTML-таблицы вместе с предшествующими им абзацами (где часто пишется дата!)
    final extractedTables =
        (payload['extractedTables'] as List<dynamic>?) ?? const [];
    for (final item in extractedTables) {
      if (item is! Map<String, dynamic>) continue;
      final headingBefore = (item['headingBefore'] as String?) ?? '';
      final tableHtml = (item['tableHtml'] as String?) ?? '';
      if (tableHtml.isEmpty) continue;

      final doc = html_parser.parseFragment(tableHtml);
      final tableEl = doc.querySelector('table');
      if (tableEl == null) continue;

      final grid = _tableElementToGrid(tableEl);
      if (grid.isNotEmpty) {
        _parseGridForTargetGroup(
          grid: grid,
          contextHeading: headingBefore,
          globalDocDate: globalDocDate,
          globalDocWeekday: globalDocWeekday,
          referenceYear: refYear,
          referenceMonth: refMonth,
          lessonsByIsoDate: lessonsByIsoDate,
          lessonsByWeekday: lessonsByWeekday,
          undatedLessons: undatedLessons,
        );
      }
    }

    // 2. Если в HTML-таблицах пар не нашлось (документ отрендерен через div/span),
    // запускаем пространственный парсер по X/Y-координатам элементов
    final hasFromTables = lessonsByIsoDate.values.any((l) => l.isNotEmpty) ||
        lessonsByWeekday.values.any((l) => l.isNotEmpty) ||
        undatedLessons.isNotEmpty;

    if (!hasFromTables) {
      final rawSpatialRows =
          (payload['spatialRows'] as List<dynamic>?) ?? const [];
      final spatialRows = <List<_SpatialCell>>[];
      for (final r in rawSpatialRows) {
        if (r is! List<dynamic>) continue;
        final rowCells = <_SpatialCell>[];
        for (final c in r) {
          if (c is Map<String, dynamic>) {
            final t = (c['t'] as String?)?.trim() ?? '';
            final x = (c['x'] as num?)?.toInt() ?? 0;
            final right = (c['r'] as num?)?.toInt() ?? (x + 60);
            if (t.isNotEmpty) {
              rowCells.add(_SpatialCell(text: t, x: x, right: right));
            }
          }
        }
        if (rowCells.isNotEmpty) {
          spatialRows.add(rowCells);
        }
      }

      if (spatialRows.isNotEmpty) {
        _parseSpatialRowsForTargetGroup(
          spatialRows: spatialRows,
          globalDocDate: globalDocDate,
          globalDocWeekday: globalDocWeekday,
          referenceYear: refYear,
          referenceMonth: refMonth,
          lessonsByIsoDate: lessonsByIsoDate,
          lessonsByWeekday: lessonsByWeekday,
          undatedLessons: undatedLessons,
        );
      }
    }

    for (final list in lessonsByIsoDate.values) {
      list.sort((a, b) => a.lessonNumber.compareTo(b.lessonNumber));
    }
    for (final list in lessonsByWeekday.values) {
      list.sort((a, b) => a.lessonNumber.compareTo(b.lessonNumber));
    }
    undatedLessons.sort((a, b) => a.lessonNumber.compareTo(b.lessonNumber));

    return ScheduleDataBundle(
      lessonsByIsoDate: lessonsByIsoDate,
      lessonsByWeekday: lessonsByWeekday,
      undatedLessons: undatedLessons,
      fetchedAt: DateTime.now(),
    );
  }

  /// Парсит бинарный архив документа Office (.xlsx или .docx)
  static ScheduleDataBundle parseOfficeArchiveBytes(
    Uint8List bytes, {
    required List<DateTime> targetDates,
  }) {
    final lessonsByIsoDate = <String, List<LessonItem>>{
      for (final d in targetDates) isoKey(d): <LessonItem>[],
    };
    final lessonsByWeekday = <int, List<LessonItem>>{};
    final undatedLessons = <LessonItem>[];
    final refYear = targetDates.first.year;
    final refMonth = targetDates.first.month;

    try {
      final archive = ZipDecoder().decodeBytes(bytes);

      final wordDoc = archive.findFile('word/document.xml');
      if (wordDoc != null) {
        final xmlStr =
            utf8.decode(wordDoc.content as List<int>, allowMalformed: true);
        final sections = _extractDocxTablesWithHeadings(xmlStr);
        for (final sec in sections) {
          _parseGridForTargetGroup(
            grid: sec.grid,
            contextHeading: sec.headingBefore,
            globalDocDate: null,
            globalDocWeekday: null,
            referenceYear: refYear,
            referenceMonth: refMonth,
            lessonsByIsoDate: lessonsByIsoDate,
            lessonsByWeekday: lessonsByWeekday,
            undatedLessons: undatedLessons,
          );
        }
      }

      final sharedStringsFile = archive.findFile('xl/sharedStrings.xml');
      final sharedStrings = <String>[];
      if (sharedStringsFile != null) {
        final ssXml = utf8.decode(
          sharedStringsFile.content as List<int>,
          allowMalformed: true,
        );
        final siMatches =
            RegExp(r'<si[^>]*>(.*?)</si>', dotAll: true).allMatches(ssXml);
        for (final si in siMatches) {
          final tMatches = RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true)
              .allMatches(si.group(1)!);
          final combined = tMatches
              .map((m) => _decodeXmlEntities(m.group(1) ?? ''))
              .join('');
          sharedStrings.add(combined.trim());
        }
      }

      for (final file in archive.files) {
        if (file.name.startsWith('xl/worksheets/sheet') &&
            file.name.endsWith('.xml')) {
          final sheetXml = utf8.decode(
            file.content as List<int>,
            allowMalformed: true,
          );
          final grid = _extractXlsxSheetGrid(sheetXml, sharedStrings);
          if (grid.isNotEmpty) {
            _parseGridForTargetGroup(
              grid: grid,
              contextHeading: file.name,
              globalDocDate: null,
              globalDocWeekday: null,
              referenceYear: refYear,
              referenceMonth: refMonth,
              lessonsByIsoDate: lessonsByIsoDate,
              lessonsByWeekday: lessonsByWeekday,
              undatedLessons: undatedLessons,
            );
          }
        }
      }
    } catch (_) {}

    return ScheduleDataBundle(
      lessonsByIsoDate: lessonsByIsoDate,
      lessonsByWeekday: lessonsByWeekday,
      undatedLessons: undatedLessons,
      fetchedAt: DateTime.now(),
    );
  }

  /// Извлекает таблицы из `word/document.xml` вместе с предшествующими им параграфами дат
  static List<_DocxTableSection> _extractDocxTablesWithHeadings(String xmlStr) {
    final results = <_DocxTableSection>[];
    final tokenRegex = RegExp(
      r'(<w:tbl\b[^>]*>.*?</w:tbl>)|(<w:p\b[^>]*>.*?</w:p>)',
      dotAll: true,
    );
    final pendingParagraphs = <String>[];

    for (final match in tokenRegex.allMatches(xmlStr)) {
      final tblBlock = match.group(1);
      final pBlock = match.group(2);

      if (pBlock != null) {
        final tMatches =
            RegExp(r'<w:t\b[^>]*>(.*?)</w:t>', dotAll: true).allMatches(pBlock);
        final pText = tMatches
            .map((t) => _decodeXmlEntities(t.group(1) ?? ''))
            .join('')
            .trim();
        if (pText.isNotEmpty) {
          pendingParagraphs.add(pText);
          if (pendingParagraphs.length > 8) {
            pendingParagraphs.removeAt(0);
          }
        }
      } else if (tblBlock != null) {
        final grid = <List<String>>[];
        final trMatches = RegExp(r'<w:tr\b[^>]*>(.*?)</w:tr>', dotAll: true)
            .allMatches(tblBlock);
        for (final tr in trMatches) {
          final rowCells = <String>[];
          final tcMatches = RegExp(r'<w:tc\b[^>]*>(.*?)</w:tc>', dotAll: true)
              .allMatches(tr.group(1)!);
          for (final tc in tcMatches) {
            final pMatches = RegExp(r'<w:p\b[^>]*>(.*?)</w:p>', dotAll: true)
                .allMatches(tc.group(1)!);
            final paragraphs = <String>[];
            for (final p in pMatches) {
              final tMatches = RegExp(r'<w:t\b[^>]*>(.*?)</w:t>', dotAll: true)
                  .allMatches(p.group(1)!);
              final pText = tMatches
                  .map((t) => _decodeXmlEntities(t.group(1) ?? ''))
                  .join('')
                  .trim();
              if (pText.isNotEmpty) paragraphs.add(pText);
            }
            rowCells.add(paragraphs.join('\n'));
          }
          if (rowCells.isNotEmpty) grid.add(rowCells);
        }
        if (grid.isNotEmpty) {
          results.add(
            _DocxTableSection(
              headingBefore: pendingParagraphs.join('\n'),
              grid: grid,
            ),
          );
          pendingParagraphs.clear();
        }
      }
    }
    return results;
  }

  static List<List<String>> _extractXlsxSheetGrid(
    String sheetXml,
    List<String> sharedStrings,
  ) {
    final grid = <List<String>>[];
    final rowMatches = RegExp(r'<row\b[^>]*>(.*?)</row>', dotAll: true)
        .allMatches(sheetXml);
    for (final rowMatch in rowMatches) {
      final rowContent = rowMatch.group(1)!;
      final cellMap = <int, String>{};
      int maxCol = 0;

      final cMatches = RegExp(
        r'<c\b([^>]*?)(?:/>|>(.*?)</c>)',
        dotAll: true,
      ).allMatches(rowContent);

      for (final c in cMatches) {
        final attrs = c.group(1) ?? '';
        final inner = c.group(2) ?? '';
        final refMatch = RegExp(r'\br="([A-Z]+)\d+"').firstMatch(attrs);
        final colIndex =
            refMatch != null ? _excelColToIndex(refMatch.group(1)!) : maxCol;
        final typeMatch = RegExp(r'\bt="([^"]+)"').firstMatch(attrs);
        final cellType = typeMatch?.group(1) ?? '';

        String val = '';
        if (cellType == 'inlineStr') {
          final tMatch =
              RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true).firstMatch(inner);
          val = _decodeXmlEntities(tMatch?.group(1) ?? '');
        } else {
          final vMatch =
              RegExp(r'<v[^>]*>(.*?)</v>', dotAll: true).firstMatch(inner);
          final rawV = vMatch?.group(1)?.trim() ?? '';
          if (cellType == 's') {
            final idx = int.tryParse(rawV);
            if (idx != null && idx >= 0 && idx < sharedStrings.length) {
              val = sharedStrings[idx];
            }
          } else {
            val = _decodeXmlEntities(rawV);
          }
        }
        cellMap[colIndex] = val.trim();
        if (colIndex + 1 > maxCol) maxCol = colIndex + 1;
      }

      if (maxCol > 0) {
        grid.add(List<String>.generate(maxCol, (i) => cellMap[i] ?? ''));
      }
    }
    return grid;
  }

  static int _excelColToIndex(String colLetters) {
    int result = 0;
    for (int i = 0; i < colLetters.length; i++) {
      result = result * 26 + (colLetters.codeUnitAt(i) - 64);
    }
    return result - 1;
  }

  static String _decodeXmlEntities(String input) {
    return input
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }

  /// Преобразует HTML `<table>` в нормализованную 2D-матрицу с учётом colspan и rowspan
  static List<List<String>> _tableElementToGrid(dom.Element table) {
    final rows = table.querySelectorAll('tr');
    if (rows.isEmpty) return const [];

    final matrix = <int, Map<int, String>>{};
    int maxCols = 0;

    for (int r = 0; r < rows.length; r++) {
      matrix.putIfAbsent(r, () => <int, String>{});
      final cells = rows[r].children.where(
            (el) => el.localName == 'td' || el.localName == 'th',
          );

      int colCursor = 0;
      for (final cell in cells) {
        while (matrix[r]!.containsKey(colCursor)) {
          colCursor++;
        }
        final text = _cleanMultilineCell(cell.text);
        final colspan =
            int.tryParse(cell.attributes['colspan'] ?? '1')?.clamp(1, 50) ?? 1;
        final rowspan =
            int.tryParse(cell.attributes['rowspan'] ?? '1')?.clamp(1, 50) ?? 1;

        for (int dr = 0; dr < rowspan; dr++) {
          final targetRow = r + dr;
          matrix.putIfAbsent(targetRow, () => <int, String>{});
          for (int dc = 0; dc < colspan; dc++) {
            final targetCol = colCursor + dc;
            // Сохраняем текст в левой колонке объединённого диапазона на всех строках rowspan,
            // чтобы объединённые по вертикали номера пар, даты и 2-часовые занятия не терялись
            if (dc == 0) {
              matrix[targetRow]![targetCol] = text;
            } else if (_containsDateOrGroupHeader(text)) {
              matrix[targetRow]![targetCol] = text;
            } else {
              matrix[targetRow]![targetCol] = '';
            }
            if (targetCol + 1 > maxCols) {
              maxCols = targetCol + 1;
            }
          }
        }
        colCursor += colspan;
      }
    }

    final totalRows = matrix.keys.isEmpty
        ? 0
        : (matrix.keys.reduce((a, b) => a > b ? a : b) + 1);
    final result = <List<String>>[];
    for (int r = 0; r < totalRows; r++) {
      final rowMap = matrix[r] ?? const <int, String>{};
      final rowList = List<String>.generate(
        maxCols,
        (c) => rowMap[c] ?? '',
      );
      result.add(rowList);
    }
    return result;
  }

  static bool _containsDateOrGroupHeader(String text) {
    final now = DateTime.now();
    return _targetGroupRegex.hasMatch(text) ||
        _anyGroupHeaderRegex.hasMatch(text) ||
        _extractDateFromText(
              text,
              referenceYear: now.year,
              referenceMonth: now.month,
            ) !=
            null ||
        _extractWeekdayFromText(text) != null;
  }

  /// Пространственный парсер (по X-координатам ячеек) для документов, отрендеренных через div/span
  static void _parseSpatialRowsForTargetGroup({
    required List<List<_SpatialCell>> spatialRows,
    required DateTime? globalDocDate,
    required int? globalDocWeekday,
    required int referenceYear,
    required int referenceMonth,
    required Map<String, List<LessonItem>> lessonsByIsoDate,
    required Map<int, List<LessonItem>> lessonsByWeekday,
    required List<LessonItem> undatedLessons,
  }) {
    DateTime? activeDate = globalDocDate;
    int? activeWeekday = globalDocWeekday;

    int? colMinX;
    int? colMaxX;

    for (int r = 0; r < spatialRows.length; r++) {
      final row = spatialRows[r];
      final rowText = row.map((c) => c.text).join(' ');

      final rowDate = _extractDateFromText(
        rowText,
        referenceYear: referenceYear,
        referenceMonth: referenceMonth,
      );
      if (rowDate != null) {
        activeDate = rowDate;
      }
      final rowWd = _extractWeekdayFromText(rowText);
      if (rowWd != null) {
        activeWeekday = rowWd;
      }

      _SpatialCell? targetCell;
      for (final cell in row) {
        if (_targetGroupRegex.hasMatch(cell.text)) {
          targetCell = cell;
          break;
        }
      }

      if (targetCell != null) {
        colMinX = targetCell.x - 25;
        int? nextGroupLeft;
        for (final cell in row) {
          if (cell.x > targetCell.x + 15 &&
              !_targetGroupRegex.hasMatch(cell.text) &&
              _anyGroupHeaderRegex.hasMatch(cell.text)) {
            if (nextGroupLeft == null || cell.x < nextGroupLeft) {
              nextGroupLeft = cell.x;
            }
          }
        }
        colMaxX = nextGroupLeft != null
            ? (nextGroupLeft - 8)
            : (targetCell.right + 180);
        continue;
      }

      final otherGroupsCount =
          row.where((c) => _anyGroupHeaderRegex.hasMatch(c.text)).length;
      if (otherGroupsCount >= 2) {
        colMinX = null;
        colMaxX = null;
        continue;
      }

      if (colMinX != null && colMaxX != null) {
        final leftCells = <String>[];
        final groupCells = <String>[];

        for (final cell in row) {
          final center = (cell.x + cell.right) ~/ 2;
          if (center >= colMinX && center <= colMaxX) {
            groupCells.add(cell.text);
          } else if (cell.x < colMinX) {
            leftCells.add(cell.text);
          }
        }

        if (groupCells.isNotEmpty) {
          final combined = groupCells.join(' ');
          if (_isSubheaderText(combined) || _isEmptyPlaceholderCell(combined)) {
            continue;
          }

          int? lessonNumber;
          String timeRange = '';
          for (final lc in leftCells) {
            final t = _extractTimeRange(lc);
            if (t != null && timeRange.isEmpty) timeRange = t;
            final nm = RegExp(
              r'^\s*([1-8])\s*(?:пара|п\.|урок)?\s*$',
              caseSensitive: false,
            ).firstMatch(lc);
            if (nm != null && lessonNumber == null) {
              lessonNumber = int.tryParse(nm.group(1)!);
            }
          }

          lessonNumber ??= (timeRange.isNotEmpty
                  ? _inferLessonNumberFromTime(timeRange)
                  : null) ??
              1;
          if (timeRange.isEmpty) {
            timeRange = _defaultBellSchedule[lessonNumber] ?? '';
          }

          final item = _parseRawLessonCells(
            groupCells: groupCells,
            lessonNumber: lessonNumber,
            timeRange: timeRange,
          );
          if (item != null) {
            _storeParsedLesson(
              item: item,
              activeDate: activeDate,
              activeWeekday: activeWeekday,
              lessonsByIsoDate: lessonsByIsoDate,
              lessonsByWeekday: lessonsByWeekday,
              undatedLessons: undatedLessons,
            );
          }
        }
      }
    }
  }

  /// Ядро анализа 2D-таблицы с поддержкой:
  /// 1) Заголовка даты НАД таблицей (contextHeading) и внутри строк
  /// 2) Матричного режима (ИСИП-25-4 — заголовок колонки)
  /// 3) Построчного/блочного режима (ИСИП-25-4 — строка или секция группы)
  static void _parseGridForTargetGroup({
    required List<List<String>> grid,
    required String contextHeading,
    required DateTime? globalDocDate,
    required int? globalDocWeekday,
    required int referenceYear,
    required int referenceMonth,
    required Map<String, List<LessonItem>> lessonsByIsoDate,
    required Map<int, List<LessonItem>> lessonsByWeekday,
    required List<LessonItem> undatedLessons,
  }) {
    if (grid.isEmpty) return;

    DateTime? activeDate = _extractDateFromText(
          contextHeading,
          referenceYear: referenceYear,
          referenceMonth: referenceMonth,
        ) ??
        globalDocDate;
    int? activeWeekday =
        _extractWeekdayFromText(contextHeading) ?? globalDocWeekday;

    int? groupColStart;
    int? groupColEnd;
    int lessonNumCol = 0;
    int? timeCol;
    int? dateCol;
    bool inTargetGroupRowSection = false;

    for (int r = 0; r < grid.length; r++) {
      final row = grid[r];
      final nonEmptyCells = row.where((c) => c.isNotEmpty).toList();
      if (nonEmptyCells.isEmpty) continue;

      DateTime? rowDate;
      int? rowWeekday;
      if (dateCol != null && dateCol < row.length && row[dateCol].isNotEmpty) {
        rowDate = _extractDateFromText(
          row[dateCol],
          referenceYear: referenceYear,
          referenceMonth: referenceMonth,
        );
        rowWeekday = _extractWeekdayFromText(row[dateCol]);
      }
      if (rowDate == null) {
        for (int c = 0; c < row.length && c <= (groupColStart ?? 4); c++) {
          final d = _extractDateFromText(
            row[c],
            referenceYear: referenceYear,
            referenceMonth: referenceMonth,
          );
          if (d != null) {
            rowDate = d;
            break;
          }
        }
      }
      if (rowWeekday == null) {
        for (int c = 0; c < row.length && c <= 2; c++) {
          final wd = _extractWeekdayFromText(row[c]);
          if (wd != null) {
            rowWeekday = wd;
            break;
          }
        }
      }
      if (rowDate != null) activeDate = rowDate;
      if (rowWeekday != null) activeWeekday = rowWeekday;

      int? foundTargetCol;
      for (int c = 0; c < row.length; c++) {
        if (_targetGroupRegex.hasMatch(row[c])) {
          foundTargetCol = c;
          break;
        }
      }

      final groupsInRowCount =
          row.where((c) => _anyGroupHeaderRegex.hasMatch(c)).length;

      if (foundTargetCol != null) {
        final hasHeaderKeywords = row.any((c) {
          final l = c.toLowerCase();
          return l.contains('пара') ||
              l.contains('время') ||
              l.contains('№') ||
              l.contains('часы') ||
              l.contains('урок');
        });

        // Матричный режим: в строке несколько групп ИЛИ ключевые слова шапки («Пара», «Время», «№»)
        if (groupsInRowCount >= 2 || hasHeaderKeywords) {
          groupColStart = foundTargetCol;
          int endCol = foundTargetCol;
          for (int c = foundTargetCol + 1; c < row.length; c++) {
            final cellText = row[c];
            if (cellText.isNotEmpty &&
                !_targetGroupRegex.hasMatch(cellText) &&
                _anyGroupHeaderRegex.hasMatch(cellText)) {
              break;
            }
            if (c - foundTargetCol < 3) {
              endCol = c;
            } else {
              break;
            }
          }
          groupColEnd = endCol;
          inTargetGroupRowSection = false;

          for (int c = 0; c < foundTargetCol; c++) {
            final lower = row[c].toLowerCase();
            if (lower.contains('дата') || lower.contains('день')) {
              dateCol = c;
            } else if (lower.contains('время') || lower.contains('час')) {
              timeCol = c;
            } else if (lower.contains('пара') ||
                lower.contains('№') ||
                lower.contains('урок')) {
              lessonNumCol = c;
            }
          }
          continue;
        } else {
          // Секционный/построчный режим: строка содержит ИСИП-25-4 (и, возможно, первую пару в этой же строке)
          inTargetGroupRowSection = true;
          groupColStart = null;
          groupColEnd = null;

          final otherCells = <String>[];
          for (int c = 0; c < row.length; c++) {
            if (c != foundTargetCol && row[c].trim().isNotEmpty) {
              otherCells.add(row[c].trim());
            }
          }
          if (otherCells.isNotEmpty) {
            final firstRowLesson = _extractLessonFromFlatCells(otherCells);
            if (firstRowLesson != null) {
              _storeParsedLesson(
                item: firstRowLesson,
                activeDate: activeDate,
                activeWeekday: activeWeekday,
                lessonsByIsoDate: lessonsByIsoDate,
                lessonsByWeekday: lessonsByWeekday,
                undatedLessons: undatedLessons,
              );
            }
          }
          continue;
        }
      }

      if (groupsInRowCount >= 1) {
        if (groupsInRowCount >= 2) {
          groupColStart = null;
          groupColEnd = null;
        }
        inTargetGroupRowSection = false;
        continue;
      }

      if (groupColStart != null && groupColEnd != null) {
        final lesson = _extractLessonFromMatrixRow(
          grid: grid,
          rowIndex: r,
          groupColStart: groupColStart,
          groupColEnd: groupColEnd,
          lessonNumCol: lessonNumCol,
          timeCol: timeCol,
        );
        if (lesson != null) {
          _storeParsedLesson(
            item: lesson,
            activeDate: activeDate,
            activeWeekday: activeWeekday,
            lessonsByIsoDate: lessonsByIsoDate,
            lessonsByWeekday: lessonsByWeekday,
            undatedLessons: undatedLessons,
          );
        }
      } else if (inTargetGroupRowSection) {
        final lesson = _extractLessonFromFlatCells(nonEmptyCells);
        if (lesson != null) {
          _storeParsedLesson(
            item: lesson,
            activeDate: activeDate,
            activeWeekday: activeWeekday,
            lessonsByIsoDate: lessonsByIsoDate,
            lessonsByWeekday: lessonsByWeekday,
            undatedLessons: undatedLessons,
          );
        }
      }
    }
  }

  static void _storeParsedLesson({
    required LessonItem item,
    required DateTime? activeDate,
    required int? activeWeekday,
    required Map<String, List<LessonItem>> lessonsByIsoDate,
    required Map<int, List<LessonItem>> lessonsByWeekday,
    required List<LessonItem> undatedLessons,
  }) {
    if (activeDate != null) {
      final iso = isoKey(activeDate);
      final targetList = lessonsByIsoDate.putIfAbsent(iso, () => <LessonItem>[]);
      _addOrMergeLesson(targetList, item);
    } else if (activeWeekday != null) {
      final targetList =
          lessonsByWeekday.putIfAbsent(activeWeekday, () => <LessonItem>[]);
      _addOrMergeLesson(targetList, item);
    } else {
      _addOrMergeLesson(undatedLessons, item);
    }
  }

  static void _addOrMergeLesson(List<LessonItem> existing, LessonItem lesson) {
    final duplicateIndex = existing.indexWhere(
      (e) => e.lessonNumber == lesson.lessonNumber,
    );
    if (duplicateIndex == -1) {
      existing.add(lesson);
    } else {
      existing[duplicateIndex] = _mergeLessonSubrows(
        existing[duplicateIndex],
        lesson,
      );
    }
  }

  static LessonItem? _extractLessonFromFlatCells(List<String> cells) {
    int? lessonNumber;
    String timeRange = '';
    final contentCells = <String>[];
    final now = DateTime.now();

    for (final cell in cells) {
      if (_extractDateFromText(
                cell,
                referenceYear: now.year,
                referenceMonth: now.month,
              ) !=
              null &&
          cells.length > 2) {
        continue;
      }
      if (_extractWeekdayFromText(cell) != null &&
          cell.trim().length <= 14 &&
          cells.length > 2) {
        continue;
      }
      final t = _extractTimeRange(cell);
      if (t != null && timeRange.isEmpty) {
        timeRange = t;
        continue;
      }
      final numMatch = RegExp(
        r'^\s*([1-8])\s*(?:пара|п\.|урок)?\s*$',
        caseSensitive: false,
      ).firstMatch(cell);
      if (numMatch != null && lessonNumber == null) {
        lessonNumber = int.tryParse(numMatch.group(1)!);
        continue;
      }
      contentCells.add(cell);
    }

    if (contentCells.isEmpty) return null;
    lessonNumber ??=
        (timeRange.isNotEmpty ? _inferLessonNumberFromTime(timeRange) : null) ??
            1;
    if (timeRange.isEmpty) {
      timeRange = _defaultBellSchedule[lessonNumber] ?? '';
    }

    return _parseRawLessonCells(
      groupCells: contentCells,
      lessonNumber: lessonNumber,
      timeRange: timeRange,
    );
  }

  static LessonItem? _extractLessonFromMatrixRow({
    required List<List<String>> grid,
    required int rowIndex,
    required int groupColStart,
    required int groupColEnd,
    required int lessonNumCol,
    required int? timeCol,
  }) {
    final row = grid[rowIndex];
    if (groupColStart >= row.length) return null;

    final groupCells = <String>[];
    for (int c = groupColStart; c <= groupColEnd && c < row.length; c++) {
      final val = row[c].trim();
      if (val.isNotEmpty) {
        groupCells.add(val);
      }
    }
    if (groupCells.isEmpty) return null;

    final combinedCellText = groupCells.join(' | ');
    if (_isSubheaderText(combinedCellText) ||
        _isEmptyPlaceholderCell(combinedCellText)) {
      return null;
    }

    int? lessonNumber;
    String timeRange = '';

    for (int c = 0; c < groupColStart && c < row.length; c++) {
      final cell = row[c].trim();
      if (cell.isEmpty) continue;

      final extractedTime = _extractTimeRange(cell);
      if (extractedTime != null && timeRange.isEmpty) {
        timeRange = extractedTime;
      }

      if (lessonNumber == null) {
        final numMatch = RegExp(
          r'^\s*([1-8])\s*(?:пара|п\.|урок)?\s*$',
          caseSensitive: false,
        ).firstMatch(cell);
        if (numMatch != null) {
          lessonNumber = int.tryParse(numMatch.group(1)!);
        }
      }
    }

    if (lessonNumber == null && rowIndex > 0) {
      final prevRow = grid[rowIndex - 1];
      for (int c = 0; c < groupColStart && c < prevRow.length; c++) {
        final numMatch = RegExp(r'^\s*([1-8])\s*(?:пара|п\.)?\s*$')
            .firstMatch(prevRow[c].trim());
        if (numMatch != null) {
          lessonNumber = int.tryParse(numMatch.group(1)!);
          break;
        }
      }
    }

    if (lessonNumber == null && timeRange.isNotEmpty) {
      lessonNumber = _inferLessonNumberFromTime(timeRange);
    }

    lessonNumber ??= 1;
    if (timeRange.isEmpty) {
      timeRange = _defaultBellSchedule[lessonNumber] ?? '';
    }

    return _parseRawLessonCells(
      groupCells: groupCells,
      lessonNumber: lessonNumber,
      timeRange: timeRange,
    );
  }

  static bool _isSubheaderText(String text) {
    final lower = text.toLowerCase().trim();
    return lower == 'дисциплина' ||
        lower == 'предмет' ||
        lower == 'ауд.' ||
        lower == 'каб.' ||
        lower == 'аудитория' ||
        lower == 'дисциплина | ауд.' ||
        lower == 'предмет | каб.';
  }

  static LessonItem? _parseRawLessonCells({
    required List<String> groupCells,
    required int lessonNumber,
    required String timeRange,
  }) {
    var workingCells = List<String>.from(groupCells);
    String classroom = '';
    String teacher = '';
    final subjectParts = <String>[];

    if (workingCells.length >= 2) {
      final lastCell = workingCells.last.trim();
      if (_looksLikeStandaloneClassroom(lastCell)) {
        classroom = _formatClassroomBadge(lastCell);
        workingCells = workingCells.sublist(0, workingCells.length - 1);
      }
    }

    final lines = workingCells
        .expand((cell) => cell.split(RegExp(r'[\r\n]+')))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    for (var line in lines) {
      final roomMatch = RegExp(
        r'(?:каб\.?|ауд\.?|к\.?)\s*([0-9]{1,4}[а-яА-Яa-zA-Z/-]*)|\b(спортзал|с/з|актовый\s+зал|дистант|онлайн|дот)\b',
        caseSensitive: false,
        unicode: true,
      ).firstMatch(line);

      if (roomMatch != null) {
        final rawRoom = (roomMatch.group(1) ?? roomMatch.group(2) ?? '').trim();
        if (rawRoom.isNotEmpty && classroom.isEmpty) {
          classroom = _formatClassroomBadge(rawRoom);
        }
        line = line.replaceFirst(roomMatch.group(0)!, '').trim();
      }

      final teacherMatches = RegExp(
        r'([А-ЯЁ][а-яё]{2,}\s+[А-ЯЁ]\.\s*[А-ЯЁ]\.?|[А-ЯЁ]\.\s*[А-ЯЁ]\.?\s+[А-ЯЁ][а-яё]{2,})',
        unicode: true,
      ).allMatches(line).toList();

      if (teacherMatches.isNotEmpty) {
        final extractedTeachers =
            teacherMatches.map((m) => m.group(0)!.trim()).join(', ');
        teacher = teacher.isEmpty
            ? extractedTeachers
            : '$teacher, $extractedTeachers';
        for (final m in teacherMatches) {
          line = line.replaceFirst(m.group(0)!, '').trim();
        }
      }

      line =
          line.replaceAll(RegExp(r'^[,;:\-–—|/]+|[,;:\-–—|/]+$'), '').trim();
      if (line.isNotEmpty && !_isEmptyPlaceholderCell(line)) {
        subjectParts.add(line);
      }
    }

    final subject = subjectParts.join(' / ').trim();
    if (subject.isEmpty && teacher.isEmpty) return null;

    return LessonItem(
      lessonNumber: lessonNumber,
      timeRange: timeRange,
      subject: subject.isEmpty ? 'Учебное занятие' : subject,
      classroom: classroom,
      teacher: teacher,
    );
  }

  static LessonItem _mergeLessonSubrows(LessonItem primary, LessonItem extra) {
    final mergedSubject = (extra.subject != 'Учебное занятие' &&
            !primary.subject.contains(extra.subject))
        ? '${primary.subject} (${extra.subject})'
        : primary.subject;

    final mergedTeacher = primary.teacher.isNotEmpty
        ? (extra.teacher.isNotEmpty && !primary.teacher.contains(extra.teacher)
            ? '${primary.teacher}, ${extra.teacher}'
            : primary.teacher)
        : extra.teacher;

    final mergedClassroom =
        primary.classroom.isNotEmpty ? primary.classroom : extra.classroom;

    return LessonItem(
      lessonNumber: primary.lessonNumber,
      timeRange: primary.timeRange,
      subject: mergedSubject,
      classroom: mergedClassroom,
      teacher: mergedTeacher,
    );
  }

  /// Распознаёт дату в форматах:
  /// - «15.10.2026», «15/10/2026», «15-10-2026», «15.10.26»
  /// - «на «15» октября 2026 г.», «"15" октября», «15 октября»
  /// - короткий формат «15.10» (исключая коды МДК 01.01 и время 10.10-11.40)
  static DateTime? _extractDateFromText(
    String text, {
    required int referenceYear,
    required int referenceMonth,
  }) {
    if (text.isEmpty) return null;
    final cleaned = text.toLowerCase().trim();

    final numericFull = RegExp(
      r'(?<![0-9])([0-3]?\d)[./\-]([0-1]?\d)[./\-](20\d{2}|\d{2})(?![0-9])',
    ).firstMatch(cleaned);
    if (numericFull != null) {
      final day = int.tryParse(numericFull.group(1)!);
      final month = int.tryParse(numericFull.group(2)!);
      var year = int.tryParse(numericFull.group(3)!);
      if (day != null && month != null && year != null) {
        if (year < 100) year += 2000;
        if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
          return DateTime(year, month, day);
        }
      }
    }

    const monthNames = <String, int>{
      'январ': 1,
      'феврал': 2,
      'март': 3,
      'апрел': 4,
      'ма': 5,
      'июн': 6,
      'июл': 7,
      'август': 8,
      'сентябр': 9,
      'октябр': 10,
      'ноябр': 11,
      'декабр': 12,
    };

    final verbalMatch = RegExp(
      r'''[«"'\s]*([0-3]?\d)[»"'\s]+(января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря|янв|фев|мар|апр|июн|июл|авг|сен|сент|окт|ноя|дек)\.?(?:\s+(20\d{2}))?''',
      unicode: true,
    ).firstMatch(cleaned);
    if (verbalMatch != null) {
      final day = int.tryParse(verbalMatch.group(1)!);
      final monthWord = verbalMatch.group(2)!;
      final year = int.tryParse(verbalMatch.group(3) ?? '') ?? referenceYear;
      int? month;
      for (final entry in monthNames.entries) {
        if (monthWord.startsWith(entry.key)) {
          month = entry.value;
          break;
        }
      }
      if (day != null && month != null && day >= 1 && day <= 31) {
        return DateTime(year, month, day);
      }
    }

    if (!RegExp(r'\b(мдк|оп|пм|уп|пп|оуд|огсэ)\s*\.', unicode: true)
        .hasMatch(cleaned)) {
      for (final m in RegExp(r'(?<![0-9:])([0-3]?\d)\.([0-1]\d)(?![0-9.])')
          .allMatches(cleaned)) {
        final day = int.tryParse(m.group(1)!);
        final month = int.tryParse(m.group(2)!);
        if (day != null &&
            month != null &&
            day >= 1 &&
            day <= 31 &&
            month >= 1 &&
            month <= 12) {
          final monthDiff = (month - referenceMonth).abs();
          if (monthDiff <= 1 ||
              monthDiff == 11 ||
              _extractWeekdayFromText(cleaned) != null) {
            return DateTime(referenceYear, month, day);
          }
        }
      }
    }

    return null;
  }

  /// Извлекает день недели (1 = Понедельник .. 7 = Воскресенье)
  static int? _extractWeekdayFromText(String text) {
    if (text.isEmpty) return null;
    final lower = text.toLowerCase();
    if (lower.contains('понедельник')) return DateTime.monday;
    if (lower.contains('вторник')) return DateTime.tuesday;
    if (lower.contains('среда') || lower.contains('среду')) {
      return DateTime.wednesday;
    }
    if (lower.contains('четверг')) return DateTime.thursday;
    if (lower.contains('пятница') || lower.contains('пятницу')) {
      return DateTime.friday;
    }
    if (lower.contains('суббота') || lower.contains('субботу')) {
      return DateTime.saturday;
    }
    if (lower.contains('воскресенье')) return DateTime.sunday;
    return null;
  }

  static String? _extractTimeRange(String text) {
    final match = RegExp(
      r'([0-2]?\d[:.][0-5]\d)\s*[-–—]\s*([0-2]?\d[:.][0-5]\d)',
    ).firstMatch(text);
    if (match == null) return null;
    final start = match.group(1)!.replaceAll('.', ':');
    final end = match.group(2)!.replaceAll('.', ':');
    return '$start – $end';
  }

  static int? _inferLessonNumberFromTime(String timeRange) {
    if (timeRange.startsWith('08:') || timeRange.startsWith('8:')) return 1;
    if (timeRange.startsWith('10:')) return 2;
    if (timeRange.startsWith('11:') || timeRange.startsWith('12:')) return 3;
    if (timeRange.startsWith('13:') || timeRange.startsWith('14:')) return 4;
    if (timeRange.startsWith('15:')) return 5;
    if (timeRange.startsWith('16:') || timeRange.startsWith('17:')) return 6;
    return null;
  }

  static bool _looksLikeStandaloneClassroom(String text) {
    final cleaned = text.trim();
    if (cleaned.isEmpty || cleaned.length > 14) return false;
    return RegExp(
      r'^(?:(?:каб\.?|ауд\.?)\s*)?[0-9]{1,4}[а-яА-Яa-zA-Z/-]*$|^(?:спортзал|с/з|актовый зал|дистант|дот)$',
      caseSensitive: false,
      unicode: true,
    ).hasMatch(cleaned);
  }

  static String _formatClassroomBadge(String raw) {
    final trimmed = raw.trim();
    if (RegExp(r'^[0-9]+').hasMatch(trimmed)) {
      return 'Каб. $trimmed';
    }
    return trimmed;
  }

  static bool _isEmptyPlaceholderCell(String text) {
    final cleaned =
        text.replaceAll(RegExp(r'[\s|_—–\-.,/]+'), '').toLowerCase();
    return cleaned.isEmpty ||
        cleaned == 'нет' ||
        cleaned == 'выходной' ||
        cleaned == 'самостоятельнаяработа';
  }

  static String _cleanMultilineCell(String input) {
    return input
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }

  static String isoKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

class _DocxTableSection {
  final String headingBefore;
  final List<List<String>> grid;

  const _DocxTableSection({
    required this.headingBefore,
    required this.grid,
  });
}
