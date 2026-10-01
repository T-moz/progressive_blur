import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_shaders/flutter_shaders.dart';

/// Asset key of the blur shader.
const _shaderAssetKey =
    'packages/progressive_blur/lib/shaders/progressive_blur.frag';

/// The fragment program loaded by [ProgressiveBlurWidget.precache], shared by
/// every widget of this package.
ui.FragmentProgram? _program;

/// Bound as the filter input of [ui.ImageFilter.shader] to pick its sampling.
///
/// The shader merges pairs of taps into one bilinear fetch, so the input must
/// be sampled with a linear filter. The engine samples the input of an
/// [ui.ImageFilter.shader] with the filter quality of the image set on sampler
/// 0, and with nearest-neighbor filtering when sampler 0 is left unset; the
/// image itself is replaced by the input.
ui.Image? _linearInputSampler;

/// Float uniform indices of the blur shader. The engine sets sampler 0
/// (`child_texture`) and floats 0, 1 (`child_size`) for
/// [ui.ImageFilter.shader].
abstract final class _Uniform {
  static const childSize = 0;
  static const sigma = 2;
  static const direction = 3;
  static const tint = 4;
  static const maskRect = 8;
  static const blurRect = 12;
  static const edgeColor = 16;
}

/// Sets every uniform of the blur shader except the ones the engine manages.
///
/// [maskRect] lays the blur texture out, [blurRect] (left, top, right, bottom)
/// restricts the blurred pixels. Both are in the pass's `FlutterFragCoord`
/// pixels; [Rect.zero] means the whole input. A vertical pass with a visible
/// [edgeColor] reads it above and below [maskRect] instead of the input.
void _setBlurUniforms(
  ui.FragmentShader shader, {
  required ui.Image blurTexture,
  required double sigma,
  required Color tintColor,
  required double direction,
  Rect maskRect = Rect.zero,
  Rect blurRect = Rect.zero,
  Color edgeColor = Colors.transparent,
}) {
  shader.setImageSampler(1, blurTexture); // blur_texture
  if (_linearInputSampler case final input?) {
    shader.setImageSampler(0, input, filterQuality: FilterQuality.low);
  }
  shader.setFloat(_Uniform.sigma, sigma);
  shader.setFloat(_Uniform.direction, direction);
  shader.setFloat(_Uniform.tint, tintColor.r);
  shader.setFloat(_Uniform.tint + 1, tintColor.g);
  shader.setFloat(_Uniform.tint + 2, tintColor.b);
  shader.setFloat(_Uniform.tint + 3, tintColor.a);
  shader.setFloat(_Uniform.maskRect, maskRect.left);
  shader.setFloat(_Uniform.maskRect + 1, maskRect.top);
  shader.setFloat(_Uniform.maskRect + 2, maskRect.width);
  shader.setFloat(_Uniform.maskRect + 3, maskRect.height);
  shader.setFloat(_Uniform.blurRect, blurRect.left);
  shader.setFloat(_Uniform.blurRect + 1, blurRect.top);
  shader.setFloat(_Uniform.blurRect + 2, blurRect.right);
  shader.setFloat(_Uniform.blurRect + 3, blurRect.bottom);
  shader.setFloat(_Uniform.edgeColor, edgeColor.r * edgeColor.a);
  shader.setFloat(_Uniform.edgeColor + 1, edgeColor.g * edgeColor.a);
  shader.setFloat(_Uniform.edgeColor + 2, edgeColor.b * edgeColor.a);
  shader.setFloat(_Uniform.edgeColor + 3, edgeColor.a);
}

ui.Image _createLinearInputSampler() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawPaint(Paint());
  final picture = recorder.endRecording();
  final image = picture.toImageSync(1, 1);
  picture.dispose();
  return image;
}

ui.FragmentProgram? _precachedProgram() {
  final program = _program;
  assert(
    program != null,
    'ProgressiveBlurWidget.precache() must be awaited before the widget is '
    'built.',
  );
  return program;
}

