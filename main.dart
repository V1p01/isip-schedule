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

/// Единственный разрешённый источник данных расписания (Яндекс 360 Документы)
const String kScheduleUrl =
    'https://docs.360.yandex.ru/view/d/eSjfjNM06Zcyzwqv5124yiPegnqahzm72s0qoIz-cKg6Y1haOWRpYXFSZw';

/// Целевая учебная группа (жёсткий фильтр)
const String kTargetGroup = 'ИСИП-25-4';

/// Ключи локального кэша
const String kCacheKeyScheduleJson = 'cached_schedule_isip_25_4_v1';
const String kCacheKeyUpdatedAt = 'cached_schedule_updated_at_v1';
const String kCacheKeyThemeMode = 'cached_theme_mode_v1';

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

/// Модель расписания на весь доступный диапазон дат (ключ: YYYY-MM-DD)
class ScheduleDataBundle {
  /// Карта: ключ даты 'YYYY-MM-DD' -> список пар для группы ИСИП-25-4
  final Map<String, List<LessonItem>> lessonsByIsoDate;

  /// Время последнего успешного обновления
  final DateTime fetchedAt;

  const ScheduleDataBundle({
    required this.lessonsByIsoDate,
    required this.fetchedAt,
  });

  Map<String, dynamic> toJson() => {
        'fetchedAt': fetchedAt.toIso8601String(),
        'lessonsByIsoDate': lessonsByIsoDate.map(
          (key, value) => MapEntry(
            key,
            value.map((e) => e.toJson()).toList(),
          ),
        ),
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
    return ScheduleDataBundle(
      lessonsByIsoDate: parsedMap,
      fetchedAt: DateTime.tryParse((json['fetchedAt'] as String?) ?? '') ??
          DateTime.now(),
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

  /// Таймер автоматического сдвига дат после 00:00
  Timer? _midnightTimer;
  Timer? _periodicDateCheckTimer;

  /// Состояние загрузки и кэша
  bool _isLoading = false;
  bool _isOfflineFallback = false;
  bool _needsCaptchaVerification = false;
  String? _statusMessage;
  ScheduleDataBundle? _scheduleBundle;

  /// Скрытый контроллер WebView для рендеринга JS-таблиц Яндекс 360
  WebViewController? _headlessWebViewController;
  Completer<String>? _webViewHtmlCompleter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });

    _initHeadlessWebView();
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

