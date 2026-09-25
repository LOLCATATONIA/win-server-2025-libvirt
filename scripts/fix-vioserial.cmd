@echo off
:: Runs once, automatically, via the temporary autologon set up by
:: autologon-runonce.reg. Stages and installs the vioserial driver (needed
:: for the QEMU Guest Agent's virtio-serial channel to work at all), starts
:: the guest agent service, then removes the temporary autologon it was
:: triggered by. Place at C:\Windows\Setup\fix-vioserial.cmd inside the
:: guest filesystem before applying autologon-runonce.reg.
::
:: Unlike a build that hot-plugs the virtio-serial channel device onto an
:: already-installed VM, this one adds the channel device offline (via
:: virt-xml) while the VM is still stopped, before its first relevant boot —
:: so there's no stale "no driver found" device-enumeration cache to delete
:: first. If you add the channel device to an already-booted VM instead,
:: you'll also need to clear that cached PCI enum entry (see
:: win11-iot-ltsc-libvirt's delete-vioserial-enum.reg for the technique).

set LOG=C:\Windows\Temp\vioser-install.log

:: C:\Windows\INF is a valid *destination* for staged drivers, but pnputil
:: refuses to treat it as a *source* — stage the files somewhere else first.
mkdir C:\drivers\vioserial 2>nul
copy /y C:\Windows\INF\vioser.inf C:\drivers\vioserial\vioser.inf >> %LOG% 2>&1
copy /y C:\Windows\INF\vioser.sys C:\drivers\vioserial\vioser.sys >> %LOG% 2>&1
copy /y C:\Windows\INF\vioser.cat C:\drivers\vioserial\vioser.cat >> %LOG% 2>&1

pnputil /add-driver C:\drivers\vioserial\vioser.inf /install >> %LOG% 2>&1
pnputil /scan-devices >> %LOG% 2>&1

net start QEMU-GA >> %LOG% 2>&1

:: Self-cleanup: remove the temporary autologon this script was launched from.
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f >> %LOG% 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /f >> %LOG% 2>&1
