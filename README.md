# iso

Builds the installer image of pearOS BSD.  `build.sh` (run as root on FreeBSD) fetches every repository it needs (`pear_fetch`: darwinator, d, SkyLight, WindowServer, AppKit, open, SDK, QuartzCore, CoreUI, LaunchServices, apps) into one workspace, builds them and writes the ISO.

`overlay/`, `esp/`, `manifest/` — what goes into the image;  `ci/` — build and test scripts;  `ports/` — ports;  `dmg/` — dmgtool.
