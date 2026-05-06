unit MCPServer.IdHTTPServer;

interface

// TaurusTLS provides OpenSSL 3.x support with modern ECDHE cipher suites
// Install via GetIt Package Manager: Search for "TaurusTLS" or get from https://github.com/JPeterMugaas/TaurusTLS
{$DEFINE USE_TAURUS_TLS}  // Comment this line to use standard Indy SSL (OpenSSL 1.0.2)

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Rtti,
  System.IOUtils,
  System.Generics.Collections,
  IdHTTPServer,
  IdContext,
  IdCustomHTTPServer,
  IdGlobal,
  IdGlobalProtocols,
  {$IFDEF USE_TAURUS_TLS}
  TaurusTLS,
  {$ELSE}
  IdSSLOpenSSL,
  {$ENDIF}
  IdServerIOHandler,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.JsonRpcProcessor,
  MCPServer.CoreManager;

type
  TMCPIdHTTPServer = class(TComponent)
  private
    FHTTPServer: TIdHTTPServer;
    {$IFDEF USE_TAURUS_TLS}
    FSSLHandler: TTaurusTLSServerIOHandler;
    {$ELSE}
    FSSLHandler: TIdServerIOHandlerSSLOpenSSL;
    {$ENDIF}
    FCoreManager: TMCPCoreManager;
    FCoreJsonRpcProcessor: TMCPJsonRpcProcessor;
    FPort: Word;
    FActive: Boolean;
    FSettings: TMCPCustomSettings;
    FEventIDCounter: Int64;
    FCoreManagerRegistry: IMCPManagerRegistry;
    procedure DoParseAuthentication(AContext: TIdContext; const AAuthType, AAuthData: String; var VUsername, VPassword: String; var VHandled: Boolean);
    procedure ConfigureSSL;
    procedure HandleQuerySSLPort(APort: Word; var VUseSSL: Boolean);
    procedure HandleHTTPRequest(Context: TIdContext; RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
    function VerifyAndSetCORSHeaders(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo): Boolean;
    procedure HandleOptionsRequest(ResponseInfo: TIdHTTPResponseInfo);
    procedure HandleGetRequest(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
    procedure HandlePostRequest(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
    procedure HandlePostRequestSSE(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo; const RequestBody: string; var SessionID: string);
    procedure HandlePostRequestJSON(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo; const RequestBody: string; var SessionID: string);
    function GetNextEventID: string;
    function AcceptsSSE(const AcceptHeader: string): Boolean;
    function IsRequestOnlyNotificationsOrResponses(JSONRequest: TJSONValue): Boolean;
    procedure SetCoreManager(const Value: TMCPCoreManager);
  public
    constructor Create(Owner: TComponent); override;
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    property Port: Word read FPort write FPort;
    property Active: Boolean read FActive;
    property CoreManager: TMCPCoreManager read FCoreManager write SetCoreManager;
    property CoreManagerRegistry: IMCPManagerRegistry read FCoreManagerRegistry;
    property Settings: TMCPCustomSettings read FSettings write FSettings;
  end;

implementation

uses
  MCPServer.Resource.Server,
  MCPServer.ManagerRegistry,
  MCPServer.Logger;

const
  KEEP_ALIVE_TIMEOUT = 300;
  DEFAULT_MCP_PORT = 3000;

  // HTTP Status Codes
  HTTP_OK = 200;
  HTTP_ACCEPTED = 202;
  HTTP_NO_CONTENT = 204;
  HTTP_NOT_FOUND = 404;
  HTTP_METHOD_NOT_ALLOWED = 405;
  HTTP_NOT_ACCEPTABLE = 406;
  HTTP_FORBIDDEN = 403;

  // CORS Max Age (24 hours in seconds)
  CORS_MAX_AGE = 86400;

  // JSON-RPC 2.0 Error Codes
  JSONRPC_PARSE_ERROR = -32700;
  JSONRPC_INVALID_REQUEST = -32600;
  JSONRPC_METHOD_NOT_FOUND = -32601;
  JSONRPC_INVALID_PARAMS = -32602;
  JSONRPC_INTERNAL_ERROR = -32603;

  // SSE Message Format
  SSE_EVENT_PREFIX = 'event: ';
  SSE_DATA_PREFIX = 'data: ';
  SSE_ID_PREFIX = 'id: ';
  SSE_MESSAGE_TERMINATOR = #10#10;

{ TMCPIdHTTPServer }

constructor TMCPIdHTTPServer.Create(Owner: TComponent);
begin
  inherited Create(Owner);
  FPort := DEFAULT_MCP_PORT;
  FActive := False;
  FEventIDCounter := 0;
  FCoreJsonRpcProcessor := nil;

  FHTTPServer := TIdHTTPServer.Create(Self);
  FHTTPServer.KeepAlive := True;
  FHTTPServer.OnCommandGet := HandleHTTPRequest;
  FHTTPServer.OnCommandOther := HandleHTTPRequest;
  FHTTPServer.OnQuerySSLPort := HandleQuerySSLPort;
  FHTTPServer.OnParseAuthentication := DoParseAuthentication;
  FSSLHandler := nil;
end;

destructor TMCPIdHTTPServer.Destroy;
begin
  if FActive then
    Stop;
  FHTTPServer.Free;
  if Assigned(FSSLHandler) then
    FSSLHandler.Free;
  FCoreJsonRpcProcessor.Free;
  SetCoreManager(nil);
  inherited;
end;

procedure TMCPIdHTTPServer.DoParseAuthentication(AContext: TIdContext; const AAuthType, AAuthData: String; var VUsername,
  VPassword: String; var VHandled: Boolean);
begin
  if AAuthType = 'Bearer' then
  begin
    VHandled := true;
  end;
end;

procedure TMCPIdHTTPServer.SetCoreManager(const Value: TMCPCoreManager);
begin
  FCoreManagerRegistry := nil;

  if Assigned(FCoreManager) then
    IInterface(FCoreManager)._Release;

  if Assigned(Value) then
  begin
    FCoreManagerRegistry := TMCPManagerRegistry.Create;
    FCoreManagerRegistry.RegisterManager(Value);
  end;

  FCoreManager := Value;

  if Assigned(FCoreManager) then
    IInterface(FCoreManager)._AddRef;
end;

procedure TMCPIdHTTPServer.Start;
begin
  if FActive then
    Exit;

  if not Assigned(FCoreManagerRegistry) then
    raise Exception.Create('CoreManager not assigned');

  FCoreJsonRpcProcessor := TMCPJsonRpcProcessor.Create(FCoreManagerRegistry);

  if Assigned(FSettings) then
  begin
    FPort := Word(FSettings.Port);

    // Configure SSL if enabled
    if FSettings.SSLEnabled then
      ConfigureSSL;
  end;

  FHTTPServer.DefaultPort := FPort;
  FHTTPServer.Active := True;
  FActive := True;

  TLogger.Info('MCP Server started on ' + FSettings.Protocol + '://' + FSettings.Host + ':' + IntToStr(FPort));
end;

procedure TMCPIdHTTPServer.Stop;
begin
  if not FActive then
    Exit;
    
  FHTTPServer.Active := False;
  FActive := False;
  TLogger.Info('MCP Server stopped');
end;

procedure TMCPIdHTTPServer.HandleHTTPRequest(Context: TIdContext; 
  RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
begin
  TServerStatusResource.ConnectionOpened;
  try
    TServerStatusResource.IncrementRequestCount;

    if not VerifyAndSetCORSHeaders(RequestInfo, ResponseInfo) then
      Exit; // CORS blocked the request

    var RequestPath := RequestInfo.Document;

    // Only handle requests to the configured MCP endpoint
    if (RequestPath <> FSettings.Endpoint) then
    begin
      ResponseInfo.ResponseNo := HTTP_NOT_FOUND;
      ResponseInfo.ResponseText := 'Not Found';
      Exit;
    end;
    
    if RequestInfo.Command = 'OPTIONS' then
      HandleOptionsRequest(ResponseInfo)
    else if RequestInfo.CommandType = hcGET then
      HandleGetRequest(RequestInfo, ResponseInfo)
    else if RequestInfo.CommandType = hcPOST then
      HandlePostRequest(RequestInfo, ResponseInfo)
    else
    begin
      ResponseInfo.ResponseNo := HTTP_METHOD_NOT_ALLOWED;
      ResponseInfo.ResponseText := 'Method Not Allowed';
    end;
  finally
    TServerStatusResource.ConnectionClosed;
  end;
end;

function TMCPIdHTTPServer.VerifyAndSetCORSHeaders(RequestInfo: TIdHTTPRequestInfo;
  ResponseInfo: TIdHTTPResponseInfo): Boolean;
begin
  Result := True;

  var Origin := RequestInfo.RawHeaders.Values['Origin'];
  var AllowedOrigin: string := '*';

  if not Assigned(FSettings) or not FSettings.CorsEnabled then
  begin
    AllowedOrigin := Origin;
  end else
  begin
    if (FSettings.CorsAllowedOrigins <> '*') and (Origin <> '') then
    begin
      var OriginsList := TStringList.Create;
      try
        OriginsList.CommaText := FSettings.CorsAllowedOrigins;
        var Found := False;

        for var CurrentOrigin in OriginsList do
        begin
          if SameText(Trim(CurrentOrigin), Origin) then
          begin
            AllowedOrigin := Origin;
            Found := True;
            Break;
          end;
        end;

        if not Found then
        begin
          Result := False;
          ResponseInfo.ResponseNo := HTTP_FORBIDDEN;
          ResponseInfo.ResponseText := 'Forbidden - Origin not allowed';
          TLogger.Info('CORS blocked origin: ' + Origin);
          Exit;
        end;
      finally
        OriginsList.Free;
      end;
    end;
  end;

  ResponseInfo.CustomHeaders.Values['Access-Control-Allow-Origin'] := AllowedOrigin;
  ResponseInfo.CustomHeaders.Values['Access-Control-Allow-Methods'] := 'POST, GET, OPTIONS';
  ResponseInfo.CustomHeaders.Values['Access-Control-Allow-Headers'] := 'Content-Type, Mcp-Session-Id, Authorization, mcp-protocol-version';
  ResponseInfo.CustomHeaders.Values['Access-Control-Max-Age'] := CORS_MAX_AGE.ToString;
end;

procedure TMCPIdHTTPServer.HandleOptionsRequest(ResponseInfo: TIdHTTPResponseInfo);
begin
  ResponseInfo.ResponseNo := HTTP_OK;
  ResponseInfo.ResponseText := 'OK';
end;

procedure TMCPIdHTTPServer.HandleGetRequest(RequestInfo: TIdHTTPRequestInfo;
  ResponseInfo: TIdHTTPResponseInfo);
begin
  var AcceptHeader := RequestInfo.RawHeaders.Values['Accept'];

  if AcceptsSSE(AcceptHeader) then
  begin
    TLogger.Debug('Received GET request - opening SSE stream for server-initiated messages');

    ResponseInfo.ContentType := 'text/event-stream';
    ResponseInfo.CharSet := 'utf-8';
    ResponseInfo.CustomHeaders.Values['Cache-Control'] := 'no-cache';
    ResponseInfo.CustomHeaders.Values['Connection'] := 'keep-alive';
    ResponseInfo.CustomHeaders.Values['X-Accel-Buffering'] := 'no';

    var SessionID := RequestInfo.RawHeaders.Values['Mcp-Session-Id'];
    if SessionID <> '' then
      ResponseInfo.CustomHeaders.Values['Mcp-Session-Id'] := SessionID;

    ResponseInfo.ResponseNo := HTTP_OK;
    ResponseInfo.ContentText := ''; // Empty SSE stream, close immediately

    // Note: GET endpoint for SSE streams is optional per MCP spec 2025-03-26
    // Server MAY keep connection open to send server-initiated notifications/requests
    // Current implementation: basic support, closes stream immediately (no persistent connection)
    TLogger.Debug('SSE stream opened (no server-initiated messages to send)');
  end
  else
  begin
    TLogger.Info('Received GET request - returning endpoint info');

    ResponseInfo.ContentType := 'application/json';
    ResponseInfo.CustomHeaders.Values['Cache-Control'] := 'no-cache';
    ResponseInfo.CustomHeaders.Values['Connection'] := 'keep-alive';

    ResponseInfo.ContentText := '{"url": "' + FSettings.Protocol + '://' + FSettings.Host + ':' + IntToStr(FPort) +
                    FSettings.Endpoint + '", "transport": "' + FSettings.Protocol + '"}';

    ResponseInfo.ResponseNo := HTTP_OK;
  end;
end;

procedure TMCPIdHTTPServer.HandlePostRequest(RequestInfo: TIdHTTPRequestInfo;
  ResponseInfo: TIdHTTPResponseInfo);
begin
  var RequestBody := '';
  if Assigned(RequestInfo.PostStream) and (RequestInfo.PostStream.Size > 0) then
  begin
    RequestInfo.PostStream.Position := 0;
    RequestBody := ReadStringFromStream(RequestInfo.PostStream, -1, IndyTextEncoding_UTF8);
  end;

  TLogger.Info('Request: ' + RequestBody);

  var SessionID := RequestInfo.RawHeaders.Values['Mcp-Session-Id'];
  if SessionID <> '' then
    TLogger.Info('Session ID from header: ' + SessionID);

  var AcceptHeader := RequestInfo.RawHeaders.Values['Accept'];

  var JSONRequest: TJSONValue := nil;
  try
    JSONRequest := TJSONObject.ParseJSONValue(RequestBody);

    if Assigned(JSONRequest) and IsRequestOnlyNotificationsOrResponses(JSONRequest) then
    begin
      TLogger.Info('Request contains only notifications/responses, returning 202 Accepted');
      ResponseInfo.ResponseNo := HTTP_ACCEPTED;
    end else
    begin
      if AcceptsSSE(AcceptHeader) then
        HandlePostRequestSSE(RequestInfo, ResponseInfo, RequestBody, SessionID)
      else
        HandlePostRequestJSON(RequestInfo, ResponseInfo, RequestBody, SessionID);
    end;

    if SessionID <> '' then
      ResponseInfo.CustomHeaders.Values['Mcp-Session-Id'] := SessionID;
  finally
    JSONRequest.Free;
  end;
end;

procedure TMCPIdHTTPServer.ConfigureSSL;
begin
  // Check if certificate files exist
  if not TFile.Exists(FSettings.SSLCertFile) then
  begin
    TLogger.Error('SSL Certificate file not found: ' + FSettings.SSLCertFile);
    raise Exception.Create('SSL Certificate file not found: ' + FSettings.SSLCertFile);
  end;
  
  if not TFile.Exists(FSettings.SSLKeyFile) then
  begin
    TLogger.Error('SSL Key file not found: ' + FSettings.SSLKeyFile);
    raise Exception.Create('SSL Key file not found: ' + FSettings.SSLKeyFile);
  end;
  
  // Create and configure SSL handler
  {$IFDEF USE_TAURUS_TLS}
  // TaurusTLS with OpenSSL 3.x support
  FSSLHandler := TTaurusTLSServerIOHandler.Create(Self);
  FSSLHandler.DefaultCert.PublicKey := FSettings.SSLCertFile;
  FSSLHandler.DefaultCert.PrivateKey := FSettings.SSLKeyFile;
  {$ELSE}
  // Standard Indy SSL with OpenSSL 1.0.2
  FSSLHandler := TIdServerIOHandlerSSLOpenSSL.Create(Self);
  FSSLHandler.SSLOptions.CertFile := FSettings.SSLCertFile;
  FSSLHandler.SSLOptions.KeyFile := FSettings.SSLKeyFile;
  
  if (FSettings.SSLRootCertFile <> '') and TFile.Exists(FSettings.SSLRootCertFile) then
    FSSLHandler.SSLOptions.RootCertFile := FSettings.SSLRootCertFile;
  
  // Configure SSL options
  FSSLHandler.SSLOptions.Method := sslvTLSv1_2;
  FSSLHandler.SSLOptions.SSLVersions := [sslvTLSv1, sslvTLSv1_1, sslvTLSv1_2];
  FSSLHandler.SSLOptions.Mode := sslmServer;
  {$ENDIF}
  
  // Assign handler to HTTP server
  FHTTPServer.IOHandler := FSSLHandler;
  
  TLogger.Info('SSL configured successfully');
  TLogger.Info('Certificate: ' + FSettings.SSLCertFile);
  TLogger.Info('Private Key: ' + FSettings.SSLKeyFile);
  if FSettings.SSLRootCertFile <> '' then
    TLogger.Info('Root Certificate: ' + FSettings.SSLRootCertFile);
end;

procedure TMCPIdHTTPServer.HandleQuerySSLPort(APort: Word; var VUseSSL: Boolean);
begin
  // Enable SSL for our configured port when SSL is enabled
  VUseSSL := FSettings.SSLEnabled and (APort = FPort);
end;

function TMCPIdHTTPServer.GetNextEventID: string;
begin
  Result := AtomicIncrement(FEventIDCounter).ToString;
end;

function TMCPIdHTTPServer.AcceptsSSE(const AcceptHeader: string): Boolean;
begin
  Result := Pos('text/event-stream', AcceptHeader) > 0;
end;

function TMCPIdHTTPServer.IsRequestOnlyNotificationsOrResponses(JSONRequest: TJSONValue): Boolean;
begin
  if JSONRequest is TJSONObject then
  begin
    var Obj := JSONRequest as TJSONObject;
    var MethodValue := Obj.GetValue('method');
    var IdValue := Obj.GetValue('id');
    var ResultValue := Obj.GetValue('result');
    var ErrorValue := Obj.GetValue('error');

    if Assigned(MethodValue) and not Assigned(IdValue) then
      Exit(True);

    if Assigned(ResultValue) or Assigned(ErrorValue) then
      Exit(True);

    Result := False;
  end
  else if JSONRequest is TJSONArray then
  begin
    var Arr := JSONRequest as TJSONArray;
    Result := True;
    for var I := 0 to Arr.Count - 1 do
    begin
      if not IsRequestOnlyNotificationsOrResponses(Arr.Items[I]) then
      begin
        Result := False;
        Break;
      end;
    end;
  end
  else
    Result := False;
end;

procedure TMCPIdHTTPServer.HandlePostRequestSSE(RequestInfo: TIdHTTPRequestInfo;
  ResponseInfo: TIdHTTPResponseInfo; const RequestBody: string; var SessionID: string);
begin
  TLogger.Info('Handling POST request with SSE stream');
  try
    ResponseInfo.ContentType := 'text/event-stream';
    ResponseInfo.CharSet := 'utf-8';
    ResponseInfo.CustomHeaders.Values['Cache-Control'] := 'no-cache';
    ResponseInfo.CustomHeaders.Values['Connection'] := 'keep-alive';
    ResponseInfo.CustomHeaders.Values['X-Accel-Buffering'] := 'no';

    var AuthHeader := RequestInfo.RawHeaders.Values['Authorization'];
    var RpcProcessor: TMCPJsonRpcProcessor := FCoreJsonRpcProcessor;

    if Length(SessionID) > 0 then
    begin
      CoreManager.ValidateSession(SessionId, AuthHeader, RpcProcessor);
    end;

    var JSONResponse := RpcProcessor.ProcessRequest(RequestBody, SessionID, AuthHeader);

    if JSONResponse <> '' then
    begin
      var EventID := GetNextEventID;
      var SSEMessage := '';

      if EventID <> '' then
        SSEMessage := SSEMessage + SSE_ID_PREFIX + EventID + #10;

      SSEMessage := SSEMessage + SSE_EVENT_PREFIX + 'message' + #10;
      SSEMessage := SSEMessage + SSE_DATA_PREFIX + JSONResponse + SSE_MESSAGE_TERMINATOR;

      ResponseInfo.ContentText := SSEMessage;
      TLogger.Info('SSE response prepared with event ID: ' + EventID);
    end
    else
    begin
      ResponseInfo.ContentText := '';
    end;

    ResponseInfo.ResponseNo := HTTP_OK;
  except
    on E: Exception do
    begin
      if E is EMCPStatusError then
      begin
        ResponseInfo.ResponseNo := EMCPStatusError(E).HTTPStatus;
        ResponseInfo.ContentText := Format('{"error": "%s"}', [EMCPStatusError(E).Message]);
      end else
        raise;
    end;
  end;
end;

procedure TMCPIdHTTPServer.HandlePostRequestJSON(RequestInfo: TIdHTTPRequestInfo;
  ResponseInfo: TIdHTTPResponseInfo; const RequestBody: string; var SessionID: string);
begin
  TLogger.Info('Handling POST request with JSON response');
  try
    var AuthHeader := RequestInfo.RawHeaders.Values['Authorization'];
    var RpcProcessor: TMCPJsonRpcProcessor := FCoreJsonRpcProcessor;

    if Length(SessionID) > 0 then
    begin
      CoreManager.ValidateSession(SessionId, AuthHeader, RpcProcessor);
    end;

    var ResponseBody := RpcProcessor.ProcessRequest(RequestBody, SessionID, AuthHeader);

    if ResponseBody = '' then
    begin
      ResponseInfo.ResponseNo := HTTP_NO_CONTENT;
      Exit;
    end;

    ResponseInfo.ContentType := 'application/json';
    ResponseInfo.CustomHeaders.Values['Connection'] := 'keep-alive';

    ResponseInfo.ContentStream := TStringStream.Create(ResponseBody, TEncoding.UTF8);
    ResponseInfo.FreeContentStream := True;
    ResponseInfo.ResponseNo := HTTP_OK;

    TLogger.Info('Response: ' + ResponseBody);
  except
    on E: Exception do
    begin
      if E is EMCPStatusError then
      begin
        ResponseInfo.ResponseNo := EMCPStatusError(E).HTTPStatus;
        ResponseInfo.ContentText := Format('{"error": "%s"}', [EMCPStatusError(E).Message]);
      end else
        raise;
    end;
  end;
end;


end.