unit MCPServer.Settings;

interface

uses
  System.SysUtils,
  System.IniFiles,
  System.IOUtils;

type
  TMCPCustomSettings = class
  private
    FPort: Integer;
    FHost: string;
    FServerName: string;
    FServerVersion: string;
    FEndpoint: string;
    FCorsEnabled: Boolean;
    FCorsAllowedOrigins: string;
    FSSLEnabled: Boolean;
    FSSLCertFile: string;
    FSSLKeyFile: string;
    FSSLRootCertFile: string;
    FSettingsFile: string;
    function GetProtocol: string;

    procedure LoadDefaults;
  public
    constructor Create; virtual;

    property Port: Integer read FPort write FPort;
    property Host: string read FHost write FHost;
    property Protocol: string read GetProtocol;
    property ServerName: string read FServerName write FServerName;
    property ServerVersion: string read FServerVersion write FServerVersion;
    property Endpoint: string read FEndpoint write FEndpoint;
    property CorsEnabled: Boolean read FCorsEnabled write FCorsEnabled;
    property CorsAllowedOrigins: string read FCorsAllowedOrigins write FCorsAllowedOrigins;
    property SettingsFile: string read FSettingsFile;
    property SSLEnabled: Boolean read FSSLEnabled write FSSLEnabled;
    property SSLCertFile: string read FSSLCertFile write FSSLCertFile;
    property SSLKeyFile: string read FSSLKeyFile write FSSLKeyFile;
    property SSLRootCertFile: string read FSSLRootCertFile write FSSLRootCertFile;
  end;

  TMCPSettings = class(TMCPCustomSettings)
  private
    FSettingsFile: string;
  protected
    procedure CreateDefaultSettingsFile;
  public
    constructor Create(const ASettingsFile: string = '');

    procedure LoadFromFile;
    procedure SaveToFile;
  end;

implementation

uses
  MCPServer.Logger;

{ TMCPCustomSettings }

procedure TMCPCustomSettings.LoadDefaults;
begin
  FPort := 3000;
  FHost := 'localhost';
  FServerName := 'delphi-mcp-server';
  FServerVersion := '1.0.0';
  FEndpoint := '/mcp';
  FCorsEnabled := True;
  FCorsAllowedOrigins := 'http://localhost,http://127.0.0.1,https://localhost,https://127.0.0.1';
  FSSLEnabled := False;
  FSSLCertFile := '';
  FSSLKeyFile := '';
  FSSLRootCertFile := '';
end;

constructor TMCPCustomSettings.Create;
begin
  inherited;
  LoadDefaults;
end;

function TMCPCustomSettings.GetProtocol: string;
const
  Prot: array[Boolean] of String = ('http', 'https');
begin
  Result := Prot[FSSLEnabled];
end;

{ TMCPSettings }

constructor TMCPSettings.Create(const ASettingsFile: string);
begin
  inherited Create;

  if ASettingsFile = '' then
    FSettingsFile := TPath.Combine(ExtractFilePath(ParamStr(0)), 'settings.ini')
  else
    FSettingsFile := ASettingsFile;

  if not TFile.Exists(FSettingsFile) then
  begin
    TLogger.Info('Settings file not found. Creating default settings: ' + FSettingsFile);
    CreateDefaultSettingsFile;
  end;

  LoadFromFile;
end;

procedure TMCPSettings.CreateDefaultSettingsFile;
begin
  var IniFile := TIniFile.Create(FSettingsFile);
  try
    IniFile.WriteString('Server', '; Server configuration', '');
    IniFile.WriteInteger('Server', 'Port', FPort);
    IniFile.WriteString('Server', 'Host', FHost);
    IniFile.WriteString('Server', 'Name', FServerName);
    IniFile.WriteString('Server', 'Version', FServerVersion);
    IniFile.WriteString('Server', 'Endpoint', FEndpoint);

    IniFile.WriteString('CORS', '; Cross-Origin Resource Sharing configuration', '');
    IniFile.WriteBool('CORS', 'Enabled', FCorsEnabled);
    IniFile.WriteString('CORS', '; Comma-separated list of allowed origins', '');
    IniFile.WriteString('CORS', 'AllowedOrigins', FCorsAllowedOrigins);

    IniFile.WriteString('SSL', '; SSL/TLS configuration (optional)', '');
    IniFile.WriteBool('SSL', 'Enabled', FSSLEnabled);
    IniFile.WriteString('SSL', 'CertFile', FSSLCertFile);
    IniFile.WriteString('SSL', 'KeyFile', FSSLKeyFile);
    IniFile.WriteString('SSL', 'RootCertFile', FSSLRootCertFile);
  finally
    IniFile.Free;
  end;
end;

procedure TMCPSettings.LoadFromFile;
begin
  if not TFile.Exists(FSettingsFile) then
    Exit;

  var IniFile := TIniFile.Create(FSettingsFile);
  try
    FPort := IniFile.ReadInteger('Server', 'Port', FPort);
    FHost := IniFile.ReadString('Server', 'Host', FHost);
    FServerName := IniFile.ReadString('Server', 'Name', FServerName);
    FServerVersion := IniFile.ReadString('Server', 'Version', FServerVersion);
    FEndpoint := IniFile.ReadString('Server', 'Endpoint', FEndpoint);

    FCorsEnabled := IniFile.ReadBool('CORS', 'Enabled', FCorsEnabled);
    FCorsAllowedOrigins := IniFile.ReadString('CORS', 'AllowedOrigins', FCorsAllowedOrigins);

    FSSLEnabled := IniFile.ReadBool('SSL', 'Enabled', FSSLEnabled);
    FSSLCertFile := IniFile.ReadString('SSL', 'CertFile', FSSLCertFile);
    FSSLKeyFile := IniFile.ReadString('SSL', 'KeyFile', FSSLKeyFile);
    FSSLRootCertFile := IniFile.ReadString('SSL', 'RootCertFile', FSSLRootCertFile);

    TLogger.Info('Settings loaded from: ' + FSettingsFile);
    TLogger.Info('Server: ' + Protocol + '://' + FHost + ':' + IntToStr(FPort));
    if FSSLEnabled then
    begin
      TLogger.Info('SSL Enabled: True');
      if FSSLCertFile <> '' then
        TLogger.Info('SSL Certificate: ' + FSSLCertFile);
    end;
    TLogger.Info('CORS Enabled: ' + BoolToStr(FCorsEnabled, True));
    if FCorsEnabled then
      TLogger.Info('CORS Allowed Origins: ' + FCorsAllowedOrigins);
  finally
    IniFile.Free;
  end;
end;

procedure TMCPSettings.SaveToFile;
begin
  var IniFile := TIniFile.Create(FSettingsFile);
  try
    IniFile.WriteInteger('Server', 'Port', FPort);
    IniFile.WriteString('Server', 'Host', FHost);
    IniFile.WriteString('Server', 'Name', FServerName);
    IniFile.WriteString('Server', 'Version', FServerVersion);
    IniFile.WriteString('Server', 'Endpoint', FEndpoint);

    IniFile.WriteBool('CORS', 'Enabled', FCorsEnabled);
    IniFile.WriteString('CORS', 'AllowedOrigins', FCorsAllowedOrigins);

    IniFile.WriteBool('SSL', 'Enabled', FSSLEnabled);
    IniFile.WriteString('SSL', 'CertFile', FSSLCertFile);
    IniFile.WriteString('SSL', 'KeyFile', FSSLKeyFile);
    IniFile.WriteString('SSL', 'RootCertFile', FSSLRootCertFile);
  finally
    IniFile.Free;
  end;
end;

end.