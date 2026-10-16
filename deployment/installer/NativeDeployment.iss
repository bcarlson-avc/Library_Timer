#include "ComDiagnostics.iss"

// Privileged deployment is compiled into Setup and its generated uninstaller.
// No command shell, PowerShell host, script evaluation, or external helper.
const
  AVCService = 'AVCPublicAccessService';
  AVCTask = 'AVC Public Access Watchdog';
type
  TServiceState = record
    ServiceType, State, Accepted, Win32Exit, SpecificExit, CheckPoint, WaitHint: LongWord;
  end;
  TSidBuffer = record
    Data: array[0..67] of Byte;
  end;
  TWatchdogDefinition = record
    PrincipalId, ActionContext, UserId, GroupSid: String;
    LogonType, RunLevel, TriggerCount, MultipleInstances, RestartCount: Integer;
    LogonTrigger, TriggerEnabled, TaskEnabled, DisallowBattery, StopOnBattery,
      StartWhenAvailable, RunOnlyIdle, RunOnlyNetwork, Hidden, AllowDemand,
      AllowTerminate: Boolean;
    TriggerUser, StartBoundary, EndBoundary, Delay, RepetitionInterval,
      RepetitionDuration, TriggerLimit, ExecutionLimit, RestartInterval: String;
    RepetitionStop: Boolean;
  end;
var
  DeploymentRoot: String;
  WatchdogDisabledByInstaller: Boolean;
#ifdef DeploymentTest
  MockState: LongWord;
  MockStateFile, MockTemporaryState, MockQueryError, MockReparse,
    MockActive, MockApiError, MockStopWritesState, MockResumed: Boolean;
  MockPostFailure, MockUninstallCalls: Integer;
  MockUninstallConfirmed, MockUninstallFailure, MockRegistrationsRemoved: Boolean;
#endif

function OpenSCManager(Machine, Database: NativeUInt; Access: LongWord): THandle;
  external 'OpenSCManagerW@advapi32.dll stdcall';
function OpenService(Manager: THandle; Name: String; Access: LongWord): THandle;
  external 'OpenServiceW@advapi32.dll stdcall';
function CloseServiceHandle(Handle: THandle): Boolean;
  external 'CloseServiceHandle@advapi32.dll stdcall';
function QueryServiceStatus(Handle: THandle; var Status: TServiceState): Boolean;
  external 'QueryServiceStatus@advapi32.dll stdcall';
function ControlService(Handle: THandle; Control: LongWord; var Status: TServiceState): Boolean;
  external 'ControlService@advapi32.dll stdcall';
function StartService(Handle: THandle; Count: LongWord; Args: NativeUInt): Boolean;
  external 'StartServiceW@advapi32.dll stdcall';
function CreateService(Manager: THandle; Name, Display: String; Access, ServiceType,
  StartType, ErrorControl: LongWord; Binary: String; Group, Tag, Dependencies: NativeUInt;
  Account: String; Password: NativeUInt): THandle;
  external 'CreateServiceW@advapi32.dll stdcall';
function ChangeServiceConfig(Handle: THandle; ServiceType, StartType, ErrorControl: LongWord;
  Binary: String; Group, Tag, Dependencies: NativeUInt; Account: String;
  Password: NativeUInt; Display: String): Boolean;
  external 'ChangeServiceConfigW@advapi32.dll stdcall';
function DeleteService(Handle: THandle): Boolean;
  external 'DeleteService@advapi32.dll stdcall';
function Attributes(Path: String): LongWord;
  external 'GetFileAttributesW@kernel32.dll stdcall';
function ReplaceConfiguration(Replaced, Replacement: String; Backup: NativeUInt;
  Flags: LongWord; Exclude, Reserved: NativeUInt): Boolean;
  external 'ReplaceFileW@kernel32.dll stdcall';
function OpenProcess(Access: LongWord; Inherit: Boolean; PID: LongWord): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function ProcessImage(Handle: THandle; Flags: LongWord; Image: String; var Size: LongWord): Boolean;
  external 'QueryFullProcessImageNameW@kernel32.dll stdcall';
function TerminateProcess(Handle: THandle; ExitCode: LongWord): Boolean;
  external 'TerminateProcess@kernel32.dll stdcall';
function WaitForSingleObject(Handle: THandle; Milliseconds: LongWord): LongWord;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function ConvertSDDL(Text: String; Revision: LongWord; var Descriptor: NativeUInt;
  Size: NativeUInt): Boolean;
  external 'ConvertStringSecurityDescriptorToSecurityDescriptorW@advapi32.dll stdcall';
function SetFileSecurity(Path: String; Information: LongWord; Descriptor: NativeUInt): Boolean;
  external 'SetFileSecurityW@advapi32.dll stdcall';
function LocalFree(Memory: NativeUInt): NativeUInt;
  external 'LocalFree@kernel32.dll stdcall';
function TickCount: Int64;
  external 'GetTickCount64@kernel32.dll stdcall';
function LookupAccountName(SystemName: NativeUInt; Account: String; var Sid: TSidBuffer;
  var SidSize: LongWord; Domain: String; var DomainSize, SidUse: LongWord): Boolean;
  external 'LookupAccountNameW@advapi32.dll stdcall';
function CreateWellKnownSid(Kind: Integer; Domain: NativeUInt; var Sid: TSidBuffer;
  var Size: LongWord): Boolean;
  external 'CreateWellKnownSid@advapi32.dll stdcall';
