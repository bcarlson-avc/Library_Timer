// x64 IDispatch instrumentation. Invoke directly so Pascal Script cannot discard
// EXCEPINFO.scode/source/description. Arguments retain their original VARIANT types.
type
  TComStringVariant = record
    Kind, Reserved1, Reserved2, Reserved3: Word;
    Value, Extra: NativeUInt;
  end;
  TComParams = record
    Args, NamedArgs: NativeUInt;
    Count, NamedCount: LongWord;
  end;
  TComException = record
    Code, Reserved: Word;
    Padding1: LongWord;
    Source, Description, HelpFile: NativeUInt;
    HelpContext, Padding2: LongWord;
    ReservedPointer, DeferredFill: NativeUInt;
    Error, Padding3: LongInt;
  end;
  IAvcDispatch = interface(IUnknown)
    '{00020400-0000-0000-C000-000000000046}'
    function GetTypeInfoCount(var Count: LongWord): HResult;
    function GetTypeInfo(Index, Locale: LongWord; var Info: IUnknown): HResult;
    function GetIDsOfNames(const IID: TGUID; var Names: NativeUInt;
      Count, Locale: LongWord; var Id: LongInt): HResult;
    function Invoke(Id: LongInt; const IID: TGUID; Locale: LongWord; Flags: Word;
      var Params: TComParams; var Value: Variant; var Exception: TComException;
      var ArgError: LongWord): HResult;
  end;
var
  DeploymentPhase, DeploymentOperation, LastComFailure: String;

#ifdef WatchdogIntegrationProbe
var
  ProbeRegistrationSeen: Boolean;
  ProbeRegistrationUserKind, ProbeRegistrationPasswordKind, ProbeRegistrationLogonType: Integer;
#endif

function ComAllocString(Value: String): NativeUInt;
  external 'SysAllocString@oleaut32.dll stdcall';
function ComAllocSizedString(Value: String; Characters: LongWord): NativeUInt;
  external 'SysAllocStringLen@oleaut32.dll stdcall';
procedure ComFreeString(Value: NativeUInt);
  external 'SysFreeString@oleaut32.dll stdcall';
function ComStringLength(Value: NativeUInt): LongWord;
  external 'SysStringLen@oleaut32.dll stdcall';
procedure ComCopyString(Destination: String; Source, Bytes: NativeUInt);
  external 'RtlMoveMemory@kernel32.dll stdcall';
function ComArrayCreate(Kind: Word; Lower: LongInt; Count: LongWord): NativeUInt;
  external 'SafeArrayCreateVector@oleaut32.dll stdcall';
function ComArrayPut(Handle: NativeUInt; var Index: LongInt; var Value: Variant): HResult;
  external 'SafeArrayPutElement@oleaut32.dll stdcall';
function ComArrayAccess(Handle: NativeUInt; var Data: NativeUInt): HResult;
  external 'SafeArrayAccessData@oleaut32.dll stdcall';
function ComArrayUnlock(Handle: NativeUInt): HResult;
  external 'SafeArrayUnaccessData@oleaut32.dll stdcall';
function ComArrayDestroy(Handle: NativeUInt): HResult;
  external 'SafeArrayDestroy@oleaut32.dll stdcall';
function ComClassId(Name: String; var Id: TGUID): HResult;
  external 'CLSIDFromProgID@ole32.dll stdcall';
function ComCreate(const ClassId: TGUID; Outer: NativeUInt; Context: LongWord;
  const IID: TGUID; var Obj: IAvcDispatch): HResult;
  external 'CoCreateInstance@ole32.dll stdcall';

function ComAllocate(Bytes: NativeUInt): NativeUInt;
  external 'CoTaskMemAlloc@ole32.dll stdcall';
procedure ComReleaseNamedArgument(Memory: NativeUInt);
  external 'CoTaskMemFree@ole32.dll stdcall';
