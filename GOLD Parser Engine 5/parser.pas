﻿{
  This software is provided 'as-is', without any expressed or implied warranty.
  In no event will the author(s) be held liable for any damages arising from
  the use of this software. Permission is granted to anyone to use this software
  for any purpose. If you use this software in a product, an acknowledgment
  in the product documentation would be deeply appreciated but is not required.

  In the case of the GOLD Parser Engine source code, permission is granted
  to anyone to alter it and redistribute it freely, subject to the following
  restrictions:

  - The origin of this software must not be misrepresented; you must not claim
    that you wrote the original software.
  - Altered source versions must be plainly marked as such, and must not be
    misrepresented as being the original software.
  - This notice may not be removed or altered from any source distribution

  Copyright © 2015 Theodore Tsirpanis
  Copyright © 2018 Aleg "Kryvich" Azarouski
}
unit Parser;

interface

uses
  Classes, SysUtils, Math, gold_types, Symbol, FAState, Token, Production,
  LRState, CharacterSet, Generics.Collections, CGT;

const
  ABOUT = 'About';
  AUTHOR = 'Author';
  CASE_SENSITIVE = 'Case Sensitive';
  CHARACTER_MAPPING = 'Character Mapping';
  CHARACTER_SET = 'Character Set';
  GENERATED_BY = 'Generated By';
  GENERATED_DATE = 'Generated Date';
  Name = 'Name';
  START_SYMBOL = 'Start Symbol';
  VERSION = 'Version';
  VERSION_1_HEADER = 'GOLD Parser Tables/1.0';
  VERSION_5_HEADER = 'GOLD Parser Tables/5.0';

type
  TStrStrMap = TDictionary<string, string>;

  { TAbstractGOLDParser }

  TAbstractGOLDParser = class
  private
    FAttributes: TStrStrMap;
    FCharSetTable: TCharacterSetList;
    FCurrentLALR: integer;
    FDFA: TFAStateList;
    FExpectedSyms: TSymbolList;
    FGroupStack: TTokenStack;
    FGroupTable: TGroupList;
    FHaveReduction, FTrimReductions, FTablesLoaded: boolean;
    FInputTokens: TTokenStack;
    FLookAheadBuffer: string;
    FLRStates: TLRStateList;
    FProdTable: TProductionList;
    FStack: TTokenStack;
    FStream: TMemoryStream;
    FSymTable: TSymbolList;
    FVersion1: boolean;
    SysPosition, FCurrentPosition: TPosition;
    procedure ConsumeBuffer(const c: integer);
    function GetAttribute(const s: string): UnicodeString; overload;
    function GetCurrentReduction: TReduction;
    function GetFirstSymbolOfType(const st: TSymbolType): TSymbol;
    function GetLookaheadBuffer(Count: integer): string;
    function LookAhead(const CharIndex: integer): string;
    function LookaheadDFA: TToken;
    function ParseLALR(const tok: TToken): TParseResult;
    procedure ResolveLegacyCommentGroups;
    procedure SetAttribute(const s: string; AValue: UnicodeString);
  protected
    function GetCurrentToken: TToken;
    function GetSymbolByName(const nm: string): TSymbol;
    function LoadTables(const filename: string): boolean; overload;
    function LoadTables(const s: TStream): boolean; overload;
    function LoadTablesFromResource(const Instance: TResourceHandle;
      const ResName: string; const ResType: PChar): boolean; overload;
    function NextToken: TToken; virtual;
    function OpenFile(const s: TFilename): boolean;
    function OpenStream(const s: TStream): boolean;
    function OpenString(const s: string): boolean;
    function Parse: TParseMessage;
    function ProduceToken: TToken;
    procedure Restart;
    procedure SetCurrentReduction(AValue: TReduction);
    property IsVersion1: boolean read FVersion1 write FVersion1;
  public
    constructor Create;
    destructor Destroy; override;
    function GetAttribute(const s: string;
      const df: UnicodeString): UnicodeString; overload;
    property Attribute[const s: string]: UnicodeString
      read GetAttribute write SetAttribute;
    property CurrentPosition: TPosition read FCurrentPosition;
    property CurrentReduction: TReduction read GetCurrentReduction;
    property CurrentToken: TToken read GetCurrentToken;
    property ExpectedSymbols: TSymbolList read FExpectedSyms;
    property TrimReductions: boolean read FTrimReductions write FTrimReductions;
  end;

