// Strict RFC 8259 parser for installer configuration/status. No evaluation or
// regex edits. Nodes retain token spans so an endpoint update leaves every
// other character (including unknown settings and numeric precision) intact.
// Limits and duplicate-key rejection deliberately fail closed.
type
  TJsonNode = record
    Parent, First, Last: Integer;
    Kind, Name, Value: String;
  end;
var
  JsonText: String;
  JsonPos: Integer;
  JsonNodes: array of TJsonNode;

procedure JsonFail;
begin
  RaiseException('Invalid or ambiguous JSON; configuration was not changed.');
end;

function JsonPeek: Char;
begin
  Result := #0;
  if JsonPos <= Length(JsonText) then Result := JsonText[JsonPos];
end;

procedure JsonSpace;
begin
  while (JsonPeek = ' ') or (JsonPeek = #9) or
    (JsonPeek = #10) or (JsonPeek = #13) do JsonPos := JsonPos + 1;
end;

function JsonHex: Integer;
var I, N: Integer; C: Char;
begin
  Result := 0;
  for I := 1 to 4 do begin
    C := JsonPeek; JsonPos := JsonPos + 1;
    N := Pos(Uppercase(C), '0123456789ABCDEF') - 1;
    if (C = #0) or (N < 0) then JsonFail;
    Result := Result * 16 + N;
  end;
end;

function JsonString: String;
var C: Char; N, Low: Integer;
begin
  Result := '';
  if JsonPeek <> '"' then JsonFail;
  JsonPos := JsonPos + 1;
  while JsonPeek <> '"' do begin
    C := JsonPeek; JsonPos := JsonPos + 1;
    if Ord(C) < 32 then JsonFail;
    if C = '\' then begin
      C := JsonPeek; JsonPos := JsonPos + 1;
      case C of
        '"', '\', '/': Result := Result + C;
        'b': Result := Result + #8;
        'f': Result := Result + #12;
        'n': Result := Result + #10;
        'r': Result := Result + #13;
        't': Result := Result + #9;
        'u': begin
          N := JsonHex;
          if (N >= $D800) and (N <= $DBFF) then begin
            if JsonPeek <> '\' then JsonFail;
            JsonPos := JsonPos + 1;
            if JsonPeek <> 'u' then JsonFail;
            JsonPos := JsonPos + 1; Low := JsonHex;
            if (Low < $DC00) or (Low > $DFFF) then JsonFail;
            Result := Result + Chr(N) + Chr(Low);
          end else begin
            if (N >= $DC00) and (N <= $DFFF) then JsonFail;
            Result := Result + Chr(N);
          end;
        end;
      else JsonFail;
      end;
    end else begin
      N := Ord(C);
      if (N >= $D800) and (N <= $DBFF) then begin
        Low := Ord(JsonPeek);
        if (Low < $DC00) or (Low > $DFFF) then JsonFail;
        Result := Result + C + JsonPeek; JsonPos := JsonPos + 1;
      end else begin
        if (N >= $DC00) and (N <= $DFFF) then JsonFail;
        Result := Result + C;
      end;
    end;
  end;
  JsonPos := JsonPos + 1;
end;

function JsonDigit: Boolean;
begin Result := (JsonPeek >= '0') and (JsonPeek <= '9'); end;

procedure JsonDigits;
begin
  if not JsonDigit then JsonFail;
  while JsonDigit do JsonPos := JsonPos + 1;
end;

function JsonValue(Parent: Integer; Name: String; Depth: Integer): Integer;
var I, N, Start: Integer; Key, Literal: String; Closing: Char;
begin
  if (Depth > 64) or (GetArrayLength(JsonNodes) >= 100000) then JsonFail;
  JsonSpace;
  N := GetArrayLength(JsonNodes); SetArrayLength(JsonNodes, N + 1);
  JsonNodes[N].Parent := Parent; JsonNodes[N].Name := Name;
  JsonNodes[N].First := JsonPos;
  case JsonPeek of
    '{', '[': begin
      Closing := '}'; JsonNodes[N].Kind := 'object';
      if JsonPeek = '[' then begin Closing := ']'; JsonNodes[N].Kind := 'array'; end;
      JsonPos := JsonPos + 1; JsonSpace;
      if JsonPeek <> Closing then begin
        repeat
          Key := '';
          if Closing = '}' then begin
            Key := JsonString;
            for I := N + 1 to GetArrayLength(JsonNodes) - 1 do
              if (JsonNodes[I].Parent = N) and (JsonNodes[I].Name = Key) then JsonFail;
            JsonSpace; if JsonPeek <> ':' then JsonFail;
            JsonPos := JsonPos + 1;
          end;
          I := JsonValue(N, Key, Depth + 1); JsonSpace;
          if JsonPeek = Closing then Break;
          if JsonPeek <> ',' then JsonFail;
          JsonPos := JsonPos + 1; JsonSpace;
        until False;
      end;
      JsonPos := JsonPos + 1;
    end;
    '"': begin JsonNodes[N].Kind := 'string'; JsonNodes[N].Value := JsonString; end;
    't', 'f', 'n': begin
      Literal := 'null'; JsonNodes[N].Kind := 'null';
      if JsonPeek = 't' then begin Literal := 'true'; JsonNodes[N].Kind := 'boolean'; end;
      if JsonPeek = 'f' then begin Literal := 'false'; JsonNodes[N].Kind := 'boolean'; end;
      if Copy(JsonText, JsonPos, Length(Literal)) <> Literal then JsonFail;
      JsonNodes[N].Value := Literal; JsonPos := JsonPos + Length(Literal);
    end;
  else
    Start := JsonPos; JsonNodes[N].Kind := 'number';
    if JsonPeek = '-' then JsonPos := JsonPos + 1;
    if JsonPeek = '0' then JsonPos := JsonPos + 1 else JsonDigits;
    if JsonPeek = '.' then begin JsonPos := JsonPos + 1; JsonDigits; end;
    if (JsonPeek = 'e') or (JsonPeek = 'E') then begin
      JsonPos := JsonPos + 1;
      if (JsonPeek = '+') or (JsonPeek = '-') then JsonPos := JsonPos + 1;
      JsonDigits;
    end;
    JsonNodes[N].Value := Copy(JsonText, Start, JsonPos - Start);
  end;
  JsonNodes[N].Last := JsonPos - 1; Result := N;
end;

procedure ParseJson(const Text: String);
var N: Integer;
begin
  if Length(Text) > 1048576 then JsonFail;
  JsonText := Text; JsonPos := 1; SetArrayLength(JsonNodes, 0);
  if (Length(Text) > 0) and (Text[1] = Chr($FEFF)) then JsonPos := 2;
  N := JsonValue(-1, '', 0); JsonSpace;
  if (JsonPos <> Length(JsonText) + 1) or (JsonNodes[0].Kind <> 'object') then JsonFail;
end;

function JsonChild(Parent: Integer; const Name, Kind: String): Integer;
var I: Integer;
begin
  Result := -1;
  for I := Parent + 1 to GetArrayLength(JsonNodes) - 1 do
    if (JsonNodes[I].Parent = Parent) and (CompareText(JsonNodes[I].Name, Name) = 0) then begin
      // .NET configuration binds keys case-insensitively. Refuse aliases of a
      // schema key instead of modifying a different value from the Service.
      if (Result >= 0) or (JsonNodes[I].Name <> Name) then JsonFail;
      Result := I;
    end;
  if Result < 0 then JsonFail;
  if JsonNodes[Result].Kind <> Kind then JsonFail;
end;

function JsonQuote(const Value: String): String;
var I: Integer; C: Char;
begin
  Result := '"';
  for I := 1 to Length(Value) do begin
    C := Value[I];
    if (C = '"') or (C = '\') then Result := Result + '\' + C
    else if Ord(C) < 32 then Result := Result + '\u' + Format('%.4x', [Ord(C)])
    else Result := Result + C;
  end;
  Result := Result + '"';
end;

function ConfigEndpoint(const Text: String): String;
var N: Integer;
begin
  ParseJson(Text); N := JsonChild(0, 'PublicAccess', 'object');
  N := JsonChild(N, 'ServerAddress', 'string'); Result := JsonNodes[N].Value;
end;

function UpdateEndpoint(const Text, Endpoint: String): String;
var N: Integer;
begin
  ParseJson(Text); N := JsonChild(0, 'PublicAccess', 'object');
  N := JsonChild(N, 'ServerAddress', 'string');
  Result := Copy(Text, 1, JsonNodes[N].First - 1) + JsonQuote(Endpoint) +
    Copy(Text, JsonNodes[N].Last + 1, Length(Text));
end;