function EqualSid(var Left, Right: TSidBuffer): Boolean;
  external 'EqualSid@advapi32.dll stdcall';

procedure Require(OK: Boolean; const MessageText: String);
begin if not OK then RaiseException(MessageText); end;

function PathPresent(const Path: String): Boolean;
var A, E: LongWord;
begin
#ifdef DeploymentTest
  Require(not MockQueryError, 'Mock path query failure.');
  Require(not MockReparse, 'Mock reparse point.');
  Result := ((ExtractFileName(Path) = 'session-state.json') and MockStateFile) or
    ((ExtractFileName(Path) = 'session-state.json.tmp') and MockTemporaryState);
  Exit;
#endif
  A := Attributes(Path);
  if A = $FFFFFFFF then begin
    E := DLLGetLastError;
    Require((E = 2) or (E = 3), 'Cannot inspect protected path.');
    Result := False;
  end else begin
    Require((A and $400) = 0, 'Protected paths must not contain links or junctions.');
    Result := True;
  end;
end;

procedure CheckPath(const Path: String);
var Parent: String; Present: Boolean;
begin
  Parent := RemoveBackslashUnlessRoot(ExtractFileDir(Path));
  if (Parent <> '') and (CompareText(Parent, Path) <> 0) then CheckPath(Parent);
  Present := PathPresent(Path);
end;

function RuntimeRoot: String;
begin Result := ExpandConstant('{commonappdata}\AVC\PublicAccess'); end;

function Wmi: Variant;
var Locator: Variant;
begin
  Locator := DiagnosticCreate('WbemScripting.SWbemLocator');
  Result := ComCall(Locator, 'Deployment.Wmi.ConnectServer', ['', 'root\cimv2']);
end;

function ServiceHandle(Access: LongWord): THandle;
var Manager: THandle; E: LongWord;
begin
  Manager := OpenSCManager(0, 0, 1);
  Require(Manager <> 0, 'Cannot open Service Control Manager.');
  try
    Result := OpenService(Manager, AVCService, Access);
    if Result = 0 then begin
      E := DLLGetLastError;
      Require(E = 1060, 'Cannot inspect AVC Service.');
    end;
  finally CloseServiceHandle(Manager); end;
end;

function ServiceState: LongWord;
var H: THandle; S: TServiceState;
begin
#ifdef DeploymentTest
  Require(not MockQueryError, 'Mock SCM query failure.');
  Result := MockState; Exit;
#endif
  Result := 0; H := ServiceHandle(4);
  if H = 0 then Exit;
  try
    Require(QueryServiceStatus(H, S), 'Cannot query AVC Service state.');
    Result := S.State;
  finally CloseServiceHandle(H); end;
end;

procedure WaitService(Expected: LongWord);
var I: Integer;
begin
  for I := 1 to 120 do begin
    if ServiceState = Expected then Exit;
    Sleep(250);
  end;
  RaiseException('AVC Service did not reach the required state within 30 seconds.');
end;

procedure StartOwnedService;
var H: THandle;
begin
#ifdef DeploymentTest
  MockResumed := True; MockState := 4; Exit;
#endif
  H := ServiceHandle($10);
  Require(H <> 0, 'AVC Service is missing.');
  try Require(StartService(H, 0, 0), 'Cannot start AVC Service.');
  finally CloseServiceHandle(H); end;
  WaitService(4);
end;

function OwnedServiceMatches(const Binary, Root: String): Boolean;
begin
  Result := CompareText(Binary, '"' + Root + '\Service\AVCPublicAccess.Service.exe"') = 0;
end;

function LegacyService(const Name, Display, Binary: String): Boolean;
begin
  Result := (CompareText(Name, AVCService) <> 0) and
    ((CompareText(Display, 'AVC Public Access Service') = 0) or
    (Pos('avcpublicaccess.service.exe', Lowercase(Binary)) > 0));
end;

procedure AssertOwnedService;
var Connection, Services, S: Variant; I: Integer; Expected: String;
begin
#ifdef DeploymentTest
  Require(not MockQueryError, 'Mock ownership query failure.'); Exit;
#endif
  Expected := '"' + DeploymentRoot + '\Service\AVCPublicAccess.Service.exe"';
  Connection := Wmi;
  Services := ComCall(Connection, 'Deployment.Wmi.Services.ExecQuery', ['SELECT Name,DisplayName,PathName FROM Win32_Service']);
  for I := 0 to ComGet(Services, 'Deployment.Wmi.Services.Count') - 1 do begin
    S := ComCall(Services, 'Deployment.Wmi.Services.ItemIndex', [I]);
    if CompareText(String(ComGet(S, 'Deployment.Wmi.Service.Name')), AVCService) = 0 then
      Require(OwnedServiceMatches(String(ComGet(S, 'Deployment.Wmi.Service.PathName')), DeploymentRoot), 'Service belongs to another installation.')
    else
      Require(not LegacyService(String(ComGet(S, 'Deployment.Wmi.Service.Name')), String(ComGet(S, 'Deployment.Wmi.Service.DisplayName')), String(ComGet(S, 'Deployment.Wmi.Service.PathName'))),
        'Legacy AVC Service exists; review migration before servicing.');
  end;
  // Also query SCM: WMI/query failures must never be interpreted as absence.
  I := ServiceState;