implementation

uses
  StrUtils;

{ TAbstractGOLDParser }

procedure TAbstractGOLDParser.ConsumeBuffer(const c: integer);
var
  i: integer;
  cr: char;
begin
  if (c > 0) and (c <= Length(FLookAheadBuffer)) then
  begin
    for i := 1 to c do
    begin
      cr := FLookAheadBuffer[i];
      if cr = #10 then
      begin
        if SysPosition.Column > 1 then
          SysPosition.IncLine;
      end
      else
      if cr = #13 then
        SysPosition.IncLine
      else
        SysPosition.IncCol;
    end;
    Delete(FLookAheadBuffer, 1, c);
  end;
end;

function TAbstractGOLDParser.GetAttribute(const s: string): UnicodeString;
begin
  Result := GetAttribute(s, '');
end;


function TAbstractGOLDParser.GetCurrentReduction: TReduction;
begin
  if FHaveReduction then
    Result := FStack.Top.Reduction
  else
    Result := nil;
end;

function TAbstractGOLDParser.GetCurrentToken: TToken;
begin
  Result := FInputTokens.Top;
end;

function TAbstractGOLDParser.GetFirstSymbolOfType(const st: TSymbolType): TSymbol;
var
  sym: TSymbol;
begin
  Result := nil;
  for sym in FSymTable do
    if sym.SymbolType = st then
      Exit(sym);
end;

function TAbstractGOLDParser.GetLookaheadBuffer(Count: integer): string;
begin
  Count := Min(Length(FLookAheadBuffer), Count);
  if Count > 0 then
    Result := LeftStr(FLookAheadBuffer, Count)
  else
    Result := '';
end;

function TAbstractGOLDParser.LookAhead(const CharIndex: integer): string;
var
  ReadCount: integer;
  i: integer;
  c: byte;
begin
  Result := '';
  if CharIndex >= 0 then
  begin
    if CharIndex > Length(FLookAheadBuffer) then
    begin
      ReadCount := CharIndex - Length(FLookAheadBuffer);
      for i := 0 to ReadCount do
      begin
        if FStream.Read((@c)^, 1) = 0 then
          Break
        else
          FLookAheadBuffer := FLookAheadBuffer + char(c);
      end;
    end;
    if CharIndex <= Length(FLookAheadBuffer) then
      Result := FLookAheadBuffer[CharIndex];
  end;
end;

function TAbstractGOLDParser.LookaheadDFA: TToken;
var
  currdfa: integer;
  target: integer;
  lastaccpos: integer;
  lastaccept: integer;
  curpos: integer;
  str: string;
  done: boolean;
  found: boolean;
  i: integer;
  edg: TFAEdge;
begin
  Result := TToken.Create;
  currdfa := fdfa.InitialState;
  curpos := 1;
  lastaccept := -1;
  lastaccpos := -1;
  target := 0;
  str := LookAhead(1);
  Done := False;
  if Length(str) <> 0 then
    while not done do
    begin
      found := False;
      str := LookAhead(curpos);
      if Length(str) <> 0 then
      begin
        i := 0;
        while (not found) and (i < FDFA[currdfa].Edges.Count) do
        begin
          edg := FDFA.Items[currdfa].Edges[i];
          if edg.Chars.Contains(str[1]) then
          begin
            found := True;
            target := edg.Target;
          end;
          Inc(i);
        end;
      end;
      if found then
      begin
        if Assigned(FDFA[target].Accept) then
        begin
          lastaccept := target;
          lastaccpos := curpos;
        end;
        currdfa := target;
        Inc(curpos);
      end
      else
      begin
        done := True;
        if lastaccept = -1 then
        begin
          Result.AsSymbol := GetFirstSymbolOfType(stERROR);
          Result.Data := GetLookaheadBuffer(1);
        end
        else
        begin
          Result.AsSymbol := FDFA[lastaccept].Accept;
          Result.Data := GetLookaheadBuffer(lastaccpos);
        end;
      end;
    end
  else
  begin
    Result.Data := '';
    Result.AsSymbol := GetFirstSymbolOfType(stEND);
  end;
  Result.Position := TPosition.Create(SysPosition);
