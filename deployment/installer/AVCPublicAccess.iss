; Compile only through Build-Package.ps1: StageRoot is a fresh publish tree.
#ifndef StageRoot
  #error StageRoot must be supplied by the build script
#endif
#ifndef PackageVersion
  #error PackageVersion must be supplied by the build script
#endif
#ifndef OutputRoot
  #error OutputRoot must be supplied by the build script
#endif

[Setup]
AppId={{A3FA2FB5-0AC3-420B-B327-3120154A0F52}
AppName=AVC Public Access
AppVersion={#PackageVersion}
AppPublisher=Antelope Valley College
VersionInfoVersion={#PackageVersion}.0
DefaultDirName={autopf}\AVC\PublicAccess
DisableProgramGroupPage=yes
SetupArchitecture=x64
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.17763
PrivilegesRequired=admin
UsePreviousAppDir=yes
Uninstallable=yes
UninstallDisplayName=AVC Public Access
UninstallDisplayIcon={app}\Client\AVCPublicAccess.Client.exe
UninstallFilesDir={app}
OutputDir={#OutputRoot}
OutputBaseFilename=AVCPublicAccess-Client-Setup-{#PackageVersion}-win-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
SetupLogging=yes
DisableDirPage=auto

[Files]
; The Watchdog must remain next to Client\, not inside a Watchdog\ folder.
Source: "{#StageRoot}\Watchdog\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageRoot}\Client\*"; DestDir: "{app}\Client"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageRoot}\Service\*"; DestDir: "{app}\Service"; Excludes: "appsettings.json"; Flags: ignoreversion recursesubdirs createallsubdirs
; Preserve working configuration on upgrades and retain it on uninstall.
Source: "{#StageRoot}\Service\appsettings.json"; DestDir: "{app}\Service"; Flags: onlyifdoesntexist uninsneveruninstall
Source: "{#StageRoot}\Deployment\Deployment.ps1"; DestDir: "{app}\Deployment"; Flags: ignoreversion
Source: "{#StageRoot}\Deployment\payload-manifest.json"; DestDir: "{app}\Deployment"; Flags: ignoreversion

[Code]
var
  ServerPage: TInputQueryWizardPage;
  FreezePage: TInputOptionWizardPage;
  TestButton: TNewButton;
  SettingsLoaded: Boolean;
  SettingsRoot: String;

function Quote(const Value: String): String;
begin
  Result := '"' + Value + '"';
end;

function RunDeployment(const Action, ScriptPath, Extra: String; var MessageText: String): Boolean;
var
  ResultCode: Integer;
  Report, Params: String;
  Lines: TArrayOfString;
begin
  Report := ExpandConstant('{tmp}\avc-deployment-result.txt');
  DeleteFile(Report);
  Params := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + Quote(ScriptPath) +
    ' -Action ' + Action + ' -InstallRoot ' + Quote(ExpandConstant('{app}')) +
    ' -ReportPath ' + Quote(Report) + Extra;
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Params,
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := Result and (ResultCode = 0);
  MessageText := '';
  if FileExists(Report) and LoadStringsFromFile(Report, Lines) then
    if GetArrayLength(Lines) > 0 then MessageText := Lines[0];
  if (not Result) and (MessageText = '') then
    MessageText := 'AVC deployment helper failed. Installation is not verified; do not freeze this workstation.';
end;

function ValidAddress(const Value: String): Boolean;
var
  I, PartLength, PartValue, PartCount: Integer;
  Numeric, PreviousHyphen: Boolean;
  C: Char;
begin
  Result := False;
  if (Length(Value) = 0) or (Length(Value) > 253) then Exit;
  Numeric := True;
  for I := 1 to Length(Value) do
    if not (((Value[I] >= '0') and (Value[I] <= '9')) or (Value[I] = '.')) then Numeric := False;
  PartLength := 0;
  PartValue := 0;
  PartCount := 1;
  PreviousHyphen := False;
  for I := 1 to Length(Value) do begin
    C := Value[I];
    if C = '.' then begin
      if (PartLength = 0) or PreviousHyphen then Exit;
      if Numeric and ((PartLength > 3) or (PartValue > 255)) then Exit;
      PartLength := 0;
      PartValue := 0;
      PartCount := PartCount + 1;
    end else begin
      if not (((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
        ((C >= '0') and (C <= '9')) or (C = '-')) then Exit;
      if (PartLength = 0) and (C = '-') then Exit;
      if Numeric and (PartLength = 1) and (PartValue = 0) then Exit;
      PartLength := PartLength + 1;
      if PartLength > 63 then Exit;
      if Numeric then PartValue := PartValue * 10 + Ord(C) - Ord('0');
      PreviousHyphen := C = '-';
    end;
  end;
  if (PartLength = 0) or PreviousHyphen then Exit;
  if Numeric and ((PartCount <> 4) or (PartLength > 3) or (PartValue > 255)) then Exit;
  Result := True;
end;

function ValidEndpoint: Boolean;
var
  I, Port: Integer;
  Value: String;
begin
  Result := False;
  ServerPage.Values[0] := Trim(ServerPage.Values[0]);
  if not ValidAddress(ServerPage.Values[0]) then begin
    MsgBox('Enter a hostname or IPv4 address, without a URL scheme or path.', mbError, MB_OK);
    Exit;
  end;
  Value := ServerPage.Values[1];
  if (Length(Value) = 0) or (Length(Value) > 5) then begin
    MsgBox('Enter a numeric TCP port from 1 through 65535.', mbError, MB_OK);
    Exit;
  end;
  for I := 1 to Length(Value) do
    if (Value[I] < '0') or (Value[I] > '9') then begin
      MsgBox('Enter a numeric TCP port from 1 through 65535.', mbError, MB_OK);
      Exit;
    end;
  Port := StrToIntDef(Value, 0);
  if (Port < 1) or (Port > 65535) then begin
    MsgBox('Enter a numeric TCP port from 1 through 65535.', mbError, MB_OK);
    Exit;
  end;
  Result := True;
end;

procedure TestConnectionClick(Sender: TObject);
var
  Request: Variant;
  URL: String;
begin
  if not ValidEndpoint then Exit;
  URL := 'http://' + ServerPage.Values[0] + ':' + ServerPage.Values[1] + '/';
  try
    Request := CreateOleObject('WinHttp.WinHttpRequest.5.1');
    Request.SetTimeouts(5000, 5000, 5000, 5000);
    Request.SetAutoLogonPolicy(2); // Never send Windows logon credentials.
    Request.Option(6) := False; // No redirects or credentials.
    Request.Open('GET', URL, False);
    Request.Send;
    MsgBox('Server responded with HTTP status ' + IntToStr(Request.Status) +
      '. This checks connectivity only; access-code redemption must be tested separately.', mbInformation, MB_OK);
  except
    MsgBox('No HTTP response. Check the address, port, network, Server service, and firewall.', mbError, MB_OK);
  end;
end;

procedure InitializeWizard;
begin
  ServerPage := CreateInputQueryPage(wpSelectDir, 'AVC Server connection',
    'Configure this public workstation', 'Enter the Server hostname or IPv4 address and TCP port. No Server credentials are stored.');
  ServerPage.Add('Server &Address:', False);
  ServerPage.Add('Server &Port:', False);
  ServerPage.Values[1] := '5000';
  TestButton := TNewButton.Create(ServerPage);
  TestButton.Parent := ServerPage.Surface;
  TestButton.Left := 0;
  TestButton.Top := ServerPage.Edits[1].Top + ServerPage.Edits[1].Height + ScaleY(16);
  TestButton.Width := ScaleX(130);
  TestButton.Height := ScaleY(25);
  TestButton.Caption := '&Test Connection';
  TestButton.OnClick := @TestConnectionClick;
  FreezePage := CreateInputOptionPage(ServerPage.ID, 'Deep Freeze deployment',
    'Install and verify while THAWED', 'Do not install during a patron session. Return this workstation to FROZEN only after verification and reboot testing. Setup does not change Deep Freeze settings.', False, False);
  FreezePage.Add('I have confirmed this workstation is THAWED and no patron session is active.');
end;

procedure CurPageChanged(CurPageID: Integer);
var
  MessageText, SettingsPath: String;
begin
  if (CurPageID = ServerPage.ID) and ((not SettingsLoaded) or (SettingsRoot <> ExpandConstant('{app}'))) then begin
    ExtractTemporaryFile('Deployment.ps1');
    if not RunDeployment('ReadSettings', ExpandConstant('{tmp}\Deployment.ps1'), '', MessageText) then
      RaiseException(MessageText);
    SettingsPath := ExpandConstant('{tmp}\avc-deployment-result.txt');
    ServerPage.Values[0] := GetIniString('Server', 'Address', '', SettingsPath);
    ServerPage.Values[1] := GetIniString('Server', 'Port', '5000', SettingsPath);
    SettingsLoaded := True;
    SettingsRoot := ExpandConstant('{app}');
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = ServerPage.ID then Result := ValidEndpoint;
  if (CurPageID = FreezePage.ID) and (not FreezePage.Values[0]) then begin
    MsgBox('Confirm the workstation is thawed and has no active patron session.', mbError, MB_OK);
    Result := False;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  MessageText: String;
begin
  Result := '';
  if WizardSilent then begin
    Result := 'Unattended installation is not supported. Use the Server connection and Deep Freeze verification pages.';
    Exit;
  end;
  ExtractTemporaryFile('Deployment.ps1');
  if not RunDeployment('Prepare', ExpandConstant('{tmp}\Deployment.ps1'), '', MessageText) then Result := MessageText;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  MessageText, Extra: String;
begin
  if CurStep = ssPostInstall then begin
    Extra := ' -ServerAddress ' + Quote(ServerPage.Values[0]) + ' -ServerPort ' + Quote(ServerPage.Values[1]);
    if not RunDeployment('Install', ExpandConstant('{app}\Deployment\Deployment.ps1'), Extra, MessageText) then
      RaiseException(MessageText);
  end;
end;

function InitializeUninstall: Boolean;
var
  MessageText: String;
begin
  Result := False;
  if MsgBox('Uninstall only while THAWED and with no patron session. Continue?', mbConfirmation, MB_YESNO) <> idYes then Exit;
  Result := RunDeployment('Preflight', ExpandConstant('{app}\Deployment\Deployment.ps1'), '', MessageText);
  if not Result then MsgBox(MessageText, mbError, MB_OK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  MessageText: String;
begin
  if CurUninstallStep = usUninstall then
    if not RunDeployment('Uninstall', ExpandConstant('{app}\Deployment\Deployment.ps1'), '', MessageText) then
      RaiseException(MessageText);
end;
