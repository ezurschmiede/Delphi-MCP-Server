unit MCPServer.CoreManager;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Rtti,
  System.DateUtils,
  System.SyncObjs,
  Generics.Collections,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.Logger,
  MCPServer.Tool.Base,
  MCPServer.Resource.Base,
  MCPServer.JsonRpcProcessor,
  MCPServer.ToolsManager,
  MCPServer.ResourcesManager;

type
  TMCPSessionCoreManager = class;

  TMCPSessionClass = class of TMCPSession;
  TMCPSession = class(TMCPCustomSession)
  private
    FCoreManager: TMCPSessionCoreManager;
    FManagerRegistry: IMCPManagerRegistry;
    FToolsManager: TMCPToolsManager;
    FResourcesManager: TMCPResourcesManager;
    FProcessor: TMCPJsonRpcProcessor;
  public
    constructor Create(const ACoreManager: TMCPSessionCoreManager);
    destructor Destroy; override;

    procedure Init(const SessionId: String; const Params: TJSONObject; const AuthHeader: string); virtual;
    function ValidateAuth(const AuthHeader: string): Boolean; virtual;

    procedure RegisterTool(const Tool: IMCPTool);
    procedure RegisterResource(const Resource: IMCPResource);

    property CoreManager: TMCPSessionCoreManager read FCoreManager;
    property ManagerRegistry: IMCPManagerRegistry read FManagerRegistry;
    property ToolsManager: TMCPToolsManager read FToolsManager;
    property ResourcesManager: TMCPResourcesManager read FResourcesManager;

    property Processor: TMCPJsonRpcProcessor read FProcessor;
  end;

  TMCPCoreManager = class(TInterfacedObject, IMCPCapabilityManager)
  private
    FSettings: TMCPCustomSettings;
  protected
    procedure InitSession(const Session: TMCPSession; const SessionId: String; const Params: TJSONObject; const AuthHeader: string); virtual;
    function ValidateAuth(const Session: TMCPSession; const AuthHeader: string): Boolean; virtual;
    function CreateNewSession(const Params: TJSONObject; const AuthHeader: string): string; virtual;
  public
    constructor Create(ASettings: TMCPCustomSettings); virtual;
    destructor Destroy; override;

    function GetRpcProcessor(const SessionId: string): TMCPJsonRpcProcessor;
    function GetSession(const SessionId: string): TMCPSession; virtual;

    function ValidateSession(const SessionId, AuthHeader: string; var AProcessor: TMCPJsonRpcProcessor): TMCPSession;

    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: TJSONObject; var SessionID: string; const AuthHeader: string): TValue;

    function Initialize(const Params: TJSONObject; var SessionID: string; const AuthHeader: string): TValue;
    function Ping: TValue;
  end;

  TInitSessionEvent = reference to procedure(const Session: TMCPSession; const SessionId: String; const Params: TJSONObject; const AuthHeader: string);
  TValidateAuthEvent = reference to procedure(const Session: TMCPSession; const AuthHeader: string; var IsAuth: Boolean);

  TMCPSessionCoreManager = class(TMCPCoreManager)
  private
    FSessionLock: TCriticalSection;
    FSessions: TObjectDictionary<String, TMCPSession>;
    FOnInitSession: TInitSessionEvent;
    FOnValidateAuth: TValidateAuthEvent;
  protected
    function GetSessionClass: TMCPSessionClass; virtual;
    function ValidateAuth(const Session: TMCPSession; const AuthHeader: string): Boolean; override;
    procedure InitSession(const Session: TMCPSession; const SessionId: String; const Params: TJSONObject; const AuthHeader: string); override;
    function CreateNewSession(const Params: TJSONObject; const AuthHeader: string): string; override;
  public
    constructor Create(ASettings: TMCPCustomSettings); override;
    procedure BeforeDestruction; override;
    destructor Destroy; override;

    function GetSession(const SessionId: string): TMCPSession; override;

    property OnInitSession: TInitSessionEvent read FOnInitSession write FOnInitSession;
    property OnValidateAuth: TValidateAuthEvent read FOnValidateAuth write FOnValidateAuth;
  end;

implementation
uses
  MCPServer.ManagerRegistry;

{ TMCPCoreManager }

constructor TMCPCoreManager.Create(ASettings: TMCPCustomSettings);
begin
  inherited Create;
  FSettings := ASettings;
end;