end;

function TAbstractGOLDParser.ParseLALR(const tok: TToken): TParseResult;
var
  pac, lra, act: TLRAction;
  prd: TProduction;
  Head: TToken;
  newred: TReduction;
  i: integer;
  idx: integer;
begin
  FHaveReduction := False;
  pac := FLRStates[FCurrentLALR].Find(tok);
  case pac.LRType of
    laACCEPT: begin
      FHaveReduction := True;
      Result := prACCEPT;
    end;
    laSHIFT: begin
      FCurrentLALR := pac.Value;
      tok.State := FCurrentLALR;
      FStack.Push(tok);
      Result := prSHIFT;
    end;
    laREDUCE: begin
      prd := FProdTable[pac.Value];
      if FTrimReductions and prd.HasOneNonTerminal then begin
        Head := FStack.Pop;
        Head.AsSymbol := prd.Head;
        Result := prREDUCE_ELIMINATED;
      end else begin
        FHaveReduction := True;
        newred := TReduction.Create;
        newred.Count := prd.Handle.Count;
        newred.Parent := prd;
        for i := prd.Handle.Count - 1 downto 0 do
          newred[i] := FStack.Pop;
        Head := TToken.Create(prd.Head, newred);
        Result := prREDUCE_NORMAL;
      end;
      idx := FStack.Top.State;
      lra := FLRStates[idx].Find(prd.Head);
      if not lra.Equals(TLRAction.Undefined) then begin
        FCurrentLALR := lra.Value;
        Head.State := FCurrentLALR;
        FStack.Push(Head);
      end else
        Result := prINTERNAL_ERROR;
    end;
    laERROR, laGOTO, laUndefined: begin
      FExpectedSyms.Clear;
      for act in FLRStates[FCurrentLALR] do
        if act.TheSymbol.SymbolType in [stCONTENT, stEND, stGROUP_START,
          stGROUP_END, stCOMMENT_LINE] then
          FExpectedSyms.Add(act.TheSymbol);
      Result := prSYNTAX_ERROR;
    end;
    else
      Result := prINTERNAL_ERROR;
  end;
end;

function TAbstractGOLDParser.GetSymbolByName(const nm: string): TSymbol;
var
  sym: TSymbol;
begin
  Result := nil;
  for sym in FSymTable do
    if SameText(sym.Name, nm) then
      Exit(sym);
end;

function TAbstractGOLDParser.LoadTables(const filename: string): boolean;
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(filename, fmOpenRead);
  try
    Result := LoadTables(fs);
  finally
    fs.Free;
  end;
end;

procedure TAbstractGOLDParser.SetAttribute(const s: string; AValue: UnicodeString);
begin
  FAttributes.Add(s, AValue);
end;

procedure TAbstractGOLDParser.SetCurrentReduction(AValue: TReduction);
begin
  if FHaveReduction then
    FStack.Top.Reduction := AValue;
end;

function TAbstractGOLDParser.LoadTables(const s: TStream): boolean;
var
  cs: TCharacterSet;
  cg: TCGT;
  RecType: byte;
  index: word;
  nm: UnicodeString;
  st: TSymbolType;
  smb: TSymbol;
  hindex: word;
  prd: TProduction;
  smindex: word;
  grp: TGroup;
  cnt: word;
  accept: boolean;
  acceptindex: word;
  setindex: word;
  target: word;
  i: integer;
  lrs: TLRState;
  lrat: TLRActionType;
  vl: word;
