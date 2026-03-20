unit UMonitorTunel;

interface

uses
  System.SysUtils, System.Classes, Winapi.Windows, Winapi.TlHelp32, System.RegularExpressions, UWebCliente, UConfiguracao;

type
  TMonitorTunel = class(TThread)
  private
    FConfig: TConfiguracao;
    FWebCliente: TWebCliente;
    FUltimaUrl: string;
    FDataUltimaTentativa: TDateTime;
    FAguardandoLog: Boolean;
    procedure MatarCloudflaredAntigo;
    procedure ExecutarProcessoOculto;
    procedure LogInterno(const Msg: string);
  protected
    procedure Execute; override;
  public
    constructor Create(AConfig: TConfiguracao; ACliente: TWebCliente);
  end;

implementation

uses System.DateUtils;

constructor TMonitorTunel.Create(AConfig: TConfiguracao; ACliente: TWebCliente);
begin
  inherited Create(False);
  FreeOnTerminate := True;
  FConfig := AConfig;
  FWebCliente := ACliente;
  FUltimaUrl := '';
  FDataUltimaTentativa := 0;
  FAguardandoLog := False;
end;

procedure TMonitorTunel.LogInterno(const Msg: string);
begin
  FWebCliente.RegistrarLog(Msg);
end;

procedure TMonitorTunel.MatarCloudflaredAntigo;
var
  Snap: THandle;
  ProcEntry: TProcessEntry32;
  HProc: THandle;
begin
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snap <> INVALID_HANDLE_VALUE then
  try
    ProcEntry.dwSize := SizeOf(ProcEntry);
    if Process32First(Snap, ProcEntry) then
    repeat
      if SameText(string(ProcEntry.szExeFile), 'cloudflared.exe') then
      begin
        HProc := OpenProcess(PROCESS_TERMINATE, False, ProcEntry.th32ProcessID);
        if HProc <> 0 then
        begin
          TerminateProcess(HProc, 0);
          CloseHandle(HProc);
        end;
      end;
    until not Process32Next(Snap, ProcEntry);
  finally
    CloseHandle(Snap);
  end;
end;

procedure TMonitorTunel.ExecutarProcessoOculto;
var
  StartupInfo: TStartupInfo;
  ProcessInfo: TProcessInformation;
  SecurityAttr: TSecurityAttributes;
  ReadPipe, WritePipe: THandle;
  Buffer: array[0..4096] of AnsiChar;
  BytesRead: Cardinal;
  CaminhoExe, Comando, PastaApp: string;
  AcumuladorString: string;
  LinhaCompleta, UrlEncontrada: string;
  Match: TMatch;
  LogProcesso: TStringList;
  AchouUrl: Boolean;
  I: Integer;
begin
  if (FDataUltimaTentativa > 0) and (SecondsBetween(Now, FDataUltimaTentativa) < 120) then
  begin
    if not FAguardandoLog then
    begin
      LogInterno('Aguardando intervalo de 2 min de segurança...');
      FAguardandoLog := True;
    end;
    Exit;
  end;

  FAguardandoLog := False;
  FDataUltimaTentativa := Now;
  MatarCloudflaredAntigo;

  PastaApp := ExtractFilePath(ParamStr(0));
  CaminhoExe := PastaApp + 'cloudflared.exe';

  if not FileExists(CaminhoExe) then
  begin
    LogInterno('ERRO: cloudflared.exe nao encontrado em: ' + PastaApp);
    Exit;
  end;

  {
    SOLUÇÃO DEFINITIVA PARA 502:
    1. Usamos 127.0.0.1 para evitar erro de IPv6 (localhost).
    2. Usamos --http-host-header para o IIS/Node aceitar a conexao.
  }
  Comando := '"' + CaminhoExe + '" tunnel --url http://127.0.0.1:' + IntToStr(FConfig.PortaLocal) +
             ' --http-host-header localhost';

  LogInterno('Executando comando: ' + Comando);

  SecurityAttr.nLength := SizeOf(TSecurityAttributes);
  SecurityAttr.bInheritHandle := True;
  SecurityAttr.lpSecurityDescriptor := nil;

  if CreatePipe(ReadPipe, WritePipe, @SecurityAttr, 0) then
  try
    FillChar(StartupInfo, SizeOf(TStartupInfo), 0);
    StartupInfo.cb := SizeOf(TStartupInfo);
    StartupInfo.hStdOutput := WritePipe;
    StartupInfo.hStdError := WritePipe;
    StartupInfo.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
    StartupInfo.wShowWindow := SW_HIDE;

    if CreateProcess(nil, PChar(Comando), nil, nil, True, CREATE_NO_WINDOW, nil, PChar(PastaApp), StartupInfo, ProcessInfo) then
    begin
      CloseHandle(WritePipe);

      AcumuladorString := '';
      AchouUrl := False;
      LogProcesso := TStringList.Create;

      try
        while ReadFile(ReadPipe, Buffer, SizeOf(Buffer) - 1, BytesRead, nil) do
        begin
          if BytesRead > 0 then
          begin
            Buffer[BytesRead] := #0;
            AcumuladorString := AcumuladorString + string(Buffer);

            while Pos(#10, AcumuladorString) > 0 do
            begin
              LinhaCompleta := Copy(AcumuladorString, 1, Pos(#10, AcumuladorString) - 1);
              Delete(AcumuladorString, 1, Pos(#10, AcumuladorString));

              LogProcesso.Add(Trim(LinhaCompleta));
              if LogProcesso.Count > 10 then LogProcesso.Delete(0);

              Match := TRegEx.Match(LinhaCompleta, 'https:\/\/[a-zA-Z0-9-]+\.trycloudflare\.com');
              if Match.Success then
              begin
                AchouUrl := True;
                UrlEncontrada := Match.Value;
                if UrlEncontrada <> FUltimaUrl then
                begin
                  LogInterno('URL GERADA: ' + UrlEncontrada);
                  FWebCliente.Sincronizar(UrlEncontrada, True);
                  FUltimaUrl := UrlEncontrada;
                end;
              end;
            end;
          end;
          if Terminated then break;
        end;

        WaitForSingleObject(ProcessInfo.hProcess, 1000);
        CloseHandle(ProcessInfo.hProcess);
        CloseHandle(ProcessInfo.hThread);

        if not AchouUrl then
        begin
          LogInterno('FALHA: O processo fechou. Ultimas linhas do terminal:');
          for I := 0 to LogProcesso.Count - 1 do
            LogInterno('  > ' + LogProcesso[I]);
        end;

      finally
        LogProcesso.Free;
      end;
    end
    else
      LogInterno('Erro ao iniciar processo: ' + IntToStr(GetLastError));
  finally
    CloseHandle(ReadPipe);
  end;
end;

procedure TMonitorTunel.Execute;
begin
  while not Terminated do
  begin
    try
      ExecutarProcessoOculto;
    except
      on E: Exception do LogInterno('Erro na Thread: ' + E.Message);
    end;
    if not Terminated then Sleep(5000);
  end;
end;

end.
