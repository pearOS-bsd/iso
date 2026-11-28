#!/bin/sh
# Builds the ISO. Run as root on FreeBSD (CI: vmactions/freebsd-vm), from the repository:  sh wsbsd/iso/build.sh
#   OUT=dir               where the ISO goes (default wsbsd/iso-out)
#   PLOADER_DIR=dir       the Ploader build (ploader_x64.efi, theme/, drivers_x64/): from the `ploader` job of .github/workflows/iso.yml
#   SKIP_SOFTWARE=1       the software (GNUstep stack, WindowServer, apps) is already built and installed under /usr/local
# The result: pearOS-UltraC0re-<arch>-<YY.MM>.iso (the year and month of the build; PEAROS_VERSION overrides), UEFI, Ploader first, FreeBSD's loader without screens, then the window server.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ARCH="$(uname -p)"; case "$ARCH" in amd64) EFINAME=BOOTX64.EFI; PLNAME=ploader_x64.efi; RELDIR=amd64 ;; aarch64) EFINAME=BOOTAA64.EFI; PLNAME=ploader_aa64.efi; RELDIR=arm64/aarch64 ;; *) echo "unsupported $ARCH"; exit 1 ;; esac
# the base of the image: a newer 14.x than the build machine is fine (what is built here runs on later 14.x); override with FREEBSD_RELEASE
REL="${FREEBSD_RELEASE:-14.5-RELEASE}"
WORK="${WORK:-/tmp/isowork}"; ROOT="$WORK/root"; OUT="${OUT:-$HERE/iso-out}"
export IGNORE_OSVERSION=yes
mkdir -p "$WORK" "$OUT"; [ -d "$ROOT" ] && chflags -R noschg,nouchg "$ROOT" 2>/dev/null; rm -rf "$ROOT"; mkdir -p "$ROOT"
pear_fetch() {   # repo ref dir
	rm -rf "$3"; mkdir -p "$3"
	fetch -q -o "$WORK/$1.tgz" "https://github.com/pearOS-bsd/$1/archive/$2.tar.gz" 2>/dev/null && tar -xzf "$WORK/$1.tgz" -C "$3" --strip-components=1 2>/dev/null; rm -f "$WORK/$1.tgz"
	[ -n "$(ls -A "$3" 2>/dev/null)" ]
}
pear_repo() {    # NAME [CHECKOUT]: the directory of a repository: the checkout given in the variable (D_DIR=..., SKYLIGHT_DIR=...), else fetched (PEAR_REF: the branch, default main)
	if [ -n "$2" ] && [ -d "$2" ]; then echo "$2"; return 0; fi
	d="$WORK/repos/$1"; [ -n "$(ls -A "$d" 2>/dev/null)" ] || pear_fetch "$1" "${PEAR_REF:-main}" "$d" || { echo "pearOS-bsd/$1 could not be fetched" >&2; return 1; }
	echo "$d"
}
# every repository pearOS is made of (github.com/pearOS-bsd): the daemons, the protocol, the window server, AppKit and the launcher, the frameworks, the programs
D_DIR=$(pear_repo d "$D_DIR") || exit 1;                                  SKYLIGHT_DIR=$(pear_repo SkyLight "$SKYLIGHT_DIR") || exit 1
WSRV_DIR=$(pear_repo WindowServer "$WINDOWSERVER_DIR") || exit 1;         APPKIT_DIR=$(pear_repo AppKit "$APPKIT_DIR") || exit 1
OPEN_DIR=$(pear_repo open "$OPEN_DIR") || exit 1;                         SDK_DIR=$(pear_repo SDK "$SDK_DIR") || exit 1
QC_DIR=$(pear_repo QuartzCore "$QUARTZCORE_DIR") || exit 1;               COREUI_DIR=$(pear_repo CoreUI "$COREUI_DIR") || exit 1
LS_DIR=$(pear_repo LaunchServices "$LAUNCHSERVICES_DIR") || exit 1;       APPS_DIR=$(pear_repo apps "$APPS_DIR") || exit 1
IS_DIR=$(pear_repo IconServices "$ICONSERVICES_DIR") || exit 1
export SKYLIGHT_DIR D_DIR; export WINDOWSERVER_DIR="$WSRV_DIR"
# the workspace: the layout the build scripts were written for (wsbsd/<module>, the programs next to it), made of links to the repositories
W="$WORK/ws"; rm -rf "$W"; mkdir -p "$W/wsbsd"; WS="$W/wsbsd"; export GITHUB_WORKSPACE="$W"
ln -s "$WSRV_DIR" "$W/WindowServer"; ln -s "$SKYLIGHT_DIR" "$W/SkyLight"; ln -s "$D_DIR" "$W/d"
# copies, not links: the scripts reach their neighbours with "$D/../sdk" and the kernel resolves ".." through a link into the repository, not into this tree
put() { mkdir -p "$2"; (cd "$1" && tar cf - --exclude .git .) | (cd "$2" && tar xf -); }
for l in "$SDK_DIR:sdk" "$SDK_DIR/defaults:defaults" "$QC_DIR:quartzcore" "$COREUI_DIR:coreui" "$APPKIT_DIR:appkit" "$OPEN_DIR:open" \
	"$LS_DIR:launchservices" "$LS_DIR/desktop-pictures:desktop-pictures" "$HERE:iso" "$HERE/ci:ci" "$HERE/ports:ports" "$HERE/dmg:dmg" \
	"$APPS_DIR/finder:finder" "$APPS_DIR/topbar:topbar" "$APPS_DIR/loginwindow:loginwindow"; do put "${l%%:*}" "$WS/${l##*:}"; done
for p in terminal textedit ksa uitest; do put "$APPS_DIR/$p" "$W/$p"; done

echo "== 1. the software"
pkg info -e zsh >/dev/null 2>&1 || pkg install -y zsh >/dev/null 2>&1 || true
pkg info -e sudo >/dev/null 2>&1 || pkg install -y sudo >/dev/null 2>&1 || true
pkg info -e zsh-autosuggestions >/dev/null 2>&1 || pkg install -y zsh-autosuggestions >/dev/null 2>&1 || true
pkg info -e lsof >/dev/null 2>&1 || pkg install -y lsof >/dev/null 2>&1 || true       # Sloth (a test application) runs /usr/sbin/lsof, which the Mac has and FreeBSD does not
if [ -z "$SKIP_SOFTWARE" ]; then
	pkg install -y python3 gmake pkgconf git >/dev/null 2>&1 || true
pkg info -e llvm21 >/dev/null 2>&1 || pkg install -y llvm21 >/dev/null 2>&1 || true   # clang + ld64.lld: launchd and /open (Mach-O programs built on FreeBSD)
	sh "$WS/ci/gnustep-setup.sh" > "$WORK/gnustep.log" 2>&1 || { tail -30 "$WORK/gnustep.log"; exit 1; }
	# the display server back-end of the gui must be ours (back-wsd): the one of the package (X11) makes every program die with "Unable to connect to X Server"
	BACK=/usr/local/GNUstep/Local/Library/Bundles/libgnustep-back-032.bundle/libgnustep-back-032      # libs-back installs into the Local domain, which GNUstep searches before System
	if ! strings "$BACK" 2>/dev/null | grep -q WsdServer; then
		echo "ERROR: the installed libgnustep-back has no WindowServer server (the libs-back build or install failed); logs follow"
		echo "--- gnustep-setup.sh output (errors)"; grep -n -i -E "error|fatal|undefined|No such file|Stop\." "$WORK/gnustep.log" | head -40
		echo "--- libs-back build log (tail)"; tail -40 /tmp/back-build.log 2>/dev/null
		echo "--- gnustep-setup.sh output (tail)"; tail -30 "$WORK/gnustep.log"
		ls -la "$BACK" 2>&1; exit 1
	fi
	sh "$WS/ci/opal-build.sh" > "$WORK/opal.log" 2>&1 || true      # the script ends with a demo that is not needed here; the libraries are checked below