  /// При возврате приложения из фона проверяем, не наступил ли новый день (00:00)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAndApplyDateRollover(forceRefreshOnNewDay: true);
    }
  }

  static DateTime _stripTime(DateTime dt) =>
      DateTime(dt.year, dt.month, dt.day);

  static String _toIsoDateKey(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';

  /// Настройка точного таймера срабатывания в 00:00:01 + резервной проверки каждые 20 секунд
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

  /// Если системная дата изменилась (после 00:00), автоматически сдвигаем вкладки
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

  /// Инициализация фонового WebView для чтения динамического DOM Яндекс.Документов
  void _initHeadlessWebView() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) async {
            // Даём скриптам Яндекс 360 время отрисовать сетку таблицы и прокрутить страницы
            await Future<void>.delayed(const Duration(milliseconds: 2000));
            if (_webViewHtmlCompleter != null &&
                !_webViewHtmlCompleter!.isCompleted) {
              try {
                final extractedPayload = await _extractDomFromWebView();
                _webViewHtmlCompleter?.complete(extractedPayload);
              } catch (e) {
                _webViewHtmlCompleter?.completeError(e);
              }
            }
          },
          onWebResourceError: (WebResourceError error) {
            if (_webViewHtmlCompleter != null &&
                !_webViewHtmlCompleter!.isCompleted &&
                error.isForMainFrame == true) {
              _webViewHtmlCompleter?.completeError(
                Exception(error.description),
              );
            }
          },
        ),
      );
    _headlessWebViewController = controller;
  }

  /// Извлекает HTML и текстовые таблицы из документа Яндекс 360 через JS
  Future<String> _extractDomFromWebView() async {
    final controller = _headlessWebViewController;
    if (controller == null) return '';

    const jsExtractor = r'''
      (function() {
        var isCaptcha = !!(
          document.querySelector('.CheckboxCaptcha') ||
          document.querySelector('#captcha-form') ||
          window.location.href.indexOf('showcaptcha') !== -1 ||
          document.title.indexOf('Ой!') !== -1 ||
          document.title.indexOf('Captcha') !== -1
        );

        var combinedHtml = document.documentElement ? document.documentElement.outerHTML : '';

        // Если внутри страницы есть доступные iframe (например, просмотрщик таблиц), добавляем их DOM
        var iframes = document.querySelectorAll('iframe');
        for (var i = 0; i < iframes.length; i++) {
          try {
            var idoc = iframes[i].contentDocument || (iframes[i].contentWindow && iframes[i].contentWindow.document);
            if (idoc && idoc.documentElement) {
              combinedHtml += '\n' + idoc.documentElement.outerHTML;
            }
          } catch (e) {}
        }

        var result = {
          url: window.location.href,
          title: document.title || '',
          isCaptcha: isCaptcha,
          html: combinedHtml
        };
        return JSON.stringify(result);
      })();
    ''';

    final rawJsResult =
        await controller.runJavaScriptReturningResult(jsExtractor);
    if (rawJsResult is String) {
      if (rawJsResult.startsWith('"') && rawJsResult.endsWith('"')) {
        try {
          return jsonDecode(rawJsResult) as String;
        } catch (_) {
          return rawJsResult;
        }
      }
      return rawJsResult;
    }
    return rawJsResult.toString();
  }

  /// Загрузка сохранённого кэша и немедленный запуск сетевого обновления
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
        if (mounted) {
          setState(() {
            _scheduleBundle = bundle;
          });
        }
      }
    } catch (_) {
      // Если кэш повреждён, просто игнорируем и загружаем заново
    }
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

  /// Основной метод получения и парсинга расписания СТРОГО по ссылке kScheduleUrl
  Future<void> _fetchAndParseSchedule() async {
    _checkAndApplyDateRollover(forceRefreshOnNewDay: false);

    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _statusMessage = null;
      _needsCaptchaVerification = false;
    });

    final targetDates = <DateTime>[
      _anchorToday,
      _anchorToday.add(const Duration(days: 1)),
      _anchorToday.add(const Duration(days: 2)),
    ];

    try {
      Map<String, List<LessonItem>>? parsedSchedule;
      bool captchaDetected = false;

      // Шаг 1: Прямой HTTP-запрос к ссылке расписания Яндекс 360
      try {
        final response = await http.get(
          Uri.parse(kScheduleUrl),
          headers: const {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'ru-RU,ru;q=0.9,en-US;q=0.8',
          },
        ).timeout(const Duration(seconds: 12));

        if (response.statusCode == 200) {
          final body = utf8.decode(response.bodyBytes, allowMalformed: true);

          if (_isYandexCaptchaHtml(body)) {
            captchaDetected = true;
          } else {
            // Проверяем, есть ли внутри ответа прямая ссылка на скачивание файла (.xlsx / .docx)
            final directFileUrl =
                Yandex360ScheduleParser.extractEmbeddedDownloadUrl(body);
            if (directFileUrl != null) {
              final fileResp = await http
                  .get(Uri.parse(directFileUrl))
                  .timeout(const Duration(seconds: 12));
              if (fileResp.statusCode == 200 &&
                  fileResp.bodyBytes.length > 4 &&
                  fileResp.bodyBytes[0] == 0x50 &&
                  fileResp.bodyBytes[1] == 0x4B) {
                parsedSchedule =
                    Yandex360ScheduleParser.parseOfficeArchiveBytes(
                  fileResp.bodyBytes,
                  targetDates: targetDates,
                );
              }
            }

            // Если это HTML/JSON-представление документа Яндекс 360, парсим его напрямую
            if (parsedSchedule == null || _isAllEmpty(parsedSchedule)) {
              final htmlParsed =
                  Yandex360ScheduleParser.parseHtmlOrJsonDocument(
                body,
                targetDates: targetDates,
              );
              if (!_isAllEmpty(htmlParsed) ||
                  body.toUpperCase().contains('ИСИП')) {
                parsedSchedule = htmlParsed;
              }
            }
          }
        }
      } catch (_) {
        // При ошибке прямого HTTP переходим к рендерингу через встроенный WebView
      }

      // Шаг 2: Если документ рендерится динамически через JS в Яндекс 360,
      // загружаем ссылку через встроенный WebView и извлекаем отрисованную таблицу
      if (parsedSchedule == null || _isAllEmpty(parsedSchedule)) {
        final webViewResult = await _loadScheduleViaWebView(targetDates);
        if (webViewResult.isCaptcha) {
          captchaDetected = true;
        } else if (webViewResult.lessonsByIsoDate != null) {
          parsedSchedule = webViewResult.lessonsByIsoDate;
        }
      }

      if (captchaDetected && (parsedSchedule == null)) {
        setState(() {
          _isLoading = false;
          _isOfflineFallback = _scheduleBundle != null;
          _needsCaptchaVerification = true;
          _statusMessage =
              'Яндекс запросил проверку безопасности (SmartCaptcha). '
              'Нажмите «Пройти проверку», чтобы загрузить свежее расписание.';
        });
        return;
      }

      if (parsedSchedule != null) {
        final newBundle = ScheduleDataBundle(
          lessonsByIsoDate: parsedSchedule,
          fetchedAt: DateTime.now(),
        );
        await _saveToCache(newBundle);
        if (mounted) {
          setState(() {
            _scheduleBundle = newBundle;
            _isLoading = false;
            _isOfflineFallback = false;
            _needsCaptchaVerification = false;
            _statusMessage = null;
          });
        }
      } else {
        throw Exception('Не удалось получить данные документа');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isOfflineFallback = true;
        _statusMessage = _scheduleBundle != null
            ? 'Нет связи с сервером. Показано сохранённое расписание из памяти устройства.'
            : 'Не удалось загрузить расписание. Проверьте подключение к интернету и потяните экран вниз.';
      });
    }
  }

  bool _isAllEmpty(Map<String, List<LessonItem>> map) {
    return map.values.every((list) => list.isEmpty);
  }

  bool _isYandexCaptchaHtml(String html) {
    final lower = html.toLowerCase();
    return lower.contains('showcaptcha') ||
        lower.contains('checkboxcaptcha') ||
        lower.contains('smartcaptcha') ||
        (lower.contains('ой!') && lower.contains('робот'));
  }

  Future<_WebViewParseResult> _loadScheduleViaWebView(
    List<DateTime> targetDates,
  ) async {
    final controller = _headlessWebViewController;
    if (controller == null) {
      return const _WebViewParseResult(isCaptcha: false);
    }

    try {
      _webViewHtmlCompleter = Completer<String>();
      await controller.loadRequest(Uri.parse(kScheduleUrl));
      final rawJsonPayload = await _webViewHtmlCompleter!.future.timeout(
        const Duration(seconds: 15),
      );

      if (rawJsonPayload.isEmpty) {
        return const _WebViewParseResult(isCaptcha: false);
      }

      final payload = jsonDecode(rawJsonPayload) as Map<String, dynamic>;
      final isCaptcha = payload['isCaptcha'] == true;
      final html = (payload['html'] as String?) ?? '';

      if (isCaptcha || _isYandexCaptchaHtml(html)) {
        return const _WebViewParseResult(isCaptcha: true);
      }

      final parsed = Yandex360ScheduleParser.parseHtmlOrJsonDocument(
        html,
        targetDates: targetDates,
      );
      return _WebViewParseResult(
        isCaptcha: false,
        lessonsByIsoDate: parsed,
      );
    } catch (_) {
      return const _WebViewParseResult(isCaptcha: false);
    }
  }

  /// Открывает модальное окно для прохождения SmartCaptcha Яндекса (при необходимости)
  /// После прохождения куки сохраняются в WebView, и парсер работает автоматически
  Future<void> _openInteractiveVerificationSheet() async {
    final controller = _headlessWebViewController;
    if (controller == null) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return FractionallySizedBox(
          heightFactor: 0.85,
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Проверка доступа (Яндекс 360)',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Готово'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: WebViewWidget(controller: controller),
              ),
            ],
          ),
        );
      },
    );

    // После закрытия окна сразу считываем DOM из WebView и обновляем расписание
    try {
      setState(() => _isLoading = true);
      final targetDates = <DateTime>[
        _anchorToday,
        _anchorToday.add(const Duration(days: 1)),
        _anchorToday.add(const Duration(days: 2)),
      ];
      final rawJsonPayload = await _extractDomFromWebView();
      final payload = jsonDecode(rawJsonPayload) as Map<String, dynamic>;
      final html = (payload['html'] as String?) ?? '';
      if (!_isYandexCaptchaHtml(html)) {
        final parsed = Yandex360ScheduleParser.parseHtmlOrJsonDocument(
          html,
          targetDates: targetDates,
        );
        final bundle = ScheduleDataBundle(
          lessonsByIsoDate: parsed,
          fetchedAt: DateTime.now(),
        );
        await _saveToCache(bundle);
        if (mounted) {
          setState(() {
            _scheduleBundle = bundle;
            _isLoading = false;
            _isOfflineFallback = false;
            _needsCaptchaVerification = false;
            _statusMessage = null;
          });
          return;
        }
      }
    } catch (_) {}

    await _fetchAndParseSchedule();
  }

  /// Форматирует подпись даты и дня недели для вкладки (например: «Чт, 15 окт»)
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

  /// Полная подпись выбранного дня над списком пар (например: «Четверг, 15 октября 2026»)
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
        titleSpacing: 20,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Расписание занятий',
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
                        fontSize: 11.5,
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
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.only(right: 8),
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
          const SizedBox(width: 8),
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
      body: Column(
        children: [
          if (_statusMessage != null) _buildStatusBanner(context, isDark),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: List.generate(3, (index) {
                final date = days[index];
                final isoKey = _toIsoDateKey(date);
                final lessons =
                    _scheduleBundle?.lessonsByIsoDate[isoKey] ?? const [];
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
          if (_needsCaptchaVerification) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: _openInteractiveVerificationSheet,
              child: const Text('Пройти проверку'),
            ),
          ],
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
          if (_isLoading && _scheduleBundle == null)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: CircularProgressIndicator(),
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
  Widget _buildEmptyDayPlaceholder(BuildContext context, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
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
            'Потяните экран вниз, чтобы проверить обновление документа',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white38 : const Color(0xFF94A3B8),
            ),
          ),
        ],
      ),
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
            // Верхняя строка: Номер пары + Время проведения | Плашка (badge) кабинета
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
                // Визуальный акцент (badge/плашка) для номера кабинета / аудитории
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

            // Название предмета (крупным, хорошо читаемым шрифтом)
            Text(
              lesson.subject,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                height: 1.3,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),

            // ФИО преподавателя
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

