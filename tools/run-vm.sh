#!/bin/sh
# Starts a pearOS VM with a window (QEMU/KVM on a Linux or macOS-with-HVF machine):  sh run-vm.sh PEAROS.iso [CACHE.img]
#   PEAROS.iso   the image (a release of github.com/pearOS-bsd/iso, `xz -d` first)
#   CACHE.img    the disk with the owner's Mac frameworks and dyld cache (made by macdeps from the owner's own Mac: Apple's files are never in the image);
#                without it the VM boots the GNUstep desktop; with it the Mac programs run and the new Control Center starts (rc.d/wsbsd_macstack)
# The serial console is a socket: socat - UNIX-CONNECT:$WORK/serial.sock (the image has a login there: alex / pear).
# Environment: SSH_KEY (a public key file: a small disk labelled EFISYS with ssh.enable is attached, so the image starts sshd for that key: ssh -p 2224 alex@localhost), SMBIOS (e.g. wsbsd-ci: the test mode: the account signs in by itself and ssh is up), RAM (MB, default 6144), CPUS (default 4), SSHPORT (default 2224: ssh -p 2224 alex@localhost, password pear), DISPLAY_OPT (default gtk), WORK (default ~/.pear/vm)
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
VGA="-vga none -device virtio-vga"; DISPLAYARG="${DISPLAY_OPT:-gtk}"; [ -n "$GL" ] && { VGA="-vga none -device virtio-vga-gl"; DISPLAYARG="$DISPLAYARG,gl=on"; }
SSHARGS=""
if [ -n "$SSH_KEY" ]; then
	command -v mformat >/dev/null && command -v mcopy >/dev/null || { echo "SSH_KEY needs mformat and mcopy (mtools)"; exit 1; }
	# a GPT disk with one FAT partition labelled EFISYS: wsbsd_ssh looks at /dev/msdosfs/EFISYS and at the first partition of every disk (da0p1)
	command -v sgdisk >/dev/null || { echo "SSH_KEY needs sgdisk (gdisk)"; exit 1; }
	rm -f "$WORK/ssh.img"; dd if=/dev/zero of="$WORK/ssh.img" bs=1M count=16 2>/dev/null; sgdisk -n 1:2048:0 -t 1:0700 -c 1:EFISYS "$WORK/ssh.img" >/dev/null
	mformat -i "$WORK/ssh.img@@1M" -v EFISYS -F :: ; cp "$SSH_KEY" "$WORK/ssh.enable"; mcopy -i "$WORK/ssh.img@@1M" "$WORK/ssh.enable" ::ssh.enable
	SSHARGS="-drive if=none,id=s,file=$WORK/ssh.img,format=raw -device ide-hd,drive=s,bus=ahci.1"
fi
[ -n "$VGASTD" ] && VGA="-vga std"       # the old setting: no DRM driver, no resize
# the image is read-only (the session lives in memory): snapshot=on keeps the ISO untouched
exec qemu-system-x86_64 $ACCEL -m "${RAM:-6144}" -smp "${CPUS:-4}" -machine q35 $VGA -display "$DISPLAYARG" \
	-drive if=pflash,format=raw,readonly=on,file="$OVMF" -drive if=pflash,format=raw,file="$VARS" \
	-drive if=none,id=u,file="$ISO",format=raw,snapshot=on -device ich9-ahci,id=ahci -device ide-hd,drive=u,bus=ahci.0,bootindex=1 \
	-device qemu-xhci -device usb-kbd -device usb-tablet $CACHEARGS $SSHARGS \
	${SMBIOS:+-smbios type=1,product=$SMBIOS} -netdev user,id=n0,hostfwd=tcp::"${SSHPORT:-2224}"-:22 -device virtio-net-pci,netdev=n0 \
	-monitor unix:"$WORK/monitor.sock",server,nowait -serial "${SERIAL:-unix:$WORK/serial.sock,server,nowait}" -audiodev none,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0
