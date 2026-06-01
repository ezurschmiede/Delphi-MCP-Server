unit MCPServer.Tool.Base;

interface

uses
  System.SysUtils,
  System.Rtti,
  JsonDataObjects,
  System.JSON,
  MCPServer.Types;

type
  IMCPTool = interface
    ['{F1E2D3C4-B5A6-4798-8901-234567890ABC}']
    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetInputSchema: TJSONObject;
    function GetOutputSchema: TJSONObject;
    function Execute(const Arguments: TJSONObject): TValue;

    property Name: string read GetName;
    property Title: string read GetTitle;
    property Description: string read GetDescription;
    property InputSchema: TJSONObject read GetInputSchema;
    property OutputSchema: TJSONObject read GetOutputSchema;
  end;

  TMCPToolBase = class(TInterfacedObject, IMCPTool)
  protected
    FName: string;
    FTitle: string;
    FDescription: string;
    FSession: TMCPCustomSession;
    function BuildSchema: TJSONObject; virtual; abstract;
  public
    constructor Create; virtual;
    constructor CreateForSession(const Session: TMCPCustomSession); virtual;

    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetInputSchema: TJSONObject;
    function GetOutputSchema: TJSONObject;
    function Execute(const Arguments: TJSONObject): TValue; virtual; abstract;
  end;

  TMCPToolBase<T : class, constructor> = class(TInterfacedObject, IMCPTool)
  protected
    FName: string;
    FTitle: string;
    FDescription: string;
    FSession: TMCPCustomSession;
    function ExecuteWithParams(const Params: T): string;virtual; abstract;
    function GetParamsClass: TClass; virtual;
  public
    constructor Create; virtual;
    constructor CreateForSession(const Session: TMCPCustomSession); virtual;

    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetInputSchema: TJSONObject;
    function GetOutputSchema: TJSONObject;
    function Execute(const Arguments: TJSONObject): TValue;
  end;

  TMCPToolBase<T,R : class, constructor> = class(TInterfacedObject, IMCPTool)
  protected
    FName: string;
    FTitle: string;
    FDescription: string;
    FSession: TMCPCustomSession;
    function ExecuteWithParams(const Params: T): R;virtual; abstract;
    procedure FillOutputSchemaProperties(ASchemaProperties: TJSONObject); virtual;
    function CreateJsonTypeObj(const ATypeName: String; const ADescription: String = ''): TJSONObject;
  public
    constructor Create; virtual;
    constructor CreateForSession(const Session: TMCPCustomSession); virtual;

    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetInputSchema: TJSONObject; virtual;
    function GetOutputSchema: TJSONObject; virtual;
    function Execute(const Arguments: TJSONObject): TValue;
  end;

implementation

uses
  MCPServer.Schema.Generator,
  MCPServer.Serializer;

{ TMCPToolBase }

constructor TMCPToolBase.Create;
begin
  inherited Create;
end;

function TMCPToolBase.GetName: string;
begin
  Result := FName;
end;

function TMCPToolBase.GetTitle: string;
begin
  if FTitle <> '' then
    Result := FTitle
  else
    Result := FName;
end;

function TMCPToolBase.GetOutputSchema: TJSONObject;
begin
  result := nil;
end;

constructor TMCPToolBase.CreateForSession(const Session: TMCPCustomSession);
begin
  FSession := Session;
  Create;
end;

function TMCPToolBase.GetDescription: string;
begin
  Result := FDescription;
end;

function TMCPToolBase.GetInputSchema: TJSONObject;
begin
  Result := BuildSchema;
end;

{ TMCPToolBase<T> }

constructor TMCPToolBase<T>.Create;
begin
  inherited Create;
end;

function TMCPToolBase<T>.GetName: string;
begin
  Result := FName;
end;

function TMCPToolBase<T>.GetTitle: string;
begin
  if FTitle <> '' then
    Result := FTitle
  else
    Result := FName;
end;

function TMCPToolBase<T>.GetOutputSchema: TJSONObject;
begin
  result := nil;
end;

function TMCPToolBase<T>.GetDescription: string;
begin
  Result := FDescription;
end;

function TMCPToolBase<T>.GetInputSchema: TJSONObject;
begin
  Result := TMCPSchemaGenerator.GenerateSchema(T);
end;

constructor TMCPToolBase<T>.CreateForSession(const Session: TMCPCustomSession);
begin
  FSession := Session;
  Create;
end;

function TMCPToolBase<T>.Execute(const Arguments: TJSONObject): TValue;
var
  ParamsInstance: T;
