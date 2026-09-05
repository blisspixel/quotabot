# README gallery

The gallery uses four 960 by 960 PNGs and one 1600 by 96 mini-view PNG. Each
image links to its full size from the README. All accounts, quota values,
history and local model observations are synthetic examples.

The capture renders the current Flutter widgets, application theme, model-detail
dialog and CLI terminal renderer. It uses the existing test-only dashboard
entrypoint with native integration and preference persistence disabled. It
does not collect quota, start a local model or contact a harness. These images
show product UI; they are not native desktop, accessibility or live-account
validation evidence.

From a Windows source checkout with the pinned Flutter SDK and resolved app
dependencies:

```powershell
python tools/capture_readme_gallery.py --flutter C:/Flutter/bin/flutter.bat --fonts C:/Windows/Fonts
```

Pass `--output PATH` to render into a separate directory. The command loads
Segoe UI and Consolas from the supplied installed-font directory and Material
Icons from the Flutter SDK. It does not copy or redistribute font files.
Review all five images after capture, including chart labels, clipping,
readability at README size, and the absence of real account information.

The older portrait stills and animation remain historical documentation assets.
The README uses this static gallery.