/// Configuration shared by [ProgressiveBlurWidget] and
/// [ProgressiveBackdropBlur].
abstract class _ProgressiveBlurConfig extends StatefulWidget {
  const _ProgressiveBlurConfig({
    super.key,
    required this.linearGradientBlur,
    required this.blurTexture,
    required this.blurTextureDimensions,
    required this.sigma,
    required this.tintColor,
  });

  /// A simple constructor that allows to specify a linear gradient blur.
  final LinearGradientBlur? linearGradientBlur;

  /// Dimensions of the blur texture. If not provided, it will be set to 128.
  ///
  /// If you notice that the blur appears to be blocky, you can try increasing
  /// this value.
  final int blurTextureDimensions;

  /// The blur texture to be used as the blur strength map.
  final ui.Image? blurTexture;

  /// The standard deviation of the Gaussian blur, in physical pixels.
  final double sigma;

  /// Tint color to apply to the blurred area.
  final Color tintColor;
}

/// Owns the blur texture created from [_ProgressiveBlurConfig.linearGradientBlur].
mixin _BlurTextureState<T extends _ProgressiveBlurConfig> on State<T> {
  /// The blur texture that this widget manages.
  ui.Image? _managedBlurTexture;

  ui.Image get blurTexture => widget.blurTexture ?? _managedBlurTexture!;

  @override
  void initState() {
    super.initState();
    _maybeCreateBlurTexture();
  }

  /// Disposes of the old blur texture and creates a new one if necessary.
  void _maybeCreateBlurTexture() {
    _managedBlurTexture?.dispose();
    _managedBlurTexture = null;

    if (widget.linearGradientBlur != null) {
      _managedBlurTexture = widget.linearGradientBlur!.createTexture(
        width: widget.blurTextureDimensions,
        height: widget.blurTextureDimensions,
      );
    }
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.blurTexture != null && oldWidget.blurTexture == null) {
      _managedBlurTexture?.dispose();
      _managedBlurTexture = null;
    } else if (widget.blurTextureDimensions !=
            oldWidget.blurTextureDimensions ||
        widget.linearGradientBlur != oldWidget.linearGradientBlur) {
      _maybeCreateBlurTexture();
    }
  }

  @override
  void dispose() {
    _managedBlurTexture?.dispose();
    super.dispose();
  }
}

/// A widget that applies a progressive blur effect to its child.
///
/// Simplest way to use it is to use the default constructor and provide a
/// [LinearGradientBlur] object. See the documentation of that class for
/// more information.
///
/// Alternatively, you can apply the blur as a blur texture via the `.custom()`
/// constructor. The blur texture can be thought of as a strength map for the
/// blur (`final_sigma = sigma * texture(x, y).r`). You can supply your own blur
/// texture to create custom blur effects.
///
/// The blur is applied in two passes: first horizontally and then vertically.
///
/// Two implementations are available:
///
/// * On Impeller, each pass is a separate [ui.ImageFilter.shader] and the two
///   are chained with [ui.ImageFilter.compose], applied to the child via an
///   [ImageFiltered] widget. With this implementation the blur parameters are
///   read when the widget is built or its configuration changes; animating
///   them every frame is not supported (see
///   https://github.com/flutter/flutter/issues/163302).
/// * On other backends (Skia, web), the child subtree is rendered into a
///   composited layer and the resulting [ui.Image] is bound as a sampler
///   (via `AnimatedSampler` from `flutter_shaders`).
///
/// The implementation is selected automatically at runtime via
/// [ui.ImageFilter.isShaderFilterSupported]. To force a specific
/// implementation, set [useImageFilter].
///
/// Both implementations run the shader over every pixel of the child. When
/// the blur only covers bands of the child and the child sits on its own
/// backdrop, [ProgressiveBackdropBlur] renders the same result for a fraction
/// of the cost.
///
/// The blur shader should be precached before using this widget to avoid a
/// pop-in effect. You can do this by calling [ProgressiveBlurWidget.precache] as
/// early as possible in your app (e.g. in `main()`).
class ProgressiveBlurWidget extends _ProgressiveBlurConfig {
  const ProgressiveBlurWidget({
    super.key,
    required LinearGradientBlur super.linearGradientBlur,
    required super.sigma,
    required this.child,
    super.blurTextureDimensions = 128,
    super.tintColor = Colors.transparent,
  }) : super(blurTexture: null);