begin
  ParamsInstance := TMCPSerializer.Deserialize<T>(Arguments);
  try
    Result := ExecuteWithParams(ParamsInstance);
  finally
    ParamsInstance.Free;
  end;
end;

function TMCPToolBase<T>.GetParamsClass: TClass;
begin
  Result := T;
end;


{ TMCPToolBase<T, R> }

constructor TMCPToolBase<T, R>.Create;
begin
  inherited Create;
end;

constructor TMCPToolBase<T, R>.CreateForSession(const Session: TMCPCustomSession);
begin
  FSession := Session;
  Create;
end;

function TMCPToolBase<T, R>.Execute(const Arguments: TJSONObject): TValue;
var
  ParamsInstance: T;
  Response : R;
  JsonObj : TJSONObject;
begin
  ParamsInstance := TMCPSerializer.Deserialize<T>(Arguments);
  try
    Response := ExecuteWithParams(ParamsInstance);
    try
      if Response is TJSONObject then
      begin
        JsonObj := TJSONObject(Response);
        Response := nil;
      end else
      if Response is TJSONArray then
      begin
        JsonObj := TJSONObject.Create;
        JsonObj.AddPair('count', TJSONArray(Response).Count.ToString);
        JsonObj.AddPair('items', TJSONArray(Response));
        Response := nil;
      end else
      if Response is JsonDataObjects.TJsonObject then
      begin
        JsonObj := TJSONObject.ParseJSONValue(JsonDataObjects.TJsonObject(Response).ToJson) as TJSONObject; // ToDo: investigate more perfomant way to "clone" JsonDataObjects.TJsonObject to System.JSON.TJsonObject
      end else
      if Response is JsonDataObjects.TJsonArray then
      begin
        JsonObj := TJSONObject.Create;
        var ValueItems := TJsonArray.ParseJSONValue(JsonDataObjects.TJsonArray(Response).ToJSON) as TJsonArray;  // ToDo: investigate more perfomant way to "clone" JsonDataObjects.TJsonArray to System.JSON.TJsonArray
        JsonObj.AddPair('count', ValueItems.Count.ToString);
        JsonObj.AddPair('items', ValueItems);
      end else
      begin
        JsonObj := TJSONObject.Create;
        TMCPSerializer.Serialize(Response, JsonObj);
      end;

      Result := TValue.From(JsonObj);
    finally
      Response.Free;
    end;
  finally
    ParamsInstance.Free;
  end;
end;

function TMCPToolBase<T, R>.GetDescription: string;
begin
  result := FDescription;
end;

function TMCPToolBase<T, R>.GetInputSchema: TJSONObject;
begin
  Result := TMCPSchemaGenerator.GenerateSchema(T);
end;

function TMCPToolBase<T, R>.GetName: string;
begin
  Result := FName;
end;

function TMCPToolBase<T, R>.GetTitle: string;
begin
  if FTitle <> '' then
    Result := FTitle
  else
    Result := FName;
end;

function TMCPToolBase<T, R>.CreateJsonTypeObj(const ATypeName: String; const ADescription: String = ''): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', ATypeName);

  if ADescription.Length > 0 then
    Result.AddPair('description', ADescription);
end;

procedure TMCPToolBase<T, R>.FillOutputSchemaProperties(ASchemaProperties: TJSONObject);
begin
  //
end;

function TMCPToolBase<T, R>.GetOutputSchema: TJSONObject;
begin
  if (R = TJSONObject) or (R = JsonDataObjects.TJsonObject) then
  begin
    Result := CreateJsonTypeObj('object');

    var JsonProp := TJSONObject.Create;
    FillOutputSchemaProperties(JsonProp);
    Result.AddPair('properties', JsonProp);
  end else
  if (R = TJSONArray) or (R = JsonDataObjects.TJsonArray) then
  begin
    Result := CreateJsonTypeObj('object');

    var JsonProp := TJSONObject.Create;
    Result.AddPair('properties', JsonProp);

    JsonProp.AddPair('count', CreateJsonTypeObj('integer', 'count of items in list'));

    var JsonPropItems := CreateJsonTypeObj('array', 'list with items');
    JsonProp.AddPair('items', JsonPropItems);

    var JsonPropItemType := CreateJsonTypeObj('object');
    JsonPropItems.AddPair('items', JsonPropItemType);

    var JsonPropItemTypeProp := TJSONObject.Create;
    FillOutputSchemaProperties(JsonPropItemTypeProp);
    JsonPropItemType.AddPair('properties', JsonPropItemTypeProp);
  end else
    Result := TMCPSchemaGenerator.GenerateSchema(R);
end;

end.