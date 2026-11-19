# iso

Builds the installer image of pearOS BSD.  `build.sh` (run as root on FreeBSD) fetches every repository it needs (`pear_fetch`: darwinator, d, SkyLight, WindowServer, AppKit, open, SDK, QuartzCore, CoreUI, LaunchServices, apps) into one workspace, builds them and writes the ISO.

`overlay/`, `esp/`, `manifest/` — what goes into the image;  `ci/` — build and test scripts;  `ports/` — ports;  `dmg/` — dmgtool.

## The Mach stack and the new Control Center (2026-11-19)
`build.sh` builds the Mach-O side that the programs of the Mac need (d/darwin: notifyd, wsbridge, carender-stub, lsd-stub, svc-stub) and our Control Center (apps/controlcenter-cocoa, built with clang + ld64.lld on the open SDK) into `/usr/libexec/pearos`.  `overlay/etc-rc.d-wsbsd_macstack` starts them when the owner's Mac frameworks are mounted (`kern.darwinator.dyld=1`): launchd again with the stand-ins, then the panel of Control Center as the signed-in account (`CC_NO_SYSTEM_SERVICES=1 CC_LISTEN_ONLY=1 CC_NO_STATUSBAR=1`: the Mac's SystemUIServer already draws the items of the bar, a second set was the double Control Center icon and clock); without the cache nothing changes and the Control Center of TopBar stays.  The layout is read from and written to the real file of Control Center (`~/Library/Preferences/ByHost/com.apple.controlcenter.bentoboxes.*.plist`); the list of the controls of Edit Controls comes from chronod's database when the machine has one.

## A VM with a window
`sh tools/run-vm.sh pearOS.iso [cache.img]` starts the image in QEMU/KVM with a window (see the header of the script for the options): without the cache disk (the owner's Mac frameworks, made by `macdeps` from the owner's own Mac) it boots the GNUstep desktop, with it the Mac programs and the new Control Center.

## A local build (minutes, not an hour)
On a FreeBSD machine that already has the software installed (the GNUstep stack under /usr/local: any machine that built the image once): `git clone https://github.com/pearOS-bsd/iso && SKIP_SOFTWARE=1 WORK=/tmp/isowork OUT=$HOME/iso-out sh iso/build.sh` makes the ISO in about 7 minutes (the CI builds everything from scratch, about an hour).  `tools/run-vm.sh` runs it; `monitor.sock` in its work directory is the QEMU monitor (`screendump`, `mouse_move`, `mouse_button`).
