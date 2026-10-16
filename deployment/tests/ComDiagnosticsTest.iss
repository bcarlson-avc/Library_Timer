// Real, non-privileged COM marshalling/error tests; no Task Scheduler/SCM calls.
#ifndef TestOutputRoot
  #error TestOutputRoot required
#endif
[Setup]
AppName=AVC COM diagnostic tests
AppVersion=1.0.0
DefaultDirName={tmp}\AVC-COM-diagnostics
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=lowest
OutputDir={#TestOutputRoot}
OutputBaseFilename=ComDiagnosticsTest
SetupArchitecture=x64
MinVersion=10.0.17763
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
[Code]
#include "../installer/ComDiagnostics.iss"
procedure ExitProcess(Code: LongWord);
  external 'ExitProcess@kernel32.dll stdcall';
var Checks: Integer;
procedure Check(OK: Boolean; const Name: String);
begin
  if not OK then RaiseException('Diagnostic test failed: ' + Name);
  Checks := Checks + 1;
end;
// Exercise the deferred-EXCEPINFO ABI through a local compiled callback.
function FillDeferredException(Address: NativeUInt): LongInt;
var Ex: TComException;
begin
  ComReadException(Ex, Address, SizeOf(Ex));
  Ex.Source := ComAllocString('deferred source');
  Ex.Description := ComAllocString('deferred description');
  Ex.Error := -2147024809; Ex.DeferredFill := 0;
  ComWriteException(Address, Ex, SizeOf(Ex)); Result := 0;
end;

function InitializeSetup: Boolean;
var Doc, Root, Node, Nodes, V, Request: Variant; Failed: Boolean; MessageText, Report: String; Ex: TComException; Params: TComParams; Raw: TComStringVariant;
begin
  Result := False; Report := ExpandConstant('{param:REPORT}');
  try
    BeginDeploymentPhase('Diagnostic regression tests');
    Check(SizeOf(Ex) = 64, 'x64 EXCEPINFO layout');
    Check(SizeOf(Params) = 24, 'x64 DISPPARAMS layout');
    Check(SizeOf(Raw) = 24, 'x64 VARIANT layout');
    Doc := DiagnosticCreate('Msxml2.DOMDocument.6.0');
    ComSet(Doc, 'Test.Xml.async', False);
    Check(not Boolean(ComGet(Doc, 'Test.Xml.async')), 'boolean property put/get');
    Check(Boolean(ComCall(Doc, 'Test.Xml.loadXML', ['<root/>'])), 'string argument');
    Root := ComGet(Doc, 'Test.Xml.documentElement');
    ComCall(Root, 'Test.Root.setAttribute', ['name', 'value with spaces']);
    Check(String(ComCall(Root, 'Test.Root.getAttribute', ['name'])) = 'value with spaces', 'argument order and spaces');
    ComCall(Root, 'Test.Root.setAttribute', ['empty', '']);
    Check(String(ComCall(Root, 'Test.Root.getAttribute', ['empty'])) = '', 'empty BSTR');
    ComCall(Root, 'Test.Root.setAttribute', ['unicode', #$00E9 + #$03A9]);
    Check(String(ComCall(Root, 'Test.Root.getAttribute', ['unicode'])) = #$00E9 + #$03A9, 'Unicode BSTR');
    ComCall(Root, 'Test.Root.setAttribute', ['number', 4]);
    Check(String(ComCall(Root, 'Test.Root.getAttribute', ['number'])) = '4', 'integer argument');
    Node := ComCall(Doc, 'Test.Xml.createElement', ['child']);
    ComCall(Root, 'Test.Root.appendChild', [Node]);
    Nodes := ComCall(Doc, 'Test.Xml.selectNodes', ['/root/child']);
    Check(Integer(ComGet(Nodes, 'Test.Nodes.length')) = 1, 'COM object argument/result');
    Node := ComCall(Nodes, 'Test.Nodes.item', [0]);
    Check(String(ComGet(Node, 'Test.Node.nodeName')) = 'child', 'indexed property');
    Request := DiagnosticCreate('WinHttp.WinHttpRequest.5.1');
    ComSetIndexed(Request, 'Test.LocalApi.Option', 6, False);
    // Production writes this option; Wine does not implement its getter.
    Check(DeploymentOperation = 'Test.LocalApi.Option [put]', 'indexed boolean property put accepted without a network request');
    Failed := False;
    try V := ComGet(Doc, 'Test.Xml.NonexistentAvcDiagnosticProperty');
    except
      Failed := True; MessageText := DiagnosticFailure(GetExceptionMessage);
    end;
    Check(Failed and (Pos('NonexistentAvcDiagnosticProperty', MessageText) > 0) and
      (Pos('0x80020006', MessageText) > 0) and (Pos('-2147352570', MessageText) > 0), 'actual name-resolution HRESULT and operation');
    Failed := False;
    try ComCall(Doc, 'Test.Xml.setProperty', ['NonexistentAvcProperty', True]);
    except Failed := True; MessageText := DiagnosticFailure(GetExceptionMessage); end;
    Check(Failed and (Pos('HRESULT=0x', MessageText) > 0) and
      (Pos('COM source="', MessageText) > 0) and (Pos('COM description="', MessageText) > 0), 'actual Invoke exception details');
    BeginComOperation('Synthetic blank EXCEPINFO'); Failed := False;
    try CheckComResult(-2147352567, -2147024809, '', '');
    except Failed := True; MessageText := DiagnosticFailure(GetExceptionMessage); end;
    Check(Failed and (Pos('0x80070057', MessageText) > 0) and
      (Pos('-2147024809', MessageText) > 0) and (Pos('Synthetic blank EXCEPINFO', MessageText) > 0) and
      (Pos('Diagnostic regression tests', MessageText) > 0), 'blank source/description retains scode, operation, phase');
    BeginComOperation('Synthetic described EXCEPINFO'); Failed := False;
    try CheckComResult(-2147352567, -2147024809, 'test source', 'test description');
    except Failed := True; MessageText := DiagnosticFailure(GetExceptionMessage); end;
    Check(Failed and (Pos('test source', MessageText) > 0) and (Pos('test description', MessageText) > 0), 'source/description retained');
    BeginComOperation('Deferred EXCEPINFO regression');
    Ex.Code := 0; Ex.Reserved := 0; Ex.Padding1 := 0;
    Ex.Source := 0; Ex.Description := 0; Ex.HelpFile := 0;
    Ex.HelpContext := 0; Ex.Padding2 := 0; Ex.ReservedPointer := 0;
    Ex.DeferredFill := CreateCallback(@FillDeferredException); Ex.Error := 0; Ex.Padding3 := 0;
    try
      CompleteComException(Ex);
      Check((Ex.Error = -2147024809) and (ComReadString(Ex.Source) = 'deferred source') and
        (ComReadString(Ex.Description) = 'deferred description'), 'deferred EXCEPINFO HRESULT/source/description ABI');
    finally ComFreeString(Ex.Source); ComFreeString(Ex.Description); ComFreeString(Ex.HelpFile); end;
    SaveStringToFile(Report, 'PASS: ' + IntToStr(Checks) + ' COM diagnostic checks (real MSXML/WinHTTP plus error-format fixtures)', False);
    ExitProcess(0);
  except
    SaveStringToFile(Report, 'FAIL: ' + DiagnosticFailure(GetExceptionMessage), False);
    ExitProcess(1);
  end;
end;