fi
. /usr/local/GNUstep/System/Library/Makefiles/GNUstep.sh
for need in /usr/local/GNUstep/System/Library/Libraries/libgnustep-gui.so.0.32 /usr/local/GNUstep/System/Library/Libraries/libgnustep-base.so.1.31 /usr/local/GNUstep/Local/Library/Libraries/libgnustep-corebase.so.0 /usr/local/GNUstep/Local/Library/Libraries/libopal.so.0; do
	[ -f "$need" ] || { echo "missing after the software build: $need"; ls /usr/local/GNUstep/System/Library/Libraries /usr/local/GNUstep/Local/Library/Libraries 2>&1 | head -20; tail -20 "$WORK/gnustep.log" "$WORK/opal.log" 2>/dev/null; exit 1; }
done
# the window server twice: WindowServer = DRM/KMS display + OpenGL ES compositor (Mesa; used when a GPU driver is loaded), wsd-fb = the console framebuffer + software compositor (no GPU driver: EFI GOP, VMs, NVIDIA).
# The rc script starts WindowServer first and falls back to wsd-fb when it cannot get a display; WindowServer itself falls back to the software compositor when EGL / GLES2 cannot be initialised.
pkg info -e mesa-libs >/dev/null 2>&1 || pkg install -y mesa-libs mesa-dri libdrm >/dev/null 2>&1 || true
(cd "$WSRV_DIR" && gmake SKYLIGHT="$SKYLIGHT_DIR" fb >/dev/null && install -d /usr/local/sbin && install -m 755 WindowServer /usr/local/sbin/wsd-fb && { gmake SKYLIGHT="$SKYLIGHT_DIR" full >"$WORK/wsd-full.log" 2>&1 && install -m 755 WindowServer /usr/local/sbin/WindowServer || { echo "NOTE: gmake full failed (no Mesa / libdrm?), WindowServer is the framebuffer build"; tail -5 "$WORK/wsd-full.log"; install -m 755 wsd-fb /usr/local/sbin/WindowServer 2>/dev/null || cp /usr/local/sbin/wsd-fb /usr/local/sbin/WindowServer; }; } && gmake wsspace wsshot wsclick wskey wsdrag wswins wsfps wsmove wscursor >/dev/null && install -d /usr/local/bin && install -m 755 wsspace wsshot wsclick wskey wsdrag wswins wsfps wsmove wscursor /usr/local/bin/)
(install -d /usr/local/bin; cc -O2 -o /usr/local/bin/dmgtool "$WS/dmg/dmgtool.c" -lz -lbz2 2>"$WORK/dmgtool.log" || echo "NOTE: dmgtool did not build"; cd "$WSRV_DIR/src" && for f in client compositor_sw region ipc evrec buffer; do cc -O2 -fPIC -std=c99 -D_DEFAULT_SOURCE -I"$WSRV_DIR/include" -I"$SKYLIGHT_DIR/include" -c $f.c -o "$WORK/ws_$f.o"; done; cc -shared -o /usr/local/lib/libwsclient.so "$WORK"/ws_*.o -lm)
sh "$WS/sdk/build-compat.sh" "$WORK/compat" > "$WORK/compat.log" 2>&1; install -m 755 "$WORK/compat/libwsbsdcompat.so" /usr/local/lib/libwsbsdcompat.so; install -m 755 "$WORK/compat/libQuartzCore.so" /usr/local/lib/libQuartzCore.so
# Wi-Fi: CoreWLAN, CoreWiFi and airportd, laid out as on the Mac (installed below under /System and /usr/libexec)
sh "$WS/sdk/build-corewlan.sh" "$WORK/cw" > "$WORK/corewlan.log" 2>&1; WSBSD="$WS" sh "$D_DIR/bsd/airportd/build.sh" "$WORK/cw" >> "$WORK/corewlan.log" 2>&1; [ -x "$WORK/cw/usr/libexec/airportd" ] || { echo "airportd did not build"; tail -20 "$WORK/corewlan.log"; exit 1; }
# notifications: usernoted (the daemon) and wsnotify (a command line client), laid out like airportd; this build must not stop the image
WSBSD="$WS" sh "$D_DIR/bsd/usernoted/build.sh" "$WORK/cw" "$WORK/compat" > "$WORK/usernoted.log" 2>&1 || tail -5 "$WORK/usernoted.log"
# launchd and the launch agents of the desktop (Dock, SystemUIServer, Finder, Terminal): without them the rc script starts the programs by hand
# the Open and Save Panel Service (as on the Mac, under AppKit.framework/Versions/C/XPCServices; the programs start it on the first panel)
WSBSD="$WS" COMPAT="$WORK/compat" sh "$D_DIR/bsd/xpcservices/build.sh" "$WORK/cw/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices" > "$WORK/xpcservice.log" 2>&1 || tail -5 "$WORK/xpcservice.log"
sh "$D_DIR/bsd/launchd/build.sh" "$WORK/cw" > "$WORK/launchd.log" 2>&1 || tail -5 "$WORK/launchd.log"
install -d /usr/local/bin /usr/local/libexec
install -d /usr/local/share/wsbsd/icons && install -m 644 "$HERE"/icons/*.icns /usr/local/share/wsbsd/icons/
# the asset catalogues of the Mac that the file panels read (coreui): the small ones are in the repository, the big ones (SF Symbols 117 MB, CoreTypes 20 MB) are copied into coreui/assets before the build or are already in place
install -d /usr/local/share/wsbsd/coreui && install -m 644 "$WS"/coreui/assets/DesktopServicesPriv.car "$WS"/coreui/assets/CoreTypes-Info.plist "$WS"/coreui/assets/name_aliases.strings /usr/local/share/wsbsd/coreui/
for c in CoreGlyphs CoreTypes; do [ -f "$WS/coreui/assets/$c.car" ] && install -m 644 "$WS/coreui/assets/$c.car" /usr/local/share/wsbsd/coreui/$c.car; [ -f /usr/local/share/wsbsd/coreui/$c.car ] || echo "NOTE: $c.car missing, the file panels draw without it"; done
# the status area of the menu bar (it talks to WindowServer through the client library: a static archive of the objects above)
ar rcs "$WORK/libwsclient.a" "$WORK"/ws_*.o
COMPAT="$WORK/compat" WSCLIENT="$WORK/libwsclient.a" sh "$WS/topbar/build.sh" "$WORK/topbar" > "$WORK/topbar.log" 2>&1; install -m 755 "$WORK/topbar/TopBar" /usr/local/bin/TopBar-gnustep || { cat "$WORK/topbar.log"; exit 1; }
COMPAT="$WORK/compat" sh "$WS/loginwindow/build.sh" "$WORK/loginwindow" > "$WORK/loginwindow.log" 2>&1; install -m 755 "$WORK/loginwindow/loginwindow" /usr/local/bin/loginwindow-gnustep || { cat "$WORK/loginwindow.log"; exit 1; }
COMPAT="$WORK/compat" sh "$WS/../textedit/build.sh" "$WORK/textedit" > "$WORK/textedit.log" 2>&1; install -m 755 "$WORK/textedit/TextEdit" /usr/local/bin/TextEdit-gnustep || { cat "$WORK/textedit.log"; exit 1; }
# the Finder: built from finder/, with the resources of the reference Mac's Finder imported when they are at hand (FINDER_APP=path of Finder.app, or finder/Resources copied in before the build); it lands as /System/Library/CoreServices/Finder.app
echo "== the Finder"; COMPAT="$WORK/compat" sh "$WS/finder/build.sh" "$WORK/finder" > "$WORK/finder.log" 2>&1 || true; tail -5 "$WORK/finder.log"; FA="$WORK/finder/System/Library/CoreServices/Finder.app"; [ -x "$FA/Contents/MacOS/Finder" ] || { cat "$WORK/finder.log"; exit 1; }
if [ -n "$FINDER_APP" ] && [ -d "$FINDER_APP" ]; then sh "$WS/finder/import-resources.sh" "$FINDER_APP" "$FA" >> "$WORK/finder.log" 2>&1 || true; fi
rm -rf /usr/local/share/wsbsd/Finder.app; install -d /usr/local/share/wsbsd/Finder.app; (cd "$FA" && tar cf - .) | (cd /usr/local/share/wsbsd/Finder.app && tar xf -); install -m 755 "$FA/Contents/MacOS/Finder" /usr/local/bin/Finder-gnustep; echo "== the Finder installed"
for a in terminal:Terminal-gnustep uitest:UITest-gnustep ksa:KeyboardSetupAssistant-gnustep; do d="${a%%:*}"; b="${a##*:}"; (cd "$WS/../$d" && make gnustep $( [ "$d" = uitest ] || echo COMPAT="$WORK/compat" ) WS="$WS" > "$WORK/$d.log" 2>&1 && install -m 755 "$b" /usr/local/bin/"$b") || { echo "== $d did not build"; grep -m12 "error" "$WORK/$d.log"; [ "$d" = uitest ] || exit 1; }; done
cc -O2 -o /usr/local/libexec/dyld "$HERE/src/dyld.c"
cc -O2 -I"$WS/sdk/include" -o /usr/local/bin/xattr "$HERE/src/xattr.c" "$WS/sdk/src/xattr.c"
cc -O2 -I/usr/local/include/libdrm -I/usr/local/include -o /usr/local/bin/i915probe "$HERE/src/i915probe.c" 2>"$WORK/i915probe.log" || echo "NOTE: i915probe did not build"
cc -O2 -I/usr/local/include -o /usr/local/bin/gbmprobe "$HERE/src/gbmprobe.c" -L/usr/local/lib -lgbm -lEGL 2>"$WORK/gbmprobe.log" || { echo "NOTE: gbmprobe did not build"; cat "$WORK/gbmprobe.log"; }
cc -O2 -o /usr/local/bin/evdevprobe "$HERE/src/evdevprobe.c" 2>"$WORK/evdevprobe.log" || { echo "NOTE: evdevprobe did not build"; cat "$WORK/evdevprobe.log"; }
install -d /usr/local/sbin; cc -O2 -I"$WS/sdk/include" -o /usr/local/sbin/spctl "$HERE/src/spctl.c" "$WS/sdk/src/xattr.c"

echo "== 2. FreeBSD $REL base and kernel"
for s in base kernel; do
	[ -f "$WORK/$s.txz" ] || fetch -q -o "$WORK/$s.txz" "https://download.freebsd.org/releases/$RELDIR/$REL/$s.txz" || fetch -q -o "$WORK/$s.txz" "https://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/$RELDIR/$REL/$s.txz"
	tar -xpf "$WORK/$s.txz" --no-fflags -C "$ROOT"
done
python3 "$HERE/tools/patch_vt_logo.py" "$ROOT/boot/kernel/kernel" "$ROOT/boot/kernel/kernel" "$WSRV_DIR/src/splash_pear.inc" || echo "NOTE: the boot logo of the kernel was not changed"
rm -rf "$ROOT/usr/lib32" "$ROOT/usr/tests" "$ROOT/usr/share/doc" "$ROOT/usr/share/examples" "$ROOT/usr/share/games" "$ROOT/usr/share/man" "$ROOT/usr/share/info" "$ROOT/usr/include" "$ROOT/usr/lib/clang" "$ROOT/usr/share/dtrace" "$ROOT/usr/share/sendmail" "$ROOT/usr/share/openssl"
rm -f "$ROOT"/usr/lib/*.a "$ROOT"/usr/lib/*_p.a "$ROOT"/usr/bin/clang* "$ROOT"/usr/bin/ld.lld "$ROOT"/usr/bin/lld* "$ROOT"/usr/bin/lldb* "$ROOT"/usr/bin/llvm-* "$ROOT"/usr/bin/c++ "$ROOT"/usr/bin/cc "$ROOT"/usr/bin/c89 "$ROOT"/usr/bin/c99 "$ROOT"/usr/bin/cpp "$ROOT"/usr/bin/CC "$ROOT"/usr/bin/ld "$ROOT"/usr/bin/ld.bfd "$ROOT"/usr/bin/ar "$ROOT"/usr/bin/ranlib

echo "== 3. what we built, with the libraries it needs"
mkdir -p "$ROOT/usr/local"
PDFLIBS="$(cd / && ls usr/local/lib/libpoppler-glib.so* usr/local/lib/libEGL_mesa.so* usr/local/lib/libGLX_mesa.so* 2>/dev/null)"   # libEGL_mesa / libGLX_mesa: the Mesa vendor libraries libglvnd dlopens (without them eglGetPlatformDisplay fails with EGL_BAD_PARAMETER and no GL compositor starts)
echo "$PDFLIBS" | grep -q libEGL_mesa || echo "NOTE: libEGL_mesa.so is not installed, the GL compositor cannot start"
true   # dlopen'ed by PDFImage.m: the dependency scan below follows them
tar -C / -cf - $PDFLIBS usr/local/GNUstep usr/local/sbin/lsof usr/local/sbin/WindowServer usr/local/sbin/wsd-fb usr/local/lib/dri usr/local/lib/gbm usr/local/share/glvnd usr/local/share/drirc.d usr/local/sbin/spctl usr/local/bin usr/local/libexec/dyld usr/local/lib/libwsclient.so usr/local/lib/libwsbsdcompat.so usr/local/lib/libQuartzCore.so usr/local/share/fonts usr/local/etc/fonts usr/local/share/wsbsd usr/local/bin/zsh usr/local/bin/sudo usr/local/libexec/sudo usr/local/lib/sudo usr/local/share/zsh usr/local/share/zsh-autosuggestions usr/local/lib/zsh usr/local/share/icu usr/local/lib/libicudata.so usr/local/lib/libicudata.so.76 usr/local/lib/libicudata.so.76.1 2>/dev/null | tar -C "$ROOT" -xpf -
mkdir -p "$ROOT/usr/sbin"; ln -sf /usr/local/sbin/lsof "$ROOT/usr/sbin/lsof"       # where the Mac's applications look for it
# guest tools of VMware and VirtualBox (before the library scan, which then follows their dependencies)
sh "$HERE/tools/guesttools.sh" "$ROOT" || echo "NOTE: guest tools failed"
# Wi-Fi / Bluetooth firmware, usbmuxd + libimobiledevice (iPhone tethering)
sh "$HERE/tools/drivers.sh" "$ROOT" || echo "NOTE: driver firmware failed"
# the modules of the ports (drm-kmod, firmware) need their own linker.hints: without it i915kms cannot find the module it depends on (drmn, provided by drm.ko) and kldload fails
[ -d "$ROOT/boot/modules" ] && kldxref "$ROOT/boot/modules" && echo "kldxref: $(ls -l "$ROOT/boot/modules/linker.hints" | awk '{print $5}') bytes of hints for /boot/modules" || echo "NOTE: kldxref failed, the drm-kmod modules will not load"
# every shared library below /usr/local that these programs need (ldd closure)
find "$ROOT/usr/local" -type f \( -name '*.so*' -o -perm -u+x \) 2>/dev/null | sed "s|^$ROOT||" > "$WORK/elf.list"
: > "$WORK/needed.list"
for round in 1 2 3 4 5 6; do
	cat "$WORK/elf.list" "$WORK/needed.list" | sort -u | while read -r f; do [ -f "$f" ] && ldd "$f" 2>/dev/null | awk '/=>/ {print $3}'; done | grep '^/usr/local/' | sort -u > "$WORK/n2.list" || true
	cmp -s "$WORK/n2.list" "$WORK/needed.list" && break
	cp "$WORK/n2.list" "$WORK/needed.list"
done
while read -r l; do [ -f "$l" ] && { mkdir -p "$ROOT$(dirname "$l")"; cp -L "$l" "$ROOT$l"; }; done < "$WORK/needed.list"
mkdir -p "$ROOT/usr/local/etc"; [ -d /usr/local/etc/fonts ] && cp -R /usr/local/etc/fonts "$ROOT/usr/local/etc/" 2>/dev/null || true

echo "== 4. the macOS layout"
python3 "$HERE/tools/macfs.py" desymlink "$ROOT"
python3 "$HERE/tools/macfs.py" skeleton "$ROOT" "$HERE/manifest"
python3 "$HERE/tools/macfs.py" install "$ROOT" "$HERE/manifest" "$HERE/components.json"
# the demo account: a few folders and files on the Desktop and a folder with many mixed files (the rc script copies this into the home of the session)
rm -rf "$ROOT/Library/User Template"; python3 "$HERE/tools/mkdemo.py" "$ROOT/Library/User Template" || echo "NOTE: the demo content was not made"; : > "$ROOT/Library/User Template/.zshrc"
# /private/{etc,var,tmp} next to /etc /var /tmp (the Mac has the first as the real places and the others as links; here both are real)
mkdir -p "$ROOT/private/etc" "$ROOT/private/var" "$ROOT/private/tmp" "$ROOT/Users/Shared" "$ROOT/Users/root"
mkdir -p "$ROOT/Library/Caches"		# a memory file system at boot (rc.d/wsbsd_overlay): the Mac services write there
cp -R "$ROOT/etc/." "$ROOT/private/etc/"

echo "== 5. configuration: silent boot, desktop on start"
cp "$HERE/overlay/boot/loader.conf" "$ROOT/boot/loader.conf"
for d in etc private/etc; do
	mkdir -p "$ROOT/$d/rc.d"
	cp "$HERE/overlay/etc-rc.conf" "$ROOT/$d/rc.conf"; cp "$HERE/overlay/etc-fstab" "$ROOT/$d/fstab"; cp "$HERE/overlay/etc-syslog.conf" "$ROOT/$d/syslog.conf"
	install -m 755 "$HERE/overlay/etc-rc.d-macdesktop" "$ROOT/$d/rc.d/macdesktop"
	# the home of root is /Users/root (the session's home, with the Desktop): GNUstep's NSHomeDirectory() takes the home from the password database, not from $HOME, and looked in /root
	if [ -f "$ROOT/$d/master.passwd" ]; then sed -i '' 's|:/root:|:/Users/root:|' "$ROOT/$d/master.passwd"; pwd_mkdb -p -d "$ROOT/$d" "$ROOT/$d/master.passwd" 2>/dev/null || echo "NOTE: pwd_mkdb failed in $d"; fi
done
mkdir -p "$ROOT/System/Library/LaunchDaemons"
(cd "$WORK/cw" && find System usr -type l -name Current 2>/dev/null | while read -r l; do rm -rf "$ROOT/$l"; done)       # the desymlinked copies give way to the links
(cd "$WORK/cw" && tar -cf - System usr 2>/dev/null) | tar -C "$ROOT" -xpf - || true
install -d "$ROOT/System/Library/Desktop Pictures" && install -m 644 "$WS/desktop-pictures/dark-mode.jpg" "$WS/desktop-pictures/light-mode.jpg" "$ROOT/System/Library/Desktop Pictures/"; cp "$WS/desktop-pictures/README.md" "$ROOT/System/Library/Desktop Pictures/README.md"
install -d "$ROOT/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources" && install -m 644 "$WS/launchservices/uti_table.json" "$ROOT/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/uti_table.json"
for d in etc private/etc; do install -m 755 "$HERE/overlay/etc-rc.d-wsbsd_kbdlight" "$ROOT/$d/rc.d/wsbsd_kbdlight"; done
# the keyboard backlight driver (needs the kernel sources of the build machine; without them the image simply has no such module)
# the kernel module of the Clevo keyboard backlight (clevo_dchu, the DCHU ACPI device CLV0001): built against the kernel sources of the image's release (src.txz, only usr/src/sys is unpacked), the build machine need not have /usr/src
# the kernel modules written for pearOS live in their own repositories (github.com/pearOS-bsd/virtio, github.com/pearOS-bsd/clevo_wmi): fetched here, at the branch or tag in PEAR_VIRTIO_REF / PEAR_CLEVO_REF (default main)
SYSDIR=/usr/src/sys
if [ ! -d "$SYSDIR/dev/acpica" ]; then
	SYSDIR="$WORK/src/usr/src/sys"
	if [ ! -d "$SYSDIR/dev/acpica" ]; then
		mkdir -p "$WORK/src"; [ -f "$WORK/src.txz" ] || fetch -q -o "$WORK/src.txz" "https://download.freebsd.org/releases/$RELDIR/$REL/src.txz" || fetch -q -o "$WORK/src.txz" "https://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/$RELDIR/$REL/src.txz" || true
		[ -f "$WORK/src.txz" ] && tar -xf "$WORK/src.txz" -C "$WORK/src" usr/src/sys 2>/dev/null; rm -f "$WORK/src.txz"
	fi
fi
if [ -d "$SYSDIR/dev/acpica" ] && pear_fetch clevo_wmi "${PEAR_CLEVO_REF:-main}" "$WORK/clevo_dchu"; then (cd "$WORK/clevo_dchu" && make SYSDIR="$SYSDIR" clean >/dev/null 2>&1; make SYSDIR="$SYSDIR" >"$WORK/clevo_dchu.log" 2>&1 && install -d "$ROOT/boot/modules" && install -m 555 clevo_dchu.ko "$ROOT/boot/modules/clevo_dchu.ko" && echo "clevo_dchu built against $SYSDIR") || { echo "NOTE: clevo_dchu did not build (see $WORK/clevo_dchu.log)"; tail -8 "$WORK/clevo_dchu.log"; }; else echo "NOTE: no kernel sources or pearOS-bsd/clevo_wmi could not be fetched: no keyboard backlight module in this image"; fi

# virtio_gpu: the DRM driver of the virtio GPU of QEMU / KVM (virgl 3D), a port of Linux 6.1's virtio_gpu over drm-kmod (github.com/pearOS-bsd/virtio); built against the sources of drm-kmod 6.1-lts, the drm.ko of the image is the drm-61-kmod package
DRMKMOD="$WORK/drm-kmod"
if [ ! -f "$DRMKMOD/kconfig.mk" ]; then
	mkdir -p "$DRMKMOD"; [ -f "$WORK/drm-kmod.tgz" ] || fetch -q -o "$WORK/drm-kmod.tgz" "https://github.com/freebsd/drm-kmod/archive/refs/heads/6.1-lts.tar.gz" || true
	[ -f "$WORK/drm-kmod.tgz" ] && tar -xzf "$WORK/drm-kmod.tgz" -C "$DRMKMOD" --strip-components=1 2>/dev/null
fi
if [ -d "$SYSDIR/dev/acpica" ] && [ -f "$DRMKMOD/kconfig.mk" ] && pear_fetch virtio "${PEAR_VIRTIO_REF:-main}" "$WORK/virtio_gpu_src"; then
	rm -rf "$DRMKMOD/virtio_gpu"; cp -R "$WORK/virtio_gpu_src" "$DRMKMOD/virtio_gpu"
	(cd "$DRMKMOD/virtio_gpu" && make SYSDIR="$SYSDIR" clean >/dev/null 2>&1; make SYSDIR="$SYSDIR" >"$WORK/virtio_gpu.log" 2>&1 && install -d "$ROOT/boot/modules" && install -m 555 virtio_gpu.ko "$ROOT/boot/modules/virtio_gpu.ko" && echo "virtio_gpu built against $SYSDIR") || { echo "NOTE: virtio_gpu did not build (see $WORK/virtio_gpu.log)"; tail -8 "$WORK/virtio_gpu.log"; }
else echo "NOTE: virtio_gpu not built (no kernel sources, no drm-kmod sources, or pearOS-bsd/virtio could not be fetched)"; fi
# the name neofetch, pciconf -lv and About This Mac show for the virtio GPU (PCI 1af4:1050) comes from FreeBSD's PCI database
if [ -f "$ROOT/usr/share/misc/pci_vendors" ]; then
	sed 's/^\t1050  Virtio 1\.0 GPU$/\t1050  pearOS Generic GPU (virtio)/' "$ROOT/usr/share/misc/pci_vendors" > "$WORK/pci_vendors.new" && cat "$WORK/pci_vendors.new" > "$ROOT/usr/share/misc/pci_vendors"; rm -f "$WORK/pci_vendors.new"
fi
[ -d "$ROOT/boot/modules" ] && kldxref "$ROOT/boot/modules"
# Mac programs (github.com/pearOS-bsd/dyld, the kernel module in github.com/pearOS-bsd/darwinator): machrun, a dyld for FreeBSD that runs Mach-O executables and applications (Objective-C 2 metadata turned into GNU runtime classes, Foundation and AppKit from GNUstep),
# its helpers (libmachcompat.so: fixes of GNUstep that Apple's programs trip over; libexctrace.so: stack traces for debugging), `macapp APP.app`, and the kernel module darwinator.ko (static Mach-O programs, not loaded by default).
# Built here, on the build machine (it has the compiler and GNUstep's headers); at boot the rc script wsbsd_machrun tells the kernel to hand Mach-O files to machrun (imgact_binmisc).
DYLD_DIR=$(pear_repo dyld "$DYLD_DIR") || DYLD_DIR=""
# the aliases of the frameworks laid out by the manifest (Foo.framework/Foo, Versions/Current): their binaries are in the dyld cache, and dlopen() of an alias path needs them (AppKit soft-links ViewBridge)
[ -n "$DYLD_DIR" ] && python3 "$DYLD_DIR/tools/fwskel.py" --tree "$ROOT"
if pear_fetch darwinator "${PEAR_DARWINATOR_REF:-main}" "$WORK/darwinator"; then
	if [ -n "$DYLD_DIR" ] && (cd "$DYLD_DIR/machrun" && make clean >/dev/null 2>&1; make CFLAGS="-fPIE -fPIC -I$DYLD_DIR/src -I$WORK/darwinator/src -O1 -Wall -Wno-unused-parameter" >"$WORK/darwinator.log" 2>&1); then
		install -d "$ROOT/usr/local/bin" "$ROOT/usr/local/lib" "$ROOT/usr/local/libexec"
		install -m 755 "$DYLD_DIR/machrun/machrun" "$ROOT/usr/local/bin/machrun"
		[ -f "$OPEN_DIR/open" ] && { install -m 755 "$OPEN_DIR/open" "$ROOT/usr/local/bin/open"; install -m 755 "$OPEN_DIR/open-patch.py" "$ROOT/usr/local/libexec/open-patch.py"; }     # the launcher; the stand-in libraries it needs (/open/AppKit ...) are built on a Mac (open/build-appkit.sh) and are not in the image yet
		install -m 755 "$DYLD_DIR/machrun/libmachcompat.so" "$DYLD_DIR/machrun/libexctrace.so" "$ROOT/usr/local/lib/"
		install -m 755 "$DYLD_DIR/tools/wrapapp.sh" "$ROOT/usr/local/libexec/wrapapp.sh"; install -m 755 "$DYLD_DIR/tools/macapp" "$ROOT/usr/local/bin/macapp"; install -m 755 "$DYLD_DIR/tools/macapp-install" "$ROOT/usr/local/bin/macapp-install"
		ldd "$DYLD_DIR/machrun/machrun" | awk '/=>/ { print $3 }' | while read -r lib; do [ -e "$ROOT$lib" ] || echo "NOTE: machrun needs $lib and the image does not have it"; done
		for need in "$ROOT/usr/local/lib/libobjc.so.4.6" "$ROOT/usr/local/lib/libdispatch.so.1" "$ROOT/usr/lib/libBlocksRuntime.so.0"; do [ -e "$need" ] || echo "NOTE: Mac applications load $need at run time and the image does not have it"; done
		echo "machrun built (darwinator $(cd "$WORK/darwinator" && ls -d .git >/dev/null 2>&1 && git rev-parse --short HEAD || echo "archive"))"
	else echo "NOTE: machrun did not build (see $WORK/darwinator.log)"; grep -E "undefined symbol|cannot find|error:" "$WORK/darwinator.log" | sort | uniq -c | sort -rn | head -25; tail -4 "$WORK/darwinator.log"; ls -la /usr/local/lib/libobjc* /usr/local/GNUstep/System/Library/Libraries/libobjc* 2>&1 | head -6; fi
	if [ -d "$SYSDIR/dev/acpica" ] && (cd "$WORK/darwinator" && make SYSDIR="$SYSDIR" clean >/dev/null 2>&1; make SYSDIR="$SYSDIR" >"$WORK/darwinator_ko.log" 2>&1); then
		install -d "$ROOT/boot/modules" && install -m 555 "$WORK/darwinator/darwinator.ko" "$ROOT/boot/modules/darwinator.ko" && echo "darwinator.ko built against $SYSDIR"
	else echo "NOTE: darwinator.ko not built (no kernel sources or it did not compile: see $WORK/darwinator_ko.log): only machrun runs Mach-O files"; fi
else echo "NOTE: pearOS-bsd/darwinator could not be fetched: this image does not run Mac programs"; fi
# /open: our AppKit, Cocoa and the stand-in libraries, built here with clang + ld64.lld from the open sources (dyld/tools/sdk/build-open-sdk.sh): no Mac, no file of Apple's. The programs run through the real dyld of the owner's Mac (macdeps puts it
# and the cache on the machine); the files of this directory are ours.
OPENLD=$(ls /usr/local/llvm*/bin/ld64.lld 2>/dev/null | tail -1)
if [ -n "$OPENLD" ] && [ -n "$DYLD_DIR" ] && [ -d "$WORK/darwinator/src" ]; then
	OT="$WORK/opentree"; rm -rf "$OT"; mkdir -p "$OT"
	FOUNDATION_DIR=$(pear_repo Foundation "$FOUNDATION_DIR") && COREGRAPHICS_DIR=$(pear_repo CoreGraphics "$COREGRAPHICS_DIR") || true
	for r in "AppKit:$APPKIT_DIR" "WindowServer:$WSRV_DIR" "SkyLight:$SKYLIGHT_DIR" "CoreUI:$COREUI_DIR" "dyld:$DYLD_DIR" "darwinator:$WORK/darwinator" "open:$OPEN_DIR" "Foundation:$FOUNDATION_DIR" "CoreGraphics:$COREGRAPHICS_DIR"; do ln -s "${r#*:}" "$OT/${r%%:*}"; done
	if sh "$DYLD_DIR/tools/sdk/build-open-sdk.sh" "$WORK/oss" "$OT" "$WORK/open-out" >"$WORK/open-sdk.log" 2>&1 && [ -f "$WORK/open-out/AppKit" ]; then
		install -d "$ROOT/open"; for f in AppKit Cocoa stub-*; do [ -f "$WORK/open-out/$f" ] && install -m 755 "$WORK/open-out/$f" "$ROOT/open/$f"; done
		echo "/open built: $(ls "$ROOT/open" | tr '\n' ' ')"
	else echo "NOTE: /open did not build (see $WORK/open-sdk.log)"; tail -5 "$WORK/open-sdk.log"; fi