class _WebViewParseResult {
  final bool isCaptcha;
  final Map<String, List<LessonItem>>? lessonsByIsoDate;

  const _WebViewParseResult({
    required this.isCaptcha,
    this.lessonsByIsoDate,
  });
}

/// Универсальный парсер расписания из документа Яндекс 360 со строгой фильтрацией «ИСИП-25-4»
class Yandex360ScheduleParser {
  /// Регулярное выражение для точного поиска ТОЛЬКО группы «ИСИП-25-4»
  /// Отсекает ИСИП-25-1, ИСИП-25-2, ИСИП-25-3, ИСИП-25-41 и любые другие группы
  static final RegExp _targetGroupRegex = RegExp(
    r'(?<![А-ЯЁа-яёA-Za-z0-9])ИСИП\s*[-–—]?\s*25\s*[-–—]\s*4(?![0-9])',
    caseSensitive: false,
    unicode: true,
  );

  /// Регулярное выражение для распознавания заголовка ЛЮБОЙ учебной группы
  static final RegExp _anyGroupHeaderRegex = RegExp(
    r'\b[А-ЯЁA-Z]{2,6}\s*[-–—]\s*\d{2}(?:\s*[-–—]\s*\d{1,2})?\b',
    caseSensitive: false,
    unicode: true,
  );

