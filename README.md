# win-server-2025-libvirt

Unattended install of **Windows Server 2025 Standard Evaluation (Desktop
Experience)** as a libvirt/QEMU/KVM virtual machine, with a working QEMU
Guest Agent — built as a lab domain controller, but the answer file and
troubleshooting notes here apply to any unattended Server 2025 install on
QEMU/KVM.

Managed entirely through `virsh`/`virt-install` — no manual
`qemu-system-x86_64` invocations. Sibling project to
[`win11-iot-ltsc-libvirt`](https://github.com/LOLCATATONIA/win11-iot-ltsc-libvirt),
which covers the client side of the same lab and the virtio-based guest-agent
fix this repo reuses.

## Why SATA + no TPM, unlike the client build

The obvious approach — reuse the client's virtio disk/network + TPM 2.0/SMM
recipe — **reliably crash-loops Windows Server 2025 Setup** on this QEMU/OVMF
stack: WinPE loads, GPT partitioning starts, exactly 512 bytes are written
(the protective MBR), then the VM silently resets itself to firmware, before
Setup's graphical UI ever appears.

Extensive isolation testing (removing the virtio-serial channel device alone,
removing TPM/SMM alone, switching disk bus alone, and combinations of the
above) never found a single decisive culprit — every variant with
virtio+TPM active crashed, every variant without it installed cleanly, but no
individual component change alone flipped the outcome. The root cause was
never fully pinned down. Along the way, two *separate*, confirmed, unrelated
bugs in the answer file itself were found and fixed (see below) — but even
with both fixed, the full virtio+TPM+channel-device combination still
crashed identically.

**The fix that works, reliably, every time:** drop TPM/SMM and virtio
entirely in favor of **SATA disk + a plain e1000e NIC**:

```sh
virt-install \
  --connect qemu:///system --name win-srv-2025 --os-variant win2k25 \
  --memory 4096 --vcpus 2 --cpu host-passthrough \
  --disk path=/var/lib/libvirt/images/win-srv-2025.qcow2,size=60,bus=sata,format=qcow2 \
  --disk path=/path/to/win-server-2025-eval.iso,device=cdrom,bus=sata,boot.order=1 \
  --disk path=/path/to/autounattend.iso,device=cdrom,bus=sata \
  --network network=default,model=e1000e \
  --graphics spice --video qxl --boot uefi --noautoconsole --noreboot
```

None of AD DS, Group Policy, PowerShell, Registry Editor, or Event Viewer
work needs TPM or virtio-level disk/network throughput, so for a lab DC this
is a fully adequate trade, not a compromise. If you're building a
performance-sensitive Server 2025 VM and hit the same crash pattern, you may
want to re-investigate the virtio+TPM combination yourself — see the two
confirmed bugs below first, since fixing those is a prerequisite either way.

**Always pass `--connect qemu:///system` explicitly.** Without it,
`virt-install`/`virsh` can silently fall back to a per-user `qemu:///session`
instance that lacks permission to write into `/var/lib/libvirt/images/`,
producing a confusing "Permission denied" from `qemu-img create`.

## Prerequisites

Tested on Arch Linux (CachyOS). Package names below are for `pacman`; the
underlying tools exist on most distros.

| Tool | Package | Purpose |
|---|---|---|
| `qemu-system-x86_64`, `qemu-img` | `qemu-full` (or `qemu-desktop`) | VM emulation, KVM acceleration |
| `virsh`, `virt-install`, `virt-xml` | `libvirt` | Domain/storage management |
| OVMF firmware | `edk2-ovmf` | UEFI firmware for the guest |
| `xorriso` | `libisoburn` (usually preinstalled) | Building the `autounattend.iso` |
| `ntfs-3g` | `ntfs-3g` | Needed only for the offline guest-agent fix below |
| `guestfish`, `hivexregedit` | `libguestfs` | Needed only for the offline guest-agent fix below |
| `msiextract` | `msitools` | Needed only for the offline guest-agent fix below |

No `swtpm` is needed here — this build deliberately runs without a TPM (see
above). You also need `libvirtd` running and your user in the `libvirt`
group (so `virsh`/`virt-install` work against `qemu:///system` without
`sudo`).

## 1. Get the install media

- **Windows Server 2025 Evaluation ISO** — official Microsoft Evaluation
  Center: https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025
- **virtio-win driver ISO** (official upstream, Fedora/Red&nbsp;Hat project) —
  needed only for the guest-agent fix, not for the OS install itself, since
  SATA/e1000e need no virtio drivers:
  https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso

Server media ships four editions (Standard/Datacenter x Core/Desktop
Experience) in one `install.wim` — check which `/IMAGE/INDEX` you want with:

```sh
wimlib-imagex info /path/to/install.wim
```

`autounattend.xml` in this repo targets index `2`
("Windows Server 2025 Standard Evaluation (Desktop Experience)") — adjust if
your ISO orders editions differently.

## 2. Build the answer file

`autounattend.xml` here drives a fully unattended install:

- GPT/UEFI partitioning (EFI System Partition + MSR + Windows partition —
  **not** a simplified single-partition layout, see the bug below on why
  that fails)
- no `DriverPaths` and no virtio drivers at all — nothing is needed at
  install time with SATA + e1000e
- creates a local administrator account, skips all OOBE/EULA/MSA screens

**Before building the ISO, open `autounattend.xml` and replace the
placeholder password** (`CHANGE-ME-Str0ng-Pa55w0rd!`) with your own. Never
commit a real password back into this file.

The XML ships with neutral defaults you'll likely want to change too — both
are called out with a comment at the relevant line:

- **Keyboard layout** (`InputLocale`, two places): `en-US` by default.
- **Timezone** (`TimeZone`): `UTC` by default, which always works. Set to a
  real Windows timezone ID (e.g. `Romance Standard Time` for
  Copenhagen/Paris/Brussels) if you want the guest clock to show local time.
- **Computer name**: `win-srv-2025` by default.

```sh
xorriso -as mkisofs -o autounattend.iso -V AUTOUNATTEND -J -R autounattend.xml
```

(A prebuilt `autounattend.iso` is included in this repo for convenience, but
it was built from the placeholder password above — rebuild it after editing
the XML.)

**Always include `-J -R`, even if you rename the source file with
`-graft-points`.** Dropping them 8.3-truncates `autounattend.xml` to
`AUTOUNAT.XML` on the resulting ISO, which Windows Setup's autodetection
does not recognize — the file becomes silently invisible to Setup. This was
the single most time-consuming bug found while building this repo; see
below.

## 3. Create the VM

Use the `virt-install` command in the "Why SATA + no TPM" section above.
`--os-variant win2k25` (via `osinfo-db`) makes `virt-install` pick a
UEFI-capable OVMF firmware descriptor and `q35` machine type automatically.

## 4. Start the VM and connect to it

`virt-install ... --noautoconsole` above only *creates and starts* the VM
without opening a display — you still need to connect separately to see
anything. `--graphics spice --video qxl` means any SPICE-capable viewer
works, the same as on any other libvirt VM.

Start (or restart) it:

```sh
virsh --connect qemu:///system start win-srv-2025
```

Check its state at any time:

```sh
virsh --connect qemu:///system list --all
```

Get a GUI, either way:

- **`virt-manager`** — the VM shows up under the `QEMU/KVM` connection
  (`qemu:///system`); double-click it to open the display.
- **`virt-viewer`** from a terminal:
  ```sh
  virt-viewer --connect qemu:///system win-srv-2025
  ```

You'll land on the Windows login screen. Log in with the local administrator
account you set in `autounattend.xml` before building the ISO (username
`admin` by default — see the `UserAccounts` section of the XML for the exact
name, and whatever password you replaced the placeholder with).

**Always shut down with `virsh shutdown`, not `virsh destroy`.** `destroy` is
a hard power-off and can leave the NTFS filesystem "unclean," which blocks a
later offline `guestfish` edit (like the guest-agent fix below) until Windows
has booted once more and shut down cleanly.

```sh
virsh --connect qemu:///system shutdown win-srv-2025
```

Once the guest agent (below) is working, a few more things become available
without needing the GUI at all:

```sh
# confirm the agent is alive
virsh --connect qemu:///system qemu-agent-command win-srv-2025 '{"execute":"guest-ping"}'

# get the guest's IP reliably (works even without a DHCP lease visible to the host)
virsh --connect qemu:///system domifaddr win-srv-2025 --source agent

# clean guest-initiated shutdown instead of an ACPI request
virsh --connect qemu:///system shutdown win-srv-2025 --mode agent
```

## 5. Two real bugs you may hit building your own answer file

These were found the hard way while developing this repo, confirmed by
booting into a WinPE command prompt mid-install (`Shift+F10` during Setup,
then `dir E:\`, `dir C:\`, etc.) to inspect what Setup actually saw:

1. **8.3 filename truncation.** An ISO built with `xorriso -as mkisofs`
   without `-J -R` (Joliet/Rock Ridge) — including when using
   `-graft-points` to rename the source file, which silently drops them if
   you don't ask for them separately — truncates `autounattend.xml` to
   `AUTOUNAT.XML`. Windows Setup's autodetection looks for the file by its
   real name and never finds it, so the "unattended" install just runs the
   interactive installer instead, with no error. Always pass `-J -R`.

2. **Wrong `PartitionID` from a simplified `DiskConfiguration`.** A
   single-`CreatePartition` answer file (just one `Primary` partition,
   relying on Setup to handle EFI/MSR automatically) works fine in the
   *interactive* installer's own partitioning wizard, but **not** through an
   unattend file — Setup's unattend engine does not auto-insert ESP+MSR
   ahead of a lone partition, so that partition actually becomes
   `PartitionID=1`, not 3. If your `ModifyPartitions`/`InstallTo` still
   targets `PartitionID=3`, it silently matches nothing: no format, no drive
   letter, and Setup stalls at "Select where to install Windows" with no
   visible `C:\` drive. Always use the full explicit 3-partition
   (EFI + MSR + Primary) scheme this repo's `autounattend.xml` uses.

## 6. Guest agent doesn't come up — why, and the fix

After install, `virsh qemu-agent-command <vm> '{"execute":"guest-ping"}'`
will keep failing with "QEMU guest agent is not connected", because
`virt-install` doesn't add a virtio-serial channel device by default, and
even once added, Windows has no driver for it and nothing ever triggers the
`RunOnce` install step at an unattended, non-interactive boot.

Unlike a build where the channel device gets hot-plugged onto an
*already-installed* VM (which leaves Windows with a stale "no driver found"
cache for that PCI device that never auto-retries), this repo's approach
adds the channel device **offline, while the VM is stopped**, before doing
any of the fix below — so there's no stale cache to clear first:

1. Shut the VM down (if running).
2. Add the virtio-serial channel device via an offline domain edit:
   ```sh
   virt-xml --connect qemu:///system win-srv-2025 \
     --add-device --channel type=unix,target.type=virtio,target.name=org.qemu.guest_agent.0
   ```
   (Omit `--update` — the VM is stopped, so this only needs to persist to
   the domain XML for the next boot.)
3. Apply the fix entirely offline (VM still powered off), using
   `guestfish`+`hivexregedit` against the qcow2 disk directly — no need to
   type a password through `virsh send-key` (fragile with non-US keyboard
   layouts, and impossible to verify since the field is masked). The
   [`scripts/`](scripts/) folder has the exact files this needs — each one
   has usage notes in its header comment:
   1. Extract `qemu-ga.exe` and its DLLs from
      `virtio-win.iso:\guest-agent\qemu-ga-x86_64.msi` with `msiextract`,
      copy them into the guest filesystem at `C:\Program Files\Qemu-ga\`,
      then register the service with
      [`scripts/qga-service.reg`](scripts/qga-service.reg) (`hivexregedit
      --merge` against the guest's `SYSTEM` hive).
   2. Copy `vioserial\2k25\amd64\vioser.{inf,sys,cat}` from `virtio-win.iso`
      into `C:\Windows\INF\` inside the guest filesystem
      ([`fix-vioserial.cmd`](scripts/fix-vioserial.cmd) stages them from
      there into a proper source folder before installing — **not**
      directly into `C:\Windows\INF\`, which `pnputil /add-driver` refuses
      as a source location).
   3. Place [`scripts/fix-vioserial.cmd`](scripts/fix-vioserial.cmd) at
      `C:\Windows\Setup\fix-vioserial.cmd` inside the guest filesystem, then
      set a **temporary** autologon that triggers it once, with
      [`scripts/autologon-runonce.reg`](scripts/autologon-runonce.reg) (edit
      the password placeholder in that file to match your real one first —
      merge against the guest's `SOFTWARE` hive). The script installs the
      driver, starts the service, and deletes the autologon settings itself
      as its last step — no permanent passwordless login left behind.
4. Boot the VM once — it logs in automatically, the script fixes the driver
   and starts the service, then disables autologon again on its own. Verify
   with `virsh qemu-agent-command <vm> '{"execute":"guest-ping"}'`.

On the build this repo is generalized from (same SATA/e1000e/no-TPM config,
just a different hostname/password), this worked first try (~50 seconds
after boot), no retries needed — likely *because* the channel device was
present from before the first relevant boot, rather than hot-plugged onto an
already-running guest with a cached negative driver-search result.

Two more pitfalls you'll hit doing this:

- **After a `virsh destroy` (forced power-off), `ntfs-3g` refuses read-write
  mounts** ("the disk contains an unclean file system") until Windows has
  booted once and been shut down *cleanly*. Always prefer `virsh shutdown`;
  only force-destroy as a last resort, and boot the VM once more afterwards
  before attempting another offline edit.
- **`C:\Windows\INF` is a destination, not a valid `pnputil /add-driver`
  source.** Stage driver files somewhere else first.

## Security notes

- Never commit a real admin password. The XML in this repo ships with an
  obvious placeholder (`CHANGE-ME-Str0ng-Pa55w0rd!`) for exactly this reason.
- The offline autologon trick above is temporary by design — verify
  `AutoAdminLogon` is back to `0` and `DefaultPassword` is gone afterwards
  (`reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon`
  via `virsh qemu-agent-command`, once the agent is up).
