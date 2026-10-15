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

#include "Json.iss"
#include "NativeDeployment.iss"
#include "Lifecycle.iss"

#include "Endpoint.iss"

function ValidEndpoint: Boolean;
begin
  Result := False;
  ServerPage.Values[0] := Trim(ServerPage.Values[0]);
  if not ValidAddress(ServerPage.Values[0]) then begin
    MsgBox('Enter a hostname or IPv4 address, without a URL scheme or path.', mbError, MB_OK);
    Exit;
  end;
  if not ValidPort(ServerPage.Values[1]) then begin
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
  Endpoint, Host, Port, Config: String;
  Split: Integer;
begin
  if (CurPageID = wpFinished) and InstallFailed then begin
    WizardForm.Caption := 'AVC Public Access - installation FAILED';
    WizardForm.FinishedHeadingLabel.Caption := 'Installation FAILED - NOT VERIFIED';
    WizardForm.FinishedLabel.Caption := UnverifiedNotice;
    WizardForm.NextButton.Caption := 'Close (failed)';
    WizardForm.NoRadio.Checked := True;
    WizardForm.YesRadio.Visible := False;
    WizardForm.NoRadio.Visible := False;
  end;
  if (CurPageID = ServerPage.ID) and ((not SettingsLoaded) or (SettingsRoot <> ExpandConstant('{app}'))) then begin
    DeploymentRoot := RemoveBackslashUnlessRoot(ExpandFileName(ExpandConstant('{app}')));
    CheckPath(DeploymentRoot);
    Config := DeploymentRoot + '\Service\appsettings.json';
    Host := ''; Port := '5000';
    if PathPresent(Config) then begin
      Endpoint := ConfigEndpoint(ReadJsonFile(Config));
      Require(CompareText(Copy(Endpoint, 1, 7), 'http://') = 0, 'Existing endpoint requires administrator review.');
      Delete(Endpoint, 1, 7);
      if (Length(Endpoint) > 0) and (Endpoint[Length(Endpoint)] = '/') then
        Delete(Endpoint, Length(Endpoint), 1);
      Split := Pos(':', Endpoint);
      if Split = 0 then begin Host := Endpoint; Port := '80'; end
      else begin Host := Copy(Endpoint, 1, Split - 1); Port := Copy(Endpoint, Split + 1, Length(Endpoint)); end;
      Require(ValidAddress(Host), 'Existing server address requires administrator review.');
    end;
    ServerPage.Values[0] := Host; ServerPage.Values[1] := Port;
    if Host <> '' then Require(ValidEndpoint, 'Existing endpoint requires administrator review.');
    SettingsLoaded := True; SettingsRoot := ExpandConstant('{app}');
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

function InitializeSetup: Boolean;
begin
  Result := not WizardSilent;
  if not Result then MsgBox('Unattended installation is not supported. Confirm THAWED/no patron session interactively.', mbError, MB_OK);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  try
    Require(FreezePage.Values[0], 'Confirm THAWED and no active patron session.');
    Require(ValidEndpoint, 'Invalid server endpoint.');
    StopDeployment;
  except
    Result := GetExceptionMessage + ' Installation is not verified; do not freeze this workstation.';
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    VerifyPostInstall('http://' + ServerPage.Values[0] + ':' + IntToStr(StrToInt(ServerPage.Values[1])));
    if InstallFailed then MsgBox(UnverifiedNotice, mbError, MB_OK);
  end;
end;