else echo "NOTE: /open not built (needs the llvm package with ld64.lld, dyld and darwinator)"; fi
# The launchd of pearOS (a Mach-O program from d/darwin/launchd, built with clang and ld64.lld: the llvm package on the build machine): it serves the bootstrap port and the service
# com.apple.bsd.dirhelper; started at boot by wsbsd_launchd when the module runs Mach-O files through a real dyld.
if [ -x /usr/local/llvm21/bin/ld64.lld ] && [ -d "$D_DIR/darwin/launchd" ]; then
	if (cd "$D_DIR/darwin/launchd" && make clean >/dev/null 2>&1; make >"$WORK/launchd.log" 2>&1); then
		install -m 755 "$D_DIR/darwin/launchd/launchd" "$ROOT/sbin/launchd"; install -m 755 "$D_DIR/darwin/launchd/mkfolders.sh" "$ROOT/usr/local/libexec/mkfolders.sh"
		echo "launchd built"
		if (cd "$D_DIR/darwin/notifyd" && make clean >/dev/null 2>&1; make >"$WORK/notifyd.log" 2>&1); then
			install -d "$ROOT/usr/sbin"; install -m 755 "$D_DIR/darwin/notifyd/notifyd" "$ROOT/usr/sbin/notifyd"; echo "notifyd built"
		else echo "NOTE: notifyd did not build (see $WORK/notifyd.log)"; fi
	else echo "NOTE: launchd did not build (see $WORK/launchd.log)"; fi