end;

#ifdef WatchdogIntegrationProbe
var DisposableWatchdogName: String;
#endif
function WatchdogTaskName: String;
begin
#ifdef WatchdogIntegrationProbe
  Require((Pos('AVC-Installer-Probe-', DisposableWatchdogName) = 1) and
    (Length(DisposableWatchdogName) > 30) and (CompareText(DisposableWatchdogName, AVCTask) <> 0),
    'Disposable probe task name is invalid; production task access forbidden.');
  Result := DisposableWatchdogName;
#else
  Result := AVCTask;
#endif
end;

procedure WatchdogComparison(const Name: String; Matches: Boolean);
begin
  BeginComOperation('Watchdog ownership comparison: ' + Name);
  if Matches then Log('MATCH ' + Name) else Log('MISMATCH ' + Name);
end;

function TaskFolder: Variant;
var Scheduler: Variant;
begin
  Scheduler := DiagnosticCreate('Schedule.Service');
  ComCall(Scheduler, 'Watchdog.Scheduler.Connect', []);
  Result := ComCall(Scheduler, 'Watchdog.Scheduler.GetFolder', ['\']);
end;

function OwnedTaskMatches(Count: Integer; const Path, Arguments, Directory, Root: String): Boolean;
begin
  Result := (Count = 1) and
    (CompareText(Path, Root + '\AVCPublicAccess.Watchdog.exe') = 0) and
    (Arguments = '') and (CompareText(Directory, Root) = 0);
end;

function IsPatronGroup(const Group: String): Boolean;
var Actual, Expected: TSidBuffer; Size, ExpectedSize, DomainSize, Use: LongWord;
  Domain: String;
begin
  BeginComOperation('Watchdog principal SID verification');
  if Group = 'S-1-5-32-545' then begin Log('MATCH Builtin Users SID'); Result := True; Exit; end;
  // Task Scheduler may return a localized account name rather than a SID.
  // Resolve it through Windows and compare binary SIDs, never English names.
  Size := SizeOf(Actual); ExpectedSize := SizeOf(Expected);
  DomainSize := 256; SetLength(Domain, DomainSize);
  Require(LookupAccountName(0, Group, Actual, Size, Domain, DomainSize, Use), 'Cannot establish Watchdog principal SID.');
  Require(CreateWellKnownSid(27, 0, Expected, ExpectedSize), 'Cannot establish Builtin Users SID.');
  Result := EqualSid(Actual, Expected);
  WatchdogComparison('resolved Builtin Users SID', Result);
end;

function WatchdogCondition(const Name: String; Matches: Boolean): Boolean;
begin
  WatchdogComparison(Name, Matches); Result := Matches;
end;

function WatchdogDefinitionMatches(const D: TWatchdogDefinition; AllowDisabled: Boolean): Boolean;
begin
  Result := WatchdogCondition('PrincipalId', (D.PrincipalId = 'Patron')) and
    WatchdogCondition('ActionContext', (D.ActionContext = 'Patron')) and
    WatchdogCondition('UserId', (D.UserId = '')) and
    WatchdogCondition('GroupSid', (D.GroupSid = 'S-1-5-32-545')) and
    WatchdogCondition('LogonType', (D.LogonType = 4)) and
    WatchdogCondition('RunLevel', (D.RunLevel = 0)) and
    WatchdogCondition('TriggerCount', (D.TriggerCount = 1)) and
    WatchdogCondition('LogonTrigger', D.LogonTrigger) and
    WatchdogCondition('TriggerEnabled', D.TriggerEnabled) and
    WatchdogCondition('TriggerUser', (D.TriggerUser = '')) and
    WatchdogCondition('StartBoundary', (D.StartBoundary = '')) and
    WatchdogCondition('EndBoundary', (D.EndBoundary = '')) and
    WatchdogCondition('Delay', ((D.Delay = '') or (D.Delay = 'PT0S'))) and
    WatchdogCondition('RepetitionInterval', (D.RepetitionInterval = '')) and
    WatchdogCondition('RepetitionDuration', (D.RepetitionDuration = '')) and
    WatchdogCondition('RepetitionStop', not D.RepetitionStop) and
    WatchdogCondition('TriggerLimit', ((D.TriggerLimit = '') or (D.TriggerLimit = 'PT0S'))) and
    WatchdogCondition('TaskEnabled', (D.TaskEnabled or AllowDisabled)) and
    WatchdogCondition('MultipleInstances', (D.MultipleInstances = 2)) and
    WatchdogCondition('DisallowBattery', not D.DisallowBattery) and
    WatchdogCondition('StopOnBattery', not D.StopOnBattery) and
    WatchdogCondition('StartWhenAvailable', D.StartWhenAvailable) and
    WatchdogCondition('ExecutionLimit', (D.ExecutionLimit = 'PT0S')) and
    WatchdogCondition('RestartInterval', (D.RestartInterval = 'PT1M')) and
    WatchdogCondition('RestartCount', (D.RestartCount = 3)) and
    WatchdogCondition('RunOnlyIdle', not D.RunOnlyIdle) and
    WatchdogCondition('RunOnlyNetwork', not D.RunOnlyNetwork) and
    WatchdogCondition('Hidden', not D.Hidden) and
    WatchdogCondition('AllowDemand', D.AllowDemand) and
    WatchdogCondition('AllowTerminate', D.AllowTerminate);
end;

procedure VerifyWatchdogDefinition(const Task: Variant);
var Definition, Principal, Triggers, Trigger, Settings, Xml: Variant;
  D: TWatchdogDefinition;
begin
  Definition := ComGet(Task, 'Watchdog.Task.Definition'); Principal := ComGet(Definition, 'Watchdog.Definition.Principal');
  Triggers := ComGet(Definition, 'Watchdog.Definition.Triggers'); Settings := ComGet(Definition, 'Watchdog.Definition.Settings');
  WatchdogComparison('exactly one trigger', ComGet(Triggers, 'Watchdog.Triggers.Count') = 1);
  Require(ComGet(Triggers, 'Watchdog.Triggers.Count') = 1, 'Watchdog must have exactly one trigger.');
  // Type is a Pascal reserved word. Verify the trigger/action types through
  // the registered XML before accessing type-specific COM properties.
  Xml := DiagnosticCreate('Msxml2.DOMDocument.6.0');
  ComSet(Xml, 'Watchdog.Xml.async', False); ComSet(Xml, 'Watchdog.Xml.resolveExternals', False); ComSet(Xml, 'Watchdog.Xml.validateOnParse', False);
  ComCall(Xml, 'Watchdog.Xml.ProhibitDTD.setProperty', ['ProhibitDTD', True]);
  ComCall(Xml, 'Watchdog.Xml.SelectionNamespaces.setProperty', ['SelectionNamespaces', 'xmlns:t="http://schemas.microsoft.com/windows/2004/02/mit/task"']);
  Require(ComCall(Xml, 'Watchdog.Xml.loadXML', [String(ComGet(Task, 'Watchdog.Task.Xml'))]), 'Cannot parse registered Watchdog definition.');
  Require((ComGet(ComCall(Xml, 'Watchdog.Xml.LogonTrigger.selectNodes', ['/t:Task/t:Triggers/t:LogonTrigger']), 'Watchdog.Xml.Nodes.length') = 1) and
    (ComGet(ComCall(Xml, 'Watchdog.Xml.ExecAction.selectNodes', ['/t:Task/t:Actions/t:Exec']), 'Watchdog.Xml.Nodes.length') = 1), 'Unexpected Watchdog trigger/action type.');
  Trigger := ComCall(Triggers, 'Watchdog.Triggers.Item', [1]);
  D.PrincipalId := ComGet(Principal, 'Watchdog.Principal.Id'); D.ActionContext := ComGet(ComGet(Definition, 'Watchdog.Definition.Actions'), 'Watchdog.Actions.Context');
  D.UserId := ComGet(Principal, 'Watchdog.Principal.UserId'); D.GroupSid := '';
  if IsPatronGroup(String(ComGet(Principal, 'Watchdog.Principal.GroupId'))) then D.GroupSid := 'S-1-5-32-545';
  D.LogonType := ComGet(Principal, 'Watchdog.Principal.LogonType'); D.RunLevel := ComGet(Principal, 'Watchdog.Principal.RunLevel');
  D.TriggerCount := ComGet(Triggers, 'Watchdog.Triggers.Count'); D.LogonTrigger := True;
  D.TriggerEnabled := ComGet(Trigger, 'Watchdog.Trigger.Enabled'); D.TriggerUser := ComGet(Trigger, 'Watchdog.Trigger.UserId');
  D.StartBoundary := ComGet(Trigger, 'Watchdog.Trigger.StartBoundary'); D.EndBoundary := ComGet(Trigger, 'Watchdog.Trigger.EndBoundary');
  D.Delay := ComGet(Trigger, 'Watchdog.Trigger.Delay'); D.TriggerLimit := '';
  if ComGet(ComCall(Xml, 'Watchdog.Xml.selectNodes', ['/t:Task/t:Triggers/t:LogonTrigger/t:ExecutionTimeLimit']), 'Watchdog.Xml.Nodes.length') <> 0 then
    D.TriggerLimit := ComGet(ComCall(Xml, 'Watchdog.Xml.selectSingleNode', ['/t:Task/t:Triggers/t:LogonTrigger/t:ExecutionTimeLimit']), 'Watchdog.Xml.Node.text');
  D.RepetitionInterval := ComGet(ComGet(Trigger, 'Watchdog.Trigger.Repetition'), 'Watchdog.Repetition.Interval');
  D.RepetitionDuration := ComGet(ComGet(Trigger, 'Watchdog.Trigger.Repetition'), 'Watchdog.Repetition.Duration');
  D.RepetitionStop := ComGet(ComGet(Trigger, 'Watchdog.Trigger.Repetition'), 'Watchdog.Repetition.StopAtDurationEnd');
  D.TaskEnabled := ComGet(Task, 'Watchdog.Task.Enabled') and ComGet(Settings, 'Watchdog.Settings.Enabled');
  D.MultipleInstances := ComGet(Settings, 'Watchdog.Settings.MultipleInstances');
  D.DisallowBattery := ComGet(Settings, 'Watchdog.Settings.DisallowStartIfOnBatteries');
  D.StopOnBattery := ComGet(Settings, 'Watchdog.Settings.StopIfGoingOnBatteries');
  D.StartWhenAvailable := ComGet(Settings, 'Watchdog.Settings.StartWhenAvailable');
  D.ExecutionLimit := ComGet(Settings, 'Watchdog.Settings.ExecutionTimeLimit');
  D.RestartInterval := ComGet(Settings, 'Watchdog.Settings.RestartInterval'); D.RestartCount := ComGet(Settings, 'Watchdog.Settings.RestartCount');
  D.RunOnlyIdle := ComGet(Settings, 'Watchdog.Settings.RunOnlyIfIdle'); D.RunOnlyNetwork := ComGet(Settings, 'Watchdog.Settings.RunOnlyIfNetworkAvailable');
  D.Hidden := ComGet(Settings, 'Watchdog.Settings.Hidden'); D.AllowDemand := ComGet(Settings, 'Watchdog.Settings.AllowDemandStart');
  D.AllowTerminate := ComGet(Settings, 'Watchdog.Settings.AllowHardTerminate');
  Require(WatchdogDefinitionMatches(D, WatchdogDisabledByInstaller), 'Watchdog principal, trigger, or settings do not match this installation.');
end;

function OwnedTask: Variant;
var Folder, Tasks, Task, Actions, Action: Variant; I, Count: Integer;
  NameMatches: Boolean; ActionPath, Arguments, Directory: String;
begin
  Result := Unassigned;
#ifdef DeploymentTest
  Require(not MockQueryError, 'Mock task query failure.'); Exit;
#endif
  Folder := TaskFolder; Tasks := ComCall(Folder, 'Watchdog.Folder.GetTasks', [1]); // include hidden tasks
  for I := 1 to ComGet(Tasks, 'Watchdog.Tasks.Count') do begin
    Task := ComCall(Tasks, 'Watchdog.Tasks.Item', [I]);
    NameMatches := CompareText(String(ComGet(Task, 'Watchdog.Task.Name')), WatchdogTaskName) = 0;
    WatchdogComparison('task enumeration candidate name', NameMatches);
    if NameMatches then begin
      WatchdogComparison('exact task name', True);
      Actions := ComGet(ComGet(Task, 'Watchdog.Task.Definition'), 'Watchdog.Definition.Actions');
      Count := ComGet(Actions, 'Watchdog.Actions.Count');
      WatchdogComparison('single action', Count = 1);
      Require(Count = 1, 'Watchdog task has unexpected actions.');
      Action := ComCall(Actions, 'Watchdog.Actions.Item', [1]);
      // Non-exec actions have no Path/Arguments: COM access fails closed.
      Count := ComGet(Actions, 'Watchdog.Actions.Count');
      ActionPath := ComGet(Action, 'Watchdog.Action.Path');
      Arguments := ComGet(Action, 'Watchdog.Action.Arguments');
      Directory := ComGet(Action, 'Watchdog.Action.WorkingDirectory');
      WatchdogComparison('executable path', CompareText(ActionPath, DeploymentRoot + '\AVCPublicAccess.Watchdog.exe') = 0);
      WatchdogComparison('empty arguments', Arguments = '');
      WatchdogComparison('working directory', CompareText(Directory, DeploymentRoot) = 0);
      Require(OwnedTaskMatches(Count, ActionPath, Arguments, Directory, DeploymentRoot),
        'Watchdog task belongs to another installation.');
      VerifyWatchdogDefinition(Task);
      Result := Task;
    end;
  end;
end;

function StatusAvailable(const Text: String; Production: Boolean): Boolean;
var N: Integer;
begin
  ParseJson(Text);
  // Worker uses JsonSerializerDefaults.Web: property names are camelCase.
  N := JsonChild(0, 'status', 'string');
  Result := JsonNodes[N].Value = 'Available';
  if Production then begin
    N := JsonChild(0, 'testMode', 'boolean');
    Result := Result and (JsonNodes[N].Value = 'false');
  end;
end;

function LocalStatus(Production: Boolean): Boolean;
var Request: Variant;
begin
#ifdef DeploymentTest
  Require(not MockApiError, 'Mock API failure.'); Result := not MockActive; Exit;
#endif
  Request := DiagnosticCreate('WinHttp.WinHttpRequest.5.1');
  ComCall(Request, 'Deployment.LocalApi.SetProxy', [1]); // fixed loopback API must never use a proxy
  ComCall(Request, 'Deployment.LocalApi.SetTimeouts', [2000, 2000, 2000, 2000]);
  ComCall(Request, 'Deployment.LocalApi.SetAutoLogonPolicy', [2]);
  ComSetIndexed(Request, 'Deployment.LocalApi.Option', 6, False);
  ComCall(Request, 'Deployment.LocalApi.Open', ['GET', 'http://127.0.0.1:5051/status', False]);
  ComCall(Request, 'Deployment.LocalApi.Send', []);
  Require(ComGet(Request, 'Deployment.LocalApi.Status') = 200, 'AVC local API did not return success.');
  Result := StatusAvailable(String(ComGet(Request, 'Deployment.LocalApi.ResponseText')), Production);
end;

procedure AssertNoPatronState;
var State: LongWord;
begin
  CheckPath(DeploymentRoot); CheckPath(RuntimeRoot + '\watchdog.log');
  Require(not PathPresent(RuntimeRoot + '\session-state.json'), 'Patron enforcement state exists; do not delete it.');
  Require(not PathPresent(RuntimeRoot + '\session-state.json.tmp'), 'Pending patron enforcement state exists; do not delete it.');
  State := ServiceState;
  if State = 4 then Require(LocalStatus(False), 'AVC Service must be Available before servicing.')
  else Require((State = 0) or (State = 1), 'AVC Service is transitioning; retry after reviewing its state.');
end;

procedure DeploymentPreflight;
var Task: Variant;
begin
#ifdef DeploymentTest
  DeploymentRoot := 'C:\AVC';
#else
  DeploymentRoot := RemoveBackslashUnlessRoot(ExpandFileName(ExpandConstant('{app}')));
#endif
  CheckPath(DeploymentRoot + '\Service\AVCPublicAccess.Service.exe');
  CheckPath(DeploymentRoot + '\Client\AVCPublicAccess.Client.exe');
  CheckPath(DeploymentRoot + '\AVCPublicAccess.Watchdog.exe');
  CheckPath(DeploymentRoot + '\Service\appsettings.json');
  CheckPath(DeploymentRoot + '\Deployment\payload-manifest.json');
  AssertOwnedService; Task := OwnedTask; AssertNoPatronState;
end;

procedure StopOwnedProcesses;
var Connection, Processes, P: Variant; I: Integer; H: THandle;
  Image, Expected: String; Size: LongWord;
begin
#ifdef DeploymentTest
  Exit;
#endif
  Connection := Wmi;
  Processes := ComCall(Connection, 'Deployment.Wmi.Processes.ExecQuery', ['SELECT ProcessId,Name FROM Win32_Process WHERE Name="AVCPublicAccess.Watchdog.exe" OR Name="AVCPublicAccess.Client.exe"']);
  for I := 0 to ComGet(Processes, 'Deployment.Wmi.Processes.Count') - 1 do begin
    P := ComCall(Processes, 'Deployment.Wmi.Processes.ItemIndex', [I]);
    Expected := DeploymentRoot + '\AVCPublicAccess.Watchdog.exe';
    if CompareText(String(ComGet(P, 'Deployment.Wmi.Process.Name')), 'AVCPublicAccess.Client.exe') = 0 then
      Expected := DeploymentRoot + '\Client\AVCPublicAccess.Client.exe';
    H := OpenProcess($100000 or $1000 or 1, False, ComGet(P, 'Deployment.Wmi.Process.ProcessId'));
    Require(H <> 0, 'Cannot inspect an AVC process; servicing aborted.');
    try
      SetLength(Image, 32768); Size := Length(Image);
      Require(ProcessImage(H, 0, Image, Size), 'Cannot verify AVC process executable path.');
      SetLength(Image, Size);
      if CompareText(Image, Expected) = 0 then begin
        Require(TerminateProcess(H, 0), 'Cannot stop the verified AVC process.');
        Require(WaitForSingleObject(H, 30000) = 0, 'AVC process did not stop.');
      end;
    finally CloseHandle(H); end;
  end;
end;

procedure StopOwnedService;
var H: THandle; S: TServiceState;
begin
#ifdef DeploymentTest
  MockState := 1;
  if MockStopWritesState then MockStateFile := True;
  Exit;
#endif
  H := ServiceHandle($20);
  if H = 0 then Exit;
  try
    if ServiceState <> 1 then Require(ControlService(H, 1, S), 'Cannot stop AVC Service.');
  finally CloseServiceHandle(H); end;
  WaitService(1);
end;

procedure StopDeployment;
var Task: Variant; WasRunning: Boolean;
begin
  BeginDeploymentPhase('Ordered deployment shutdown');
  DeploymentPreflight;
  Task := OwnedTask;
  if not VarIsEmpty(Task) then begin
    ComSet(Task, 'Watchdog.Task.Enabled', False);
    WatchdogDisabledByInstaller := True; // permit only our own deliberate disabled phase
    ComCall(Task, 'Watchdog.Task.Stop', [0]);
  end;
  StopOwnedProcesses;
  AssertNoPatronState; // after closing UI: reject an in-flight redemption
  WasRunning := ServiceState = 4;
  try
    StopOwnedService;
    AssertNoPatronState; // after SCM stop: never replace newly persisted state
  except
    if WasRunning then begin
      // SCM stop may have timed out. Restart only after observing Stopped;
      // if inspection fails, surface that failure rather than assuming success.
      if ServiceState = 1 then StartOwnedService;
    end;
    RaiseException('Servicing stopped: enforcement state/query changed during shutdown. Do not clear state or freeze this workstation.');
  end;
end;

function ReadJsonFile(const Path: String): String;
var Bytes: AnsiString;
begin
  CheckPath(Path);
  Require(LoadStringFromFile(Path, Bytes), 'Cannot read configuration.');
  Result := UTF8Decode(Bytes);
  Require(UTF8Encode(Result) = Bytes, 'Configuration must be valid UTF-8.');
  ParseJson(Result);
end;

procedure WriteEndpoint(const Endpoint: String);
var Path, Temporary, Text: String;
begin
  Path := DeploymentRoot + '\Service\appsettings.json'; Temporary := Path + '.installer.tmp';
  Text := UpdateEndpoint(ReadJsonFile(Path), Endpoint);
  Require(not PathPresent(Temporary), 'Configuration replacement already exists; review before retrying.');
  try
    Require(SaveStringToFile(Temporary, UTF8Encode(Text), False), 'Cannot write updated configuration.');
    Require(ReplaceConfiguration(Path, Temporary, 0, 0, 0, 0), 'Cannot atomically replace configuration.');
  finally
    if FileExists(Temporary) then DeleteFile(Temporary);
  end;
end;

procedure SecurePath(const Path, SDDL: String);
var Descriptor: NativeUInt;
begin
  CheckPath(Path); Descriptor := 0;
  Require(ConvertSDDL(SDDL, 1, Descriptor, 0), 'Cannot construct runtime security descriptor.');
  try
    Require(SetFileSecurity(Path, $80000005, Descriptor), 'Cannot protect runtime directory/file.');
  finally LocalFree(Descriptor); end;
end;

procedure InitializeRuntime;
var LogPath: String;
begin
  CheckPath(RuntimeRoot); Require(ForceDirectories(RuntimeRoot), 'Cannot create runtime directory.');
  SecurePath(RuntimeRoot, 'O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;GRGX;;;BU)');
  LogPath := RuntimeRoot + '\watchdog.log';
  if not PathPresent(LogPath) then Require(SaveStringToFile(LogPath, '', False), 'Cannot create Watchdog log.');
  Require((Attributes(LogPath) and $10) = 0, 'Watchdog log must be a regular file.');
  SecurePath(LogPath, 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGW;;;BU)');
end;

procedure RegisterService;
var Manager, H: THandle; Binary, Key, Source, MessageFile: String; I: Integer;
begin
  AssertOwnedService;
  Manager := OpenSCManager(0, 0, 3); Require(Manager <> 0, 'Cannot configure SCM.');
  try
    Binary := '"' + DeploymentRoot + '\Service\AVCPublicAccess.Service.exe"';
    H := ServiceHandle(2);
    if H = 0 then begin
      H := CreateService(Manager, AVCService, 'AVC Public Access Service', 2, $10, 2, 1,
        Binary, 0, 0, 0, 'LocalSystem', 0);
      Require(H <> 0, 'Cannot create AVC Service.');
    end else Require(ChangeServiceConfig(H, $10, 2, 1, Binary, 0, 0, 0, 'LocalSystem', 0,
      'AVC Public Access Service'), 'Cannot configure AVC Service.');
    CloseServiceHandle(H);
  finally CloseServiceHandle(Manager); end;
  MessageFile := ExpandConstant('{win}\Microsoft.NET\Framework64\v4.0.30319\EventLogMessages.dll');
  Require(FileExists(MessageFile), 'Windows Event Log message resource is missing.');
  for I := 0 to 1 do begin
    Source := AVCService; if I = 1 then Source := 'AVCPublicAccess.Service';
    Key := 'SYSTEM\CurrentControlSet\Services\EventLog\Application\' + Source;
    if not RegKeyExists(HKLM, Key) then begin
      Require(RegWriteStringValue(HKLM, Key, 'EventMessageFile', MessageFile), 'Cannot register Event Log source.');
      Require(RegWriteDWordValue(HKLM, Key, 'TypesSupported', 7), 'Cannot register Event Log types.');
    end;
  end;
end;

procedure RegisterWatchdog;
var Scheduler, Folder, Definition, Principal, Trigger, Action, Task, Settings, Actions: Variant;
begin
  BeginDeploymentPhase('Watchdog ownership preflight');
  Task := OwnedTask;
  BeginDeploymentPhase('Watchdog task construction');
  Scheduler := DiagnosticCreate('Schedule.Service');
  ComCall(Scheduler, 'Watchdog.Scheduler.Connect', []);
  Folder := ComCall(Scheduler, 'Watchdog.Scheduler.GetFolder', ['\']);
  Definition := ComCall(Scheduler, 'Watchdog.Scheduler.NewTask', [0]);
  ComSet(ComGet(Definition, 'Watchdog.Definition.RegistrationInfo'), 'Watchdog.RegistrationInfo.Description', 'AVC Public Access patron-session Watchdog');
  Principal := ComGet(Definition, 'Watchdog.Definition.Principal');
  ComSet(Principal, 'Watchdog.Principal.GroupId', 'S-1-5-32-545');
  ComSet(Principal, 'Watchdog.Principal.Id', 'Patron');
  Actions := ComGet(Definition, 'Watchdog.Definition.Actions');
  ComSet(Actions, 'Watchdog.Actions.Context', 'Patron');
  ComSet(Principal, 'Watchdog.Principal.LogonType', 4);
  ComSet(Principal, 'Watchdog.Principal.RunLevel', 0);
  Trigger := ComCall(ComGet(Definition, 'Watchdog.Definition.Triggers'), 'Watchdog.Triggers.Create', [9]);
  ComSet(Trigger, 'Watchdog.Trigger.Enabled', True);
  ComSet(Trigger, 'Watchdog.Trigger.ExecutionTimeLimit', 'PT0S');
  Settings := ComGet(Definition, 'Watchdog.Definition.Settings');
  ComSet(Settings, 'Watchdog.Settings.MultipleInstances', 2);
  ComSet(Settings, 'Watchdog.Settings.DisallowStartIfOnBatteries', False);
  ComSet(Settings, 'Watchdog.Settings.StopIfGoingOnBatteries', False);
  ComSet(Settings, 'Watchdog.Settings.StartWhenAvailable', True);
  ComSet(Settings, 'Watchdog.Settings.Enabled', True);
  ComSet(Settings, 'Watchdog.Settings.ExecutionTimeLimit', 'PT0S');
  ComSet(Settings, 'Watchdog.Settings.RestartInterval', 'PT1M');
  ComSet(Settings, 'Watchdog.Settings.RestartCount', 3);
  ComSet(Settings, 'Watchdog.Settings.RunOnlyIfIdle', False);
  ComSet(Settings, 'Watchdog.Settings.RunOnlyIfNetworkAvailable', False);
  ComSet(Settings, 'Watchdog.Settings.Hidden', False);
  ComSet(Settings, 'Watchdog.Settings.AllowDemandStart', True);
  ComSet(Settings, 'Watchdog.Settings.AllowHardTerminate', True);
  Action := ComCall(Actions, 'Watchdog.Actions.Create', [0]);
  ComSet(Action, 'Watchdog.Action.Path', DeploymentRoot + '\AVCPublicAccess.Watchdog.exe');
  ComSet(Action, 'Watchdog.Action.WorkingDirectory', DeploymentRoot);
  // Preserve the existing unset/empty arguments, without adding a setter.
  WatchdogComparison('construction: default empty arguments', String(ComGet(Action, 'Watchdog.Action.Arguments')) = '');
  BeginDeploymentPhase('Watchdog task registration');
  Task := ComCall(Folder, 'Watchdog.Folder.RegisterTaskDefinition', [WatchdogTaskName, Definition, 6, 'S-1-5-32-545', '', 4]);
  WatchdogDisabledByInstaller := False;
  BeginDeploymentPhase('Watchdog registered-task readback');
  Task := OwnedTask;
  WatchdogComparison('registered task present', not VarIsEmpty(Task));
  Require(not VarIsEmpty(Task), 'Registered Watchdog could not be read back.');
end;

procedure InstallDeployment(const Endpoint: String);
var Deadline: Int64; Ready: Boolean;
begin
#ifdef DeploymentTest
  // Inject failures at platform boundaries without privileged host operations.
  Require(MockPostFailure <> 1, 'Mock configuration failure.');
  Require(MockPostFailure <> 2, 'Mock ACL failure.');
  Require(MockPostFailure <> 3, 'Mock Service registration failure.');
  Require(MockPostFailure <> 4, 'Mock task registration/readback failure.');
  Require(MockPostFailure <> 5, 'Mock Service startup failure.');
  Require(MockPostFailure <> 6, 'Mock API failure.');
  if MockPostFailure = 7 then Require(StatusAvailable('{"status":"Available","testMode":true}', True), 'Mock TestMode rejection.');
  if MockPostFailure = 8 then Require(StatusAvailable('{"status":"In Use","testMode":false}', True), 'Mock active status rejection.');
  Require(MockPostFailure <> 9, 'Mock required query failure.');
  Exit;
#endif
  BeginDeploymentPhase('Post-install preflight'); DeploymentPreflight;
  BeginDeploymentPhase('Configuration update'); WriteEndpoint(Endpoint);
  BeginDeploymentPhase('Runtime security initialization'); InitializeRuntime;
  BeginDeploymentPhase('Service registration'); RegisterService;
  RegisterWatchdog;
  BeginDeploymentPhase('Service startup'); StartOwnedService;
  BeginDeploymentPhase('Local API readiness');
  Ready := False; Deadline := TickCount + 30000;
  repeat
    try Ready := LocalStatus(True) and (ServiceState = 4); except Ready := False; end;
    if Ready then Break;
    Sleep(500);
  until TickCount >= Deadline;
  Require(Ready, 'Service did not become Available with TestMode=false. Installation is not verified; do not freeze this workstation.');
end;

function ServiceRemoved: Boolean;
var Manager, H: THandle; E: LongWord;
begin
  Manager := OpenSCManager(0, 0, 1);
  Require(Manager <> 0, 'Cannot verify Service deletion.');
  try
    H := OpenService(Manager, AVCService, 4);
    if H <> 0 then begin CloseServiceHandle(H); Result := False; end
    else begin
      E := DLLGetLastError;
      Require((E = 1060) or (E = 1072), 'Cannot verify Service deletion.');
      Result := E = 1060; // marked-for-deletion is not yet deleted
    end;
  finally CloseServiceHandle(Manager); end;
end;

procedure UninstallDeployment;
var Task, Folder: Variant; H: THandle; I: Integer;
begin
#ifdef DeploymentTest
  MockUninstallCalls := MockUninstallCalls + 1;
  StopDeployment;
  Require(not MockUninstallFailure, 'Mock destructive uninstall failure.');
  MockRegistrationsRemoved := True; Exit;
#endif
  StopDeployment; Task := OwnedTask;
  if not VarIsEmpty(Task) then begin Folder := TaskFolder; ComCall(Folder, 'Watchdog.Folder.DeleteTask', [WatchdogTaskName, 0]); end;
  AssertOwnedService; H := ServiceHandle($10000);
  if H <> 0 then begin
    try Require(DeleteService(H), 'Cannot delete AVC Service.');
    finally CloseServiceHandle(H); end;
    for I := 1 to 120 do begin if ServiceRemoved then Break; Sleep(250); end;
    Require(ServiceRemoved, 'Service deletion is pending; close management consoles before retrying.');
  end;
  // Inno removes only its installed files. Configuration/ProgramData are retained.
end;