begin
  Result := True;
  cg := TCGT.Create;
  with cg do
    try
      cg.Open(s);
      Restart;
      FTablesLoaded := False;
      while Result do
      begin
        GetNextRecord;
        if EOF then
          Break;
        RecType := RetrieveByte;
        case TCGTRecord(RecType) of
          crPARAMETER:
          begin
            FVersion1 := True;
            Attribute[Name] := RetrieveString;
            Attribute[VERSION] := RetrieveString;
            Attribute[AUTHOR] := RetrieveString;
            Attribute[ABOUT] := RetrieveString;
            Attribute[CASE_SENSITIVE] := BoolToStr(RetrieveBoolean, True);
            Attribute[START_SYMBOL] := IntToStr(RetrieveInteger);
          end;
          crPROPERTY:
          begin
            FVersion1 := False;
            RetrieveInteger;
            Attribute[RetrieveString] := RetrieveString;
          end;
          crCOUNTS5,
          crCOUNTS:
          begin
            FSymTable.Count := RetrieveInteger;
            FCharSetTable.Count := RetrieveInteger;
            FProdTable.Count := RetrieveInteger;
            FDFA.Count := RetrieveInteger;
            FLRStates.Count := RetrieveInteger;
            if FVersion1 then
              FGroupTable.Count := 0
            else
              FGroupTable.Count := RetrieveInteger;
          end;
          crCHARSET:
          begin
            index := RetrieveInteger;
            cs := TCharacterSet.Create;
            FCharSetTable[index] := cs;
            cs.Add(TCharacterRange.Create(RetrieveString));
          end;
          crCHARRANGES:
          begin
            index := RetrieveInteger;
            RetrieveInteger;
            RetrieveInteger;
            RetrieveEntry;
            cs := TCharacterSet.Create;
            FCharSetTable[index] := cs;
            while not IsRecordComplete do
              cs.Add(TCharacterRange.Create(
                WideChar(RetrieveInteger), WideChar(RetrieveInteger)));
          end;
          crSYMBOL:
          begin
            index := RetrieveInteger;
            nm := RetrieveString;
            st := TSymbolType(RetrieveInteger);
            smb := TSymbol.Create(nm, st, index);
            FSymTable[index] := smb;
          end;
          crRULE:
          begin
            index := RetrieveInteger;
            hindex := RetrieveInteger;
            RetrieveEntry;
            prd := TProduction.Create(FSymTable[hindex], index);
            FProdTable[index] := prd;
            while not IsRecordComplete do
            begin
              smindex := RetrieveInteger;
              prd.Handle.Add(FSymTable[smindex]);
            end;
          end;
          crINITIALSTATES:
          begin
            FDFA.InitialState := RetrieveInteger;
            FLRStates.InitialState := RetrieveInteger;
          end;
          crGROUP:
          begin
            index := RetrieveInteger;
            grp := TGroup.Create;
            grp.Name := RetrieveString;
            grp.Container := FSymTable[RetrieveInteger];
            grp.Start := FSymTable[RetrieveInteger];
            grp._End := FSymTable[RetrieveInteger];
            grp.AdvanceMode := TAdvanceMode(RetrieveInteger);
            grp.EndingMode := TEndingMode(RetrieveInteger);
            RetrieveEntry;
            cnt := RetrieveInteger;
            for i := 0 to cnt - 1 do
              grp.Nesting.Add(RetrieveInteger);
            FGroupTable[index] := grp;
          end;
          crGROUPNESTING: ;
          crDFASTATE:
          begin
            index := RetrieveInteger;
            accept := RetrieveBoolean;
            acceptindex := RetrieveInteger;
            RetrieveEntry;
            if accept then
              FDFA[index] := TFAState.Create(FSymTable[acceptindex])
            else
              FDFA[index] := TFAState.Create(nil);
            while not IsRecordComplete do
            begin
              setindex := RetrieveInteger;
              target := RetrieveInteger;
              RetrieveEntry;
              FDFA.Items[index].Edges.Add(
                TFAEdge.Create(FCharSetTable[setindex], target));
            end;
          end;
          crLRSTATE:
          begin
            index := RetrieveInteger;
            RetrieveEntry;
            lrs := TLRState.Create;
            FLRStates[index] := lrs;
            while not IsRecordComplete do
            begin
              smb := FSymTable[RetrieveInteger];
              lrat := TLRActionType(RetrieveInteger);
              vl := RetrieveInteger;
              RetrieveEntry;
              lrs.Add(TLRAction.Create(smb, lrat, vl));
            end;
          end;
          else
            raise EParserException.CreateFmt('Undefined type (%u) was read', [RecType]);
        end;
      end;
    finally
      cg.Close;
      cg.Free;
    end;
  FTablesLoaded := Result;
  ResolveLegacyCommentGroups;
end;

function TAbstractGOLDParser.LoadTablesFromResource(const Instance: TResourceHandle;
  const ResName: string; const ResType: PChar): boolean;