procedure ComWriteLong(Destination: NativeUInt; var Source: LongInt; Bytes: NativeUInt);
  external 'RtlMoveMemory@kernel32.dll stdcall';

function ComNamedArgumentPointer(var Value: LongInt): NativeUInt;
begin
  Result := ComAllocate(4);
  if Result = 0 then RaiseException('Cannot allocate COM named argument.');
  ComWriteLong(Result, Value, 4);
end;

procedure ComCopyVariant(var Destination: Variant; var Source: TComStringVariant; Bytes: NativeUInt);
  external 'RtlMoveMemory@kernel32.dll stdcall';

procedure ComInitString(const Value: String; var Destination: Variant);
var Raw: TComStringVariant;
begin
  Destination := Unassigned;
  Raw.Kind := 8; Raw.Reserved1 := 0; Raw.Reserved2 := 0; Raw.Reserved3 := 0;
  Raw.Value := ComAllocSizedString(Value, Length(Value)); Raw.Extra := 0;
  if Raw.Value = 0 then RaiseException('Cannot allocate COM string.');
  ComCopyVariant(Destination, Raw, SizeOf(Raw)); // VARIANT now owns the BSTR
end;

function ComDeferredCall(Instance, FunctionAddress: NativeUInt; Convention: Integer;
  ReturnKind: Word; Count: LongWord; var ArgumentKind: Word;
  var ArgumentPointer: NativeUInt; var Value: Variant): HResult;
  external 'DispCallFunc@oleaut32.dll stdcall';
procedure ComWriteException(Destination: NativeUInt; var Source: TComException; Bytes: NativeUInt);
  external 'RtlMoveMemory@kernel32.dll stdcall';
procedure ComReadException(var Destination: TComException; Source, Bytes: NativeUInt);
  external 'RtlMoveMemory@kernel32.dll stdcall';
procedure ComWriteRawVariant(Destination: NativeUInt; var Source: TComStringVariant; Bytes: NativeUInt);
  external 'RtlMoveMemory@kernel32.dll stdcall';

procedure CompleteComException(var Ex: TComException);
var Memory, Argument: NativeUInt; Kind: Word; Value: Variant; HR: HResult; Raw: TComStringVariant;
begin
  if Ex.DeferredFill = 0 then Exit;
  Memory := ComAllocate(SizeOf(Ex)); Argument := ComAllocate(SizeOf(Raw));
  try
    if (Memory = 0) or (Argument = 0) then begin
      Log('Deferred EXCEPINFO could not be populated: allocation failure.'); Exit;
    end;
    ComWriteException(Memory, Ex, SizeOf(Ex));
    // DispCallFunc accepts VARIANTARG**, not pointers to untyped raw values.
    Raw.Kind := 26; Raw.Reserved1 := 0; Raw.Reserved2 := 0; Raw.Reserved3 := 0;
    Raw.Value := Memory; Raw.Extra := 0;
    ComWriteRawVariant(Argument, Raw, SizeOf(Raw));
    Kind := 26; // VT_PTR, one EXCEPINFO* argument, stdcall, HRESULT return
    HR := ComDeferredCall(0, Ex.DeferredFill, 4, 3, 1, Kind, Argument, Value);
    ComReadException(Ex, Memory, SizeOf(Ex));
    if HR < 0 then Log('Deferred EXCEPINFO callback invocation HRESULT=' + IntToStr(HR))
    else if LongInt(Value) < 0 then Log('Deferred EXCEPINFO population HRESULT=' + IntToStr(LongInt(Value)));
  finally
    ComReleaseNamedArgument(Argument); ComReleaseNamedArgument(Memory);
  end;
end;

function ComReadString(Value: NativeUInt): String;
var N: LongWord;
begin
  Result := '';
  if Value = 0 then Exit;
  N := ComStringLength(Value); SetLength(Result, N);
  if N <> 0 then ComCopyString(Result, Value, N * 2);
end;

