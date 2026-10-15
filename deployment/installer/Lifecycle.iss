// Shared lifecycle gates, compiled into the real installer/uninstaller and the
// build-host regression harness. Required deployment failures are latched;
// they do not rely on an exception escaping ssPostInstall (Inno catches it).
const
  UnverifiedNotice = 'Installation FAILED and is NOT VERIFIED. This workstation must remain THAWED. Do not freeze it or return it to patron use. Review the installation failure before retrying.';
var
  InstallAttempted, InstallVerified, InstallFailed: Boolean;

procedure VerifyPostInstall(const Endpoint: String);
begin
  if InstallAttempted then Exit; // a failed attempt cannot later become success
  InstallAttempted := True; InstallVerified := False; InstallFailed := True;
  try
    InstallDeployment(Endpoint);
    InstallVerified := True; InstallFailed := False;
  except
    // Keep the failure latch even though Setup continues after ssPostInstall.
    Log(UnverifiedNotice);
    Log('Required deployment operation failed: ' + GetExceptionMessage);
  end;
end;

function GetCustomSetupExitCode: Integer;
begin
  Result := 0;
  if InstallFailed or (InstallAttempted and not InstallVerified) then Result := 1001;
end;

function InitializeUninstall: Boolean;
begin
  Result := False;
#ifdef DeploymentTest
  if not MockUninstallConfirmed then Exit;
#else
  if UninstallSilent then Exit;
  if MsgBox('Uninstall only while THAWED and with no patron session. Continue?', mbConfirmation, MB_YESNO) <> idYes then Exit;
#endif
  try
    // Inno has not shown its final uninstall confirmation yet. Queries only.
    DeploymentPreflight;
    Result := True;
  except
#ifndef DeploymentTest
    MsgBox(GetExceptionMessage + ' Uninstall aborted; do not freeze this workstation.', mbError, MB_OK);
#endif
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then begin
    // Inno 7.1 invokes this after confirmation and before PerformUninstall.
    // Exceptions here are fatal: never catch and allow file deletion to follow.
    UninstallDeployment;
  end;
end;