var
  rst: TResourceStream;
begin
  rst := TResourceStream.Create(Instance, ResName, ResType);
  try
    Result := OpenStream(rst);
  finally
    rst.Free;
  end;
end;

function TAbstractGOLDParser.NextToken: TToken;
begin
  Result := ProduceToken;
end;

function TAbstractGOLDParser.OpenFile(const s: TFilename): boolean;
var
  strm: TFileStream;
begin
  strm := TFileStream.Create(s, fmOpenRead);
  try
    Result := OpenStream(strm);
  finally
    strm.Free;
  end;
end;

function TAbstractGOLDParser.OpenStream(const s: TStream): boolean;
begin
  Restart;
  FStream.Clear;
  FStream.LoadFromStream(s);
  FStack.Push(TToken.Create);
  Result := True;
end;

function TAbstractGOLDParser.OpenString(const s: string): boolean;
var
  strm: TStringStream;
begin
  strm := TStringStream.Create(s);
  try
    Result := OpenStream(strm);
  finally
    strm.Free;
  end;
end;

function TAbstractGOLDParser.Parse: TParseMessage;
var
  Read: TToken;
  Done: boolean;
begin
  Result := pmINTERNAL_ERROR;
  Done := False;
  if not FTablesLoaded then
    Exit(pmNOT_LOADED_ERROR);
  while not Done do begin
    if FInputTokens.Count = 0 then begin
      Read := NextToken;
      FInputTokens.Push(Read);
      if (Read.SymbolType = stEND) and (FGroupStack.Count > 0) then
        Result := pmGROUP_ERROR
      else
        Result := pmTOKEN_READ;
      Done := True;
    end else begin
      Read := FInputTokens.Top;
      FCurrentPosition := TPosition.Create(Read.Position);
      if (Read.SymbolType = stEND) and (FGroupStack.Count > 0) then begin
        Result := pmGROUP_ERROR;
        Done := True;
      end else
        case Read.SymbolType of
          stNOISE: FInputTokens.Pop;
          stERROR: begin
            Result := pmLEXICAL_ERROR;
            Done := True;
          end;
          else
            case ParseLALR(Read) of
              prACCEPT:
              begin
                Result := pmACCEPT;
                Done := True;
              end;
              prSHIFT: FInputTokens.MemberList.Delete(0);
              prREDUCE_NORMAL:
              begin
                Result := pmREDUCTION;
                Done := True;
              end;
              prSYNTAX_ERROR:
              begin
                Result := pmSYNTAX_ERROR;
                Done := True;
              end;
              prINTERNAL_ERROR:
              begin
                Result := pmINTERNAL_ERROR;
                Done := True;
              end;
            end;
        end;
    end;
  end;
end;

function TAbstractGOLDParser.ProduceToken: TToken;
var
  Done: boolean;
  NestGroup: boolean;
  rd: TToken;
  pop: TToken;
  top: TToken;
begin
  Result := nil;
  Done := False;
  while not Done do begin
    rd := LookaheadDFA;
    // Groups (comments, etc.)
    // The logic - to determine if a group should be nested - requires that the top
    // of the stack and the symbol's linked group need to be looked at. Both of these
    // can be unset. So, this section sets a boolean and avoids errors. We will use
    // this boolean in the logic chain below.
    if rd.SymbolType in [stGROUP_START, stCOMMENT_LINE] then
      if FGroupStack.Count = 0 then
        NestGroup := True
      else
        NestGroup := FGroupStack.Top.SymbolGroup.Nesting.Contains(
          rd.SymbolGroup.Index)
    else
      NestGroup := False;
    // Logic chain
    if NestGroup then begin
      ConsumeBuffer(Length(rd.ToString));
      // fix up the comment block
      if rd.Data <> '' then begin
        rd.AppendData(rd.Data);
        rd.Data := '';
      end;
      FGroupStack.Push(rd);
    end else if FGroupStack.Count = 0 then begin
      ConsumeBuffer(Length(rd.ToString));
      Result := rd;
      Done := True;
    end else if FGroupStack.Top.SymbolGroup._End.TableIndex = rd.TableIndex then begin
      pop := FGroupStack.Pop;
      if pop.SymbolGroup.EndingMode = emClosed then begin
        pop.AppendData(rd.ToString);
        ConsumeBuffer(Length(rd.ToString));
      end;
      if FGroupStack.Count = 0 then begin
        pop.AsSymbol := pop.SymbolGroup.Container;
        Result := pop;
        Done := True;
      end else
        FGroupStack.Top.AppendData(pop.ToString);
    end else if rd.SymbolType = stEND then begin
      Result := rd;
      Done := True;
    end else begin
      top := FGroupStack.Top;
      if top.SymbolGroup.AdvanceMode = amToken then begin
        top.AppendData(rd.ToString);
        ConsumeBuffer(Length(rd.ToString));
      end else begin
        top.AppendData(rd.ToString[1]);
        ConsumeBuffer(1);
      end;
    end;
  end;
