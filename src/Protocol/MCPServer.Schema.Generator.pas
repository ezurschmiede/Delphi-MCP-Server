unit MCPServer.Schema.Generator;

interface

uses
  System.SysUtils,
  System.Rtti,
  System.TypInfo,
  System.JSON;

type
  TMCPSchemaGenerator = class
  private
    class function GetJsonTypeFromRttiType(RttiType: TRttiType; out TypeFormat: String): string;
    class function GetPropertyJsonName(Prop: TRttiProperty; RType: TRttiType): string;
    class function IsRequiredProperty(Prop: TRttiProperty): Boolean;
  public
    class function GenerateSchema(Cls: TClass): TJSONObject;
    class function GenerateSchemaFromInstance(Instance: TObject): TJSONObject;
  end;

implementation

uses
  System.Generics.Collections,
  MCPServer.Types;

{ TMCPSchemaGenerator }

class function TMCPSchemaGenerator.GenerateSchema(Cls: TClass): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');

  var Properties := TJSONObject.Create;
  Result.AddPair('properties', Properties);
  var RequiredArray := TJSONArray.Create;

  var RttiContext := TRttiContext.Create;
  try
    var RttiType := RttiContext.GetType(Cls);

    for var RttiProp in RttiType.GetProperties do
    begin
      if RttiProp.IsReadable and RttiProp.IsWritable then
      begin
        var JsonName := GetPropertyJsonName(RttiProp, RttiType);

        var PropSchema := TJSONObject.Create;
        Properties.AddPair(JsonName, PropSchema);

        var JsonTypeFormat := '';
        var JsonType := GetJsonTypeFromRttiType(RttiProp.PropertyType, JsonTypeFormat);
        PropSchema.AddPair('type', JsonType);

        if JsonType = 'array' then
        begin
          var items := TJSONObject.Create;
          PropSchema.AddPair('items', items);

          if RttiProp.PropertyType is TRttiDynamicArrayType then
          begin
            var JsonElTypeFormat := '';
            var JsonElType := GetJsonTypeFromRttiType(TRttiDynamicArrayType(RttiProp.PropertyType).ElementType, JsonElTypeFormat);

            items.AddPair('type', JsonElType);

            if JsonElTypeFormat.Length > 0 then
              items.AddPair('format', JsonElTypeFormat);
          end;
        end;

        for var Attr in RttiProp.GetAttributes do
        begin
          if Attr is SchemaDescriptionAttribute then
          begin
            PropSchema.AddPair('description', SchemaDescriptionAttribute(Attr).Description);
          end else
          if Attr is SchemaEnumAttribute then
          begin
            var EnumArray := TJSONArray.Create;
            for var Value in SchemaEnumAttribute(Attr).Values do
              EnumArray.Add(Value);
            PropSchema.AddPair('enum', EnumArray);
          end else
          if Attr is SchemaFormatAttribute then
          begin
            JsonTypeFormat := SchemaFormatAttribute(Attr).Format;
          end;
        end;

        if JsonTypeFormat.Length > 0 then
          PropSchema.AddPair('format', JsonTypeFormat);

        if IsRequiredProperty(RttiProp) then
          RequiredArray.Add(JsonName);
      end;
    end;

    if RequiredArray.Count > 0 then
      Result.AddPair('required', RequiredArray)
    else
      RequiredArray.Free;
  finally
    RttiContext.Free;
  end;
end;

class function TMCPSchemaGenerator.GenerateSchemaFromInstance(Instance: TObject): TJSONObject;
begin
  Result := GenerateSchema(Instance.ClassType);
end;

class function TMCPSchemaGenerator.GetJsonTypeFromRttiType(RttiType: TRttiType; out TypeFormat: String): string;
begin
  TypeFormat := '';

  case RttiType.TypeKind of
    tkInteger, tkInt64: Result := 'integer';
    tkFloat:
      begin
        if RttiType.Handle = TypeInfo(TDateTime) then
        begin
          TypeFormat := 'date-time';
          Result := 'string';
        end else
        if RttiType.Handle = TypeInfo(TDate) then
        begin
          TypeFormat := 'date';
          Result := 'string';
        end else
        if RttiType.Handle = TypeInfo(TTime) then
        begin
          TypeFormat := 'time';
          Result := 'string';
        end else
        begin
          Result := 'number';
        end;
      end;

    tkString, tkLString, tkWString, tkUString: Result := 'string';
    tkEnumeration:
      if RttiType.Name = 'Boolean' then
        Result := 'boolean'
      else
        Result := 'string';
    tkSet: Result := 'array';
    tkClass:
      if RttiType.Name = 'TJSONArray' then
        Result := 'array'
      else
        Result := 'object';
    tkArray, tkDynArray: Result := 'array';
  else
    Result := 'string';
  end;
end;

class function TMCPSchemaGenerator.GetPropertyJsonName(Prop: TRttiProperty; RType: TRttiType): string;
begin
  Result := LowerCase(Prop.Name);
end;

class function TMCPSchemaGenerator.IsRequiredProperty(Prop: TRttiProperty): Boolean;
begin
  for var Attr in Prop.GetAttributes do
  begin
    if Attr is OptionalAttribute then
      Exit(False);
  end;
  Result := True;
end;

end.