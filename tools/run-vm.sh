#!/bin/sh
# Starts a pearOS VM with a window (QEMU/KVM on a Linux or macOS-with-HVF machine):  sh run-vm.sh PEAROS.iso [CACHE.img]
#   PEAROS.iso   the image (a release of github.com/pearOS-bsd/iso, `xz -d` first)
#   CACHE.img    the disk with the owner's Mac frameworks and dyld cache (made by macdeps from the owner's own Mac: Apple's files are never in the image);
#                without it the VM boots the GNUstep desktop; with it the Mac programs run and the new Control Center starts (rc.d/wsbsd_macstack)
# Environment: SMBIOS (e.g. wsbsd-ci: the test mode: the account signs in by itself and ssh is up), RAM (MB, default 6144), CPUS (default 4), SSHPORT (default 2224: ssh -p 2224 alex@localhost, password pear), DISPLAY_OPT (default gtk), WORK (default ~/.pear/vm)
set -e
ISO="${1:?usage: run-vm.sh PEAROS.iso [CACHE.img]}"; CACHE="$2"
WORK="${WORK:-$HOME/.pear/vm}"; mkdir -p "$WORK"
OVMF=$(ls /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/qemu/edk2-x86_64-code.fd /opt/homebrew/share/qemu/edk2-x86_64-code.fd 2>/dev/null | head -1)
[ -n "$OVMF" ] || { echo "no OVMF firmware found (apt install ovmf / brew install qemu)"; exit 1; }
VARS="$WORK/vars.fd"; if [ ! -f "$VARS" ]; then for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd; do [ -f $v ] && cp $v "$VARS" && break; done; [ -f "$VARS" ] || dd if=/dev/zero of="$VARS" bs=1k count=540 2>/dev/null; fi
case "$(uname -s)" in Linux) ACCEL="-accel kvm -cpu host";; Darwin) ACCEL="-accel hvf -cpu host";; *) ACCEL="-accel tcg";; esac
CACHEARGS=""; [ -n "$CACHE" ] && CACHEARGS="-drive if=none,id=c,file=$CACHE,format=raw,readonly=on -device virtio-blk-pci,drive=c"
# the GPU: virtio-vga (vendor 1af4:1050): the image has a DRM/KMS driver for it (module virtio_gpu) and the window server follows the size of the window (dynamic resolution: resize the QEMU window and the
# screen gets the new size); GL=1: virtio-vga-gl with the host's OpenGL (virgl: the OpenGL ES compositor).  "-vga std" (the old setting) has no resize: the guest keeps its size and QEMU scales the picture.
VGA="-device virtio-vga"; DISPLAYARG="${DISPLAY_OPT:-gtk}"; [ -n "$GL" ] && { VGA="-device virtio-vga-gl"; DISPLAYARG="$DISPLAYARG,gl=on"; }
# the image is read-only (the session lives in memory): snapshot=on keeps the ISO untouched
exec qemu-system-x86_64 $ACCEL -m "${RAM:-6144}" -smp "${CPUS:-4}" -machine q35 -vga none $VGA -display "$DISPLAYARG" \
	-drive if=pflash,format=raw,readonly=on,file="$OVMF" -drive if=pflash,format=raw,file="$VARS" \
	-drive if=none,id=u,file="$ISO",format=raw,snapshot=on -device ich9-ahci,id=ahci -device ide-hd,drive=u,bus=ahci.0,bootindex=1 \
	-device qemu-xhci -device usb-kbd -device usb-tablet $CACHEARGS \
	${SMBIOS:+-smbios type=1,product=$SMBIOS} -netdev user,id=n0,hostfwd=tcp::"${SSHPORT:-2224}"-:22 -device virtio-net-pci,netdev=n0 \
	-monitor unix:"$WORK/monitor.sock",server,nowait -audiodev none,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0