end;

procedure TAbstractGOLDParser.ResolveLegacyCommentGroups;
var
  grp: TGroup;
  smstart, smend, si, sei: TSymbol;
begin
  if FVersion1 then begin
    for si in FSymTable do
      if si.SymbolType = stCOMMENT_LINE then begin
        smstart := si;
        grp := TGroup.Create;
        grp.Name := 'Comment Line';
        grp.Container := FSymTable.FindByName(SYMBOL_COMMENT);
        grp.Start := smstart;
        grp._End := FSymTable.FindByName('NewLine');
        grp.AdvanceMode := amToken;
        grp.EndingMode := emOpen;
        FGroupTable.Add(grp);
        smstart.SymbolGroup := grp;
        Break;
      end;

    for si in FSymTable do
      if si.SymbolType = stGROUP_START then
      begin
        smstart := si;
        smend := si;
        for sei in FSymTable do
          if sei.SymbolType = stGROUP_END then
          begin
            smend := sei;
            Break;
          end;
        grp := TGroup.Create;
        grp.Name := 'Comment Block';
        grp.Container := FSymTable.FindByName(SYMBOL_COMMENT);
        grp.Start := smstart;
        grp._End := smend;
        grp.AdvanceMode := amToken;
        grp.EndingMode := emClosed;
        FGroupTable.Add(grp);
        smstart.SymbolGroup := grp;
        smend.SymbolGroup := grp;
        Break;
      end;
  end;
end;

procedure TAbstractGOLDParser.Restart;
begin
  FCurrentLALR := FLRStates.InitialState;
  SysPosition := TPosition.Create;
  FCurrentPosition := TPosition.Create;
  FLookAheadBuffer := '';
  FHaveReduction := False;
  FExpectedSyms.Clear;
  FGroupStack.Clear;
  FInputTokens.Clear;
  FStack.Clear;
end;

constructor TAbstractGOLDParser.Create;
begin
  inherited Create;
  FStream := TMemoryStream.Create;
  FVersion1 := False;
  FLookAheadBuffer := '';
  FHaveReduction := False;
  FTrimReductions := False;
  FTablesLoaded := False;
  SysPosition := TPosition.Create;
  FCurrentPosition := TPosition.Create;
  FSymTable := TSymbolList.Create;
  FDFA := TFAStateList.Create;
  FCharSetTable := TCharacterSetList.Create;
  FProdTable := TProductionList.Create;
  FLRStates := TLRStateList.Create;
  FCurrentLALR := 0;
  FStack := TTokenStack.Create;
  FExpectedSyms := TSymbolList.Create(False);
  FInputTokens := TTokenStack.Create;
  FAttributes := TStrStrMap.Create;
  FGroupStack := TTokenStack.Create;
  FGroupTable := TGroupList.Create;
end;

destructor TAbstractGOLDParser.Destroy;
begin
  FStream.Free;
  FSymTable.Free;
  FDFA.Free;
  FCharSetTable.Free;
  FProdTable.Free;
  FLRStates.Free;
  FStack.Free;
  FExpectedSyms.Free;
  FInputTokens.Free;
  FAttributes.Free;
  FGroupStack.Free;
  FGroupTable.Free;
  inherited Destroy;
end;

function TAbstractGOLDParser.GetAttribute(const s: string;
  const df: UnicodeString): UnicodeString;
begin
  if FAttributes.ContainsKey(s) then
    Result := FAttributes.Items[s]
  else
    Result := df;
end;

end.
