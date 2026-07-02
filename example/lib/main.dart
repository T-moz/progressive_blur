import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:example/albums.dart';
import 'package:figma_squircle/figma_squircle.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:progressive_blur/progressive_blur.dart';

Future<void> main() async {
  await ProgressiveBlurWidget.precache();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoApp(
      debugShowCheckedModeBanner: false,
      theme: MaterialBasedCupertinoThemeData(
        materialTheme: ThemeData.from(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue,
            brightness: Brightness.light,
          ),
        ),
      ),
      home: const MainPage(),
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  var _displayIndex = 0;
  final _albums = <(String, String, String, String)>[];

  var _useImageFilter = false;

  @override
  void initState() {
    super.initState();
    _loadAlbums();

    _useImageFilter = ProgressiveBlurWidget.useImageFilter ??
        ui.ImageFilter.isShaderFilterSupported;
  }

  void _setUseImageFilter(bool value) {
    setState(() {
      _useImageFilter = value;
      ProgressiveBlurWidget.useImageFilter = value;
    });
  }

  void _loadAlbums() {
    final json = jsonDecode(data) as List<dynamic>;
    for (final album in json) {
      final albumMap = album as Map<String, dynamic>;
      _albums.add((
        albumMap['image'] as String,
        albumMap['url'] as String,
        albumMap['name'] as String,
        albumMap['artist'] as String,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = switch (_displayIndex) {
      0 => CustomScrollView(
          slivers: [
            const CupertinoSliverNavigationBar(
              largeTitle: Text('Music'),
              border: Border(),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16.0),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  const preferredItemSize = 160.0;
                  final crossAxisCount = math.max(
                    1,
                    (constraints.crossAxisExtent / preferredItemSize).floor(),
                  );

                  return SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      mainAxisSpacing: 16.0,
                      crossAxisSpacing: 16.0,
                      childAspectRatio: 1.0,
                    ),
                    itemCount: _albums.length,
                    itemBuilder: (context, index) {
                      final album = _albums[index];

                      return _AlbumCard(
                        key: ValueKey(album.$1),
                        imageUrl: album.$1,
                        redirectUrl: album.$2,
                        title: album.$3,
                        artist: album.$4,
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      1 => FlutterMap(
          children: [
            ProgressiveBlurWidget(
              sigma: 16.0,
              linearGradientBlur: const LinearGradientBlur(
                values: [1, 0],
                stops: [0, 0.125],
                start: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              child: TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.kekland.progressive_blur_example',
              ),
            ),
          ],
        ),
      _ => throw Exception('Invalid index'),
    };

    return Scaffold(
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ColoredBox(
            color: CupertinoColors.systemBackground.resolveFrom(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 4.0,
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Use ImageFilter.shader'),
                  ),
                  CupertinoSwitch(
                    value: _useImageFilter,
                    onChanged: _setUseImageFilter,
                  ),
                ],
              ),
            ),
          ),
          CupertinoTabBar(
            currentIndex: _displayIndex,
            onTap: (index) => setState(() => _displayIndex = index),
            iconSize: 22.0,
            items: const [
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.music_note),
                label: 'Music',
              ),
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.map),
                label: 'Map',
              ),
            ],
          ),
        ],
      ),
      body: child,
    );
  }
}

class _AlbumCard extends StatefulWidget {
  const _AlbumCard({
    super.key,
    required this.imageUrl,
    required this.redirectUrl,
    required this.title,
    required this.artist,
  });

  final String imageUrl;
  final String redirectUrl;
  final String title;
  final String artist;

  @override
  State<_AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends State<_AlbumCard>
    with AutomaticKeepAliveClientMixin {
  Color? _prominentColor;

  @override
  void initState() {
    super.initState();
    _loadProminentColor();
  }

  Future<void> _loadProminentColor() async {
    final palette = await PaletteGenerator.fromImageProvider(
      NetworkImage(widget.imageUrl),
    );

    if (palette.dominantColor?.color != null) {
      _prominentColor = Color.lerp(
        palette.dominantColor?.color,
        Colors.black,
        0.5,
      );
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final child = AspectRatio(
      aspectRatio: 1.0,
      child: Container(
        color: Colors.grey,
        child: Image.network(
          widget.imageUrl,
          fit: BoxFit.cover,
          errorBuilder: (context, _, __) => Container(color: Colors.black),
        ),
      ),
    );

    final cupertinoTheme = CupertinoTheme.of(context);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipSmoothRect(
          radius: SmoothBorderRadius(
            cornerRadius: 32,
            cornerSmoothing: 0.6,
          ),
          child: ProgressiveBlurWidget(
            tintColor: _prominentColor ?? Colors.black.withValues(alpha: 0.5),
            linearGradientBlur: const LinearGradientBlur(
              values: [0, 1],
              stops: [0.5, 0.8],
              start: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            sigma: 24.0,
            blurTextureDimensions: 128,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black38,
                  ],
                ),
              ),
              child: child,
            ),
          ),
        ),
        Positioned(
          left: 16.0,
          right: 16.0,
          bottom: 16.0,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: cupertinoTheme.textTheme.navLargeTitleTextStyle.copyWith(
                  color: Colors.white,
                  fontSize: 20.0,
                ),
              ),
              Text(
                widget.artist,
                style: cupertinoTheme.textTheme.textStyle.copyWith(
                  color: Colors.white38,
                  fontSize: 14.0,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  bool get wantKeepAlive => true;
}