  const ProgressiveBlurWidget.custom({
    super.key,
    required ui.Image super.blurTexture,
    required super.sigma,
    required this.child,
    super.tintColor = Colors.transparent,
  }) : super(
          linearGradientBlur: null,
          // Irrelevant in case of a custom blur texture
          blurTextureDimensions: -1,
        );

  /// Overrides the automatic implementation selection.
  ///
  /// * `null` (default): use the [ui.ImageFilter.shader] implementation when
  ///   the backend supports it (Impeller), otherwise fall back to the
  ///   `AnimatedSampler` implementation.
  /// * `true`: always use the [ui.ImageFilter.shader] implementation.
  /// * `false`: always use the `AnimatedSampler` implementation (render the
  ///   subtree into a composited layer and bind the resulting [ui.Image] as a
  ///   sampler).
  static bool? useImageFilter;

  static bool get _shouldUseImageFilter =>
      useImageFilter ?? ui.ImageFilter.isShaderFilterSupported;

  /// Precaches the blur shader so that it can be used synchronously later.
  /// This should be called as early as possible in your app (e.g. in `main()`).
  ///
  /// Both implementations are precached so that [useImageFilter] can be
  /// changed at any point afterwards. [ProgressiveBackdropBlur] needs it too.
  static Future<void> precache() async {
    _program ??= await ui.FragmentProgram.fromAsset(_shaderAssetKey);
    _linearInputSampler ??= _createLinearInputSampler();
    await ShaderBuilder.precacheShader(_shaderAssetKey);
  }

  /// The widget to be blurred.
  final Widget child;

  @override
  State<ProgressiveBlurWidget> createState() => _ProgressiveBlurWidgetState();
}

class _ProgressiveBlurWidgetState extends State<ProgressiveBlurWidget>
    with _BlurTextureState {
  @override
  Widget build(BuildContext context) {
    final Widget blurred;

    if (ProgressiveBlurWidget._shouldUseImageFilter) {
      blurred = _ImpellerProgressiveBlurWidget(
        blurTexture: blurTexture,
        sigma: widget.sigma,
        tintColor: widget.tintColor,
        child: widget.child,
      );
    } else {
      blurred = _SkiaProgressiveBlurWidget(
        blurTexture: blurTexture,
        sigma: widget.sigma,
        tintColor: widget.tintColor,
        child: widget.child,
      );
    }

    return RepaintBoundary(child: blurred);
  }
}

/// The fallback implementation for backends without [ui.ImageFilter.shader]
/// support (Skia, web).
///
/// Renders the child subtree into a composited layer and binds the resulting
/// [ui.Image] as a sampler, drawing the two blur passes manually.
class _SkiaProgressiveBlurWidget extends StatelessWidget {
  const _SkiaProgressiveBlurWidget({
    required this.blurTexture,
    required this.sigma,
    required this.tintColor,
    required this.child,
  });

  final ui.Image blurTexture;
  final double sigma;
  final Color tintColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The output texture should be scaled by the device pixel ratio.
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);

    return ShaderBuilder(
      (context, shader, child) {
        return AnimatedSampler(
          (image, size, canvas) {
            final scaledSize = size * devicePixelRatio;

            // First do X-axis pass
            final firstPassRecorder = ui.PictureRecorder();
            final firstPassCanvas = Canvas(firstPassRecorder);

            shader.setFloat(_Uniform.childSize, scaledSize.width);
            shader.setFloat(_Uniform.childSize + 1, scaledSize.height);
            _setBlurUniforms(
              shader,
              blurTexture: blurTexture,
              sigma: sigma,
              tintColor: tintColor,
              direction: 0,
            );
            shader.setImageSampler(
              0,
              image,
              filterQuality: FilterQuality.low,
            ); // child_texture

            // Draw the first pass
            final paint = Paint()..shader = shader;
            firstPassCanvas.drawRect(Offset.zero & scaledSize, paint);

            // End the first pass and get the image reference
            final firstPassPicture = firstPassRecorder.endRecording();
            final firstPassImage = firstPassPicture.toImageSync(
              scaledSize.width.toInt(),
              scaledSize.height.toInt(),
            );

            // Then do Y-axis pass
            shader.setImageSampler(
              0,
              firstPassImage,
              filterQuality: FilterQuality.low,
            ); // child_texture
            shader.setFloat(_Uniform.direction, 1.0);

            // Scale the canvas back so that we can apply the pixel ratio
            // scaling.
            canvas.scale(1 / devicePixelRatio);
            canvas.drawRect(Offset.zero & scaledSize, paint);

            // Dispose the first pass resources.
            firstPassPicture.dispose();
            firstPassImage.dispose();
          },
          child: child!,
        );
      },
      assetKey: _shaderAssetKey,
      child: child,
    );
  }
}

