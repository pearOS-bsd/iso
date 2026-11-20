# iso

Builds the installer image of pearOS BSD.  `build.sh` (run as root on FreeBSD) fetches every repository it needs (`pear_fetch`: darwinator, d, SkyLight, WindowServer, AppKit, open, SDK, QuartzCore, CoreUI, LaunchServices, apps) into one workspace, builds them and writes the ISO.

`overlay/`, `esp/`, `manifest/` — what goes into the image;  `ci/` — build and test scripts;  `ports/` — ports;  `dmg/` — dmgtool.

## The Mach stack and the new Control Center (2026-11-19)
`build.sh` builds the Mach-O side that the programs of the Mac need (d/darwin: notifyd, wsbridge, carender-stub, lsd-stub, svc-stub) and our Control Center (apps/controlcenter-cocoa, built with clang + ld64.lld on the open SDK) into `/usr/libexec/pearos`.  `overlay/etc-rc.d-wsbsd_macstack` starts them when the owner's Mac frameworks are mounted (`kern.darwinator.dyld=1`): launchd again with the stand-ins, then the panel of Control Center as the signed-in account (`CC_NO_SYSTEM_SERVICES=1 CC_LISTEN_ONLY=1 CC_NO_STATUSBAR=1`: the Mac's SystemUIServer already draws the items of the bar, a second set was the double Control Center icon and clock); without the cache nothing changes and the Control Center of TopBar stays.  The layout is read from and written to the real file of Control Center (`~/Library/Preferences/ByHost/com.apple.controlcenter.bentoboxes.*.plist`); the list of the controls of Edit Controls comes from chronod's database when the machine has one.

## A VM with a window
`sh tools/run-vm.sh pearOS.iso [cache.img]` starts the image in QEMU/KVM with a window (see the header of the script for the options): without the cache disk (the owner's Mac frameworks, made by `macdeps` from the owner's own Mac) it boots the GNUstep desktop, with it the Mac programs and the new Control Center.

## A local build (minutes, not an hour)
On a FreeBSD machine that already has the software installed (the GNUstep stack under /usr/local: any machine that built the image once): `git clone https://github.com/pearOS-bsd/iso && SKIP_SOFTWARE=1 WORK=/tmp/isowork OUT=$HOME/iso-out sh iso/build.sh` makes the ISO in about 7 minutes (the CI builds everything from scratch, about an hour).  `tools/run-vm.sh` runs it; `monitor.sock` in its work directory is the QEMU monitor (`screendump`, `mouse_move`, `mouse_button`).

## Findings of 2026-11-20 (VM with a window)
* `-vga std` has no DRM driver and never resizes; `virtio-vga` gets the `virtio_gpu` driver (KMS, the OpenGL ES compositor on llvmpipe) and the window server follows the QEMU window (`WindowServer: display changed: WxH`).
* On that machine the boot froze at "Feeding entropy" when the screen was the only console and `boot_mute` was on; with the serial port as a console too it boots.  Debugging aids: `tools/run-vm.sh` with `SERIAL=file:...` / the serial socket, `SSH_KEY` (a disk with `ssh.enable`: only on the AHCI controller, the image has no USB mass storage driver), the QEMU monitor socket.
* The pear boot logo of the kernel: `tools/patch_vt_logo.py` looked for the picture in the old `wsbsd` layout; fixed.

## The Mac side of the image needs the owner's cache disk (2026-11-20)
The programs of the Mac (our Control Center, Terminal ...) run on the Mac's own dyld, shared cache, `cfprefsd` and fonts, which never are in the image.  Attach the disk labelled `MACCACHE` (made by `macdeps` from the owner's Mac: `Preboot/Cryptexes/OS/System/Library/dyld/` (the cache), `dyld` (thin x86_64 slice of /usr/lib/dyld), `cfprefsd`, `Fonts/`): the rc script `wsbsd_macdeps` mounts it and puts the files in place, `wsbsd_macstack` then starts the Mach stack and our Control Center when an account is on the screen.  Without the disk the top bar's own (GNUstep) Control Center is the only one (it has no Edit Controls).
* Control Center (Mac side) answers the click on the bar's item through an event tap: `/var/run/wsbsd_cc_active` tells the top bar not to open its own panel.
* Testing without a window: `DISPLAY_OPT=none RES=1920x1080 sh tools/run-vm.sh ...` gives a screen of exactly that size (a GTK window forces its own size); `screendump` through the monitor socket, keys with `sendkey`, serial login on the socket.  Log in: Return on the account, `pear`, Return.
* The window server uses its software compositor when EGL's renderer is llvmpipe (CPU): faster than GL on the CPU.
