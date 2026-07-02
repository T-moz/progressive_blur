![Demo image](images/image.png)

> [!NOTE]
> Early version of the project. The performance may be suboptimal, and the APIs may change in the future.

An iOS-like progressive blur implementation for Flutter.

## Usage

See the example folder for a complete example.

> [!CAUTION]
> The CanvasKit web performance seems to be terrible. I'm not exactly sure why at the moment. However, `skwasm` performs much better.

```dart
import 'package:progressive_blur/progressive_blur.dart';

// Simple gradient blur with optional tint
ProgressiveBlurWidget(
  sigma: 24.0,
  linearGradientBlur: const LinearGradientBlur(
    values: [0, 1], // 0 - no blur, 1 - full blur
    stops: [0.5, 0.8],
    start: Alignment.topCenter,
    end: Alignment.bottomCenter,
  ),
  tintColor: Colors.orange.withOpacity(0.3), // Optional tint color
  child: ...
);

// Advanced: custom blur texture
//
// You can create a custom blur texture using the Flutter's Canvas API. Note that the red channel controls the blur strength (0 - no blur, 255 - full blur).
ProgressiveBlurWidget.custom(
  sigma: 24.0,
  blurTexture: [instance of ui.Image],
  tintColor: Colors.purple.withOpacity(0.4), // Optional tint color
  child: ...,
)
```

## Rendering implementations

The package ships two implementations of the blur:

- **`ImageFilter.shader` (Impeller only)**: the two blur passes are applied as
  chained [`ui.ImageFilter.shader`](https://api.flutter.dev/flutter/dart-ui/ImageFilter/ImageFilter.shader.html)
  filters via an `ImageFiltered` widget. This avoids rendering the subtree into
  an intermediate `ui.Image` every frame. Requires Flutter 3.35+ and the
  Impeller rendering engine.
- **`AnimatedSampler` (fallback)**: the original implementation — the subtree
  is rendered into a composited layer and the resulting `ui.Image` is bound as
  a shader sampler. Works on Skia and on the web.

By default, the implementation is selected automatically at runtime via
`ui.ImageFilter.isShaderFilterSupported`. You can override the selection with
the static `useImageFilter` toggle:

```dart
// null (default): pick automatically — ImageFilter.shader on Impeller,
// AnimatedSampler otherwise.
ProgressiveBlurWidget.useImageFilter = null;

// Force the ImageFilter.shader implementation.
ProgressiveBlurWidget.useImageFilter = true;

// Force the AnimatedSampler implementation.
ProgressiveBlurWidget.useImageFilter = false;
```

The toggle can be changed at any time (existing widgets pick it up on their
next rebuild), and both implementations render identically.

> [!NOTE]
> With the `ImageFilter.shader` implementation, the blur parameters are read
> when the widget is built or its configuration changes — animating them every
> frame is not supported yet (see
> [flutter/flutter#163302](https://github.com/flutter/flutter/issues/163302)).

## Additional information

Feel free to report bugs/issues on GitHub.

If you have questions, you can contact me directly at `kk.erzhan@gmail.com`.

Credits:
- https://www.shadertoy.com/view/Mfd3DM - an inspiration for the blur shader
- [`flutter_shaders`](https://pub.dev/packages/flutter_shaders) - a great library for working with shaders in Flutter