/// The Impeller implementation, built on [ui.ImageFilter.shader].
///
/// The two blur passes are separate shader filters chained with
/// [ui.ImageFilter.compose] and applied to the child via [ImageFiltered].
class _ImpellerProgressiveBlurWidget extends StatefulWidget {
  const _ImpellerProgressiveBlurWidget({
    required this.blurTexture,
    required this.sigma,
    required this.tintColor,
    required this.child,
  });

  final ui.Image blurTexture;
  final double sigma;
  final Color tintColor;
  final Widget child;

  @override
  State<_ImpellerProgressiveBlurWidget> createState() =>
      _ImpellerProgressiveBlurWidgetState();
}

class _ImpellerProgressiveBlurWidgetState
    extends State<_ImpellerProgressiveBlurWidget> {
  /// The horizontal (first) and vertical (second) pass shaders.
  ui.FragmentShader? _xShader;
  ui.FragmentShader? _yShader;

  /// The composed two-pass image filter applied to the child.
  ui.ImageFilter? _filter;

  @override
  void initState() {
    super.initState();
    _rebuildFilter();
  }

  @override
  void didUpdateWidget(covariant _ImpellerProgressiveBlurWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Rebuild the filter whenever any input that feeds it changes. A fresh
    // ImageFilter instance is required for the change to take effect
    // (see https://github.com/flutter/flutter/issues/163302).
    if (widget.sigma != oldWidget.sigma ||
        widget.tintColor != oldWidget.tintColor ||
        widget.blurTexture != oldWidget.blurTexture) {
      _rebuildFilter();
    }
  }

  @override
  void dispose() {
    _xShader?.dispose();
    _yShader?.dispose();
    super.dispose();
  }

  /// Creates a pass shader. The tint is set on both passes, like the
  /// `AnimatedSampler` implementation does (which sets the uniforms once and
  /// draws both passes with them), so that the two implementations render
  /// identically.
  ui.FragmentShader _passShader(
    ui.FragmentProgram program, {
    required double direction,
  }) {
    final shader = program.fragmentShader();
    _setBlurUniforms(
      shader,
      blurTexture: widget.blurTexture,
      sigma: widget.sigma,
      tintColor: widget.tintColor,
      direction: direction,
    );
    return shader;
  }

  /// Rebuilds the two pass shaders and the composed filter from the current
  /// configuration.
  void _rebuildFilter() {
    _xShader?.dispose();
    _yShader?.dispose();
    _xShader = null;
    _yShader = null;

    final program = _precachedProgram();
    if (program == null) {
      _filter = null;
      return;
    }

    final xShader = _xShader = _passShader(program, direction: 0);
    final yShader = _yShader = _passShader(program, direction: 1);

    _filter = ui.ImageFilter.compose(
      outer: ui.ImageFilter.shader(yShader),
      inner: ui.ImageFilter.shader(xShader),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filter = _filter;

    if (filter == null) {
      return widget.child;
    }

    return ImageFiltered(
      imageFilter: filter,
      child: widget.child,
    );
  }
}

/// Progressively blurs what is painted behind it, running the blur only
/// inside [bands].
///
/// The blur strength map ([linearGradientBlur] or [blurTexture]) is laid over
/// the bounds of this widget, the way [ProgressiveBlurWidget] lays it over its
/// child, but the shader only runs inside [bands] (rects in this widget's
/// coordinates). Outside of them, nothing is blurred.
///
/// Stacked on top of content that sits on a uniform background, it renders
/// what wrapping that content in a [ProgressiveBlurWidget] would, provided
/// every pixel whose kernel ([sigma] times the strength, times 3) is non-zero
/// lies inside a band, and every band edge that is not an edge of the screen
/// is far enough from the blurred pixels for their kernel not to reach it. The
/// content itself is not rebuilt, re-laid out nor moved into a new layer when
/// the blur appears or disappears.
///
/// Each band is two nested [BackdropFilterLayer]s clipped to the band: the
/// horizontal pass reads the backdrop, which all bands of a widget share
/// through one [BackdropKey], and the vertical pass reads the band the
/// horizontal pass produced.
///
/// [ProgressiveBlurWidget] blurs its child over transparency: past the top
/// and bottom of the child, its vertical pass reads transparent pixels, which
/// then show whatever is behind the child. Set [backgroundColor] to that color
/// to render the same edges; otherwise the blur repeats the backdrop's edge
/// rows. Horizontally, both repeat the edge columns.
///
/// The blur reads where the widget sits on screen when it paints; an ancestor
/// that moves it without repainting it (e.g. a transform over a repaint
/// boundary) shifts the strength map.
///
/// Requires [ui.ImageFilter.isShaderFilterSupported] (Impeller); paints
/// nothing otherwise. [ProgressiveBlurWidget.precache] must have completed
/// before it is built.
class ProgressiveBackdropBlur extends _ProgressiveBlurConfig {
  const ProgressiveBackdropBlur({
    super.key,
    required LinearGradientBlur super.linearGradientBlur,
    required super.sigma,
    required this.bands,
    this.backgroundColor,
    super.blurTextureDimensions = 128,
    super.tintColor = Colors.transparent,
  }) : super(blurTexture: null);

  const ProgressiveBackdropBlur.custom({
    super.key,
    required ui.Image super.blurTexture,
    required super.sigma,
    required this.bands,
    this.backgroundColor,
    super.tintColor = Colors.transparent,
  }) : super(linearGradientBlur: null, blurTextureDimensions: -1);

  /// The regions to blur, in this widget's coordinates.
  final List<Rect> bands;

  /// The opaque color behind the blurred content, read past the top and
  /// bottom of this widget. When null, the blur repeats the edge rows.
  final Color? backgroundColor;

  @override
  State<ProgressiveBackdropBlur> createState() =>
      _ProgressiveBackdropBlurState();
}

class _ProgressiveBackdropBlurState extends State<ProgressiveBackdropBlur>
    with _BlurTextureState {
  final _backdropKey = BackdropKey();

  @override
  Widget build(BuildContext context) {
    final program = _precachedProgram();
    if (program == null || !ui.ImageFilter.isShaderFilterSupported) {
      return const SizedBox.expand();
    }
    return _BackdropBlurBands(
      program: program,
      blurTexture: blurTexture,
      sigma: widget.sigma,
      tintColor: widget.tintColor,
      bands: widget.bands,
      backgroundColor: widget.backgroundColor ?? Colors.transparent,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      backdropKey: _backdropKey,
    );
  }
}

class _BackdropBlurBands extends LeafRenderObjectWidget {
  const _BackdropBlurBands({
    required this.program,
    required this.blurTexture,
    required this.sigma,
    required this.tintColor,
    required this.bands,
    required this.backgroundColor,
    required this.devicePixelRatio,
    required this.backdropKey,
  });

  final ui.FragmentProgram program;
  final ui.Image blurTexture;
  final double sigma;
  final Color tintColor;
  final List<Rect> bands;
  final Color backgroundColor;
  final double devicePixelRatio;
  final BackdropKey backdropKey;

  @override
  _RenderBackdropBlurBands createRenderObject(BuildContext context) {
    return _RenderBackdropBlurBands(
      program: program,
      blurTexture: blurTexture,
      sigma: sigma,
      tintColor: tintColor,
      bands: bands,
      backgroundColor: backgroundColor,
      devicePixelRatio: devicePixelRatio,
      backdropKey: backdropKey,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderBackdropBlurBands renderObject,
  ) {
    renderObject
      ..program = program
      ..blurTexture = blurTexture
      ..sigma = sigma
      ..tintColor = tintColor
      ..bands = bands
      ..backgroundColor = backgroundColor
      ..devicePixelRatio = devicePixelRatio
      ..backdropKey = backdropKey;
  }
}

/// The physical-pixel geometry the band filters were built for.
@immutable
class _BandGeometry {
  const _BandGeometry({required this.mask, required this.band});

  /// The widget's bounds on screen.
  final Rect mask;

  /// The band on screen.
  final Rect band;

  @override
  bool operator ==(Object other) =>
      other is _BandGeometry && other.mask == mask && other.band == band;

  @override
  int get hashCode => Object.hash(mask, band);
}

/// The layers and pass shaders of one band.
class _Band {
  final clip = LayerHandle<ClipRectLayer>();
  final horizontal = LayerHandle<BackdropFilterLayer>(BackdropFilterLayer());
  final vertical = LayerHandle<BackdropFilterLayer>(BackdropFilterLayer());

  _BandGeometry? _geometry;
  ui.FragmentShader? _horizontalShader;
  ui.FragmentShader? _verticalShader;

  void _disposeShaders() {
    _horizontalShader?.dispose();
    _verticalShader?.dispose();
    _horizontalShader = null;
    _verticalShader = null;
    _geometry = null;
  }

  void dispose() {
    _disposeShaders();
    clip.layer = null;
    horizontal.layer = null;
    vertical.layer = null;
  }
}

class _RenderBackdropBlurBands extends RenderBox {
  _RenderBackdropBlurBands({
    required ui.FragmentProgram program,
    required ui.Image blurTexture,
    required double sigma,
    required Color tintColor,
    required List<Rect> bands,
    required Color backgroundColor,
    required double devicePixelRatio,
    required BackdropKey backdropKey,
  })  : _program = program,
        _blurTexture = blurTexture,
        _sigma = sigma,
        _tintColor = tintColor,
        _bands = bands,
        _backgroundColor = backgroundColor,
        _devicePixelRatio = devicePixelRatio,
        _backdropKey = backdropKey;

  ui.FragmentProgram _program;
  set program(ui.FragmentProgram value) {
    if (value == _program) return;
    _program = value;
    _invalidateFilters();
  }

  ui.Image _blurTexture;
  set blurTexture(ui.Image value) {
    if (value == _blurTexture) return;
    _blurTexture = value;
    _invalidateFilters();
  }

  double _sigma;
  set sigma(double value) {
    if (value == _sigma) return;
    _sigma = value;
    _invalidateFilters();
  }

  Color _tintColor;
  set tintColor(Color value) {
    if (value == _tintColor) return;
    _tintColor = value;
    _invalidateFilters();
  }

  List<Rect> _bands;
  set bands(List<Rect> value) {
    if (listEquals(value, _bands)) return;
    _bands = value;
    markNeedsPaint();
  }

  Color _backgroundColor;
  set backgroundColor(Color value) {
    if (value == _backgroundColor) return;
    _backgroundColor = value;
    _invalidateFilters();
  }

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  BackdropKey _backdropKey;
  set backdropKey(BackdropKey value) {
    if (value == _backdropKey) return;
    _backdropKey = value;
    markNeedsPaint();
  }

  final _layers = <_Band>[];

  void _invalidateFilters() {
    for (final band in _layers) {
      band._disposeShaders();
    }
    markNeedsPaint();
  }

  @override
  bool get sizedByParent => true;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) {
    while (_layers.length > _bands.length) {
      _layers.removeLast().dispose();
    }
    while (_layers.length < _bands.length) {
      _layers.add(_Band());
    }

    final mask = _toPhysical(Offset.zero & size);
    for (var i = 0; i < _bands.length; i++) {
      final band = _layers[i];
      final bandRect = _bands[i];
      _updateFilters(
        band,
        _BandGeometry(mask: mask, band: _toPhysical(bandRect)),
      );
      band.clip.layer = context.pushClipRect(
        needsCompositing,
        offset,
        bandRect,
        (context, offset) => context.pushLayer(
          band.horizontal.layer!,
          (context, offset) =>
              context.pushLayer(band.vertical.layer!, _paintNothing, offset),
          offset,
        ),
        oldLayer: band.clip.layer,
      );
    }
  }

  static void _paintNothing(PaintingContext context, Offset offset) {}

  Rect _toPhysical(Rect local) {
    final topLeft = localToGlobal(local.topLeft) * _devicePixelRatio;
    final bottomRight = localToGlobal(local.bottomRight) * _devicePixelRatio;
    return Rect.fromPoints(topLeft, bottomRight);
  }

  /// Builds the band's pass filters for [geometry].
  ///
  /// The horizontal pass reads the backdrop, so its `FlutterFragCoord` is in
  /// screen pixels. The vertical pass reads the layer the band's clip
  /// creates, whose origin is the band's top-left corner rounded down to the
  /// pixel grid.
  void _updateFilters(_Band band, _BandGeometry geometry) {
    if (band._geometry == geometry) return;
    band._disposeShaders();
    band._geometry = geometry;

    final bandPixels = Rect.fromLTRB(
      geometry.band.left.floorToDouble(),
      geometry.band.top.floorToDouble(),
      geometry.band.right.ceilToDouble(),
      geometry.band.bottom.ceilToDouble(),
    );
    final horizontalShader = band._horizontalShader = _passShader(
      direction: 0,
      maskRect: geometry.mask,
      blurRect: bandPixels,
    );
    final verticalShader = band._verticalShader = _passShader(
      direction: 1,
      maskRect: geometry.mask.shift(-bandPixels.topLeft),
      edgeColor: _backgroundColor,
    );

    band.horizontal.layer!
      ..filter = ui.ImageFilter.shader(horizontalShader)
      ..backdropKey = _backdropKey;
    band.vertical.layer!.filter = ui.ImageFilter.shader(verticalShader);
  }

  ui.FragmentShader _passShader({
    required double direction,
    required Rect maskRect,
    Rect blurRect = Rect.zero,
    Color edgeColor = Colors.transparent,
  }) {
    final shader = _program.fragmentShader();
    _setBlurUniforms(
      shader,
      blurTexture: _blurTexture,
      sigma: _sigma,
      tintColor: _tintColor,
      direction: direction,
      maskRect: maskRect,
      blurRect: blurRect,
      edgeColor: edgeColor,
    );
    return shader;
  }

  @override
  void dispose() {
    for (final band in _layers) {
      band.dispose();
    }
    _layers.clear();
    super.dispose();
  }
}

/// Parameters to use to create a blur texture for the [ProgressiveBlurWidget].
///
/// By itself it can only create a linear gradient blur. For more complex blur
/// effects, you can create a custom blur texture and provide it to the widget.
class LinearGradientBlur {
  const LinearGradientBlur({
    required this.values,
    required this.stops,
    required this.start,
    required this.end,
  });

  /// List of values to be used in the gradient. 1.0 represents maximum blur,
  /// 0.0 represents no blur.
  final List<double> values;

  /// List of stops to be used in the gradient. Must be the same length as
  /// [values].
  final List<double> stops;

  /// The alignment of the start of the gradient.
  final Alignment start;

  /// The alignment of the end of the gradient.
  final Alignment end;

  /// Creates the blur texture. By default, width and height are set to 128.
  ui.Image createTexture({int width = 128, int height = 128}) {
    final size = Size(width.toDouble(), height.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    final gradient = ui.Gradient.linear(
      start.alongSize(size),
      end.alongSize(size),
      values.map((v) => Color.fromARGB(255, (v * 255).round(), 0, 0)).toList(),
      stops,
    );

    final paint = ui.Paint()..shader = gradient;
    canvas.drawRect(Offset.zero & size, paint);

    final picture = recorder.endRecording();
    final image = picture.toImageSync(width, height);

    return image;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is LinearGradientBlur &&
        listEquals(other.values, values) &&
        listEquals(other.stops, stops) &&
        other.start == start &&
        other.end == end;
  }

  @override
  int get hashCode => Object.hashAll([...values, ...stops, start, end]);
}
