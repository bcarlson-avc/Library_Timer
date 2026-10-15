// Shared pure endpoint validation: compiled into Setup and build-host tests.
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

function ValidPort(const Value: String): Boolean;
var I, Port: Integer;
begin
  Result := False;
  if (Length(Value) = 0) or (Length(Value) > 5) then Exit;
  for I := 1 to Length(Value) do
    if (Value[I] < '0') or (Value[I] > '9') then Exit;
  Port := StrToIntDef(Value, 0);
  Result := (Port >= 1) and (Port <= 65535);
end;