procedure BeginDeploymentPhase(const Name: String);
begin
  DeploymentPhase := Name; DeploymentOperation := ''; LastComFailure := '';
  Log('Deployment phase: ' + Name);
end;

procedure BeginComOperation(const Name: String);
begin
  DeploymentOperation := Name; LastComFailure := '';
  Log('BEGIN phase=' + DeploymentPhase + '; operation=' + Name);
end;

procedure CheckComResult(HR, ServerError: LongInt; const Source, Description: String);
var Effective: LongInt;
begin
  if HR >= 0 then Exit;
  Effective := HR;
  if (HR = -2147352567) and (ServerError < 0) then Effective := ServerError;
  LastComFailure := 'phase=' + DeploymentPhase + '; operation=' + DeploymentOperation +
    '; HRESULT=0x' + Format('%.8x', [Effective]) + ' (' + IntToStr(Effective) + ')' +
    '; InvokeHRESULT=0x' + Format('%.8x', [HR]) + ' (' + IntToStr(HR) + ')' +
    '; COM source="' + Source + '"; COM description="' + Description + '"';
  Log('FAIL ' + LastComFailure);
  RaiseException(LastComFailure);
end;

function DiagnosticFailure(const Original: String): String;
begin
  if LastComFailure <> '' then Result := LastComFailure
  else Result := 'phase=' + DeploymentPhase + '; operation=' + DeploymentOperation +
    '; error=' + Original + '; HRESULT unavailable (outside instrumented COM call)';
end;

function DiagnosticCreate(const ProgId: String): Variant;
var ClassId: TGUID; Obj: IAvcDispatch; HR: HResult;
begin
  BeginComOperation('Create COM object ' + ProgId);
  HR := ComClassId(ProgId, ClassId); CheckComResult(HR, 0, '', '');
  HR := ComCreate(ClassId, 0, 5, StringToGUID('{00020400-0000-0000-C000-000000000046}'), Obj);
  CheckComResult(HR, 0, '', '');
  Result := IDispatch(Obj);
  Log('OK operation=' + DeploymentOperation);
end;

function DiagnosticInvoke(const Obj: Variant; const Member: String; Flags: Word;
  const Arguments: array of Variant): Variant;
var D: IAvcDispatch; IID: TGUID; Name, ArrayHandle: NativeUInt;
  Params: TComParams; Ex: TComException; Id, I, NamedId: LongInt;
  ArgError: LongWord; HR: HResult; V: Variant; Source, Description, DispatchMember, StringArgument: String; Dot, J: Integer;
begin
  if Flags = 4 then BeginComOperation(Member + ' [put]')
  else BeginComOperation(Member + ' [get/call]');
  D := IAvcDispatch(IDispatch(Obj)); IID := StringToGUID('{00000000-0000-0000-0000-000000000000}');
  Dot := 0;
  for J := 1 to Length(Member) do if Member[J] = '.' then Dot := J;
  DispatchMember := Copy(Member, Dot + 1, Length(Member));
  if DispatchMember = 'RegisterTaskDefinition' then begin
    Log('Task registration credential override types: userId=' + IntToStr(VarType(Arguments[3])) +
      '; password=' + IntToStr(VarType(Arguments[4])) + '; logonType=' + IntToStr(Integer(Arguments[5])));
#ifdef WatchdogIntegrationProbe
    ProbeRegistrationSeen := False;
    ProbeRegistrationUserKind := -1; ProbeRegistrationPasswordKind := -1;
    ProbeRegistrationLogonType := -1;