  /// Стандартное расписание звонков колледжа (используется, если в ячейке указан только номер пары)
  static const Map<int, String> _defaultBellSchedule = {
    1: '08:30 – 10:00',
    2: '10:10 – 11:40',
    3: '12:10 – 13:40',
    4: '13:50 – 15:20',
    5: '15:30 – 17:00',
    6: '17:10 – 18:40',
    7: '18:50 – 20:20',
  };

  /// Извлекает прямую ссылку на скачивание исходного файла из JSON-состояния Яндекс Документов
  static String? extractEmbeddedDownloadUrl(String htmlContent) {
    final patterns = <RegExp>[
      RegExp(r'"downloadUrl"\s*:\s*"([^"]+)"'),
      RegExp(r'"fileUrl"\s*:\s*"([^"]+)"'),
      RegExp(r'"docUrl"\s*:\s*"([^"]+)"'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(htmlContent);
      if (match != null) {
        final raw = match.group(1) ?? '';
        final unescaped = raw
            .replaceAll(r'\u0026', '&')
            .replaceAll(r'\/', '/')
            .replaceAll('&amp;', '&');
        if (unescaped.startsWith('http')) {
          return unescaped;
        }
      }
    }
    return null;
  }

  /// Парсит бинарный архив документа Office (.xlsx или .docx), если Яндекс 360 отдаёт файл напрямую
  static Map<String, List<LessonItem>> parseOfficeArchiveBytes(
    Uint8List bytes, {
    required List<DateTime> targetDates,
  }) {
    final result = <String, List<LessonItem>>{
      for (final d in targetDates) _isoKey(d): <LessonItem>[],
    };

    try {
      final archive = ZipDecoder().decodeBytes(bytes);

      // 1. Проверяем, является ли архив документом Word (.docx: word/document.xml)
      final wordDoc = archive.findFile('word/document.xml');
      if (wordDoc != null) {
        final xmlStr =
            utf8.decode(wordDoc.content as List<int>, allowMalformed: true);
        final grids = _extractDocxTables(xmlStr);
        for (final grid in grids) {
          _parseGridForTargetGroup(
            grid: grid,
            sheetHint: '',
            targetDates: targetDates,
            accumulator: result,
          );
        }
      }

      // 2. Проверяем, является ли архив книгой Excel (.xlsx: xl/worksheets/sheet*.xml)
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
          final tMatches =
              RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true).allMatches(si.group(1)!);
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
              sheetHint: file.name,
              targetDates: targetDates,
              accumulator: result,
            );
          }
        }
      }
    } catch (_) {}

    return result;
  }

  /// Извлекает таблицы из XML документа Word (`word/document.xml`)
  static List<List<List<String>>> _extractDocxTables(String xmlStr) {
    final tables = <List<List<String>>>[];
    final tblMatches =
        RegExp(r'<w:tbl\b[^>]*>(.*?)</w:tbl>', dotAll: true).allMatches(xmlStr);
    for (final tbl in tblMatches) {
      final grid = <List<String>>[];
      final trMatches = RegExp(r'<w:tr\b[^>]*>(.*?)</w:tr>', dotAll: true)
          .allMatches(tbl.group(1)!);
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
      if (grid.isNotEmpty) tables.add(grid);
    }
    return tables;
  }

  /// Извлекает 2D-таблицу из листа Excel (`xl/worksheets/sheet*.xml`)
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

  /// Парсинг HTML-страницы или встроенного JSON-состояния Яндекс 360 Документов
  static Map<String, List<LessonItem>> parseHtmlOrJsonDocument(
    String rawContent, {
    required List<DateTime> targetDates,
  }) {
    final result = <String, List<LessonItem>>{
      for (final d in targetDates) _isoKey(d): <LessonItem>[],
    };

    final doc = html_parser.parse(rawContent);

    // 1. Извлекаем и анализируем все HTML-таблицы (<table>) с учётом colspan и rowspan
    final tables = doc.querySelectorAll('table');
    for (final table in tables) {
      final grid = _tableElementToGrid(table);
      if (grid.isNotEmpty) {
        _parseGridForTargetGroup(
          grid: grid,
          sheetHint: '',
          targetDates: targetDates,
          accumulator: result,
        );
      }
    }

    // 2. Извлекаем ARIA/CSS-сетки редактора таблиц Яндекс 360 ([role="row"] / .row)
    final roleRows = doc.querySelectorAll('[role="row"], .spreadsheet-row');
    if (roleRows.isNotEmpty) {
      final grid = <List<String>>[];
      for (final r in roleRows) {
        final cells = r.querySelectorAll(
          '[role="gridcell"], [role="columnheader"], .cell',
        );
        if (cells.isNotEmpty) {
          grid.add(cells.map((c) => _cleanWhitespace(c.text)).toList());
        }
      }
      if (grid.isNotEmpty) {
        _parseGridForTargetGroup(
          grid: grid,
          sheetHint: '',
          targetDates: targetDates,
          accumulator: result,
        );
      }
    }

    // 3. Если таблицы представлены текстовыми блоками или параграфами
    if (result.values.every((l) => l.isEmpty)) {
      _parseStructuredTextBlocks(
        doc: doc,
        rawContent: rawContent,
        targetDates: targetDates,
        accumulator: result,
      );
    }

    // Сортируем пары внутри каждого дня по номеру пары
    for (final key in result.keys) {
      final list = result[key]!;
      list.sort((a, b) => a.lessonNumber.compareTo(b.lessonNumber));
    }

    return result;
  }

  /// Преобразует HTML `<table>` в нормализованную 2D-матрицу строк с учётом colspan/rowspan
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
            if (dr == 0 && dc == 0) {
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
    return _targetGroupRegex.hasMatch(text) ||
        _anyGroupHeaderRegex.hasMatch(text) ||
        _extractDateFromText(text, referenceYear: DateTime.now().year) != null;
  }

  /// Ядро анализа 2D-таблицы: поддерживает и матричный формат (группа в шапке колонки),
  /// и построчный/блочный формат (группа в колонке «Группа» или заголовке секции)
  static void _parseGridForTargetGroup({
    required List<List<String>> grid,
    required String sheetHint,
    required List<DateTime> targetDates,
    required Map<String, List<LessonItem>> accumulator,
  }) {
    if (grid.isEmpty) return;

    final refYear = targetDates.first.year;
    final targetIsoSet = targetDates.map(_isoKey).toSet();

    DateTime? activeDate =
        _extractDateFromText(sheetHint, referenceYear: refYear);

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

      // Проверяем наличие даты в текущей строке
      DateTime? rowDate;
      if (dateCol != null && dateCol < row.length && row[dateCol].isNotEmpty) {
        rowDate = _extractDateFromText(row[dateCol], referenceYear: refYear);
      }
      if (rowDate == null) {
        for (int c = 0; c < row.length && c <= (groupColStart ?? 4); c++) {
          final d = _extractDateFromText(row[c], referenceYear: refYear);
          if (d != null) {
            rowDate = d;
            break;
          }
        }
      }
      if (rowDate != null) {
        activeDate = rowDate;
      }

      // Ищем ячейку с целевой группой «ИСИП-25-4» в текущей строке
      int? foundTargetCol;
      for (int c = 0; c < row.length; c++) {
        if (_targetGroupRegex.hasMatch(row[c])) {
          foundTargetCol = c;
          break;
        }
      }

      // Подсчитываем, сколько разных групп указано в этой строке
      final groupsInRowCount =
          row.where((c) => _anyGroupHeaderRegex.hasMatch(c)).length;

      if (foundTargetCol != null) {
        // Сценарий А: Строка содержит сразу несколько заголовков групп (Матричная шапка)
        // или заголовок таблицы с «Пара / Время / ИСИП-25-4»
        final hasHeaderKeywords = row.any((c) {
          final l = c.toLowerCase();
          return l.contains('пара') || l.contains('время') || l.contains('№');
        });

        if (groupsInRowCount >= 2 || hasHeaderKeywords || foundTargetCol >= 1) {
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
          // Сценарий Б: Блочный или построчный режим (секция группы ИСИП-25-4)
          inTargetGroupRowSection = true;
          groupColStart = null;
          groupColEnd = null;
          // Если в этой же строке кроме названия группы уже записана пара, извлекаем её
          final otherCells = <String>[];
          for (int c = 0; c < row.length; c++) {
            if (c != foundTargetCol && row[c].trim().isNotEmpty) {
              otherCells.add(row[c].trim());
            }
          }
          if (otherCells.isNotEmpty &&
              activeDate != null &&
              targetIsoSet.contains(_isoKey(activeDate))) {
            _tryExtractLessonFromFlatRow(
              cells: otherCells,
              activeDate: activeDate,
              accumulator: accumulator,
            );
          }
          continue;
        }
      }

      // Если в строке указаны другие группы, но НЕТ ИСИП-25-4
      if (groupsInRowCount >= 1) {
        if (groupsInRowCount >= 2) {
          groupColStart = null;
          groupColEnd = null;
        }
        inTargetGroupRowSection = false;
        continue;
      }

      // Извлечение пар в Матричном режиме (по колонке ИСИП-25-4)
      if (groupColStart != null &&
          groupColEnd != null &&
          activeDate != null &&
          targetIsoSet.contains(_isoKey(activeDate))) {
        final lesson = _extractLessonFromMatrixRow(
          grid: grid,
          rowIndex: r,
          groupColStart: groupColStart,
          groupColEnd: groupColEnd,
          lessonNumCol: lessonNumCol,
          timeCol: timeCol,
        );
        if (lesson != null) {
          _addOrMergeLesson(accumulator[_isoKey(activeDate)]!, lesson);
        }
      } else if (inTargetGroupRowSection &&
          activeDate != null &&
          targetIsoSet.contains(_isoKey(activeDate))) {
        // Извлечение пар в Секционном/Построчном режиме
        _tryExtractLessonFromFlatRow(
          cells: nonEmptyCells,
          activeDate: activeDate,
          accumulator: accumulator,
        );
      }
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

  static void _tryExtractLessonFromFlatRow({
    required List<String> cells,
    required DateTime activeDate,
    required Map<String, List<LessonItem>> accumulator,
  }) {
    int? lessonNumber;
    String timeRange = '';
    final contentCells = <String>[];

    for (final cell in cells) {
      if (_extractDateFromText(cell, referenceYear: activeDate.year) != null &&
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

    if (contentCells.isEmpty) return;
    lessonNumber ??=
        (timeRange.isNotEmpty ? _inferLessonNumberFromTime(timeRange) : null) ??
            (accumulator[_isoKey(activeDate)]!.length + 1);
    if (timeRange.isEmpty) {
      timeRange = _defaultBellSchedule[lessonNumber] ?? '';
    }

    final item = _parseRawLessonCells(
      groupCells: contentCells,
      lessonNumber: lessonNumber,
      timeRange: timeRange,
    );
    if (item != null) {
      _addOrMergeLesson(accumulator[_isoKey(activeDate)]!, item);
    }
  }

  /// Извлекает карточку пары из строки матрицы для колонки группы «ИСИП-25-4»
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
    if (_isEmptyPlaceholderCell(combinedCellText)) return null;

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

    // Если номер пары был указан в предыдущей строке (для двухстрочных ячеек предмета/преподавателя)
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

  /// Разбирает содержимое ячеек группы на Предмет, Кабинет и ФИО преподавателя
  static LessonItem? _parseRawLessonCells({
    required List<String> groupCells,
    required int lessonNumber,
    required String timeRange,
  }) {
    var workingCells = List<String>.from(groupCells);
    String classroom = '';
    String teacher = '';
    final subjectParts = <String>[];

    // Если отдельная правая подколонка содержит короткий номер кабинета (например, «305», «214а», «Спортзал»)
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
        r'(?:каб\.?|ауд\.?|к\.?)\s*([0-9]{1,4}[а-яА-Яa-zA-Z/-]*)|\b(спортзал|актовый\s+зал|дистант|онлайн|дот)\b',
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
        r'([А-ЯЁ][а-яё]{2,}\s+[А-ЯЁ]\.\s*[А-ЯЁ]\.|[А-ЯЁ]\.\s*[А-ЯЁ]\.\s+[А-ЯЁ][а-яё]{2,})',
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

  /// Объединяет две подстроки одной и той же пары (например, 1-я строка — предмет, 2-я — преподаватель)
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

  /// Резервный парсер текстовых блоков документа (для текстовых представлений Яндекс 360)
  static void _parseStructuredTextBlocks({
    required dom.Document doc,
    required String rawContent,
    required List<DateTime> targetDates,
    required Map<String, List<LessonItem>> accumulator,
  }) {
    final refYear = targetDates.first.year;
    final targetIsoSet = targetDates.map(_isoKey).toSet();

    final textLines = (doc.body?.text ?? rawContent)
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    DateTime? currentDate;
    bool insideTargetGroup = false;

    for (final line in textLines) {
      final maybeDate = _extractDateFromText(line, referenceYear: refYear);
      if (maybeDate != null) {
        currentDate = maybeDate;
      }

      if (_targetGroupRegex.hasMatch(line)) {
        insideTargetGroup = true;
        continue;
      } else if (_anyGroupHeaderRegex.hasMatch(line)) {
        insideTargetGroup = false;
        continue;
      }

      if (insideTargetGroup &&
          currentDate != null &&
          targetIsoSet.contains(_isoKey(currentDate))) {
        final pairMatch = RegExp(
          r'^([1-8])\s*(?:пара|п\.|\))\s*(.*)$',
          caseSensitive: false,
          unicode: true,
        ).firstMatch(line);

        if (pairMatch != null) {
          final pairNum = int.parse(pairMatch.group(1)!);
          var rest = pairMatch.group(2)!.trim();
          final time =
              _extractTimeRange(rest) ?? (_defaultBellSchedule[pairNum] ?? '');
          if (time.isNotEmpty) {
            rest = rest.replaceFirst(time, '').trim();
          }
          final item = _parseRawLessonCells(
            groupCells: [rest],
            lessonNumber: pairNum,
            timeRange: time,
          );
          if (item != null) {
            accumulator[_isoKey(currentDate)]!.add(item);
          }
        }
      }
    }
  }

  /// Извлекает дату из строки документа в форматах «15.10.2026», «15.10», «15 октября» и т.д.
  static DateTime? _extractDateFromText(
    String text, {
    required int referenceYear,
  }) {
    if (text.isEmpty) return null;
    final cleaned = text.toLowerCase().trim();

    // 1. Формат DD.MM.YYYY или DD.MM.YY или DD/MM/YYYY
    final numericFull = RegExp(
      r'(?<![0-9])([0-3]?\d)[./]([0-1]?\d)[./](20\d{2}|\d{2})(?![0-9])',
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

    // 2. Словесный формат: «15 октября 2026» или «четверг, 15 октября»
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
      r'(?<![0-9])([0-3]?\d)\s+(января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря)(?:\s+(20\d{2}))?',
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

    // 3. Короткий числовой формат DD.MM рядом с днём недели или словом «дата»
    final hasWeekdayOrDateHint = RegExp(
      r'(понедельник|вторник|среда|четверг|пятница|суббота|воскресенье|пн|вт|ср|чт|пт|сб|вс|дата|расписание)',
      unicode: true,
    ).hasMatch(cleaned);

    if (hasWeekdayOrDateHint || cleaned.length <= 12) {
      final shortDate =
          RegExp(r'(?<![0-9:])([0-3]?\d)\.([0-1]\d)(?![0-9.])')
              .firstMatch(cleaned);
      if (shortDate != null) {
        final day = int.tryParse(shortDate.group(1)!);
        final month = int.tryParse(shortDate.group(2)!);
        if (day != null &&
            month != null &&
            month >= 1 &&
            month <= 12 &&
            day >= 1 &&
            day <= 31) {
          return DateTime(referenceYear, month, day);
        }
      }
    }

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
      r'^(?:(?:каб\.?|ауд\.?)\s*)?[0-9]{1,4}[а-яА-Яa-zA-Z/-]*$|^(?:спортзал|актовый зал|дистант|дот)$',
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

  static String _cleanWhitespace(String input) =>
      input.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _cleanMultilineCell(String input) {
    return input
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }

  static String _isoKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
