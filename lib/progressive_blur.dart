import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_shaders/flutter_shaders.dart';

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
/// The blur shader should be precached before using this widget to avoid a
/// pop-in effect. You can do this by calling [ProgressiveBlurWidget.precache] as
/// early as possible in your app (e.g. in `main()`).
class ProgressiveBlurWidget extends StatefulWidget {
  const ProgressiveBlurWidget({
    super.key,
    required this.linearGradientBlur,
    required this.sigma,
    required this.child,
    this.blurTextureDimensions = 128,
    this.tintColor = Colors.transparent,
  }) : blurTexture = null;

  const ProgressiveBlurWidget.custom({
    super.key,
    required this.blurTexture,
    required this.sigma,
    required this.child,
    this.tintColor = Colors.transparent,
  })  : linearGradientBlur = null,
        // Irrelevant in case of a custom blur texture
        blurTextureDimensions = -1;

  /// Asset key of the shader.
  static const _shaderAssetKey =
      'packages/progressive_blur/lib/shaders/progressive_blur.frag';

  /// The fragment program loaded by [precache], shared across all instances.
  static ui.FragmentProgram? _program;

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
  /// changed at any point afterwards.
  static Future<void> precache() async {
    _program ??= await ui.FragmentProgram.fromAsset(_shaderAssetKey);
    await ShaderBuilder.precacheShader(_shaderAssetKey);
  }

  /// A simple constructor that allows to specify a linear gradient blur.
  final LinearGradientBlur? linearGradientBlur;

  /// Dimensions of the blur texture. If not provided, it will be set to 128.
  ///
  /// If you notice that the blur appears to be blocky, you can try increasing
  /// this value.
  final int blurTextureDimensions;

  /// The blur texture to be used as the blur strength map.
  final ui.Image? blurTexture;

  /// The standard deviation of the Gaussian blur.
  final double sigma;

  /// Tint color to apply to the blurred area.
  final Color tintColor;

  /// The widget to be blurred.
  final Widget child;

  @override
  State<ProgressiveBlurWidget> createState() => _ProgressiveBlurWidgetState();
}

class _ProgressiveBlurWidgetState extends State<ProgressiveBlurWidget> {
  /// The blur texture that this widget manages.
  ui.Image? _managedBlurTexture;

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
  void didUpdateWidget(covariant ProgressiveBlurWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.blurTexture != null && oldWidget.blurTexture == null) {
      _managedBlurTexture?.dispose();
      _managedBlurTexture = null;
    } else {
      var shouldCreateBlurTexture = false;

      if (widget.blurTextureDimensions != oldWidget.blurTextureDimensions) {
        shouldCreateBlurTexture = true;
      }

      if (widget.linearGradientBlur != oldWidget.linearGradientBlur) {
        shouldCreateBlurTexture = true;
      }

      if (shouldCreateBlurTexture) {
        _maybeCreateBlurTexture();
      }
    }
  }

  @override
  void dispose() {
    _managedBlurTexture?.dispose();
    super.dispose();
  }

  ui.Image get blurTexture => widget.blurTexture ?? _managedBlurTexture!;

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

            shader.setImageSampler(0, image); // child_texture
            shader.setImageSampler(1, blurTexture); // blur_texture

            shader.setFloat(0, scaledSize.width); // child_size.x
            shader.setFloat(1, scaledSize.height); // child_size.y
            shader.setFloat(2, sigma); // blur_sigma
            shader.setFloat(3, 0.0); // blur_direction
            shader.setFloat(4, tintColor.r); // tint.r
            shader.setFloat(5, tintColor.g); // tint.g
            shader.setFloat(6, tintColor.b); // tint.b
            shader.setFloat(7, tintColor.a); // tint.a

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
            shader.setImageSampler(0, firstPassImage); // child_texture
            shader.setFloat(3, 1.0); // blur_direction

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
      assetKey: ProgressiveBlurWidget._shaderAssetKey,
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

  /// Sets the uniforms that the engine does not manage automatically.
  ///
  /// For [ui.ImageFilter.shader], the engine sets sampler 0 to the filter input
  /// (`child_texture`) and floats 0,1 to its size (`child_size`). Everything
  /// else is set here.
  /// Note: the tint is set on both passes, like the `AnimatedSampler`
  /// implementation does (which sets the uniforms once and draws both passes
  /// with them), so that the two implementations render identically.
  void _setUniforms(
    ui.FragmentShader shader, {
    required double direction,
  }) {
    shader.setImageSampler(1, widget.blurTexture); // blur_texture
    shader.setFloat(2, widget.sigma); // blur_sigma
    shader.setFloat(3, direction); // blur_direction
    shader.setFloat(4, widget.tintColor.r); // tint.r
    shader.setFloat(5, widget.tintColor.g); // tint.g
    shader.setFloat(6, widget.tintColor.b); // tint.b
    shader.setFloat(7, widget.tintColor.a); // tint.a
  }

  /// Rebuilds the two pass shaders and the composed filter from the current
  /// configuration.
  void _rebuildFilter() {
    _xShader?.dispose();
    _yShader?.dispose();
    _xShader = null;
    _yShader = null;

    final program = ProgressiveBlurWidget._program;
    assert(
      program != null,
      'ProgressiveBlurWidget.precache() must be awaited before the widget is '
      'built.',
    );
    if (program == null) {
      _filter = null;
      return;
    }

    final xShader = program.fragmentShader();
    final yShader = program.fragmentShader();

    _setUniforms(xShader, direction: 0.0);
    _setUniforms(yShader, direction: 1.0);

    _xShader = xShader;
    _yShader = yShader;

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
