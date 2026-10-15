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
  Locator := CreateOleObject('WbemScripting.SWbemLocator');
  Result := Locator.ConnectServer('', 'root\cimv2');
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
  Services := Connection.ExecQuery('SELECT Name,DisplayName,PathName FROM Win32_Service');
  for I := 0 to Services.Count - 1 do begin
    S := Services.ItemIndex(I);
    if CompareText(String(S.Name), AVCService) = 0 then
      Require(OwnedServiceMatches(String(S.PathName), DeploymentRoot), 'Service belongs to another installation.')
    else
      Require(not LegacyService(String(S.Name), String(S.DisplayName), String(S.PathName)),
        'Legacy AVC Service exists; review migration before servicing.');
  end;
  // Also query SCM: WMI/query failures must never be interpreted as absence.
  I := ServiceState;
end;

function TaskFolder: Variant;
var Scheduler: Variant;
begin
  Scheduler := CreateOleObject('Schedule.Service'); Scheduler.Connect;
  Result := Scheduler.GetFolder('\');
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
  if Group = 'S-1-5-32-545' then begin Result := True; Exit; end;
  // Task Scheduler may return a localized account name rather than a SID.
  // Resolve it through Windows and compare binary SIDs, never English names.
  Size := SizeOf(Actual); ExpectedSize := SizeOf(Expected);
  DomainSize := 256; SetLength(Domain, DomainSize);
  Require(LookupAccountName(0, Group, Actual, Size, Domain, DomainSize, Use), 'Cannot establish Watchdog principal SID.');
  Require(CreateWellKnownSid(27, 0, Expected, ExpectedSize), 'Cannot establish Builtin Users SID.');
  Result := EqualSid(Actual, Expected);
end;

function WatchdogDefinitionMatches(const D: TWatchdogDefinition; AllowDisabled: Boolean): Boolean;
begin
  Result := (D.PrincipalId = 'Patron') and (D.ActionContext = 'Patron') and
    (D.UserId = '') and (D.GroupSid = 'S-1-5-32-545') and
    (D.LogonType = 4) and (D.RunLevel = 0) and
    (D.TriggerCount = 1) and D.LogonTrigger and D.TriggerEnabled and
    (D.TriggerUser = '') and (D.StartBoundary = '') and (D.EndBoundary = '') and
    ((D.Delay = '') or (D.Delay = 'PT0S')) and
    (D.RepetitionInterval = '') and (D.RepetitionDuration = '') and not D.RepetitionStop and
    ((D.TriggerLimit = '') or (D.TriggerLimit = 'PT0S')) and
    (D.TaskEnabled or AllowDisabled) and (D.MultipleInstances = 2) and
    not D.DisallowBattery and not D.StopOnBattery and D.StartWhenAvailable and
    (D.ExecutionLimit = 'PT0S') and (D.RestartInterval = 'PT1M') and (D.RestartCount = 3) and
    not D.RunOnlyIdle and not D.RunOnlyNetwork and not D.Hidden and D.AllowDemand and D.AllowTerminate;
end;

procedure VerifyWatchdogDefinition(const Task: Variant);
var Definition, Principal, Triggers, Trigger, Settings, Xml: Variant;
  D: TWatchdogDefinition;
begin
  Definition := Task.Definition; Principal := Definition.Principal;
  Triggers := Definition.Triggers; Settings := Definition.Settings;
  Require(Triggers.Count = 1, 'Watchdog must have exactly one trigger.');
  // Type is a Pascal reserved word. Verify the trigger/action types through
  // the registered XML before accessing type-specific COM properties.
  Xml := CreateOleObject('Msxml2.DOMDocument.6.0');
  Xml.async := False; Xml.resolveExternals := False; Xml.validateOnParse := False;
  Xml.setProperty('ProhibitDTD', True);
  Xml.setProperty('SelectionNamespaces', 'xmlns:t="http://schemas.microsoft.com/windows/2004/02/mit/task"');
  Require(Xml.loadXML(String(Task.Xml)), 'Cannot parse registered Watchdog definition.');
  Require((Xml.selectNodes('/t:Task/t:Triggers/t:LogonTrigger').length = 1) and
    (Xml.selectNodes('/t:Task/t:Actions/t:Exec').length = 1), 'Unexpected Watchdog trigger/action type.');
  Trigger := Triggers.Item(1);
  D.PrincipalId := Principal.Id; D.ActionContext := Definition.Actions.Context;
  D.UserId := Principal.UserId; D.GroupSid := '';
  if IsPatronGroup(String(Principal.GroupId)) then D.GroupSid := 'S-1-5-32-545';
  D.LogonType := Principal.LogonType; D.RunLevel := Principal.RunLevel;
  D.TriggerCount := Triggers.Count; D.LogonTrigger := True;
  D.TriggerEnabled := Trigger.Enabled; D.TriggerUser := Trigger.UserId;
  D.StartBoundary := Trigger.StartBoundary; D.EndBoundary := Trigger.EndBoundary;
  D.Delay := Trigger.Delay; D.TriggerLimit := '';
  if Xml.selectNodes('/t:Task/t:Triggers/t:LogonTrigger/t:ExecutionTimeLimit').length <> 0 then
    D.TriggerLimit := Xml.selectSingleNode('/t:Task/t:Triggers/t:LogonTrigger/t:ExecutionTimeLimit').text;
  D.RepetitionInterval := Trigger.Repetition.Interval;
  D.RepetitionDuration := Trigger.Repetition.Duration;
  D.RepetitionStop := Trigger.Repetition.StopAtDurationEnd;
  D.TaskEnabled := Task.Enabled and Settings.Enabled;
  D.MultipleInstances := Settings.MultipleInstances;
  D.DisallowBattery := Settings.DisallowStartIfOnBatteries;
  D.StopOnBattery := Settings.StopIfGoingOnBatteries;
  D.StartWhenAvailable := Settings.StartWhenAvailable;
  D.ExecutionLimit := Settings.ExecutionTimeLimit;
  D.RestartInterval := Settings.RestartInterval; D.RestartCount := Settings.RestartCount;
  D.RunOnlyIdle := Settings.RunOnlyIfIdle; D.RunOnlyNetwork := Settings.RunOnlyIfNetworkAvailable;
  D.Hidden := Settings.Hidden; D.AllowDemand := Settings.AllowDemandStart;
  D.AllowTerminate := Settings.AllowHardTerminate;
  Require(WatchdogDefinitionMatches(D, WatchdogDisabledByInstaller), 'Watchdog principal, trigger, or settings do not match this installation.');
end;

function OwnedTask: Variant;
var Folder, Tasks, Task, Actions, Action: Variant; I: Integer;
begin
  Result := Unassigned;
#ifdef DeploymentTest
  Require(not MockQueryError, 'Mock task query failure.'); Exit;
#endif
  Folder := TaskFolder; Tasks := Folder.GetTasks(1); // include hidden tasks
  for I := 1 to Tasks.Count do begin
    Task := Tasks.Item(I);
    if CompareText(String(Task.Name), AVCTask) = 0 then begin
      Actions := Task.Definition.Actions;
      Require(Actions.Count = 1, 'Watchdog task has unexpected actions.');
      Action := Actions.Item(1);
      // Non-exec actions have no Path/Arguments: COM access fails closed.
      Require(OwnedTaskMatches(Actions.Count, String(Action.Path), String(Action.Arguments),
        String(Action.WorkingDirectory), DeploymentRoot),
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
  Request := CreateOleObject('WinHttp.WinHttpRequest.5.1');
  Request.SetProxy(1); // fixed loopback API must never use a proxy
  Request.SetTimeouts(2000, 2000, 2000, 2000);
  Request.SetAutoLogonPolicy(2); Request.Option(6) := False;
  Request.Open('GET', 'http://127.0.0.1:5051/status', False); Request.Send;
  Require(Request.Status = 200, 'AVC local API did not return success.');
  Result := StatusAvailable(String(Request.ResponseText), Production);
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
  Processes := Connection.ExecQuery('SELECT ProcessId,Name FROM Win32_Process WHERE Name="AVCPublicAccess.Watchdog.exe" OR Name="AVCPublicAccess.Client.exe"');
  for I := 0 to Processes.Count - 1 do begin
    P := Processes.ItemIndex(I);
    Expected := DeploymentRoot + '\AVCPublicAccess.Watchdog.exe';
    if CompareText(String(P.Name), 'AVCPublicAccess.Client.exe') = 0 then
      Expected := DeploymentRoot + '\Client\AVCPublicAccess.Client.exe';
    H := OpenProcess($100000 or $1000 or 1, False, P.ProcessId);
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
  DeploymentPreflight;
  Task := OwnedTask;
  if not VarIsEmpty(Task) then begin
    Task.Enabled := False;
    WatchdogDisabledByInstaller := True; // permit only our own deliberate disabled phase
    Task.Stop(0);
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
var Scheduler, Folder, Definition, Principal, Trigger, Action, Task: Variant;
begin
  Task := OwnedTask;
  Scheduler := CreateOleObject('Schedule.Service'); Scheduler.Connect;
  Folder := Scheduler.GetFolder('\'); Definition := Scheduler.NewTask(0);
  Definition.RegistrationInfo.Description := 'AVC Public Access patron-session Watchdog';
  Principal := Definition.Principal; Principal.GroupId := 'S-1-5-32-545';
  Principal.Id := 'Patron'; Definition.Actions.Context := 'Patron';
  Principal.LogonType := 4; Principal.RunLevel := 0;
  Trigger := Definition.Triggers.Create(9); Trigger.Enabled := True;
  Trigger.ExecutionTimeLimit := 'PT0S';
  Definition.Settings.MultipleInstances := 2;
  Definition.Settings.DisallowStartIfOnBatteries := False;
  Definition.Settings.StopIfGoingOnBatteries := False;
  Definition.Settings.StartWhenAvailable := True;
  Definition.Settings.Enabled := True;
  Definition.Settings.ExecutionTimeLimit := 'PT0S';
  Definition.Settings.RestartInterval := 'PT1M'; Definition.Settings.RestartCount := 3;
  Definition.Settings.RunOnlyIfIdle := False;
  Definition.Settings.RunOnlyIfNetworkAvailable := False;
  Definition.Settings.Hidden := False;
  Definition.Settings.AllowDemandStart := True;
  Definition.Settings.AllowHardTerminate := True;
  Action := Definition.Actions.Create(0);
  Action.Path := DeploymentRoot + '\AVCPublicAccess.Watchdog.exe';
  Action.WorkingDirectory := DeploymentRoot;
  Task := Folder.RegisterTaskDefinition(AVCTask, Definition, 6, 'S-1-5-32-545', '', 4);
  WatchdogDisabledByInstaller := False;
  Task := OwnedTask;
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
  DeploymentPreflight; WriteEndpoint(Endpoint); InitializeRuntime;
  RegisterService; RegisterWatchdog; StartOwnedService;
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
  if not VarIsEmpty(Task) then begin Folder := TaskFolder; Folder.DeleteTask(AVCTask, 0); end;
  AssertOwnedService; H := ServiceHandle($10000);
  if H <> 0 then begin
    try Require(DeleteService(H), 'Cannot delete AVC Service.');
    finally CloseServiceHandle(H); end;
    for I := 1 to 120 do begin if ServiceRemoved then Break; Sleep(250); end;
    Require(ServiceRemoved, 'Service deletion is pending; close management consoles before retrying.');
  end;
  // Inno removes only its installed files. Configuration/ProgramData are retained.
end;
