@echo off

echo creating installation directory...
set InstallDir=C:\Program Files\IOMon
if not exist "%InstallDir%" md "%InstallDir%"

echo copying files...
copy .\DiskIOMon.ps1 "%InstallDir%" /y >nul

echo Importing scheduled task...
SCHTASKS.exe /END /TN DiskIOMon
SCHTASKS.exe /Delete /TN DiskIOMon /f
SCHTASKS.exe /Create /XML .\SchTask-DiskIOMon.xml /TN DiskIOMon
SCHTASKS.exe /RUN /TN DiskIOMon



