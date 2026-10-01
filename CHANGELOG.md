## 0.1.0

* Added `ProgressiveBackdropBlur`: blurs what is painted behind it, inside
  bands only, without moving the content into a new layer (Impeller).
* The blur shader computes the Gaussian weights incrementally and reads two
  taps per bilinear fetch, halving its texture reads for the same image.

## 0.0.2

* Added tint color support (thanks @JulienDev!)

## 0.0.1

* Initial release.
