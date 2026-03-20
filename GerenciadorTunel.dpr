program GerenciadorTunel;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  Winapi.Windows,
  UConfiguracao in 'UConfiguracao.pas',
  UWebCliente in 'UWebCliente.pas',
  UMonitorTunel in 'UMonitorTunel.pas';

var
  Config: TConfiguracao;
  WebCliente: TWebCliente;
  Monitor: TMonitorTunel;
  InputIP, InputPorta: string;
  CaminhoLog: string;

begin
  try
    CaminhoLog := ExtractFilePath(ParamStr(0)) + 'monitoramento.txt';

    // VALIDAÇÃO: PRIMEIRA VEZ RODANDO?
    if not FileExists(CaminhoLog) then
    begin
      // Não esconde a janela agora para permitir o input
      Writeln('=== CONFIGURACAO INICIAL DO GERENCIADOR ===');
      Writeln('Atenção: Se você usa IIS, verifique se sua API está na porta 80 ou outra.');
      Write('Digite a URL da sua API (ex: http://192.168.1.10/api): ');
      Readln(InputIP);
      Write('Digite a Porta do seu sistema local (ex: 80): ');
      Readln(InputPorta);

      // Salva no INI
      with TStringList.Create do
      try
        Add('[Config]');
        Add('URL_API=' + InputIP);
        Add('PORTA_SISTEMA=' + InputPorta);
        SaveToFile(ExtractFilePath(ParamStr(0)) + 'config.ini');
      finally
        Free;
      end;

      // Cria o arquivo de log para não perguntar de novo
      with TStringList.Create do
      try
        Add(FormatDateTime('[dd/mm/yyyy hh:nn:ss] ', Now) + 'Instalacao concluida.');
        SaveToFile(CaminhoLog);
      finally
        Free;
      end;

      Writeln('Configuracao salva! O programa agora rodara em segundo plano.');
      Sleep(2000);
    end;

    // Agora esconde a janela para rodar como servico
    ShowWindow(GetConsoleWindow, SW_HIDE);

    Config := TConfiguracao.Create;
    try
      Config.Carregar;
      WebCliente := TWebCliente.Create(Config);

      try
        WebCliente.RegistrarLog('>>> INICIANDO SERVICO GERENCIADOR DE TUNEL <<<');

        // O Monitor agora controla o próprio ciclo de vida internamente
        Monitor := TMonitorTunel.Create(Config, WebCliente);

        // Loop apenas para manter o .DPR vivo enquanto a Thread trabalha
        while True do
        begin
          Sleep(60000);
        end;

      finally
        // WebCliente será liberado no encerramento do processo
      end;
    finally
      Config.Free;
    end;

  except
    on E: Exception do
    begin
      if Assigned(WebCliente) then
        WebCliente.RegistrarLog('ERRO FATAL NO ARRANQUE: ' + E.Message);
    end;
  end;
end.
