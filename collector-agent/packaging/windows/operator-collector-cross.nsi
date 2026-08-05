Unicode true

!include "MUI2.nsh"

!ifndef APP_VERSION
  !error "APP_VERSION is required"
!endif
!ifndef BUNDLE_DIR
  !error "BUNDLE_DIR is required"
!endif
!ifndef OUTPUT_FILE
  !error "OUTPUT_FILE is required"
!endif

Name "Operator Collector"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\OperatorCollector"
InstallDirRegKey HKCU "Software\LoveMoon\OperatorCollector" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma

VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey /LANG=1033 "ProductName" "Operator Collector"
VIAddVersionKey /LANG=1033 "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=1033 "CompanyName" "LoveMoon"
VIAddVersionKey /LANG=1033 "FileDescription" "Operator Collector Agent installer"
VIAddVersionKey /LANG=1033 "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=1033 "LegalCopyright" "Copyright LoveMoon"

!define MUI_ABORTWARNING
!define MUI_ICON "${NSISDIR}/Contrib/Graphics/Icons/modern-install.ico"
!define MUI_UNICON "${NSISDIR}/Contrib/Graphics/Icons/modern-uninstall.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Section "Operator Collector" SecMain
  SetShellVarContext current
  IfFileExists "$INSTDIR\operator-collector-stop.ps1" 0 +2
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\operator-collector-stop.ps1"'

  SetOutPath "$INSTDIR"
  File /r "${BUNDLE_DIR}/*.*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  WriteRegStr HKCU "Software\LoveMoon\OperatorCollector" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OperatorCollector" "DisplayName" "Operator Collector"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OperatorCollector" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OperatorCollector" "Publisher" "LoveMoon"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OperatorCollector" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OperatorCollector" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OperatorCollector" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OperatorCollector" "NoRepair" 1

  CreateDirectory "$SMPROGRAMS\Operator Collector"
  CreateShortCut "$SMPROGRAMS\Operator Collector\启动 Operator Collector.lnk" "$WINDIR\System32\wscript.exe" '"$INSTDIR\operator-collector-background.vbs"'
  CreateShortCut "$SMPROGRAMS\Operator Collector\卸载 Operator Collector.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortCut "$SMSTARTUP\Operator Collector.lnk" "$WINDIR\System32\wscript.exe" '"$INSTDIR\operator-collector-background.vbs"'

  Exec '"$WINDIR\System32\wscript.exe" "$INSTDIR\operator-collector-background.vbs"'
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\operator-collector-stop.ps1"'
  Sleep 1000
  Delete "$SMSTARTUP\Operator Collector.lnk"
  RMDir /r "$SMPROGRAMS\Operator Collector"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OperatorCollector"
  DeleteRegKey HKCU "Software\LoveMoon\OperatorCollector"
  RMDir /r "$INSTDIR"
SectionEnd
