import 'dart:convert';
import 'package:canvas_app/models/quest_table_model.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

class TableViewerScreen extends StatefulWidget {
  final String tableName;
  final QuestTable table;

  const TableViewerScreen({
    super.key,
    required this.tableName,
    required this.table,
  });

  @override
  State<TableViewerScreen> createState() => _TableViewerScreenState();
}

class _TableViewerScreenState extends State<TableViewerScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ScrollController _verticalScroll = ScrollController();
  final ScrollController _horizontalScroll = ScrollController();

  bool get _hasRows => widget.table.rows.isNotEmpty;

  @override
  void initState() {
    super.initState();
    int tabCount = 1;
    if (_hasRows) tabCount++;

    _tabController = TabController(length: tabCount, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _verticalScroll.dispose();
    _horizontalScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.tableName,
              style: GoogleFonts.manrope(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            Text(
              tr('Просмотр данных'),
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ],
        ),
        bottom: _buildTabBar(),
      ),
      body: AdaptiveContent(maxWidth: 1100, child: _buildBody()),
    );
  }

  PreferredSizeWidget? _buildTabBar() {
    final tabs = <Widget>[];
    if (_hasRows) tabs.add(Tab(text: tr('Строки (Таблица)')));
    tabs.add(Tab(text: tr('Данные (Дерево)')));

    return TabBar(
      controller: _tabController,
      indicatorColor: Colors.orangeAccent,
      labelColor: Colors.orangeAccent,
      unselectedLabelColor: Colors.white54,
      tabs: tabs,
    );
  }

  Widget _buildBody() {
    final views = <Widget>[];

    if (_hasRows) {
      views.add(_buildRowsView());
    }

    views.add(_buildDataTreeView());

    return TabBarView(controller: _tabController, children: views);
  }

  Widget _buildRowsView() {
    if (widget.table.rows.isEmpty) {
      return Center(
        child: Text(tr('Список пуст'), style: TextStyle(color: Colors.white38)),
      );
    }

    final allColumns = {...widget.table.columns};
    for (var row in widget.table.rows) {
      allColumns.addAll(row.keys);
    }
    final columnsList = allColumns.toList();

    return Scrollbar(
      controller: _horizontalScroll,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _horizontalScroll,
        scrollDirection: Axis.horizontal,
        child: SingleChildScrollView(
          controller: _verticalScroll,
          child: DataTable(
            headingRowColor: MaterialStateProperty.all(const Color(0xFF2A2A2A)),
            dataRowColor: MaterialStateProperty.resolveWith((states) {
              return const Color(0xFF121212);
            }),
            border: TableBorder.all(color: Colors.white10),
            columns: [
              const DataColumn(
                label: Text('#', style: TextStyle(color: Colors.grey)),
              ),
              ...columnsList.map(
                (col) => DataColumn(
                  label: Text(
                    col,
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
            rows: List.generate(widget.table.rows.length, (index) {
              final row = widget.table.rows[index];
              return DataRow(
                cells: [
                  DataCell(
                    Text(
                      '${index + 1}',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                  ...columnsList.map((col) {
                    final val = row[col];
                    final nested = QuestTable.nestedFromValue(val);
                    final cell = nested != null
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.grid_on_rounded,
                                size: 16,
                                color: Colors.orangeAccent,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  trf('Таблица {p0}×{p1}', {
                                    'p0': nested.columns.length,
                                    'p1': nested.rows.length,
                                  }),
                                  style: GoogleFonts.firaCode(
                                    color: Colors.orangeAccent,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const Icon(
                                Icons.chevron_right,
                                size: 16,
                                color: Colors.orangeAccent,
                              ),
                            ],
                          )
                        : Text(
                            _formatValueSimple(val),
                            style: GoogleFonts.firaCode(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                            overflow: TextOverflow.ellipsis,
                          );
                    return DataCell(
                      Container(
                        constraints: const BoxConstraints(maxWidth: 200),
                        child: cell,
                      ),
                      onTap: () => nested != null
                          ? _openNestedTable(index, col, nested)
                          : _showFullValue(col, val),
                    );
                  }),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _buildDataTreeView() {
    if (widget.table.data.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.data_object, size: 64, color: Colors.white12),
            const SizedBox(height: 16),
            Text(
              tr('Хранилище данных пусто'),
              style: TextStyle(color: Colors.white38),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        _JsonNodeWidget(
          keyName: "root",
          value: widget.table.data,
          isRoot: true,
        ),
      ],
    );
  }

  String _formatValueSimple(dynamic value) {
    if (value == null) return "null";
    if (value is String) return '"$value"';
    if (value is num || value is bool) return value.toString();
    try {
      return jsonEncode(value);
    } catch (_) {
      return value.toString();
    }
  }

  void _openNestedTable(int rowIndex, String column, QuestTable nested) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TableViewerScreen(
          tableName: '${widget.tableName}.$column${rowIndex + 1}',
          table: nested,
        ),
      ),
    );
  }

  void _showFullValue(String key, dynamic value) {
    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(key, style: const TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: SelectableText(
            _formatValueSimple(value),
            style: GoogleFonts.firaCode(color: Colors.white, fontSize: 14),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Закрыть')),
          ),
        ],
      ),
    );
  }
}

class _JsonNodeWidget extends StatelessWidget {
  final dynamic keyName;
  final dynamic value;
  final bool isRoot;

  const _JsonNodeWidget({
    required this.keyName,
    required this.value,
    this.isRoot = false,
  });

  @override
  Widget build(BuildContext context) {
    if (value is Map) {
      return _buildMapNode(context, value as Map);
    } else if (value is List) {
      return _buildListNode(context, value as List);
    } else {
      return _buildPrimitiveNode();
    }
  }

  Widget _buildMapNode(BuildContext context, Map map) {
    final title = isRoot ? 'ROOT (Object)' : '$keyName: Object {${map.length}}';

    if (isRoot) {
      // Для корня сразу разворачиваем
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: map.entries.map((e) {
          return Padding(
            padding: const EdgeInsets.only(left: 8.0),
            child: _JsonNodeWidget(keyName: e.key, value: e.value),
          );
        }).toList(),
      );
    }

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: Text(
          title,
          style: GoogleFonts.firaCode(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.orangeAccent,
          ),
        ),
        childrenPadding: const EdgeInsets.only(left: 16),
        collapsedIconColor: Colors.white54,
        iconColor: Colors.orangeAccent,
        children: map.entries.map((e) {
          return _JsonNodeWidget(keyName: e.key, value: e.value);
        }).toList(),
      ),
    );
  }

  Widget _buildListNode(BuildContext context, List list) {
    final title = '$keyName: Array [${list.length}]';

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: Text(
          title,
          style: GoogleFonts.firaCode(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.blueAccent,
          ),
        ),
        childrenPadding: const EdgeInsets.only(left: 16),
        collapsedIconColor: Colors.white54,
        iconColor: Colors.blueAccent,
        children: list.asMap().entries.map((e) {
          return _JsonNodeWidget(keyName: "[${e.key}]", value: e.value);
        }).toList(),
      ),
    );
  }

  Widget _buildPrimitiveNode() {
    Color valueColor = Colors.white;
    String displayValue = "$value";

    if (value is String) {
      valueColor = Colors.greenAccent;
      displayValue = '"$value"';
    } else if (value is num) {
      valueColor = Colors.lightBlueAccent;
    } else if (value is bool) {
      valueColor = Colors.purpleAccent;
    } else if (value == null) {
      valueColor = Colors.grey;
      displayValue = "null";
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "$keyName: ",
            style: GoogleFonts.firaCode(color: Colors.white70, fontSize: 13),
          ),
          Expanded(
            child: SelectableText(
              displayValue,
              style: GoogleFonts.firaCode(color: valueColor, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
