// Build-host-only harness. Mock platform boundaries; execute the same compiled
// JSON, ownership predicates, state gates, and shutdown ordering as Setup.
// Never distributed and never performs privileged machine operations.
#define DeploymentTest
#ifndef TestOutputRoot
  #error TestOutputRoot required
#endif
[Setup]
AppName=AVC installer code tests
AppVersion=1.0.0
DefaultDirName={tmp}\AVC-installer-tests
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=lowest
OutputDir={#TestOutputRoot}
OutputBaseFilename=InstallerSelfTest
SetupArchitecture=x64
MinVersion=10.0.17763
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
WizardStyle=modern
[Code]
#include "../installer/Endpoint.iss"
#include "../installer/Json.iss"
#include "../installer/NativeDeployment.iss"
#include "../installer/Lifecycle.iss"
var Checks: Integer;

procedure ExitProcess(Code: LongWord);
  external 'ExitProcess@kernel32.dll stdcall';

procedure Check(Condition: Boolean; const Name: String);
begin
  Require(Condition, 'Test failed: ' + Name); Checks := Checks + 1;
end;

procedure RejectJson(const Text: String);
var Rejected: Boolean;
begin
  Rejected := False;
  try ParseJson(Text); except Rejected := True; end;
  Check(Rejected, 'Reject malformed/ambiguous JSON');
end;

procedure ResetMocks;
begin
  MockState := 4; MockStateFile := False; MockTemporaryState := False;
  MockQueryError := False; MockReparse := False; MockActive := False;
  MockApiError := False; MockStopWritesState := False; MockResumed := False;
  MockPostFailure := 0; MockUninstallCalls := 0; MockUninstallConfirmed := True;
  MockUninstallFailure := False; MockRegistrationsRemoved := False;
  WatchdogDisabledByInstaller := False;
  InstallAttempted := False; InstallVerified := False; InstallFailed := False;
end;

function ExpectedWatchdog: TWatchdogDefinition;
begin
  Result.PrincipalId := 'Patron'; Result.ActionContext := 'Patron';
  Result.UserId := ''; Result.GroupSid := 'S-1-5-32-545';
  Result.LogonType := 4; Result.RunLevel := 0;
  Result.TriggerCount := 1; Result.LogonTrigger := True; Result.TriggerEnabled := True;
  Result.TriggerUser := ''; Result.StartBoundary := ''; Result.EndBoundary := '';
  Result.Delay := ''; Result.RepetitionInterval := ''; Result.RepetitionDuration := '';
  Result.TriggerLimit := ''; Result.RepetitionStop := False;
  Result.TaskEnabled := True; Result.MultipleInstances := 2;
  Result.DisallowBattery := False; Result.StopOnBattery := False; Result.StartWhenAvailable := True;
  Result.ExecutionLimit := 'PT0S'; Result.RestartInterval := 'PT1M'; Result.RestartCount := 3;
  Result.RunOnlyIdle := False; Result.RunOnlyNetwork := False; Result.Hidden := False;
  Result.AllowDemand := True; Result.AllowTerminate := True;
end;

procedure LifecycleTests;
var D: TWatchdogDefinition; I: Integer; Rejected: Boolean;
begin
  D := ExpectedWatchdog; Check(WatchdogDefinitionMatches(D, False), 'Complete expected Watchdog identity');
  D.GroupSid := 'S-1-5-18'; Check(not WatchdogDefinitionMatches(D, False), 'SYSTEM principal rejected');
  D := ExpectedWatchdog; D.UserId := 'other-user'; Check(not WatchdogDefinitionMatches(D, False), 'Named user principal rejected');
  D := ExpectedWatchdog; D.PrincipalId := 'Other'; Check(not WatchdogDefinitionMatches(D, False), 'Principal context identity rejected');
  D := ExpectedWatchdog; D.ActionContext := 'Other'; Check(not WatchdogDefinitionMatches(D, False), 'Action principal mismatch rejected');
  D := ExpectedWatchdog; D.LogonType := 5; Check(not WatchdogDefinitionMatches(D, False), 'Service logon rejected');
  D := ExpectedWatchdog; D.RunLevel := 1; Check(not WatchdogDefinitionMatches(D, False), 'Elevated Watchdog rejected');
  D := ExpectedWatchdog; D.TriggerCount := 2; Check(not WatchdogDefinitionMatches(D, False), 'Extra trigger rejected');
  D := ExpectedWatchdog; D.LogonTrigger := False; Check(not WatchdogDefinitionMatches(D, False), 'Non-logon trigger rejected');
  D := ExpectedWatchdog; D.TriggerEnabled := False; Check(not WatchdogDefinitionMatches(D, False), 'Disabled trigger rejected');
  D := ExpectedWatchdog; D.TriggerUser := 'other-user'; Check(not WatchdogDefinitionMatches(D, False), 'User-limited trigger rejected');
  D := ExpectedWatchdog; D.StartBoundary := '2026-01-01T00:00:00'; Check(not WatchdogDefinitionMatches(D, False), 'Trigger boundary rejected');
  D := ExpectedWatchdog; D.EndBoundary := '2026-12-31T00:00:00'; Check(not WatchdogDefinitionMatches(D, False), 'Expiring trigger rejected');
  D := ExpectedWatchdog; D.Delay := 'PT1H'; Check(not WatchdogDefinitionMatches(D, False), 'Delayed trigger rejected');
  D := ExpectedWatchdog; D.RepetitionInterval := 'PT1M'; Check(not WatchdogDefinitionMatches(D, False), 'Repeating trigger rejected');
  D := ExpectedWatchdog; D.TriggerLimit := 'PT1M'; Check(not WatchdogDefinitionMatches(D, False), 'Trigger execution limit rejected');
  D := ExpectedWatchdog; D.MultipleInstances := 0; Check(not WatchdogDefinitionMatches(D, False), 'Parallel instances rejected');
  D := ExpectedWatchdog; D.ExecutionLimit := 'PT72H'; Check(not WatchdogDefinitionMatches(D, False), 'Task execution limit rejected');
  D := ExpectedWatchdog; D.RestartCount := 0; Check(not WatchdogDefinitionMatches(D, False), 'Missing restart policy rejected');
  D := ExpectedWatchdog; D.RestartInterval := 'PT1H'; Check(not WatchdogDefinitionMatches(D, False), 'Wrong restart interval rejected');
  D := ExpectedWatchdog; D.DisallowBattery := True; Check(not WatchdogDefinitionMatches(D, False), 'Battery restriction rejected');
  D := ExpectedWatchdog; D.RunOnlyIdle := True; Check(not WatchdogDefinitionMatches(D, False), 'Idle-only task rejected');
  D := ExpectedWatchdog; D.RunOnlyNetwork := True; Check(not WatchdogDefinitionMatches(D, False), 'Network-dependent task rejected');
  D := ExpectedWatchdog; D.TaskEnabled := False;
  Check(not WatchdogDefinitionMatches(D, False), 'Initially disabled task rejected');
  Check(WatchdogDefinitionMatches(D, True), 'Our deliberate shutdown disable is permitted');
  D.RunLevel := 1; Check(not WatchdogDefinitionMatches(D, True), 'Shutdown flag never bypasses identity checks');

  ResetMocks; MockUninstallConfirmed := False;
  Check(not InitializeUninstall, 'THAWED confirmation cancellation aborts');
  Check((MockUninstallCalls = 0) and not MockRegistrationsRemoved and (MockState = 4), 'Cancel leaves Service and task unchanged');
  ResetMocks;
  Check(InitializeUninstall, 'Non-destructive preflight succeeds');
  Check((MockUninstallCalls = 0) and not MockRegistrationsRemoved and (MockState = 4), 'Final confirmation not yet accepted: no destruction');
  // Inno does not dispatch usUninstall after its final confirmation is cancelled.
  CurUninstallStepChanged(usDone);
  Check((MockUninstallCalls = 0) and not MockRegistrationsRemoved, 'Cancellation/other lifecycle steps cannot remove registrations');
  CurUninstallStepChanged(usUninstall);
  Check((MockUninstallCalls = 1) and MockRegistrationsRemoved, 'Confirmed usUninstall performs guarded destruction');
  ResetMocks; MockStateFile := True; Check(not InitializeUninstall, 'Active state blocks uninstall preflight');
  Rejected := False;
  try CurUninstallStepChanged(usUninstall); except Rejected := True; end;
  Check(Rejected and not MockRegistrationsRemoved and MockStateFile, 'Late state abort propagates before file deletion');
  ResetMocks; MockUninstallFailure := True; Rejected := False;
  try CurUninstallStepChanged(usUninstall); except Rejected := True; end;
  Check(Rejected and not MockRegistrationsRemoved, 'Destructive failure is not swallowed');

  for I := 1 to 9 do begin
    ResetMocks; MockPostFailure := I; VerifyPostInstall('http://test:5000');
    Check(InstallAttempted and InstallFailed and not InstallVerified and (GetCustomSetupExitCode <> 0), 'Every required post-install failure returns nonzero');
    MockPostFailure := 0; VerifyPostInstall('http://test:5000');
    Check(InstallFailed and not InstallVerified and (GetCustomSetupExitCode <> 0), 'Failure cannot later turn into success');
  end;
  ResetMocks; MockStateFile := True; MockPostFailure := 2; VerifyPostInstall('http://test:5000');
  Check(MockStateFile, 'Failure reporting never clears enforcement state');
  ResetMocks; VerifyPostInstall('http://test:5000');
  Check(InstallAttempted and InstallVerified and not InstallFailed and (GetCustomSetupExitCode = 0), 'Only verified completion returns success');
  Check((Pos('NOT VERIFIED', UnverifiedNotice) > 0) and (Pos('THAWED', UnverifiedNotice) > 0), 'Unmistakable failure notice');
end;

procedure RejectPreflight;
var Rejected: Boolean;
begin
  Rejected := False;
  try DeploymentPreflight; except Rejected := True; end;
  Check(Rejected, 'Unsafe/query-failed preflight must reject');
end;

procedure RunTests;
var Original, Expected, Deep: String; I, N: Integer; Rejected: Boolean;
begin
  Check(ValidAddress('server.example.edu') and ValidAddress('192.0.2.20'), 'Hostname and IPv4');
  Check(not ValidAddress('') and not ValidAddress('http://host') and not ValidAddress('user@host'), 'Address syntax');
  Check(not ValidAddress('host/path') and not ValidAddress('host&command') and not ValidAddress('-host'), 'Address injection');
  Check(not ValidAddress('host-') and not ValidAddress('host..edu') and not ValidAddress('256.1.1.1'), 'Address labels');
  Check(not ValidAddress('1.2.3') and not ValidAddress('01.2.3.4') and not ValidAddress('::1') and not ValidAddress('host_name'), 'IPv4/hostname restrictions');
  Check(ValidPort('5000') and ValidPort('65535') and ValidPort('00001'), 'Valid ports');
  Check(not ValidPort('') and not ValidPort('0') and not ValidPort('65536') and not ValidPort('-1'), 'Port bounds');
  Check(not ValidPort('5.0') and not ValidPort('5000;command') and not ValidPort(' 5000') and not ValidPort('123456'), 'Port syntax');
  Original := '{"PublicAccess":{"ServerAddress":"http://old:5000","Location":"Existing","HeartbeatSeconds":19},"Unknown":[null,true,1.234567890123456789e30,{"x":"a\\b"}]}';
  Expected := '{"PublicAccess":{"ServerAddress":"http://new:5001","Location":"Existing","HeartbeatSeconds":19},"Unknown":[null,true,1.234567890123456789e30,{"x":"a\\b"}]}';
  Check(UpdateEndpoint(Original, 'http://new:5001') = Expected, 'Only endpoint token changes; unknown fields/precision preserved');
  Check(ConfigEndpoint(Original) = 'http://old:5000', 'Read existing endpoint');
  Check(ConfigEndpoint(Chr($FEFF) + Original) = 'http://old:5000', 'UTF8 BOM accepted');
  ParseJson('{"escaped":"\"\\\/\b\f\n\r\t\u0041\uD83D\uDE00"}');
  N := JsonChild(0, 'escaped', 'string'); Check(Length(JsonNodes[N].Value) = 11, 'JSON string escapes and surrogate pair');
  RejectJson(''); RejectJson('{} garbage'); RejectJson('{"a":1,"a":2}');
  RejectJson('{"a":1,"\u0061":2}'); RejectJson('{"a":01}'); RejectJson('{"a":1.}');
  RejectJson('{"a":1e}'); RejectJson('{"a":+1}'); RejectJson('{"a":NaN}');
  RejectJson('{"a":true,}'); RejectJson('{"a":[1,]}'); RejectJson('{"a":"unterminated}');
  RejectJson('{"a":"\x41"}'); RejectJson('{"a":"\uD800"}'); RejectJson('{"a":"\uDC00"}');
  RejectJson('{"a":"' + #10 + '"}'); RejectJson('[]');
  Deep := '{"a":'; for I := 1 to 66 do Deep := Deep + '[';
  Deep := Deep + '0'; for I := 1 to 66 do Deep := Deep + ']';
  RejectJson(Deep + '}');
  Rejected := False;
  try Original := UpdateEndpoint('{"Logging":{}}', 'http://new:5000'); except Rejected := True; end;
  Check(Rejected, 'Missing endpoint never overwritten');
  Rejected := False;
  try Original := UpdateEndpoint('{"PublicAccess":{"ServerAddress":"one","serverAddress":"two"}}', 'http://new:5000');
  except Rejected := True; end;
  Check(Rejected, 'Case aliases cannot redirect the configuration update');
  RejectJson('{"a":"' + Chr($D800) + '"}');
  Check(StatusAvailable('{"status":"Available","testMode":false}', True), 'Production API available');
  Check(not StatusAvailable('{"status":"In Use","testMode":false}', True), 'Active session rejected');
  Check(not StatusAvailable('{"status":"Available","testMode":true}', True), 'Test mode rejected');
  Rejected := False;
  try Rejected := StatusAvailable('{"status":"Available","testMode":"false"}', True); Rejected := False;
  except Rejected := True; end;
  Check(Rejected, 'String false is not production Boolean false');
  Rejected := False;
  try Rejected := StatusAvailable('{"status":"Available"}', True); Rejected := False;
  except Rejected := True; end;
  Check(Rejected, 'Missing production flag fails closed');
  Check(OwnedServiceMatches('"C:\AVC\Service\AVCPublicAccess.Service.exe"', 'C:\AVC'), 'Owned Service');
  Check(not OwnedServiceMatches('"C:\Other\Service.exe"', 'C:\AVC'), 'Foreign Service');
  Check(not OwnedServiceMatches('"C:\AVC\Service\AVCPublicAccess.Service.exe" --other', 'C:\AVC'), 'Unexpected Service arguments');
  Check(LegacyService('Legacy', 'AVC Public Access Service', 'other'), 'Legacy display name');
  Check(LegacyService('Legacy', 'other', 'C:\AVCPublicAccess.Service.exe'), 'Legacy executable');
  Check(OwnedTaskMatches(1, 'C:\AVC\AVCPublicAccess.Watchdog.exe', '', 'C:\AVC', 'C:\AVC'), 'Owned Watchdog');
  Check(not OwnedTaskMatches(2, 'C:\AVC\AVCPublicAccess.Watchdog.exe', '', 'C:\AVC', 'C:\AVC'), 'Extra task action');
  Check(not OwnedTaskMatches(1, 'C:\Other.exe', '', 'C:\AVC', 'C:\AVC'), 'Foreign Watchdog');
  Check(not OwnedTaskMatches(1, 'C:\AVC\AVCPublicAccess.Watchdog.exe', '--other', 'C:\AVC', 'C:\AVC'), 'Task arguments');
  Check(not OwnedTaskMatches(1, 'C:\AVC\AVCPublicAccess.Watchdog.exe', '', 'C:\Other', 'C:\AVC'), 'Task working directory');
  ResetMocks; DeploymentPreflight; Check(True, 'Available preflight');
  MockStateFile := True; RejectPreflight; Check(MockStateFile, 'State retained');
  ResetMocks; MockTemporaryState := True; RejectPreflight; Check(MockTemporaryState, 'Temporary state retained');
  ResetMocks; MockActive := True; RejectPreflight;
  ResetMocks; MockApiError := True; RejectPreflight;
  ResetMocks; MockQueryError := True; RejectPreflight;
  ResetMocks; MockReparse := True; RejectPreflight;
  ResetMocks; MockState := 3; RejectPreflight;
  ResetMocks; StopDeployment; Check((MockState = 1) and not MockResumed, 'Idle shutdown');
  ResetMocks; MockStopWritesState := True; Rejected := False;
  try StopDeployment; except Rejected := True; end;
  Check(Rejected and MockStateFile and MockResumed and (MockState = 4), 'In-flight state preserved and enforcement resumed');
end;

function InitializeSetup: Boolean;
var Report: String;
begin
  Report := ExpandConstant('{param:REPORT|}');
  try
    RunTests;
    LifecycleTests;
    if not SaveStringToFile(Report, 'PASS: ' + IntToStr(Checks) + ' compiled installer checks', False) then ExitProcess(2);
    ExitProcess(0);
  except
    SaveStringToFile(Report, 'FAIL: ' + GetExceptionMessage, False); ExitProcess(1);
  end;
  Result := False;
end;
