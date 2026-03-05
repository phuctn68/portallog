// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:portal_log/model/heartbeat_log_entry.dart';
import 'package:portal_log/utils/utils.dart';
import 'package:printing/printing.dart';
import 'package:http/http.dart' as http; // Thêm ' as http;

class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  List<HeartbeatLogEntry> _allLogs = [];
  List<int> _filteredIndices = [];
  String _searchText = '';
  final TextEditingController _searchController = TextEditingController();
  String? _error;
  String? _loadedFileName;
  bool _sortAscending = true;
  int _rowsPerPage = 50;
  int _currentPage = 0;
  final List<int> _pageSizeOptions = [50, 100, 200, 500, 1000];
  bool _isFileLoading = false;
  bool _isTableLoading = false;
  DateTime? _fromGenDateTime;
  DateTime? _toGenDateTime;
  Timer? _searchDebounce;
  bool _showUserIdColumn = true;
  final ScrollController _tableScrollController = ScrollController();
  final DateFormat _dateTimeLabel = DateFormat('dd/MM/yyyy HH:mm');
  double? _importProgress;
  int _importToken = 0;
  int _filterToken = 0;

  bool get _busy => _isFileLoading || _isTableLoading;
  int get _total => _filteredIndices.length;
  int get _pageCount => _total == 0 ? 1 : (_total / _rowsPerPage).ceil();
  int get _currentPageSafe {
    if (_total == 0) return 0;
    return _currentPage.clamp(0, _pageCount - 1);
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    
    // Tự động gọi API ngay khi giao diện dựng xong
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchLogsFromDB();
    });
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchDebounce?.cancel();
    _tableScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _total;
    final pageCount = _pageCount;
    final currentPage = _currentPageSafe;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final slice = _slicePage();
    final startIndex = slice.start;
    final endIndex = slice.end;
    final pageLogs = slice.logs;

    return Scaffold(
      appBar: AppBar(title: const Text('Heartbeat Device Log Viewer')),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _headerView(scheme),

                const SizedBox(height: 12),

                _filterTextView(scheme),

                const SizedBox(height: 8),

                _filterDateTimeView(scheme),

                const SizedBox(height: 8),

                _loadingTableView,

                const SizedBox(height: 8),
                if (_error != null) _errorTextView,
                const SizedBox(height: 8),
                Expanded(
                  child: _pageTableView(
                    theme: theme,
                    pageLogs: pageLogs,
                    total: total,
                    pageCount: pageCount,
                    currentPage: currentPage,
                    startIndex: startIndex,
                    endIndex: endIndex,
                  ),
                ),
              ],
            ),
          ),

          if (_isFileLoading) _loadingView,
        ],
      ),
    );
  }

  Widget get _errorTextView =>
      Text(_error!, style: const TextStyle(color: Colors.red));

  Widget get _loadingView => Positioned.fill(
    child: Container(
      color: Colors.black.withAlpha(10),
      child: Center(
        child: Card(
          elevation: 10,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 14),
                const Text('Đang tải CSV...'),
                const SizedBox(height: 10),
                SizedBox(
                  width: 220,
                  child: LinearProgressIndicator(
                    value: _importProgress,
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 8),
                if (_importProgress != null)
                  Text(
                    '${(_importProgress! * 100).clamp(0, 100).toStringAsFixed(0)}%',
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget get _loadingTableView => AnimatedSwitcher(
    duration: const Duration(milliseconds: 200),
    child: _isTableLoading
        ? const LinearProgressIndicator(key: ValueKey('loading'))
        : const SizedBox(key: ValueKey('no_loading'), height: 4),
  );

  Widget _headerView(ColorScheme scheme) => Row(
    children: [
      FilledButton.icon(
        onPressed: _busy ? null : _fetchLogsFromDB, // Đổi từ chọn file sang fetch API
        icon: const Icon(Icons.refresh), // Đổi icon cho hợp lý
        label: const Text('Làm mới dữ liệu'),
      ),
      const SizedBox(width: 8),
      FilledButton.tonalIcon(
        onPressed: (_busy || _filteredIndices.isEmpty)
            ? null
            : _exportFilteredToPdf,
        icon: const Icon(Icons.picture_as_pdf),
        label: const Text('Export PDF'),
      ),
      const SizedBox(width: 12),
      if (_loadedFileName != null)
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(999),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.coffee, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      '$_loadedFileName • ${_allLogs.length} log(s)',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontStyle: FontStyle.italic,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );

  Widget _filterTextView(ColorScheme scheme) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _searchController,
        builder: (context, value, _) {
          final hasText = value.text.isNotEmpty;
          return TextField(
            controller: _searchController,
            enabled: !_isFileLoading,
            decoration: InputDecoration(
              labelText: 'Search theo message / user_id / error',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: scheme.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
              suffixIcon: hasText
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => _searchController.clear(),
                    )
                  : null,
            ),
          );
        },
      );

  Widget _filterDateTimeView(ColorScheme scheme) => Row(
    children: [
      Expanded(
        child: OutlinedButton.icon(
          onPressed: _busy ? null : _pickFromGenDateTime,
          icon: const Icon(Icons.calendar_today),
          label: Text(
            _fromGenDateTime == null
                ? 'From gen_time'
                : 'From: ${_dateTimeLabel.format(_fromGenDateTime!)}',
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: scheme.primary,
            side: BorderSide(color: scheme.outlineVariant),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: OutlinedButton.icon(
          onPressed: _busy ? null : _pickToGenDateTime,
          icon: const Icon(Icons.calendar_today_outlined),
          label: Text(
            _toGenDateTime == null
                ? 'To gen_time'
                : 'To: ${_dateTimeLabel.format(_toGenDateTime!)}',
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: scheme.primary,
            side: BorderSide(color: scheme.outlineVariant),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
      IconButton(
        tooltip: 'Xoá filter thời gian',
        onPressed: _busy ? null : _clearTimeFilter,
        icon: const Icon(Icons.clear),
      ),
    ],
  );

  Widget _pageTableView({
    required ThemeData theme,
    required List<HeartbeatLogEntry> pageLogs,
    required int total,
    required int pageCount,
    required int currentPage,
    required int startIndex,
    required int endIndex,
  }) {
    if (total == 0) {
      return const Center(
        child: Text('Không có dữ liệu (hoặc chưa chọn file).'),
      );
    }

    final cellStyle = theme.textTheme.bodyMedium;
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Card(
            color: scheme.surface,
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // header
                  Container(
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      border: Border(
                        bottom: BorderSide(color: scheme.outlineVariant),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (_showUserIdColumn)
                          Expanded(
                            flex: 3,
                            child: Text(
                              'user_id',
                              style: theme.textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: scheme.onPrimary,
                              ),
                            ),
                          ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            'created_at',
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: scheme.onPrimary,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: InkWell(
                            onTap: _busy ? null : _toggleSort,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'gen_time',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: scheme.onPrimary,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  _sortAscending
                                      ? Icons.arrow_upward
                                      : Icons.arrow_downward,
                                  size: 16,
                                  color: scheme.onPrimary,
                                ),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 12,
                          child: Text(
                            'message',
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: scheme.onPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // body
                  Expanded(
                    child: SelectionArea(
                      child: Scrollbar(
                        controller: _tableScrollController,
                        thumbVisibility: true,
                        child: ListView.builder(
                          controller: _tableScrollController,
                          itemCount: pageLogs.length,
                          itemBuilder: (context, index) {
                            final log = pageLogs[index];
                            final globalIndex = startIndex + index;

                            final isEven = globalIndex.isEven;
                            final baseRowColor = isEven
                                ? scheme.surface
                                : scheme.primaryContainer.withAlpha(80);

                            final hasErr = log.hasError;

                            final rowColor = hasErr
                                ? scheme.errorContainer.withAlpha(170)
                                : baseRowColor;

                            final textColor = hasErr
                                ? scheme.onErrorContainer
                                : scheme.onSurface;

                            return Container(
                              decoration: BoxDecoration(
                                color: rowColor,
                                border: hasErr
                                    ? Border(
                                        left: BorderSide(
                                          color: scheme.error,
                                          width: 4,
                                        ),
                                      )
                                    : null,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (_showUserIdColumn)
                                    Expanded(
                                      flex: 3,
                                      child: Text(
                                        log.userId,
                                        style: cellStyle?.copyWith(
                                          color: textColor,
                                        ),
                                      ),
                                    ),
                                  Expanded(
                                    flex: 2,
                                    child: Text(
                                      log.createdAt,
                                      style: cellStyle?.copyWith(
                                        color: textColor,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 2,
                                    child: Text(
                                      log.genTimeFormatted,
                                      style: cellStyle?.copyWith(
                                        color: textColor,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 12,
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (hasErr) ...[
                                          Icon(
                                            Icons.error_outline,
                                            size: 16,
                                            color: scheme.error,
                                          ),
                                          const SizedBox(width: 6),
                                        ],
                                        Expanded(
                                          child: Text(
                                            log.message,
                                            style: cellStyle?.copyWith(
                                              color: textColor,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 8),

        // pagination
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Text(
                  'Trang ${currentPage + 1} / $pageCount · '
                  'Hiển thị ${startIndex + 1}–$endIndex / $total',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 16),
                Text('Rows/page:', style: theme.textTheme.bodySmall),
                const SizedBox(width: 4),
                DropdownButton<int>(
                  value: _rowsPerPage,
                  borderRadius: BorderRadius.circular(16),
                  focusColor: scheme.primaryContainer,
                  items: _pageSizeOptions
                      .map(
                        (v) =>
                            DropdownMenuItem<int>(value: v, child: Text('$v')),
                      )
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value == null) return;
                          _changeRowsPerPage(value);
                        },
                ),
              ],
            ),
            Row(
              children: [
                IconButton.filledTonal(
                  onPressed: _busy || currentPage <= 0
                      ? null
                      : () => _changePage(currentPage - 1),
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Trang trước',
                ),
                const SizedBox(width: 4),
                Text('${currentPage + 1}', style: theme.textTheme.bodyMedium),
                const SizedBox(width: 4),
                IconButton.filledTonal(
                  onPressed: _busy || currentPage >= pageCount - 1
                      ? null
                      : () => _changePage(currentPage + 1),
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Trang sau',
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    // Tăng thời gian chờ lên 500ms để tránh gửi request liên tục khi đang gõ
    _searchDebounce = Timer(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      
      // Quan trọng: Gọi hàm fetch từ Database thay vì lọc local
      _fetchLogsFromDB(); 
    });
  }

  Future<void> _ensureOverlayPainted() async {
    await Future<void>.delayed(Duration.zero);
    await WidgetsBinding.instance.endOfFrame;
  }

  // TODO: IMPORT CSV

  // Thay thế hoặc sửa lại hàm nạp dữ liệu
  Future<void> _fetchLogsFromDB() async {
    setState(() {
      _isFileLoading = true;
      _error = null;
    });

    try {
      // 1. Lấy nội dung từ ô Search
      final String searchText = _searchController.text.trim();
      
      // 2. Xây dựng URL kèm tham số search (phải khớp với request.GET.get('search') ở Django)
      // Nếu bạn muốn tìm theo cả user_id thì có thể tách ra hoặc gửi chung vào tham số search
      final String url = '/monitoring/heartbeat/logs/api?search=$searchText';

      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final List<dynamic> rawData = json.decode(response.body);
        
        final logs = rawData.map((m) => HeartbeatLogEntry(
          createdAt: m['createdAt'] ?? '',
          userId: m['userId'] ?? '',
          typeData: m['typeData'] ?? 0,
          message: m['message'] ?? '',
          genTime: m['genTime'] ?? 0,
          error: m['error']?.toString(),
        )).toList();

        setState(() {
          _allLogs = logs;
          _filteredIndices = List<int>.generate(logs.length, (i) => i);
        });
        
        // Không cần gọi _applyFilters nữa vì Server đã lọc hộ rồi
      } else {
        setState(() => _error = 'Lỗi: ${response.statusCode}');
      }
    } catch (e) {
      setState(() => _error = 'Lỗi kết nối: $e');
    } finally {
      setState(() => _isFileLoading = false);
    }
  }

  // TODO: FILTER

  Future<void> _applyFilters({required bool resetPage}) async {
    if (_isFileLoading) return;

    final int token = ++_filterToken;

    final fromMs = _fromGenDateTime?.toUtc().millisecondsSinceEpoch;
    final toMs = _toGenDateTime?.toUtc().millisecondsSinceEpoch;

    final searchLower = _searchText.trim().toLowerCase();
    final asc = _sortAscending;

    setState(() => _isTableLoading = true);

    await Future<void>.delayed(Duration.zero);
    if (!mounted || token != _filterToken) return;

    final indices = await _filterIndicesChunked(
      token: token,
      searchLower: searchLower,
      fromMs: fromMs,
      toMs: toMs,
      asc: asc,
    );

    if (!mounted || token != _filterToken) return;

    setState(() {
      _filteredIndices = indices;
      if (resetPage) _currentPage = 0;
      _isTableLoading = false;
    });

    if (_tableScrollController.hasClients) {
      _tableScrollController.jumpTo(0);
    }
  }

  Future<List<int>> _filterIndicesChunked({
    required int token,
    required String searchLower,
    required int? fromMs,
    required int? toMs,
    required bool asc,
  }) async {
    final out = <int>[];
    final n = _allLogs.length;

    const int chunkSize = 3000;

    bool pass(HeartbeatLogEntry log) {
      if (fromMs != null && log.genTime < fromMs) return false;
      if (toMs != null && log.genTime > toMs) return false;

      if (searchLower.isNotEmpty) {
        final msg = log.message.toLowerCase();
        final uid = log.userId.toLowerCase();
        final err = (log.error ?? '').toLowerCase();
        if (!msg.contains(searchLower) &&
            !uid.contains(searchLower) &&
            !err.contains(searchLower)) {
          return false;
        }
      }
      return true;
    }

    if (asc) {
      for (int start = 0; start < n; start += chunkSize) {
        if (token != _filterToken) return const <int>[];
        final end = math.min(start + chunkSize, n);
        for (int i = start; i < end; i++) {
          if (pass(_allLogs[i])) out.add(i);
        }
        await Future<void>.delayed(Duration.zero);
      }
    } else {
      for (int end = n; end > 0; end -= chunkSize) {
        if (token != _filterToken) return const <int>[];
        final start = math.max(0, end - chunkSize);
        for (int i = end - 1; i >= start; i--) {
          if (pass(_allLogs[i])) out.add(i);
        }
        await Future<void>.delayed(Duration.zero);
      }
    }

    return out;
  }

  // TODO: EXPORT PDF

  Future<void> _exportFilteredToPdf() async {
    if (_filteredIndices.isEmpty) {
      setState(() => _error = 'Không có dữ liệu để export PDF.');
      return;
    }

    final baseFont = await PdfGoogleFonts.notoSansRegular();
    final boldFont = await PdfGoogleFonts.notoSansBold();
    final doc = pw.Document();

    final now = DateTime.now();
    final title = 'Heartbeat Device Logs';
    final subtitle =
        'Export at ${DateFormat('yyyy-MM-dd HH:mm:ss').format(now)}';
    final total = _filteredIndices.length;

    final showUid = _showUserIdColumn;
    final hasAnyError = _filteredIndices.any((i) => _allLogs[i].hasError);

    final headers = <String>[
      if (showUid) 'user_id',
      'created_at',
      'gen_time',
      if (hasAnyError) 'error',
      'message',
    ];

    final data = _filteredIndices.map((i) {
      final log = _allLogs[i];
      return <String>[
        if (showUid) log.userId,
        log.createdAt,
        log.genTimeFormatted,
        if (hasAnyError) (log.error ?? ''),
        log.message,
      ];
    }).toList();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        theme: pw.ThemeData.withFont(base: baseFont, bold: boldFont),
        header: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              title,
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              subtitle,
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              'Total: $total record(s)',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 8),
            pw.Divider(thickness: 0.5),
            pw.SizedBox(height: 4),
          ],
        ),
        footer: (context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 8),
          child: pw.Text(
            'Page ${context.pageNumber} / ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
          ),
        ),
        build: (_) => [
          pw.TableHelper.fromTextArray(
            headers: headers,
            data: data,
            headerStyle: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              fontSize: 9,
            ),
            cellStyle: const pw.TextStyle(fontSize: 8),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 3,
              vertical: 2,
            ),
          ),
        ],
      ),
    );

    await Printing.layoutPdf(onLayout: (_) async => doc.save());
  }

  // TODO: DATE PICKERS

  Future<void> _pickFromGenDateTime() async {
    if (_busy) return;

    final now = DateTime.now();
    final initial =
        _fromGenDateTime ??
        (_allLogs.isNotEmpty ? _allLogs.first.genTimeDateTime : now);

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pickedDate == null) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );

    final result = pickedTime != null
        ? DateTime(
            pickedDate.year,
            pickedDate.month,
            pickedDate.day,
            pickedTime.hour,
            pickedTime.minute,
          )
        : DateTime(pickedDate.year, pickedDate.month, pickedDate.day);

    setState(() => _fromGenDateTime = result);
    await _applyFilters(resetPage: true);
  }

  Future<void> _pickToGenDateTime() async {
    if (_busy) return;

    final now = DateTime.now();
    final initial =
        _toGenDateTime ??
        (_allLogs.isNotEmpty ? _allLogs.last.genTimeDateTime : now);

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pickedDate == null) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );

    final result = pickedTime != null
        ? DateTime(
            pickedDate.year,
            pickedDate.month,
            pickedDate.day,
            pickedTime.hour,
            pickedTime.minute,
          )
        : DateTime(pickedDate.year, pickedDate.month, pickedDate.day, 23, 59);

    setState(() => _toGenDateTime = result);
    await _applyFilters(resetPage: true);
  }

  Future<void> _clearTimeFilter() async {
    if (_busy) return;
    if (_fromGenDateTime == null && _toGenDateTime == null) return;

    setState(() {
      _fromGenDateTime = null;
      _toGenDateTime = null;
    });
    await _applyFilters(resetPage: true);
  }

  // TODO: PAGING + SORT

  void _changePage(int newPage) {
    if (_busy) return;
    setState(() => _currentPage = newPage);
    if (_tableScrollController.hasClients) _tableScrollController.jumpTo(0);
  }

  void _changeRowsPerPage(int newSize) {
    if (_busy) return;
    if (newSize == _rowsPerPage) return;
    setState(() {
      _rowsPerPage = newSize;
      _currentPage = 0;
    });
    if (_tableScrollController.hasClients) _tableScrollController.jumpTo(0);
  }

  Future<void> _toggleSort() async {
    if (_busy) return;
    setState(() => _sortAscending = !_sortAscending);
    await _applyFilters(resetPage: true);
  }

  // TODO: PAGE SLICE

  ({int start, int end, List<HeartbeatLogEntry> logs}) _slicePage() {
    final total = _total;
    if (total == 0) return (start: 0, end: 0, logs: <HeartbeatLogEntry>[]);

    final currentPage = _currentPageSafe;
    final start = currentPage * _rowsPerPage;
    final end = math.min(start + _rowsPerPage, total);

    final idxSlice = _filteredIndices.sublist(start, end);
    final logs = idxSlice.map((i) => _allLogs[i]).toList(growable: false);

    return (start: start, end: end, logs: logs);
  }
}
