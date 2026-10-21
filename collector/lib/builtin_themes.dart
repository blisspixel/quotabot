/// Canonical built-in theme text.
///
/// app/themes/*.toml is the same text. Collector tests compare the files to
/// these constants. The desktop app also loads the files from the asset bundle
/// so a packaged build does not depend on the source tree.
library;

const builtinDarkThemeSource = r'''name = "Dark"
slug = "dark"
variant = "dark"
author = "blisspixel"
source = ""
license = "MIT"

[colors]
bg = "#14161A"
surface = "#1C1F25"
text = "#FFFFFF"
muted = "#8A91A0"
accent = "#58A6FF"
success = "#3FB950"
warning = "#D29922"
caution = "#DB6D28"
error = "#F85149"
info = "#58A6FF"
selection = "#1E2A3A"
chart-1 = "#79B8FF"
chart-2 = "#5FB3C8"
chart-3 = "#8FB4C9"
chart-4 = "#9AA7B8"
chart-5 = "#6E8CA0"
chart-6 = "#3D9A9A"
''';

const builtinLightThemeSource = r'''name = "Light"
slug = "light"
variant = "light"
author = "blisspixel"
source = ""
license = "MIT"

[colors]
bg = "#F4F5F7"
surface = "#FFFFFF"
text = "#111317"
muted = "#69707E"
accent = "#285AC8"
success = "#1A7F37"
warning = "#9A6700"
caution = "#B45014"
error = "#CF222E"
info = "#285AC8"
selection = "#F3F6FB"
chart-1 = "#1F4E8C"
chart-2 = "#0E6A74"
chart-3 = "#3D5A73"
chart-4 = "#245C86"
chart-5 = "#4A6274"
chart-6 = "#2A6F97"
''';

const builtinGreenScreenThemeSource = r'''name = "Green Screen"
slug = "green-screen"
variant = "dark"
author = "blisspixel"
source = ""
license = "MIT"

[colors]
bg = "#0E1511"
surface = "#151F19"
text = "#B4DCB9"
muted = "#82AB89"
accent = "#8FD19E"
success = "#8FD19E"
warning = "#D9B86A"
caution = "#E0A070"
error = "#E08A7A"
info = "#86BFC4"
selection = "#24402D"
chart-1 = "#7EB6C9"
chart-2 = "#9BB0B6"
chart-3 = "#6E9AA8"
chart-4 = "#A8C0B4"
chart-5 = "#5E8F99"
chart-6 = "#8AA0AA"
''';

const builtinThemeSources = <String, String>{
  'dark': builtinDarkThemeSource,
  'light': builtinLightThemeSource,
  'green-screen': builtinGreenScreenThemeSource,
};
