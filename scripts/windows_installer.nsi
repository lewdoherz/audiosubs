; Compile through package_windows_release.ps1 with an open-source NSIS 3.x distribution.
; Payload extraction and exact-file uninstall lists are generated from the ZIP stage.
; Never use recursive deletion here: support data, models and user-added files survive.
Unicode true
RequestExecutionLevel user
ManifestDPIAware true

!ifndef APP_VERSION
  !error "APP_VERSION is required; use package_windows_release.ps1."
!endif
!ifndef APP_FILE_VERSION
  !error "APP_FILE_VERSION is required."
!endif
!ifndef SOURCE_DIR
  !error "SOURCE_DIR is required."
!endif
!ifndef OUTPUT_FILE
  !error "OUTPUT_FILE is required."
!endif
!ifndef PAYLOAD_INCLUDE
  !error "PAYLOAD_INCLUDE is required."
!endif

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
!include "${PAYLOAD_INCLUDE}"

; This identity must not change between versions. App support/storage identity is
; managed by Flutter, independently of this per-user installation registration.
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\AudioSubs"
Name "AudioSubs ${APP_VERSION}"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\AudioSubs"
InstallDirRegKey HKCU "${UNINSTALL_KEY}" "InstallLocation"
SetCompressor /SOLID lzma
SetDateSave on
ShowInstDetails show
ShowUninstDetails show
VIProductVersion "${APP_FILE_VERSION}"
VIAddVersionKey /LANG=1033 "ProductName" "AudioSubs"
VIAddVersionKey /LANG=1033 "FileDescription" "AudioSubs per-user installer (unsigned)"
VIAddVersionKey /LANG=1033 "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=1033 "FileVersion" "${APP_FILE_VERSION}"
VIAddVersionKey /LANG=1033 "LegalCopyright" "AudioSubs contributors"

!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TEXT "This unsigned installer installs AudioSubs for the current Windows user only.$\r$\n$\r$\nPython and the headless transcription worker are included. Speech and translation models are downloaded separately in AudioSubs.$\r$\n$\r$\nClose AudioSubs before installing or upgrading. Your library, settings, models and imported media are kept."
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchAudioSubs
!define MUI_FINISHPAGE_RUN_TEXT "Launch AudioSubs"
!insertmacro MUI_PAGE_WELCOME
!define MUI_LICENSEPAGE_TEXT_TOP "These are component-specific Intel and Microsoft terms, not an AudioSubs application licence. LGPL replacement/relinking rights are preserved."
!insertmacro MUI_PAGE_LICENSE "${SOURCE_DIR}\transcription_runtime\_internal\THIRD-PARTY-LICENSES\WINDOWS-TERMS.txt"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH
!insertmacro MUI_LANGUAGE "English"

Var PreviousInstallDirectory
Var PreviousUninstallResult

Function .onInit
  SetShellVarContext current
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "AudioSubs requires 64-bit Windows." /SD IDOK
    SetErrorLevel 1
    Abort
  ${EndIf}
FunctionEnd

Function un.onInit
  SetShellVarContext current
FunctionEnd

Function LaunchAudioSubs
  SetOutPath "$INSTDIR"
  Exec '"$INSTDIR\AudioSubs.exe"'
FunctionEnd

Section "AudioSubs (required)" MainSection
  SectionIn RO
  ; Run the previously registered exact-file uninstaller before replacing payload.
  ; _?= must be last and unquoted even for paths with spaces. It keeps ExecWait
  ; attached to the actual uninstaller instead of its temporary launcher process.
  ReadRegStr $PreviousInstallDirectory HKCU "${UNINSTALL_KEY}" "InstallLocation"
  ${If} $PreviousInstallDirectory != ""
    ${If} ${FileExists} "$PreviousInstallDirectory\uninstall.exe"
      ClearErrors
      ExecWait '"$PreviousInstallDirectory\uninstall.exe" /S _?=$PreviousInstallDirectory' $PreviousUninstallResult
      ${If} ${Errors}
        MessageBox MB_OK|MB_ICONSTOP "The previous AudioSubs installation could not be uninstalled. Close AudioSubs and retry." /SD IDOK
        SetErrorLevel 1
        Abort
      ${EndIf}
      ${If} $PreviousUninstallResult != 0
        MessageBox MB_OK|MB_ICONSTOP "The previous AudioSubs uninstaller failed. Close AudioSubs and retry." /SD IDOK
        SetErrorLevel 1
        Abort
      ${EndIf}
      ; The directly executed old uninstaller cannot delete its running image.
      Delete "$PreviousInstallDirectory\uninstall.exe"
      RMDir "$PreviousInstallDirectory"
    ${Else}
      MessageBox MB_OK|MB_ICONSTOP "The previous AudioSubs installation is missing its uninstaller. Restore it before upgrading." /SD IDOK
      SetErrorLevel 1
      Abort
    ${EndIf}
  ${EndIf}

  SetOverwrite on
  ClearErrors
  !insertmacro InstallPayload
  SetOutPath "$INSTDIR"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  ${If} ${Errors}
    MessageBox MB_OK|MB_ICONSTOP "AudioSubs could not write all installation files. Close AudioSubs and check the destination permissions." /SD IDOK
    SetErrorLevel 1
    Abort
  ${EndIf}

  CreateDirectory "$SMPROGRAMS\AudioSubs"
  CreateShortcut "$SMPROGRAMS\AudioSubs\AudioSubs.lnk" "$INSTDIR\AudioSubs.exe" "" "$INSTDIR\AudioSubs.exe" 0
  CreateShortcut "$SMPROGRAMS\AudioSubs\Uninstall AudioSubs.lnk" "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "AudioSubs"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "lewdoherz"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\AudioSubs.exe,0"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "URLInfoAbout" "https://github.com/lewdoherz/audiosubs"
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  ${If} ${Errors}
    MessageBox MB_OK|MB_ICONSTOP "AudioSubs installation registration failed. Check your user profile permissions." /SD IDOK
    SetErrorLevel 1
    Abort
  ${EndIf}
  SetErrorLevel 0
SectionEnd

Section /o "Desktop shortcut" DesktopSection
  SetOutPath "$INSTDIR"
  CreateShortcut "$DESKTOP\AudioSubs.lnk" "$INSTDIR\AudioSubs.exe" "" "$INSTDIR\AudioSubs.exe" 0
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${MainSection} "AudioSubs, Flutter assets and the private headless worker. No system Python is needed."
  !insertmacro MUI_DESCRIPTION_TEXT ${DesktopSection} "Add a shortcut to the current user's desktop (optional)."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Section "Uninstall"
  ; Only paths present in the packaged application manifest are removed.
  ; Unknown files and non-empty directories are deliberately retained.
  !insertmacro RemovePayload
  Delete "$SMPROGRAMS\AudioSubs\AudioSubs.lnk"
  Delete "$SMPROGRAMS\AudioSubs\Uninstall AudioSubs.lnk"
  RMDir "$SMPROGRAMS\AudioSubs"
  Delete "$DESKTOP\AudioSubs.lnk"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  SetErrorLevel 0
SectionEnd