function TMCPCoreManager.GetCapabilityName: string;
begin
  Result := 'core';
end;

function TMCPCoreManager.GetRpcProcessor(const SessionId: string): TMCPJsonRpcProcessor;
begin
  var Session := GetSession(SessionId);

  if Assigned(Session) then
    Result := Session.Processor
  else
    Result := nil;
end;

function TMCPCoreManager.GetSession(const SessionId: string): TMCPSession;
begin
  Result := nil;
end;

function TMCPCoreManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := (Method = 'initialize') or 
            (Method = 'notifications/initialized') or
            (Method = 'ping');
end;

function TMCPCoreManager.CreateNewSession(const Params: TJSONObject; const AuthHeader: string): string;
begin
  Result := TGuid.NewGuid.ToString;

  TLogger.Info('Created new MCP session: ' + Result);

  if Assigned(Params) then
  begin
    var ClientInfo := Params.GetValue('clientInfo') as TJSONObject;

    if Assigned(ClientInfo) then
    begin
      var ClientName := ClientInfo.GetValue('name');
      var ClientVersion := ClientInfo.GetValue('version');

      if Assigned(ClientName) and Assigned(ClientVersion) then
        TLogger.Info(Format('Client: %s v%s', [ClientName.Value, ClientVersion.Value]));
    end;
  end;
end;

destructor TMCPCoreManager.Destroy;
begin
  
  inherited;
end;

function TMCPCoreManager.ExecuteMethod(const Method: string; const Params: TJSONObject; var SessionID: string; const AuthHeader: string): TValue;
begin
  if Method = 'initialize' then
    Result := Initialize(Params, SessionID, AuthHeader)
  else if Method = 'notifications/initialized' then
  begin
    TLogger.Info('MCP Initialized notification received');
    Result := TValue.Empty;
  end
  else if Method = 'ping' then
    Result := Ping
  else
    raise Exception.CreateFmt('Method %s not handled by %s', [Method, GetCapabilityName]);
end;

function TMCPCoreManager.ValidateAuth(const Session: TMCPSession; const AuthHeader: string): Boolean;
begin
  Result := true;
end;

function TMCPCoreManager.ValidateSession(const SessionId, AuthHeader: string; var AProcessor: TMCPJsonRpcProcessor): TMCPSession;
begin
  Result := GetSession(SessionId);

  if Assigned(Result) then
  begin
    if Result.ValidateAuth(AuthHeader) then
      AProcessor := Result.Processor
    else
      raise EMCPStatusError.Create(404, 'Invalid authentication');
  end;
end;

function TMCPCoreManager.Initialize(const Params: TJSONObject; var SessionID: string; const AuthHeader: string): TValue;
begin
  TLogger.Info('MCP Initialize called');

  SessionID := CreateNewSession(Params, AuthHeader);

  var ResultJSON := TJSONObject.Create;
  try
    ResultJSON.AddPair('protocolVersion', MCP_PROTOCOL_VERSION);
    
    var Capabilities := TJSONObject.Create;
    ResultJSON.AddPair('capabilities', Capabilities);
    
    var ToolsCap := TJSONObject.Create;
    Capabilities.AddPair('tools', ToolsCap);
    ToolsCap.AddPair('supportsProgress', TJSONBool.Create(False));
    ToolsCap.AddPair('supportsCancellation', TJSONBool.Create(False));
    
    var ResourcesCap := TJSONObject.Create;
    Capabilities.AddPair('resources', ResourcesCap);
    ResourcesCap.AddPair('subscribe', TJSONBool.Create(False));
    ResourcesCap.AddPair('listChanged', TJSONBool.Create(False));
    
    ResultJSON.AddPair('sessionId', SessionID);
    
    var ServerInfo := TJSONObject.Create;
    ResultJSON.AddPair('serverInfo', ServerInfo);
    ServerInfo.AddPair('name', FSettings.ServerName);
    ServerInfo.AddPair('version', FSettings.ServerVersion);

    Result := TValue.From<TJSONObject>(ResultJSON);
  except
    ResultJSON.Free;
    raise;
  end;
end;

procedure TMCPCoreManager.InitSession(const Session: TMCPSession; const SessionId: String; const Params: TJSONObject;
  const AuthHeader: string);
begin
  //
end;

function TMCPCoreManager.Ping: TValue;
begin
  TLogger.Info('MCP Ping called');
  
  var ResultJSON := TJSONObject.Create;
  try
    Result := TValue.From<TJSONObject>(ResultJSON);
  except
    ResultJSON.Free;
    raise;
  end;
