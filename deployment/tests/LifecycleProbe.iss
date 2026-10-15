// Build-host-only, non-elevated integration probe. Run through Inno's real
// ssPostInstall/completion/exit-code path with mocked deployment operations.
// No application files or registrations; never staged into the product.
#define DeploymentTest
#ifndef TestOutputRoot
  #error TestOutputRoot required
#endif
[Setup]
AppName=AVC lifecycle exit-code probe
AppVersion=1.0.0
DefaultDirName={tmp}\AVC-lifecycle-probe
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=lowest
OutputDir={#TestOutputRoot}
OutputBaseFilename=LifecycleProbe
SetupArchitecture=x64
MinVersion=10.0.17763
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
DisableWelcomePage=yes
DisableReadyPage=yes
DisableFinishedPage=yes
[Code]
#include "../installer/Json.iss"
#include "../installer/NativeDeployment.iss"
#include "../installer/Lifecycle.iss"

function InitializeSetup: Boolean;
begin
  MockPostFailure := StrToIntDef(ExpandConstant('{param:FAILURE|0}'), -1);
  Result := (MockPostFailure >= 0) and (MockPostFailure <= 9);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then VerifyPostInstall('http://test:5000');
end;
