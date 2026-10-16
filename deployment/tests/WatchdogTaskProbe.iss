// Disposable Windows integration test. No DeploymentTest define: the ACTUAL
// installer Task Scheduler creation/readback and ownership path is executed.
// This executable is build-host-only and never staged into the installer.
#define WatchdogIntegrationProbe
#ifndef TestOutputRoot
  #error TestOutputRoot required
#endif
[Setup]
AppName=AVC disposable Task Scheduler probe
AppVersion=1.0.0
DefaultDirName={tmp}\AVC-task-probe
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=admin
OutputDir={#TestOutputRoot}
OutputBaseFilename=WatchdogTaskProbe
SetupArchitecture=x64
MinVersion=10.0.17763
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
[Code]
#include "../installer/Json.iss"
#include "../installer/NativeDeployment.iss"
procedure ExitProcess(Code: LongWord);
  external 'ExitProcess@kernel32.dll stdcall';
function ProbeCreateGuid(var Id: TGUID): HResult;
  external 'CoCreateGuid@ole32.dll stdcall';
function ProbeGuidString(const Id: TGUID; Buffer: String; Characters: Integer): Integer;
  external 'StringFromGUID2@ole32.dll stdcall';

// Only names are enumerated. No other task definition is read or modified.
function DisposableTaskExists(const Folder: Variant): Boolean;
var Tasks, Task: Variant; I: Integer;
begin
  Result := False;
  Tasks := ComCall(Folder, 'Probe.Folder.GetTasks', [1]);
  for I := 1 to ComGet(Tasks, 'Probe.Tasks.Count') do begin
    Task := ComCall(Tasks, 'Probe.Tasks.Item', [I]);
    if CompareText(String(ComGet(Task, 'Probe.Task.Name')), WatchdogTaskName) = 0 then Result := True;
  end;
end;

function InitializeSetup: Boolean;
var Id: TGUID; Text, Report, Failure, CleanupFailure: String;
  Folder, Task: Variant; CleanupArmed: Boolean; HR: HResult;
begin
  Result := False; CleanupArmed := False; Failure := ''; CleanupFailure := '';
  Report := ExpandConstant('{param:REPORT}');
  try
    BeginDeploymentPhase('Disposable Watchdog probe initialization');
    HR := ProbeCreateGuid(Id); CheckComResult(HR, 0, '', '');
    SetLength(Text, 39);
    if ProbeGuidString(Id, Text, 39) <> 39 then RaiseException('Cannot format disposable GUID.');
    SetLength(Text, 38);
    DisposableWatchdogName := 'AVC-Installer-Probe-' + Text;
    // Deliberately nonexistent payload path: the task cannot launch any AVC
    // application even if a user logs on during this short registration probe.
    DeploymentRoot := ExpandConstant('{tmp}') + '\' + DisposableWatchdogName;
    Log('Disposable task name: ' + WatchdogTaskName);
    Folder := TaskFolder;
    if DisposableTaskExists(Folder) then RaiseException('Disposable name unexpectedly exists; no modification permitted.');
    CleanupArmed := True;
    try
      RegisterWatchdog;
      if ExpandConstant('{param:FAILAFTERREGISTER|0}') = '1' then
        RaiseException('Injected failure after registration: verify disposable cleanup.');
      Task := OwnedTask;
      Require(not VarIsEmpty(Task), 'Disposable task missing after registration.');
      VerifyWatchdogDefinition(Task);
    except Failure := DiagnosticFailure(GetExceptionMessage); end;
  except Failure := DiagnosticFailure(GetExceptionMessage); end;
  // Cleanup runs independently of registration/readback/ownership failures.
  // The GUID name was confirmed absent before any registration attempt.
  if CleanupArmed then begin
    try
      BeginDeploymentPhase('Disposable Watchdog probe cleanup');
      Folder := TaskFolder;
      if DisposableTaskExists(Folder) then
        ComCall(Folder, 'Probe.Folder.DeleteTask', [WatchdogTaskName, 0]);
      Require(not DisposableTaskExists(Folder), 'Disposable task remains after cleanup.');
    except CleanupFailure := DiagnosticFailure(GetExceptionMessage); end;
  end;
  if CleanupFailure = '' then begin
    if CleanupArmed then CleanupFailure := 'PASS: disposable task absent'
    else CleanupFailure := 'NOT REQUIRED: no registration attempted';
  end;
  if (Failure = '') and (CleanupFailure = 'PASS: disposable task absent') then begin
    SaveStringToFile(Report, 'PASS: actual Windows Task Scheduler Watchdog creation, complete ownership readback and cleanup; task=' + DisposableWatchdogName, False);
    ExitProcess(0);
  end else begin
    SaveStringToFile(Report, 'FAIL: ' + Failure + #13#10 + 'Cleanup: ' + CleanupFailure + #13#10 + 'Task: ' + DisposableWatchdogName, False);
    ExitProcess(1);
  end;
end;