end;

{ TMCPSessionCoreManager }

procedure TMCPSessionCoreManager.BeforeDestruction;
begin
  FSessions.Clear;
  inherited;
end;

constructor TMCPSessionCoreManager.Create(ASettings: TMCPCustomSettings);
begin
  inherited ;
  FSessionLock := TCriticalSection.Create;
  FSessions := TObjectDictionary<String, TMCPSession>.Create([doOwnsValues]);
end;

function TMCPSessionCoreManager.CreateNewSession(const Params: TJSONObject; const AuthHeader: string): string;
begin
  Result := inherited CreateNewSession(Params, AuthHeader);

  var Session := GetSessionClass.Create(self);
  try
    Session.Init(Result, Params, AuthHeader);

    FSessionLock.Enter;
    try
      FSessions.Add(Result, Session);
    finally
      FSessionLock.Leave;
    end;
  except
    Session.Free;
    raise;
  end;
end;

destructor TMCPSessionCoreManager.Destroy;
begin
  FSessions.Free;
  FSessionLock.Free;
  inherited;
end;

function TMCPSessionCoreManager.GetSession(const SessionId: string): TMCPSession;
begin
  FSessionLock.Enter;
  try
    if not FSessions.TryGetValue(SessionId, Result) then
      Result := nil;
  finally
    FSessionLock.Leave;
  end;

  if not Assigned(Result) then
    raise EMCPStatusError.Create(404, Format('MCP-Session session-id "%s" not found', [SessionId]));
end;

function TMCPSessionCoreManager.GetSessionClass: TMCPSessionClass;
begin
  Result := TMCPSession;
end;

procedure TMCPSessionCoreManager.InitSession(const Session: TMCPSession; const SessionId: String; const Params: TJSONObject;
  const AuthHeader: string);
begin
  if Assigned(OnInitSession) then
    OnInitSession(Session, SessionId, Params, AuthHeader);
end;

function TMCPSessionCoreManager.ValidateAuth(const Session: TMCPSession; const AuthHeader: string): Boolean;
begin
  Result := inherited ValidateAuth(Session, AuthHeader);

  if Assigned(OnValidateAuth) then
    OnValidateAuth(Session, AuthHeader, Result);
end;

{ TMCPSession }

constructor TMCPSession.Create(const ACoreManager: TMCPSessionCoreManager);
begin
  inherited Create;
  FCoreManager := ACoreManager;
  FManagerRegistry := TMCPManagerRegistry.Create;
  FToolsManager := TMCPToolsManager.Create;
  FResourcesManager := TMCPResourcesManager.Create;
  FProcessor := TMCPJsonRpcProcessor.Create(FManagerRegistry);

  FManagerRegistry.RegisterManager(ACoreManager);
  FManagerRegistry.RegisterManager(FToolsManager);
  FManagerRegistry.RegisterManager(FResourcesManager);
end;

destructor TMCPSession.Destroy;
begin
  FProcessor.Free;
  inherited;
end;

procedure TMCPSession.Init(const SessionId: String; const Params: TJSONObject; const AuthHeader: string);
begin
  FCoreManager.InitSession(self, SessionId, Params, AuthHeader);

  // override and add session specific tools and resources. one can validate auth here, too
  //
  // TMCPSession.RegisterTool(TCalculateTool.CreateForSession(self));
  // TMCPSession.RegisterResource(TLogsRecentResource.CreateForSession(self));
  //
  // or use TMCPSessionCoreManager.OnInitSession
end;

procedure TMCPSession.RegisterResource(const Resource: IMCPResource);
begin
  FResourcesManager.RegisterResource(Resource);
end;

procedure TMCPSession.RegisterTool(const Tool: IMCPTool);
begin
  FToolsManager.RegisterTool(Tool);
end;

function TMCPSession.ValidateAuth(const AuthHeader: string): Boolean;
begin
  Result := FCoreManager.ValidateAuth(self, AuthHeader);

  // override and add/update session specific tools and resources allowed with current AuthHeader.
  //
  // TMCPSession.RegisterTool(TCalculateTool.CreateForSession(self));
  // TMCPSession.RegisterResource(TLogsRecentResource.CreateForSession(self));
  //
  // or use TMCPSessionCoreManager.OnValidateAuth
end;

end.