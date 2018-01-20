@echo off

echo Removing scheduled task...
SCHTASKS.exe /END /TN DiskIOMon
SCHTASKS.exe /Delete /TN DiskIOMon /f

echo Removing installation file.. 
set InstallDir=C:\Program Files\IOMon
if exist "%InstallDir%" (
	if exist "%InstallDir%\DiskIOMon.ps1" del "%InstallDir%\DiskIOMon.ps1" 
)
