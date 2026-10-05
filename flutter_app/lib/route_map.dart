import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'route_map_model.dart';
import 'osm_tile_source.dart';
export 'route_map_model.dart';

/// Offline route geometry is always available. Online OSM tiles are per-view
/// opt-in, only for explicitly WGS84 data, and never upload route/health files.
class WorkoutRouteMap extends StatefulWidget {
  const WorkoutRouteMap({
    super.key,
    required this.lines,
    required this.contentId,
    this.height = 260,
    this.tileSourceFactory,
  });
  final List<RouteMapLine> lines;
  final String contentId;
  final double height;
  final OsmTileSource Function()? tileSourceFactory;
  @override
  State<WorkoutRouteMap> createState() => _WorkoutRouteMapState();
}

class _WorkoutRouteMapState extends State<WorkoutRouteMap>
    with WidgetsBindingObserver {
  final _transform = TransformationController();
  OsmTileSource? _tiles;
  final _futures = <OsmTileKey, Future<Uint8List>>{};
  Timer? _settle;
  ScrollPosition? _ancestorScroll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _transform.addListener(_onTransform);
  }

  void _onTransform() {
    _settle?.cancel();
    // While panning, old tiles simply move; only fetch the settled viewport.
    _tiles?.setVisibleTiles({});
    _futures.clear();
    _settle = Timer(const Duration(milliseconds: 300), () {
      if (mounted && _tiles != null) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scroll = Scrollable.maybeOf(context)?.position;
    if (scroll != _ancestorScroll) {
      _ancestorScroll?.removeListener(_onAncestorScroll);
      _ancestorScroll = scroll;
      _ancestorScroll?.addListener(_onAncestorScroll);
    }
    // ModalRoute registers an inherited dependency, including a covering route
    // whose previous page remains mounted through maintainState.
    if (ModalRoute.isCurrentOf(context) == false) _offline();
  }

  void _onAncestorScroll() {
    // Conservatively revoke consent on parent-page scrolling. This prevents a
    // cached/offscreen sliver from draining its old tile queue after it leaves view.
    if (mounted && _tiles != null) setState(_offline);
  }

  @override
  void didUpdateWidget(covariant WorkoutRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.contentId != widget.contentId ||
        !routeCanUseOsm(widget.lines)) {
      _offline();
      _transform.value = Matrix4.identity();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && mounted && _tiles != null) {
      setState(_offline);
    }
  }

  void _offline() {
    _settle?.cancel();
    _tiles?.close();
    _tiles = null;
    _futures.clear();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ancestorScroll?.removeListener(_onAncestorScroll);
    _offline();
    _transform.dispose();
    super.dispose();
  }

  Future<void> _enable() async {
    final contentId = widget.contentId;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('启用 OpenStreetMap 在线底图？'),
        content: const SingleChildScrollView(
          child: Text(
            '地图瓦片请求会向 OpenStreetMap Foundation 透露你查看的位置区域和 IP 地址，可能据此推断活动位置。'
            '轨迹线在设备本地绘制，不上传 FIT 文件或心率等数据。\n\n'
            '只加载当前视窗，瓦片会缓存到设备。在线服务可能不可用；关闭后继续显示离线轨迹。'
            '本次同意仅适用于当前活动视图；页面切换或滚动后需重新启用。\n\n'
            '隐私政策：https://osmfoundation.org/wiki/Privacy_Policy\n'
            '使用政策：https://operations.osmfoundation.org/policies/tiles/',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('同意并启用'),
          ),
        ],
      ),
    );
    if (approved == true &&
        mounted &&
        contentId == widget.contentId &&
        ModalRoute.isCurrentOf(context) != false &&
        routeCanUseOsm(widget.lines)) {
      setState(() {
        _tiles = widget.tileSourceFactory?.call() ?? CachedOsmTileSource();
      });
    }
  }

  void _attribution() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('OpenStreetMap 地图署名'),
        content: const SelectableText(
          '© OpenStreetMap contributors\n'
          '地图数据采用 Open Database License (ODbL)\n'
          'https://www.openstreetmap.org/copyright\n\n'
          '报告地图问题：https://www.openstreetmap.org/fixthemap',
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(
              const ClipboardData(
                text: 'https://www.openstreetmap.org/copyright',
              ),
            ),
            child: const Text('复制许可链接'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final online = _tiles != null;
    final systems = widget.lines.map((line) => line.coordinateSystem).toSet();
    final points = widget.lines.expand((line) => line.points).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(online ? '在线底图 · WGS-84 · 轨迹仅在本地绘制' : '离线轨迹示意 · 不发送坐标到地图服务'),
        if (!routeCanUseOsm(widget.lines) && points.isNotEmpty)
          Text(
            systems.contains(RouteCoordinateSystem.gcj02)
                ? 'GCJ-02 原始坐标仅作离线示意；请使用核心转换后的 WGS-84 轨迹查看底图'
                : '坐标系未确认，在线底图不可用，避免将原始坐标误作 WGS-84',
          ),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: () {
                _transform.value = Matrix4.identity();
              },
              icon: const Icon(Icons.center_focus_strong),
              label: const Text('回到轨迹'),
            ),
            IconButton(
              tooltip: '放大',
              onPressed: () => _zoom(2),
              icon: const Icon(Icons.add),
            ),
            IconButton(
              tooltip: '缩小',
              onPressed: () => _zoom(.5),
              icon: const Icon(Icons.remove),
            ),
            if (routeCanUseOsm(widget.lines))
              TextButton(
                onPressed: online ? () => setState(_offline) : _enable,
                child: Text(online ? '关闭在线底图' : '启用在线底图'),
              ),
          ],
        ),
        SizedBox(
          height: widget.height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, widget.height);
              if (points.isEmpty) return const Center(child: Text('没有可显示的轨迹'));
              RouteMapProjection projection;
              try {
                projection = RouteMapProjection.fit(points, size);
              } on ArgumentError {
                return const Center(child: Text('轨迹坐标无效'));
              }
              final transform = _transform.value;
              final visible = online
                  ? projection.visibleTiles(
                      scale: transform.getMaxScaleOnAxis(),
                      translation: Offset(
                        transform.entry(0, 3),
                        transform.entry(1, 3),
                      ),
                    )
                  : <RouteMapTile>[];
              final keys = visible.map((tile) => tile.key).toSet();
              _tiles?.setVisibleTiles(keys);
              _futures.removeWhere((key, _) => !keys.contains(key));
              return Stack(
                children: [
                  Positioned.fill(
                    child: ColoredBox(
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      child: InteractiveViewer(
                        transformationController: _transform,
                        minScale: 1,
                        maxScale: 64,
                        boundaryMargin: const EdgeInsets.all(double.infinity),
                        child: SizedBox(
                          width: size.width,
                          height: size.height,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              for (final tile in visible)
                                Positioned(
                                  left: tile.position.dx,
                                  top: tile.position.dy,
                                  width: tile.size + .5,
                                  height: tile.size + .5,
                                  child: FutureBuilder<Uint8List>(
                                    future: _futures.putIfAbsent(
                                      tile.key,
                                      () => _tiles!.load(tile.key),
                                    ),
                                    builder: (context, snapshot) =>
                                        snapshot.hasData
                                        ? Image.memory(
                                            snapshot.data!,
                                            fit: BoxFit.fill,
                                            gaplessPlayback: true,
                                            excludeFromSemantics: true,
                                            errorBuilder: (_, _, _) =>
                                                const ColoredBox(
                                                  color: Color(0xffe6e6e6),
                                                ),
                                          )
                                        : ColoredBox(
                                            color: const Color(0xffe6e6e6),
                                            child: snapshot.hasError
                                                ? const Center(
                                                    child: Icon(
                                                      Icons.map_outlined,
                                                      color: Colors.grey,
                                                    ),
                                                  )
                                                : null,
                                          ),
                                  ),
                                ),
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: CustomPaint(
                                    painter: _RoutePainter(
                                      widget.lines,
                                      projection,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (online)
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: Material(
                        color: Theme.of(context).colorScheme.surface,
                        child: TextButton(
                          onPressed: _attribution,
                          child: const Text(
                            '© OpenStreetMap contributors',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        if (online)
          const Text('底图加载失败时仍显示轨迹；在线服务不保证可用', style: TextStyle(fontSize: 12)),
      ],
    );
  }

  void _zoom(double factor) {
    final old = _transform.value;
    final scale = (old.getMaxScaleOnAxis() * factor).clamp(1.0, 64.0);
    _transform.value = Matrix4.identity()..scaleByDouble(scale, scale, 1, 1);
  }
}

class _RoutePainter extends CustomPainter {
  const _RoutePainter(this.lines, this.projection);
  final List<RouteMapLine> lines;
  final RouteMapProjection projection;
  @override
  void paint(Canvas canvas, Size size) {
    for (final line in lines) {
      final path = Path();
      for (var i = 0; i < line.points.length; i++) {
        final point = projection.project(line.points[i]);
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = line.color
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke,
      );
      if (line.points.length == 1) {
        canvas.drawCircle(
          projection.project(line.points.single),
          4,
          Paint()..color = line.color,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RoutePainter old) =>
      old.lines != lines || old.projection != projection;
}