#endif
  end;
  Name := ComAllocString(DispatchMember);
  try
    HR := D.GetIDsOfNames(IID, Name, 1, $800, Id);
    CheckComResult(HR, 0, '', '');
  finally ComFreeString(Name); end;
  Params.Args := 0; Params.NamedArgs := 0;
  Params.Count := GetArrayLength(Arguments); Params.NamedCount := 0;
  ArrayHandle := 0;
  try
    if Params.Count <> 0 then begin
      ArrayHandle := ComArrayCreate(12, 0, Params.Count); // VT_VARIANT
      if ArrayHandle = 0 then CheckComResult(-2147024882, 0, '', 'Cannot allocate COM arguments');
      for I := 0 to Params.Count - 1 do begin
        V := Arguments[Params.Count - 1 - I];
        // Delphi native strings are not Automation VARIANT types. Match the
        // original Pascal Script dispatcher by passing strings as VT_BSTR.
        if (VarType(V) = 256) or (VarType(V) = 258) then begin
          StringArgument := V; V := Unassigned;
          ComInitString(StringArgument, V);
        end;
#ifdef WatchdogIntegrationProbe
        // Observe the actual post-normalization VARIANTs passed to Automation,
        // not a separate mock of the caller's credential construction.
        if DispatchMember = 'RegisterTaskDefinition' then begin
          if Params.Count - 1 - I = 3 then ProbeRegistrationUserKind := VarType(V);
          if Params.Count - 1 - I = 4 then ProbeRegistrationPasswordKind := VarType(V);
          if Params.Count - 1 - I = 5 then ProbeRegistrationLogonType := Integer(V);
          ProbeRegistrationSeen := True;
        end;
#endif
        HR := ComArrayPut(ArrayHandle, I, V); CheckComResult(HR, 0, '', '');
      end;
      HR := ComArrayAccess(ArrayHandle, Params.Args); CheckComResult(HR, 0, '', '');
    end;
    // DISPID_PROPERTYPUT is a 32-bit LONG, separate from VARIANT arguments.
    NamedId := -3;
    if Flags = 4 then begin
      Params.NamedCount := 1;
      Params.NamedArgs := ComNamedArgumentPointer(NamedId);
    end;
    Ex.Code := 0; Ex.Reserved := 0; Ex.Padding1 := 0;
    Ex.Source := 0; Ex.Description := 0; Ex.HelpFile := 0;
    Ex.HelpContext := 0; Ex.Padding2 := 0; Ex.ReservedPointer := 0;
    Ex.DeferredFill := 0; Ex.Error := 0; Ex.Padding3 := 0;
    ArgError := 0; Result := Unassigned;
    HR := D.Invoke(Id, IID, $800, Flags, Params, Result, Ex, ArgError);
    try
      CompleteComException(Ex);
      if HR < 0 then Log('COM Invoke argument index=' + IntToStr(ArgError) + '; exception code=' + IntToStr(Ex.Code));
      Source := ComReadString(Ex.Source); Description := ComReadString(Ex.Description);
      CheckComResult(HR, Ex.Error, Source, Description);
    finally
      ComFreeString(Ex.Source); ComFreeString(Ex.Description); ComFreeString(Ex.HelpFile);
    end;
  finally
    if ArrayHandle <> 0 then begin
      if Params.Args <> 0 then ComArrayUnlock(ArrayHandle);
      ComArrayDestroy(ArrayHandle);
    end;
    if Params.NamedArgs <> 0 then ComReleaseNamedArgument(Params.NamedArgs);
  end;
  Log('OK phase=' + DeploymentPhase + '; operation=' + Member);
end;

function ComGet(const Obj: Variant; const Member: String): Variant;
begin Result := DiagnosticInvoke(Obj, Member, 3, []); end;
procedure ComSet(const Obj: Variant; const Member: String; const Value: Variant);
var Ignored: Variant;
begin Ignored := DiagnosticInvoke(Obj, Member, 4, [Value]); end;
function ComCall(const Obj: Variant; const Member: String; const Arguments: array of Variant): Variant;
begin Result := DiagnosticInvoke(Obj, Member, 3, Arguments); end;

procedure ComSetIndexed(const Obj: Variant; const Member: String; Index: Integer; const Value: Variant);
var Ignored: Variant;
begin Ignored := DiagnosticInvoke(Obj, Member, 4, [Index, Value]); end;
