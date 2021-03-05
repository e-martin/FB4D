{******************************************************************************}
{                                                                              }
{  Delphi FB4D Library                                                         }
{  Copyright (c) 2018-2021 Christoph Schneider                                 }
{  Schneider Infosystems AG, Switzerland                                       }
{  https://github.com/SchneiderInfosystems/FB4D                                }
{                                                                              }
{******************************************************************************}
{                                                                              }
{  Licensed under the Apache License, Version 2.0 (the "License");             }
{  you may not use this file except in compliance with the License.            }
{  You may obtain a copy of the License at                                     }
{                                                                              }
{      http://www.apache.org/licenses/LICENSE-2.0                              }
{                                                                              }
{  Unless required by applicable law or agreed to in writing, software         }
{  distributed under the License is distributed on an "AS IS" BASIS,           }
{  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.    }
{  See the License for the specific language governing permissions and         }
{  limitations under the License.                                              }
{                                                                              }
{******************************************************************************}

unit FB4D.FireStore.Listener;

interface

uses
  System.Types, System.Classes, System.SysUtils, System.Generics.Collections,
  System.NetConsts, System.Net.HttpClient, System.Net.URLClient,
  System.NetEncoding, System.SyncObjs,
  FB4D.Interfaces, FB4D.Helpers;

type
  TTargetKind = (tkDocument, tkQuery);
  TTarget = record
    TargetID: cardinal;
    OnChangedDoc: TOnChangedDocument;
    OnDeletedDoc: TOnDeletedDocument;
    TargetKind: TTargetKind;
    //  tkDocument:
    DocumentPath: string;
    // tkQuery:
    QueryJSON: string;
  end;

  TListenerThread = class(TThread)
  private const
    cWaitTimeBeforeReconnect = 5000; // 5 sec
    cDefTimeOutInMS = 500;
  private
    fDatabase: string;
    fAuth: IFirebaseAuthentication;
    // For ListenForValueEvents
    fLastTokenRefreshCount: cardinal;
    fSID, fGSessionID: string;
    fRequestID: string;
    fClient: THTTPClient;
    fAsyncResult: IAsyncResult;
    fGetFinishedEvent: TEvent;
    fStream: TMemoryStream;
    fReadPos: Int64;
    fMsgSize: integer;
    fOnStopListening: TOnStopListenEvent;
    fOnListenError: TOnRequestError;
    fOnAuthRevoked: TOnAuthRevokedEvent;
    fLastKeepAliveMsg: TDateTime;
    fRequireTokenRenew: boolean;
    fCloseRequest: boolean;
    fStopWaiting: boolean;
    fPartialResp: string;
    fLastTelegramNo: integer;
    fTargets: TList<TTarget>;
    function GetTargetIndById(TargetID: cardinal): integer;
    function GetRequestData: string;
    procedure InitListen(NewSIDRequest: boolean = false);
    function RequestSIDInThread: boolean;
    function SearchNextMsg: string;
    procedure Parser;
    procedure Interprete(const Telegram: string);
    procedure ReportErrorInThread(const ErrMsg: string);
    procedure OnRecData(const Sender: TObject; ContentLength, ReadCount: Int64;
      var Abort: Boolean);
    procedure OnEndListenerGet(const ASyncResult: IAsyncResult);
    procedure OnEndThread(Sender: TObject);
  protected
    procedure Execute; override;
  public
    constructor Create(const ProjectID, DatabaseID: string;
      Auth: IFirebaseAuthentication);
    destructor Destroy; override;
    procedure RegisterEvents(OnStopListening: TOnStopListenEvent;
      OnError: TOnRequestError; OnAuthRevoked: TOnAuthRevokedEvent);
    procedure StopListener(TimeOutInMS: integer = cDefTimeOutInMS);
    function IsRunning: boolean;
    function SubscribeDocument(DocumentPath: TRequestResourceParam;
      OnChangedDoc: TOnChangedDocument;
      OnDeletedDoc: TOnDeletedDocument): cardinal;
    function SubscribeQuery(Query: IStructuredQuery;
      OnChangedDoc: TOnChangedDocument;
      OnDeletedDoc: TOnDeletedDocument): cardinal;
    procedure Unsubscribe(TargetID: cardinal);
  end;

implementation

uses
  System.JSON, System.StrUtils,
  REST.Types,
  FB4D.Document, FB4D.Response, FB4D.Request;

{$DEFINE ParserLog}
{$DEFINE ParserLogDetails}

const
  cBaseURL = 'https://firestore.googleapis.com/google.firestore.v1.Firestore';
  cResourceParams: TRequestResourceParam = ['Listen', 'channel'];
  cVER = '8';
  cCVER = '22';
  cHttpHeaders =
    'X-Goog-Api-Client:gl-js/ file(8.2.3'#13#10'Content-Type:text/plain';

resourcestring
  rsEvtListenerFailed = 'Event listener failed: %s';
  rsEvtStartFailed = 'Event listener start failed: %s';
  rsEvtParserFailed = 'Exception in listener: ';
  rsParserFailed = 'Exception in event parser: ';
  rsInterpreteFailed = 'Exception in event interpreter: ';
  rsUnknownStatus = 'Unknown status msg %d: %s';

{ TListenerThread }

constructor TListenerThread.Create(const ProjectID, DatabaseID: string;
  Auth: IFirebaseAuthentication);
var
  EventName: string;
begin
  inherited Create(true);
  Assert(assigned(Auth), 'Authentication not initalized');
  fAuth := Auth;
  fDatabase := 'projects/' + ProjectID + '/databases/' + DatabaseID;
  fTargets := TList<TTarget>.Create;
  {$IFDEF WINDOWS}
  EventName := 'FB4DListenerGetFini';
  {$ELSE}
  EventName := '';
  {$ENDIF}
  fGetFinishedEvent := TEvent.Create(nil, false, false, EventName);
  OnTerminate := OnEndThread;
  FreeOnTerminate := true;
  {$IFNDEF LINUX64}
  NameThreadForDebugging('FB4D.Firestore.ListenerThread', ThreadID);
  {$ENDIF}
end;

destructor TListenerThread.Destroy;
begin
  FreeAndNil(fGetFinishedEvent);
  FreeAndNil(fTargets);
  inherited;
end;

function TListenerThread.SubscribeDocument(
  DocumentPath: TRequestResourceParam; OnChangedDoc: TOnChangedDocument;
  OnDeletedDoc: TOnDeletedDocument): cardinal;
var
  Target: TTarget;
begin
  if IsRunning then
    raise EFirestoreListener.Create(
      'SubscribeDocument must not be called for started Listener');
  Target.TargetID := (fTargets.Count + 1) * 2;
  Target.TargetKind := TTargetKind.tkDocument;
  Target.DocumentPath := TFirebaseHelpers.EncodeResourceParams(DocumentPath);
  Target.QueryJSON := '';
  Target.OnChangedDoc := OnChangedDoc;
  Target.OnDeletedDoc := OnDeletedDoc;
  fTargets.Add(Target);
  result := Target.TargetID;
end;

function TListenerThread.SubscribeQuery(Query: IStructuredQuery;
  OnChangedDoc: TOnChangedDocument; OnDeletedDoc: TOnDeletedDocument): cardinal;
var
  Target: TTarget;
  JSONobj: TJSONObject;
begin
  if IsRunning then
    raise EFirestoreListener.Create(
      'SubscribeQuery must not be called for started Listener');
  Target.TargetID := (fTargets.Count + 1) * 2;
  Target.TargetKind := TTargetKind.tkQuery;
  JSONobj := Query.AsJSON;
  JSONobj.AddPair('parent', fDatabase + '/documents');
  Target.QueryJSON := JSONobj.ToJSON;
  Target.DocumentPath := '';
  Target.OnChangedDoc := OnChangedDoc;
  Target.OnDeletedDoc := OnDeletedDoc;
  fTargets.Add(Target);
  result := Target.TargetID;
end;

procedure TListenerThread.Unsubscribe(TargetID: cardinal);
var
  c: integer;
begin
  if IsRunning then
    raise EFirestoreListener.Create(
      'Unsubscribe must not be called for started Listener');
  c := GetTargetIndById(TargetID);
  if c >= 0 then
    fTargets.Delete(c);
end;

function TListenerThread.GetTargetIndById(TargetID: cardinal): integer;
var
  c: integer;
begin
  for c := 0 to fTargets.Count - 1 do
    if fTargets[c].TargetID = TargetID then
      exit(c);
  result := -1;
end;

function TListenerThread.GetRequestData: string;
const
  // Count=1
  // ofs=0
  // req0___data__={"database":"projects/<ProjectID>/databases/(default)",
  // "addTarget":{"documents":{"documents":["projects/<ProjectID>/databases/(default)/documents/<DBPath>"]},
  // "targetId":2}}
  cDocumentTemplate =
    '{"database":"%0:s",' +
     '"addTarget":{' +
       '"documents":' +
         '{"documents":["%0:s/documents%1:s"]},' +
       '"targetId":%2:d}}';
  cQueryTemplate =
    '{"database":"%0:s",' +
     '"addTarget":{' +
       '"query":%1:s,' +
       '"targetId":%2:d}}';
  cHead = 'count=%d&ofs=0';
  cTarget= '&req%d___data__=%s';
var
  Target: TTarget;
  ind: cardinal;
  JSON: string;
begin
  ind := 0;
  result := Format(cHead, [fTargets.Count]);
  for Target in fTargets do
  begin
    case Target.TargetKind of
      tkDocument:
        JSON := Format(cDocumentTemplate,
          [fDatabase, Target.DocumentPath, Target.TargetID]);
      tkQuery:
        begin
          JSON := Format(cQueryTemplate,
            [fDatabase, Target.QueryJSON, Target.TargetID]);
          {$IFDEF ParserLogDetails}
          TFirebaseHelpers.Log('Query: ' + JSON);
          {$ENDIF}
        end;
    end;
    result := result + Format(cTarget, [ind, TNetEncoding.URL.Encode(JSON)]);
    inc(ind);
  end;
end;

procedure TListenerThread.Interprete(const Telegram: string);

  procedure HandleDocChanged(DocChangedObj: TJsonObject);
  var
    DocObj: TJsonObject;
    TargetIds: TJsonArray;
    c, ind: integer;
    Doc: IFirestoreDocument;
  begin
    DocObj := DocChangedObj.GetValue('document') as TJsonObject;
    TargetIds := DocChangedObj.GetValue('targetIds') as TJsonArray;
    Doc := TFirestoreDocument.CreateFromJSONObj(DocObj);
    try
      for c := 0 to TargetIds.Count - 1 do
      begin
        ind := GetTargetIndById(TargetIds.Items[c].AsType<integer>);
        if (ind >= 0) and assigned(fTargets[ind].OnChangedDoc) then
        begin
          TThread.Synchronize(nil,
            procedure
            begin
              fTargets[ind].OnChangedDoc(Doc);
            end);
        end;
      end;
    finally
      Doc := nil;
    end;
  end;

  function HandleDocDeleted(DocDeletedObj: TJsonObject): boolean;
  var
    DocPath: string;
    TargetIds: TJsonArray;
    TimeStamp: TDateTime;
    c, ind: integer;
  begin
    result := false;
    DocPath := DocDeletedObj.GetValue<string>('document');
    TimeStamp := DocDeletedObj.GetValue<TDateTime>('readTime');
    TargetIds := DocDeletedObj.GetValue('removedTargetIds') as TJsonArray;
    for c := 0 to TargetIds.Count - 1 do
    begin
      ind := GetTargetIndById(TargetIds.Items[c].AsType<integer>);
      if (ind >= 0) and assigned(fTargets[ind].OnDeletedDoc) then
        TThread.Queue(nil,
          procedure
          begin
            fTargets[ind].OnDeletedDoc(DocPath, TimeStamp);
          end);
    end;
  end;

  procedure HandleErrorStatus(ErrObj: TJsonObject);
  var
    ErrCode: integer;
  begin
    ErrCode := (ErrObj.GetValue('code') as TJSONNumber).AsInt;
    case ErrCode of
      401: // Missing or invalid authentication
        fRequireTokenRenew := true;
      else
        ReportErrorInThread(Format(rsUnknownStatus, [ErrCode, Telegram]));
    end;
  end;

const
  cKeepAlive = '"noop"';
  cClose = '"close"';
  cDocChange = 'documentChange';
  cDocDelete = 'documentDelete';
  cDocRemove = 'documentRemove';
  cTargetChange = 'targetChange';
  cFilter = 'filter';
  cStatusMessage = '__sm__';
var
  Obj: TJsonObject;
  ObjName: string;
  StatusArr, StatusArr2: TJSONArray;
  c, d: integer;
begin
  try
    {$IFDEF ParserLog}
    TFirebaseHelpers.Log('Telegram[' + fLastTelegramNo.ToString + ']' + Telegram);
    {$ENDIF}
    if Telegram = cKeepAlive then
      fLastKeepAliveMsg := now
    else if Telegram = cClose then
      fCloseRequest := true
    else if Telegram.StartsWith('{') and Telegram.EndsWith('}') then
    begin
      Obj := TJSONObject.ParseJSONValue(Telegram) as TJSONObject;
      try
        ObjName := Obj.Pairs[0].JsonString.Value;
        if ObjName = cTargetChange then
          // TargetChanged(Obj.Pairs[0].JsonValue as TJsonObject)
        else if ObjName = cFilter then
          // Filter(Obj.Pairs[0].JsonValue as TJsonObject)
        else if ObjName = cDocChange then
          HandleDocChanged(Obj.Pairs[0].JsonValue as TJsonObject)
        else if (ObjName = cDocDelete) or (ObjName = cDocRemove) then
          HandleDocDeleted(Obj.Pairs[0].JsonValue as TJsonObject)
        else if ObjName = cStatusMessage then
        begin
          StatusArr := (Obj.Pairs[0].JsonValue as TJsonObject).
            GetValue('status') as TJSONArray;
          for c := 0 to StatusArr.Count - 1 do
          begin
            StatusArr2 := StatusArr.Items[c] as TJSONArray;
            for d := 0 to StatusArr2.Count - 1 do
              HandleErrorStatus(
                StatusArr2.Items[c].GetValue<TJsonObject>('error'));
          end;
        end else
          raise EFirestoreListener.Create('Unknown JSON telegram: ' + Telegram);
      finally
        Obj.Free;
      end;
    end else
      raise EFirestoreListener.Create('Unknown telegram: ' + Telegram);
  except
    on e: exception do
      ReportErrorInThread(rsInterpreteFailed + e.Message);
  end;
end;

function TListenerThread.IsRunning: boolean;
begin
  result := Started and not Finished;
end;

function TListenerThread.SearchNextMsg: string;

  function GetNextLine(const Line: string; out NextResp: string): string;
  const
    cLineFeed = #10;
  var
    p: integer;
  begin
    p := Pos(cLineFeed, Line);
    if p > 1 then
    begin
      result := copy(Line, 1, p - 1);
      NextResp := copy(Line, p + 1);
    end else
      result := '';
  end;

var
  NextResp: string;
begin
  fMsgSize := StrToIntDef(GetNextLine(fPartialResp, NextResp), -1);
  if (fMsgSize >= 0) and (NextResp.Length >= fMsgSize) then
  begin
    result := copy(NextResp, 1, fMsgSize);
    fPartialResp := copy(NextResp, fMsgSize + 1);
    {$IFDEF ParserLog}
    if not fPartialResp.IsEmpty then
      TFirebaseHelpers.Log('Rest line after SearchNextMsg: ' + fPartialResp);
    {$ENDIF}
  end else
    result := '';
end;

procedure TListenerThread.Parser;

  procedure ParseNextMsg(const msg: string);

    function FindTelegramStart(var Line: string): integer;
    var
      p: integer;
    begin
      // Telegram start with '[' + MsgNo.ToString+ ',['
      if not Line.StartsWith('[') then
        raise EFirestoreListener.Create('Invalid telegram start: ' + Line);
      p := 2;
      while (p < Line.Length) and (Line[p] <> ',') do
        inc(p);
      if Copy(Line, p, 2) = ',[' then
      begin
        result := StrToIntDef(copy(Line, 2, p - 2), -1);
        Line := Copy(Line, p + 2);
      end
      else if Copy(Line, p, 2) = ',{' then
      begin
        result := StrToIntDef(copy(Line, 2, p - 2), -1);
        Line := Copy(Line, p + 1); // Take { into telegram
      end else
        raise EFirestoreListener.Create('Invalid telegram received: ' + Line);
    end;

    function FindNextTelegram(var Line: string): string;
    var
      p, BracketLevel, BraceLevel: integer;
      InString, EndFlag: boolean;
    begin
      Assert(Line.Length > 2, 'Too short telegram: ' + Line);
      BracketLevel := 0;
      BraceLevel := 0;
      InString := false;
      if Line[1] = '[' then
        BracketLevel := 1
      else if Line[1] = '{' then
        BraceLevel := 1
      else if Line[1] = '"' then
        InString := true
      else
        raise EFirestoreListener.Create('Invalid telegram start char: ' + Line);
      EndFlag := false;
      p := 2;
      result := Line[1];
      while p < Line.Length do
      begin
        if (Line[p] = '"') and (Line[p - 1] <> '\') then
        begin
          InString := not InString;
          if (Line[1] = '"') and not InString then
            EndFlag := true;
        end
        else if not InString then
        begin
          if Line[p] = '{' then
            inc(BraceLevel)
          else if Line[p] = '}' then
          begin
            dec(BraceLevel);
            if (BraceLevel = 0) and (Line[1] = '{') then
              EndFlag := true;
          end
          else if Line[p] = '[' then
            inc(BracketLevel)
          else if Line[p] = ']' then
          begin
            dec(BracketLevel);
            if (BracketLevel = 0) and (Line[1] = '[') then
              EndFlag := true;
          end;
        end;
        if InString or (Line[p] <> #10) then
          result := result + Line[p];
        inc(p);
        if EndFlag then
        begin
          if Line[p] = #10 then
            Line := Copy(Line, p + 1)
          else
            Line := Copy(Line, p);
          exit;
        end;
      end;
      raise EFirestoreListener.Create('Invalid telegram end received: ' + Line);
    end;

  var
    msgNo: integer;
    Line, Telegram: string;
  begin
    {$IFDEF ParserLogDetails}
    TFirebaseHelpers.Log('Parser: ' + msg);
    {$ENDIF}
    if not(msg.StartsWith('[') and msg.EndsWith(']')) then
      raise EFirestoreListener.Create('Invalid packet received: ' + msg);
    Line := copy(msg, 2, msg.Length - 2);
    repeat
      MsgNo := FindTelegramStart(Line);
      if MsgNo > fLastTelegramNo then
      begin
        fLastTelegramNo := MsgNo;
        Interprete(FindNextTelegram(Line));
      end else begin
        Telegram := FindNextTelegram(Line);
        {$IFDEF ParserLog}
        TFirebaseHelpers.Log('Ignore obsolete telegram ' + MsgNo.ToString + ': ' +
          Telegram);
        {$ENDIF}
      end;
      if not Line.EndsWith(']]') then
        raise EFirestoreListener.Create('Invalid telegram end received: ' + Line);
      if (Line.length > 4) and (Line[3] = ',') then
        Line := Copy(Line, 4)
      else
        Line := Copy(Line, 3);
    until Line.IsEmpty;
  end;

var
  msg: string;
begin
  if TFirebaseHelpers.AppIsTerminated then
    exit;
  try
    repeat
      msg := SearchNextMsg;
      if not msg.IsEmpty then
        ParseNextMsg(msg);
    until msg.IsEmpty;
  except
    on e: exception do
      ReportErrorInThread(rsParserFailed + e.Message);
  end;
end;

procedure TListenerThread.ReportErrorInThread(const ErrMsg: string);
begin
  if assigned(fOnListenError) and not TFirebaseHelpers.AppIsTerminated then
    TThread.Queue(nil,
      procedure
      begin
        fOnListenError(fRequestID, ErrMsg);
      end)
  else
    TFirebaseHelpers.Log('Error in Firestore listener: ' + ErrMsg);
end;

procedure TListenerThread.InitListen(NewSIDRequest: boolean);
begin
  fReadPos := 0;
  fLastKeepAliveMsg := 0;
  fRequireTokenRenew := false;
  fCloseRequest := false;
  fStopWaiting := false;
  fMsgSize := -1;
  fPartialResp := '';
  if newSIDRequest then
  begin
    fLastTelegramNo := 0;
    fSID := '';
    fGSessionID := '';
  end;
end;

function TListenerThread.RequestSIDInThread: boolean;

  function FetchSIDFromResponse(Response: IFirebaseResponse): boolean;
  // 51
  // [[0,["c","XrzGTQGX9ETvyCg6j6Rjyg","",8,12,30000]]]
  const
    cBeginPattern = '[[0,[';
    cEndPattern = ']]]'#10;
  var
    RespElement: TStringDynArray;
    Resp: string;
  begin
    fPartialResp := Response.ContentAsString;
    Resp := SearchNextMsg;
    fPartialResp := '';
    if not Resp.StartsWith(cBeginPattern) then
      raise EFirestoreListener.Create('Invalid SID response start: ' + Resp);
    if not Resp.EndsWith(cEndPattern) then
      raise EFirestoreListener.Create('Invalid SID response end: ' + Resp);
    Resp := copy(Resp, cBeginPattern.Length + 1,
     Resp.Length - cBeginPattern.Length - cEndPattern.Length);
    RespElement := SplitString(Resp, ',');
    if length(RespElement) < 2 then
      raise EFirestoreListener.Create('Invalid SID response array size: ' + Resp);
    fSID := RespElement[1];
    if (fSID.Length < 24) or
      not(fSID.StartsWith('"') and fSID.EndsWith('"')) then
      raise EFirestoreListener.Create('Invalid SID ' + fSID + ' response : ' + Resp);
    fSID := copy(fSID, 2, fSID.Length - 2);
    fGSessionID := Response.HeaderValue('x-http-session-id');
    {$IFDEF ParserLog}
    TFirebaseHelpers.Log('RequestSID: ' + fSID + ', ' + fGSessionID);
    {$ENDIF}
    result := true;
  end;

var
  Request: IFirebaseRequest;
  DataStr: TStringStream;
  QueryParams: TQueryParams;
  Response: IFirebaseResponse;
begin
  result := false;
  InitListen(true);
  try
    Request := TFirebaseRequest.Create(cBaseURL, fRequestID, fAuth);
    DataStr := TStringStream.Create(GetRequestData);
    QueryParams := TQueryParams.Create;
    try
      QueryParams.Add('database', [fDatabase]);
      QueryParams.Add('VER', [cVER]);
      QueryParams.Add('RID', ['0']);
      QueryParams.Add('CVER', [cCVER]);
      QueryParams.Add('X-HTTP-Session-Id', ['gsessionid']);
      QueryParams.Add('$httpHeaders', [cHttpHeaders]);

//      QueryParams.Add('zx', [copy(TFirebaseHelpers.CreateAutoID, 1, 12)]);
//      QueryParams.Add('t', ['2']);

      Response := Request.SendRequestSynchronous(cResourceParams, rmPost,
        DataStr, TRESTContentType.ctTEXT_PLAIN, QueryParams, tmBearer);
      if Response.StatusOk then
      begin
        fLastTokenRefreshCount := fAuth.GetTokenRefreshCount;
        result := FetchSIDFromResponse(Response);
      end else
        ReportErrorInThread(Format(rsEvtStartFailed, [Response.StatusText]));
    finally
      QueryParams.Free;
      DataStr.Free;
    end;
  except
    on e: exception do
      ReportErrorInThread(Format(rsEvtStartFailed, [e.Message]));
  end;
end;

procedure TListenerThread.Execute;
var
  URL: string;
  QueryParams: TQueryParams;
  WasTokenRefreshed: boolean;
begin
  InitListen(true);
  QueryParams := TQueryParams.Create;
  try
    while not TThread.CurrentThread.CheckTerminated and not fStopWaiting do
    begin
      if assigned(fAuth) then
        WasTokenRefreshed :=
          fAuth.GetTokenRefreshCount > fLastTokenRefreshCount
      else
        WasTokenRefreshed := false;
      if fGSessionID.IsEmpty or WasTokenRefreshed or fCloseRequest then
      begin
        if not RequestSIDInThread then
          fStopWaiting := true; // Terminate listener
      end else
        InitListen;
      fStream := TMemoryStream.Create;
      fClient := THTTPClient.Create;
      try
        fClient.HandleRedirects := true;
        fClient.Accept := '*/*';
        fClient.OnReceiveData := OnRecData;
        QueryParams.Clear;
        QueryParams.Add('database', [fDatabase]);
        QueryParams.Add('gsessionid', [fGSessionID]);
        QueryParams.Add('VER', [cVER]);
        QueryParams.Add('RID', ['rpc']);
        QueryParams.Add('SID', [fSID]);
        QueryParams.Add('AID', [fLastTelegramNo.ToString]);
        QueryParams.Add('TYPE', ['xmlhttp']);

//            QueryParams.Add('CI', ['0']);
//            QueryParams.Add('zx', [copy(TFirebaseHelpers.CreateAutoID, 1, 12)]);
//            QueryParams.Add('t', ['1']);

        URL := cBaseURL +
          TFirebaseHelpers.EncodeResourceParams(cResourceParams) +
          TFirebaseHelpers.EncodeQueryParams(QueryParams);
        {$IFDEF ParserLog}
        TFirebaseHelpers.Log('Get: [' + fLastTelegramNo.ToString + '] ' + URL);
        {$ENDIF}
        fAsyncResult := fClient.BeginGet(OnEndListenerGet, URL, fStream);
        fGetFinishedEvent.WaitFor;
        if fCloseRequest and not (fStopWaiting or fRequireTokenRenew) then
        begin
          {$IFDEF ParserLog}
          TFirebaseHelpers.Log('Listener wait before reconnect');
          {$ENDIF}
          Sleep(cWaitTimeBeforeReconnect);
        end;
      except
        on e: exception do
        begin
          ReportErrorInThread(Format(rsEvtListenerFailed, ['InnerException=' + e.Message]));
          // retry
        end;
      end;
      if fRequireTokenRenew then
      begin
        if assigned(fAuth) and
           fAuth.CheckAndRefreshTokenSynchronous(true) then
        begin
          {$IFDEF ParserLog}
          TFirebaseHelpers.Log(TimeToStr(now) + ' RequireTokenRenew: sucess');
          {$ENDIF}
          fRequireTokenRenew := false;
        end else begin
          {$IFDEF ParserLog}
          TFirebaseHelpers.Log(TimeToStr(now) + ' RequireTokenRenew: failed');
          {$ENDIF}
        end;
        if assigned(fOnAuthRevoked) and
           not TFirebaseHelpers.AppIsTerminated then
          TThread.Queue(nil,
            procedure
            begin
              fOnAuthRevoked(not fRequireTokenRenew);
            end);
      end;
      FreeAndNil(fClient);
    end;
  except
    on e: exception do
      ReportErrorInThread(Format(rsEvtListenerFailed, [e.Message]));
  end;
  {$IFDEF ParserLog}
  TFirebaseHelpers.Log('FB4D.Firestore.Exit_Thread');
  {$ENDIF}
  FreeAndNil(QueryParams);
end;

procedure TListenerThread.RegisterEvents(OnStopListening: TOnStopListenEvent;
  OnError: TOnRequestError; OnAuthRevoked: TOnAuthRevokedEvent);
begin
  if IsRunning then
    raise EFirestoreListener.Create(
      'RegisterEvents must not be called for started Listener');
  InitListen(true);
  fRequestID := 'Listener for ' + fTargets.Count.ToString + ' target(s)';
  fOnStopListening := OnStopListening;
  fOnListenError := OnError;
end;

procedure TListenerThread.OnEndListenerGet(const ASyncResult: IAsyncResult);
var
  Resp: IHTTPResponse;
begin
  {$IFDEF ParserLog}
  TFirebaseHelpers.Log('FB4D.Firestore.EndListenerGet');
  {$ENDIF}
  if not ASyncResult.GetIsCancelled then
  begin
    try
      Resp := fClient.EndAsyncHTTP(ASyncResult);
      if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
      begin
        ReportErrorInThread(Resp.StatusText);
        {$IFDEF ParserLogDetails}
        TFirebaseHelpers.Log('FB4D.Firestore.Response: ' + Resp.ContentAsString);
        {$ENDIF}
        fCloseRequest := true;
      end;
    finally
      Resp := nil;
    end;
  end;
  FreeAndNil(fStream);
  fGetFinishedEvent.SetEvent;
end;

procedure TListenerThread.OnEndThread(Sender: TObject);
begin
  if assigned(fOnStopListening) and not TFirebaseHelpers.AppIsTerminated then
    fOnStopListening(Sender);
end;

procedure TListenerThread.StopListener(TimeOutInMS: integer);
var
  Timeout: integer;
begin
  if not fStopWaiting then
  begin
    fStopWaiting := true;
    if not assigned(fClient) then
      raise EFirestoreListener.Create('Missing Client in StopListener')
    else if not assigned(fAsyncResult) then
      raise EFirestoreListener.Create('Missing AsyncResult in StopListener')
    else
      fAsyncResult.Cancel;
  end;
  Timeout := TimeOutInMS div 2;
  while not Finished and (Timeout > 0) do
  begin
    TFirebaseHelpers.SleepAndMessageLoop(5);
    dec(Timeout, 5);
  end;
  if not Finished then
  begin
    // last try
    fGetFinishedEvent.SetEvent;
    Timeout := TimeOutInMS div 2;
    while not Finished and (Timeout > 0) do
    begin
      TFirebaseHelpers.SleepAndMessageLoop(5);
      dec(Timeout, 5);
    end;
    if not Finished then
      raise EFirestoreListener.Create('Listener not stopped because of timeout');
  end;
end;

procedure TListenerThread.OnRecData(const Sender: TObject; ContentLength,
  ReadCount: Int64; var Abort: Boolean);
var
  ss: TStringStream;
  ErrMsg: string;
begin
  try
    if fStopWaiting then
     Abort := true
    else if assigned(fStream) and
      ((fMsgSize = -1) or
       (fPartialResp.Length + ReadCount - fReadPos >= fMsgSize)) then
    begin
      ss := TStringStream.Create('', TEncoding.UTF8);
      try
        Assert(fReadPos >= 0, 'Invalid stream read position');
        Assert(ReadCount - fReadPos >= 0, 'Invalid stream read count: ' +
          ReadCount.ToString + ' - ' + fReadPos.ToString);
        fStream.Position := fReadPos;
        ss.CopyFrom(fStream, ReadCount - fReadPos);
        try
          fPartialResp := fPartialResp + ss.DataString;
          fReadPos := ReadCount;
        except
          on e: EEncodingError do
            if (fMsgSize = -1) and fPartialResp.IsEmpty then
              // ignore Unicode decoding errors for the first received packet
            else
              raise;
        end;
      finally
        ss.Free;
      end;
      if not fPartialResp.IsEmpty then
        Parser;
    end;
  except
    on e: Exception do
    begin
      ErrMsg := e.Message;
      if not TFirebaseHelpers.AppIsTerminated then
        if assigned(fOnListenError) then
          TThread.Queue(nil,
            procedure
            begin
              fOnListenError(fRequestID, rsEvtParserFailed + ErrMsg)
            end)
        else
          TFirebaseHelpers.Log(rsEvtParserFailed + ErrMsg);
    end;
  end;
end;

end.