else echo "NOTE: launchd not built (no ld64.lld or no darwin/launchd in the d repository)"; fi
# The Mach side of the desktop for the programs of the Mac (d/darwin: notifyd, wsbridge = the front of the window server, carender-stub = the render server, lsd and service stand-ins; all Mach-O programs built with
# clang + ld64.lld) and our Control Center (apps/controlcenter-cocoa, built the same way on the headers of the open SDK): rc.d/wsbsd_macstack starts them when the Mac's frameworks are there.  Not fatal when a piece does not build.
if [ -x /usr/local/llvm21/bin/ld64.lld ] && [ -d "$D_DIR/darwin" ]; then
	if sh "$D_DIR/darwin/build.sh" "$WORK/darwin-out" >"$WORK/darwin.log" 2>&1; then
		install -d "$ROOT/usr/libexec/pearos"
		for f in wsbridge/wsbridge notifyd/notifyd lsd-stub/out/lsd-stub carender-stub/out/carender-stub svc-stub/out/svc-stub tccd/out/tccd opendirectoryd/out/opendirectoryd distnoted/out/distnoted cfprefsd/out/cfprefsd; do [ -x "$WORK/darwin-out/$f" ] && install -m 755 "$WORK/darwin-out/$f" "$ROOT/usr/libexec/pearos/$(basename "$f")" || echo "NOTE: $f was not built"; done
		[ -x "$ROOT/usr/libexec/pearos/tccd" ] && install -d "$ROOT/usr/libexec/pearos/jobs" && install -m 644 "$D_DIR"/darwin/tccd/launchd/*.plist "$ROOT/usr/libexec/pearos/jobs/"	# tccd (com.apple.tccd.system, com.apple.tccd): jobs of the Mach launchd, started on demand
		for n in opendirectoryd distnoted cfprefsd; do [ -x "$ROOT/usr/libexec/pearos/$n" ] && install -d "$ROOT/usr/libexec/pearos/jobs" && install -m 644 "$D_DIR"/darwin/$n/launchd/*.plist "$ROOT/usr/libexec/pearos/jobs/"; done	# opendirectoryd (libinfo, membership), distnoted (@Uv3 agent, @1v3/@0v3 daemon), cfprefsd (com.apple.cfprefsd.agent as the user, .daemon as root): jobs of the Mach launchd, started on demand
		for n in usernoted appleeventsd analyticsd filecoordinationd csnameddatad dmd useractivityd uninstalld; do [ -x "$WORK/darwin-out/$n/out/$n" ] && install -m 755 "$WORK/darwin-out/$n/out/$n" "$ROOT/usr/libexec/pearos/$n" && install -d "$ROOT/usr/libexec/pearos/jobs" && install -m 644 "$D_DIR"/darwin/$n/launchd/*.plist "$ROOT/usr/libexec/pearos/jobs/" || echo "NOTE: $n was not built"; done	# the other services the Dock looks up at start (research/docs/DOCK-SERVICES-2.md): jobs of the Mach launchd, started on demand (usernoted at load)
		install -m 755 "$D_DIR/darwin/launchd/mkfolders.sh" "$ROOT/usr/libexec/pearos/mkfolders.sh" 2>/dev/null || true
		echo "darwin stack built: $(ls "$ROOT/usr/libexec/pearos" | tr '\n' ' ')"
	else echo "NOTE: the darwin stack did not build (see $WORK/darwin.log)"; tail -5 "$WORK/darwin.log"; fi
fi
CCSRC="$APPS_DIR/controlcenter-cocoa"
if [ -f "$CCSRC/build-bsd.sh" ] && [ -d "$WORK/oss/sdk" ] && [ -d "$WORK/darwinator" ]; then
	CCW="$WORK/ccw"; rm -rf "$CCW"; mkdir -p "$CCW"
	IOKIT_DIR=$(pear_repo IOKit "$IOKIT_DIR") && CORETEXT_DIR=$(pear_repo CoreText "$CORETEXT_DIR") || true
	put "$APPS_DIR" "$CCW/apps"
	for l in "IOKit:$IOKIT_DIR" "CoreText:$CORETEXT_DIR" "SDK:$SDK_DIR" "QuartzCore:$QC_DIR" "SkyLight:$SKYLIGHT_DIR" "darwinator:$WORK/darwinator"; do [ -d "${l#*:}" ] && ln -s "${l#*:}" "$CCW/${l%%:*}"; done
	if SDK_WORK="$WORK/oss" sh "$CCW/apps/controlcenter-cocoa/build-bsd.sh" "$WORK/cc-out" >"$WORK/cc.log" 2>&1 && [ -x "$WORK/cc-out/ControlCenter.app/Contents/MacOS/ControlCenter" ]; then
		install -d "$ROOT/usr/libexec/pearos"; rm -rf "$ROOT/usr/libexec/pearos/ControlCenter.app"; cp -R "$WORK/cc-out/ControlCenter.app" "$ROOT/usr/libexec/pearos/ControlCenter.app"; echo "ControlCenter built"
	else echo "NOTE: ControlCenter did not build (see $WORK/cc.log)"; tail -5 "$WORK/cc.log"; fi
else echo "NOTE: ControlCenter not built (needs apps/controlcenter-cocoa, the open SDK and darwinator)"; fi
# /System/Library/CoreServices/SystemVersion.plist: the version of macOS that the programs of the Mac see (the release whose frameworks the owner's cache disk carries).  Without it
# HIServices' _RegisterApplication cannot compare the system with LSMinimumSystemVersion of an application and aborts it (found with the real Dock, 2026-11-27); the values are
# the facts of macOS 26.7.2 (25G332), written here (not copied from a Mac)
install -d "$ROOT/System/Library/CoreServices"
cat > "$ROOT/System/Library/CoreServices/SystemVersion.plist" <<'SVP'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>BuildID</key>
	<string>4F33A3F8-CDFC-11F1-914A-0DD9DDC6AC7B</string>
	<key>ProductBuildVersion</key>
	<string>25G332</string>
	<key>ProductCopyright</key>
	<string>1983-2026 Apple Inc.</string>
	<key>ProductName</key>
	<string>macOS</string>
	<key>ProductUserVisibleVersion</key>
	<string>26.7.2</string>
	<key>ProductVersion</key>
	<string>26.7.2</string>
	<key>iOSSupportVersion</key>
	<string>26.7</string>
</dict>
</plist>
SVP
# the Dock (apps/dock-cocoa): a Mach-O program on the Mac's frameworks, built like the Control Center; it is /System/Library/CoreServices/Dock.app, where the Mac has it, and the session's
# launchd job com.apple.Dock.agent (apps/dock-cocoa/launchd, in the launchd of d with its Mach services) starts it; it runs when the owner's cache disk is attached
if [ -f "$APPS_DIR/dock-cocoa/build-bsd.sh" ] && [ -d "${CCW:-}/apps" ]; then
	if SDK_WORK="$WORK/oss" sh "$CCW/apps/dock-cocoa/build-bsd.sh" "$WORK/dock-out" >"$WORK/dock.log" 2>&1 && [ -x "$WORK/dock-out/Dock.app/Contents/MacOS/Dock" ]; then
		rm -rf "$ROOT/System/Library/CoreServices/Dock.app"; install -d "$ROOT/System/Library/CoreServices"; cp -R "$WORK/dock-out/Dock.app" "$ROOT/System/Library/CoreServices/Dock.app"; echo "Dock built"
		install -d "$ROOT/usr/libexec/pearos/jobs"; install -m 644 "$APPS_DIR/dock-cocoa/launchd/com.apple.Dock.agent.plist" "$ROOT/usr/libexec/pearos/jobs/"	# the Mach launchd starts it as the console user, with its Mach services
	else echo "NOTE: the Dock did not build (see $WORK/dock.log)"; tail -5 "$WORK/dock.log"; fi
else echo "NOTE: the Dock not built (needs apps/dock-cocoa and the Control Center's build tree)"; fi
# lsd (github.com/pearOS-bsd/LaunchServices): the Launch Services database daemon (com.apple.lsd.mapdb), wire-compatible with the Mac's; rc.d/wsbsd_macstack starts it before every client
if [ -f "$LS_DIR/build-bsd.sh" ] && [ -d "$WORK/oss/sdk" ] && [ -d "$WORK/darwinator" ]; then
	LSW="$WORK/lsw"; rm -rf "$LSW"; mkdir -p "$LSW"; put "$LS_DIR" "$LSW/LaunchServices"; ln -s "$WORK/darwinator" "$LSW/darwinator"
	if SDK_WORK="$WORK/oss" sh "$LSW/LaunchServices/build-bsd.sh" "$WORK/ls-out" >"$WORK/ls.log" 2>&1 && [ -x "$WORK/ls-out/lsd" ]; then
		install -d "$ROOT/usr/libexec/pearos/jobs"; install -m 755 "$WORK/ls-out/lsd" "$ROOT/usr/libexec/pearos/lsd"; install -m 644 "$LS_DIR"/launchd/*.plist "$ROOT/usr/libexec/pearos/jobs/"; echo "lsd built"
		[ -x "$WORK/ls-out/launchservicesd" ] && install -m 755 "$WORK/ls-out/launchservicesd" "$ROOT/usr/libexec/pearos/launchservicesd" && echo "launchservicesd built"	# com.apple.coreservices.launchservicesd (its job plist is among launchd/*.plist; lsd-stub leaves the name to it)
	else echo "NOTE: lsd did not build (see $WORK/ls.log)"; tail -5 "$WORK/ls.log"; fi
fi
# IconServices (github.com/pearOS-bsd/IconServices): iconservicesagent (com.apple.iconservices) and iconservicesd (com.apple.iconservices.store), wire-compatible with the Mac's; rc.d/wsbsd_macstack starts them with the stack
if [ -f "$IS_DIR/build-bsd.sh" ] && [ -d "$WORK/oss/sdk" ] && [ -d "$WORK/darwinator" ]; then
	ISW="$WORK/isw"; rm -rf "$ISW"; mkdir -p "$ISW"; put "$IS_DIR" "$ISW/IconServices"; ln -s "$WORK/darwinator" "$ISW/darwinator"
	if SDK_WORK="$WORK/oss" sh "$ISW/IconServices/build-bsd.sh" "$WORK/is-out" >"$WORK/is.log" 2>&1 && [ -x "$WORK/is-out/iconservicesagent" ] && [ -x "$WORK/is-out/iconservicesd" ]; then
		install -d "$ROOT/usr/libexec/pearos"; install -m 755 "$WORK/is-out/iconservicesagent" "$WORK/is-out/iconservicesd" "$ROOT/usr/libexec/pearos/"; install -d "$ROOT/usr/libexec/pearos/jobs"; install -m 644 "$IS_DIR"/launchd/*.plist "$ROOT/usr/libexec/pearos/jobs/"; echo "IconServices built"
	else echo "NOTE: IconServices did not build (see $WORK/is.log)"; tail -5 "$WORK/is.log"; fi
else echo "NOTE: IconServices not built (needs the IconServices repository, the open SDK and darwinator)"; fi
for d in etc private/etc; do install -m 755 "$HERE/overlay/etc-rc.d-wsbsd_macstack" "$ROOT/$d/rc.d/wsbsd_macstack"; done
for d in etc private/etc; do install -m 755 "$HERE/overlay/etc-rc.d-wsbsd_launchd" "$ROOT/$d/rc.d/wsbsd_launchd"; done
for d in etc private/etc; do install -m 755 "$HERE/overlay/etc-rc.d-wsbsd_machrun" "$ROOT/$d/rc.d/wsbsd_machrun"; done
for d in etc private/etc; do install -m 755 "$HERE/overlay/etc-rc.d-wsbsd_macdeps" "$ROOT/$d/rc.d/wsbsd_macdeps"; done
for d in etc private/etc; do install -m 755 "$HERE/overlay/etc-rc.d-wsbsd_wifi" "$ROOT/$d/rc.d/wsbsd_wifi"; done
for d in etc private/etc; do install -m 755 "$HERE/overlay/etc-rc.d-wsbsd_bluetooth" "$ROOT/$d/rc.d/wsbsd_bluetooth"; done
for d in etc private/etc; do install -m 755 "$HERE/overlay/etc-rc.d-wsbsd_gpu" "$ROOT/$d/rc.d/wsbsd_gpu"; done
for d in etc private/etc; do install -m 755 "$HERE/overlay/etc-rc.d-wsbsd_ssh" "$ROOT/$d/rc.d/wsbsd_ssh"; done
for d in etc private/etc; do install -m 755 "$HERE/overlay/etc-rc.d-airportd" "$ROOT/$d/rc.d/airportd"; install -m 755 "$HERE/overlay/etc-rc.d-usernoted" "$ROOT/$d/rc.d/usernoted"; done
# no text login on the screen: the window server owns it (the serial console keeps its login)
for d in etc private/etc; do sed -i '' -E 's/^(ttyv[0-9a-f]+[[:space:]].*[[:space:]])(onifexists|on)([[:space:]]|$)/\1off\3/' "$ROOT/$d/ttys"; done
# the shell of root and of the Terminal: zsh, the default shell of macOS (/bin/zsh), with /etc/zprofile and /etc/zshrc taken from the author's Mac configuration, minus what is Mac-only
[ -x "$ROOT/usr/local/bin/zsh" ] || { echo "image check failed: zsh is not in the image"; exit 1; }
install -m 755 "$ROOT/usr/local/bin/zsh" "$ROOT/bin/zsh"
for d in etc private/etc usr/local/etc; do          # FreeBSD's zsh reads its global files from /usr/local/etc, the Mac's from /etc: both
	mkdir -p "$ROOT/$d"; [ $d = usr/local/etc ] || { grep -qx /bin/zsh "$ROOT/$d/shells" 2>/dev/null || echo /bin/zsh >> "$ROOT/$d/shells"; }
	cp "$HERE/overlay/etc-zprofile" "$ROOT/$d/zprofile"; cp "$HERE/overlay/etc-zshrc" "$ROOT/$d/zshrc"
done
pw -R "$ROOT" usermod root -s /bin/zsh
# the account of the image: alex, password "pear", administrator (wheel, sudo / doas without asking again is not given: the password is asked)
pw -R "$ROOT" groupshow alex >/dev/null 2>&1 || pw -R "$ROOT" groupadd alex -g 501
pw -R "$ROOT" usershow alex >/dev/null 2>&1 || { echo pear | pw -R "$ROOT" useradd alex -u 501 -g alex -G wheel,operator,video -c "Alex" -d /Users/alex -s /bin/zsh -h 0; }
mkdir -p "$ROOT/Users/alex"
for d in usr/local/etc etc; do mkdir -p "$ROOT/$d"; done
if [ -x "$ROOT/usr/local/bin/sudo" ] || pkg info -e sudo >/dev/null 2>&1; then printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$ROOT/usr/local/etc/sudoers"; chmod 440 "$ROOT/usr/local/etc/sudoers"; fi
printf 'permit persist :wheel\npermit nopass root\n' > "$ROOT/usr/local/etc/doas.conf"; cp "$ROOT/usr/local/etc/doas.conf" "$ROOT/etc/doas.conf" 2>/dev/null
# pkg is real and usable: the static pkg of the build machine is /usr/local/sbin/pkg (/usr/sbin/pkg, the bootstrapper, hands over to it), /usr/local is made writable at boot (wsbsd_overlay: a unionfs
# over the read-only medium), the repository is FreeBSD's own (/etc/pkg/FreeBSD.conf), the database lives in /var/db/pkg (a memory file system on the live image)
if [ -x /usr/local/sbin/pkg-static ]; then install -d "$ROOT/usr/local/sbin" "$ROOT/usr/local/etc"; install -m 755 /usr/local/sbin/pkg-static "$ROOT/usr/local/sbin/pkg"; cp /usr/local/etc/pkg.conf.sample "$ROOT/usr/local/etc/pkg.conf.sample" 2>/dev/null; else echo "NOTE: pkg-static is not on the build machine: pkg stays the bootstrapper"; fi
for d in etc private/etc; do install -m 755 "$HERE/overlay/etc-rc.d-wsbsd_overlay" "$ROOT/$d/rc.d/wsbsd_overlay"; done
# the local time zone (GNUstep's NSTimeZone and ICU's date formats need one; the image has no /etc/localtime of its own)
for d in etc private/etc; do cp "$ROOT/usr/share/zoneinfo/UTC" "$ROOT/$d/localtime" 2>/dev/null || true; done
# what the desktop needs at run time and that earlier images lacked: ICU's data (NSDateFormatter crashed without it), a time zone, no getty on the screen's console
for need in "$ROOT/usr/local/share/icu" "$ROOT/etc/localtime" "$ROOT/usr/local/lib/libicudata.so.76"; do [ -e "$need" ] || { echo "image check failed, missing: $need"; exit 1; }; done
grep -E '^ttyv0' "$ROOT/etc/ttys" | grep -qE '[[:space:]]off([[:space:]]|$)' || { echo "image check failed: ttyv0 still has a getty"; grep -E '^ttyv0' "$ROOT/etc/ttys"; exit 1; }
python3 "$HERE/tools/macfs.py" desymlink "$ROOT"
# the medium is read-only: the resolver file lives in memory (dhclient writes it; wsbsd_overlay gives it the name servers of public DNS when the network does not). After the last desymlink, which drops a link whose target does not exist yet
for d in etc private/etc; do [ -d "$ROOT/$d" ] || continue; rm -f "$ROOT/$d/resolv.conf"; ln -s /var/run/resolv.conf "$ROOT/$d/resolv.conf"; done
python3 "$HERE/tools/macfs.py" verify "$ROOT" "$HERE/manifest" || { echo "layout check failed"; [ -n "$LAYOUT_STRICT" ] && exit 1; }

echo "== 6. the EFI system partition: Ploader first, FreeBSD's loader behind it"
ESP="$WORK/esp"; rm -rf "$ESP"; mkdir -p "$ESP/EFI/BOOT" "$ESP/EFI/freebsd" "$ESP/EFI/ploader"
if [ -n "$PLOADER_DIR" ] && [ -f "$PLOADER_DIR/$PLNAME" ]; then
	cp "$PLOADER_DIR/$PLNAME" "$ESP/EFI/BOOT/$EFINAME"; cp "$PLOADER_DIR/$PLNAME" "$ESP/EFI/ploader/$PLNAME"
	[ -d "$PLOADER_DIR/theme" ] && cp -R "$PLOADER_DIR/theme" "$ESP/EFI/BOOT/theme" && cp -R "$PLOADER_DIR/theme" "$ESP/EFI/ploader/theme"
	[ -d "$PLOADER_DIR/drivers" ] && cp -R "$PLOADER_DIR/drivers" "$ESP/EFI/BOOT/drivers_$([ "$ARCH" = amd64 ] && echo x64 || echo aa64)"
	cp "$HERE/esp/ploader.conf" "$ESP/EFI/BOOT/ploader.conf"; cp "$HERE/esp/ploader.conf" "$ESP/EFI/ploader/ploader.conf"
	cp "$ROOT/boot/loader.efi" "$ESP/EFI/freebsd/loader.efi"
else
	echo "no Ploader build for $ARCH ($PLNAME): the image boots through FreeBSD's loader directly"
	cp "$ROOT/boot/loader.efi" "$ESP/EFI/BOOT/$EFINAME"
fi
makefs -t msdos -o fat_type=16 -o volume_label=EFISYS -s 64m "$WORK/efiboot.img" "$ESP"

echo "== 7. the ISO"
VERSION="${PEAROS_VERSION:-$(date +%y.%m)}"
ISO="$OUT/pearOS-UltraC0re-$ARCH-$VERSION.iso"
echo "== size of the image root (MB)"; du -sm "$ROOT"/* "$ROOT"/usr/* "$ROOT"/usr/local/* "$ROOT"/boot/* 2>/dev/null | sort -rn | head -14
makefs -t cd9660 -o rockridge -o label=PEAROS -o publisher="wsbsd" -o bootimage="i386;$WORK/efiboot.img" -o no-emul-boot -o platformid=efi "$ISO" "$ROOT"
# the ISO is also a disk image: a GPT over the EFI image inside it, so that a plain write to a USB stick (dd, Etcher) boots on a PC (iso/tools/hybrid.py)
python3 "$HERE/tools/hybrid.py" "$ISO" "$(stat -f %z "$WORK/efiboot.img" 2>/dev/null || stat -c %s "$WORK/efiboot.img")"
ls -l "$ISO"; sha256 "$ISO" > "$ISO.sha256"; cat "$ISO.sha256"

