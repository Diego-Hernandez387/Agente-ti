# ============================================================
#  diagnostico.ps1  -  Agente de Diagnostico (ventana)
#  Interfaz grafica para la mesa de ayuda.
#  Se lanza desde "Agente de Diagnostico.bat" (que da permisos).
# ============================================================

# ############################################################
#  CONFIGURACION  (edita estas 4 lineas segun tu entorno)
# ############################################################
$BaragentExe    = "C:\Program Files (x86)\inConcert\Agent\BarAgentController.exe"
$BaragentNombre = "BarAgentController.exe"
$DiademaNombre  = ""                                  # opcional: nombre exacto de la diadema
$UrlAccess      = "https://access.inconcert.cloud/"

# --- Diagnostico de red ---
$PuertoTest     = 4444                 # puerto a verificar
$IpUniminuto    = "8.28.231.128"       # servidor alianza Uniminuto
$IpOPM          = "8.28.230.147"       # servidor alianza OPM
$PuertoHost     = $IpUniminuto         # se ajusta segun la alianza elegida al inicio
$Alianza        = "Uniminuto"          # se ajusta segun la seleccion
$PingHost       = "8.8.8.8"      # destino para medir latencia
$SpeedBytes     = 25000000       # tamano de descarga de prueba (~25 MB)
# ############################################################

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Carpeta base = la carpeta del propio programa (se ejecuta en su sitio, sin copiar).
# Si por algun motivo no se puede escribir ahi, cae a AppData del usuario (solo para logs/nircmd).
$BaseDir = $null
foreach($c in @($env:AGENTE_DIR, (Join-Path $env:LOCALAPPDATA "AsistenteTI"))){
    if(-not $c){ continue }
    try {
        if(-not (Test-Path $c)){ New-Item -ItemType Directory -Path $c -Force -ErrorAction Stop | Out-Null }
        $t = Join-Path $c "_w.tmp"; Set-Content -Path $t -Value "x" -ErrorAction Stop; Remove-Item $t -Force -ErrorAction SilentlyContinue
        $BaseDir = $c; break
    } catch {}
}
if(-not $BaseDir){ $BaseDir = $env:TEMP }
$nircmd = Join-Path $BaseDir "nircmd.exe"

# ---- Archivo de registro (log) ----
$LogDir = Join-Path $BaseDir "Logs"
try { if(-not (Test-Path $LogDir)){ New-Item -ItemType Directory -Path $LogDir -Force | Out-Null } } catch { $LogDir = $env:TEMP }
$LogFile = Join-Path $LogDir ("Diagnostico_" + (Get-Date -Format "yyyy-MM-dd") + ".txt")
$script:errores = 0

# ---- Icono del acceso directo (bot): viene junto al programa ----
$IcoPath = Join-Path $env:AGENTE_DIR "asistente-ti.ico"

# ############################################################
#  CENTRALIZADOR (Fase 1) - deja CentralUrl vacio para desactivarlo
# ############################################################
$AgentVersion = "1.2.0"                     # version de este Agente
$CentralUrl   = "https://agente-ti-centralizador.diego-hernandez.workers.dev"                          # ej. https://agente-ti-centralizador.TUSUB.workers.dev
$ApiKey       = "a553e683916c4f708fba3fabd515f32036a2899c8a424483b0279c8b692c1ac2"              # clave de flota (igual a la del Worker)
$HmacSecret   = "aacb2bb192ba4aeb97688c8e5f61d9d880c21bbb2e12469c9d3b4874ffc7c1a0"          # clave para firmar el cuerpo del reporte
$PubKeyXml    = "<RSAKeyValue><Modulus>ukaJJxFDl3XjWo1L+jk8pPIPoxdrvlWU23xBn8ibX13bsTSoBUU4aUJ7UIJN8BkOAGnlr76yq8UzWPIQuPfo9OlXNLy0oUrxxMrM4oq+lBYTr+VbiXvAvpw3+Qg69zE8LYAAj4VVdqRgFc4BGlTQtO19A/UuB5WFC890IduVUZ1R50urBDJ8IWaYRvuZiY85+8Tu+pT2ROZfFuMkQvz7ZqshOKdMiU5uEsf2wQOTgrsxKb+h1kr1IwCO9AoOyk5UwQ1gHkUerELuGwnCM6AV8lEtu56Nzpn0LdfGcjjlsHYXuTWvbyfkaPPW/3e/ZkpItHf4Na2opR9DRwvUsly4oQ==</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>"    # llave publica para verificar actualizaciones
# ############################################################

# ID unico del equipo (se genera una vez y se guarda)
$DeviceIdFile = Join-Path $BaseDir "device.id"
try {
    if(Test-Path $DeviceIdFile){ $DeviceId = (Get-Content $DeviceIdFile -Raw).Trim() }
    else { $DeviceId = [guid]::NewGuid().ToString(); Set-Content -Path $DeviceIdFile -Value $DeviceId -Encoding ASCII }
} catch { $DeviceId = "sin-id" }

# ---- Colores de marca Scala ----
$morado  = [System.Drawing.Color]::FromArgb(91,42,134)
$naranja = [System.Drawing.Color]::FromArgb(242,140,40)
$blanco  = [System.Drawing.Color]::White
$grisclaro = [System.Drawing.Color]::FromArgb(235,235,238)

# ---- Helper: dar bordes redondeados a un control ----
function Redondear($ctrl,$r){
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $w = $ctrl.Width; $h = $ctrl.Height
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($w-$d, 0, $d, $d, 270, 90)
    $path.AddArc($w-$d, $h-$d, $d, $d, 0, 90)
    $path.AddArc(0, $h-$d, $d, $d, 90, 90)
    $path.CloseAllFigures()
    $ctrl.Region = New-Object System.Drawing.Region($path)
}

# ============================================================
#  FUNCIONES DE REPARACION
# ============================================================
function Log($t){
    if($txtLog){
        $txtLog.AppendText($t + "`r`n")
        $txtLog.SelectionStart = $txtLog.Text.Length
        $txtLog.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
    try { Add-Content -Path $LogFile -Value $t -Encoding UTF8 } catch {}
    if($t -match '\[X\]|\[ERROR\]|\[!\]'){ $script:errores++ }
}

function Limpiar-Chromium($base){
    if(-not (Test-Path $base)){ return }
    Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
        ForEach-Object {
            foreach($f in 'Cookies','History','Web Data'){ Remove-Item (Join-Path $_.FullName $f) -Force -ErrorAction SilentlyContinue }
            foreach($d in 'Cache','Code Cache'){ Remove-Item (Join-Path $_.FullName $d) -Recurse -Force -ErrorAction SilentlyContinue }
        }
}

function Reparar-Navegador {
    Log "Cerrando navegadores..."
    'chrome','msedge','firefox','brave' | ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
    Log "Borrando temporales..."
    Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    Log "Limpiando Chrome, Edge y Brave..."
    Limpiar-Chromium "$env:LOCALAPPDATA\Google\Chrome\User Data"
    Limpiar-Chromium "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
    Limpiar-Chromium "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
    $ff = "$env:APPDATA\Mozilla\Firefox\Profiles"
    if(Test-Path $ff){
        Get-ChildItem $ff -Directory | ForEach-Object {
            Remove-Item (Join-Path $_.FullName 'cookies.sqlite') -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $_.FullName 'places.sqlite')  -Force -ErrorAction SilentlyContinue
        }
    }
    Log "[OK] Cookies y temporales borrados."
    Log "Recuerda verificar que el navegador este actualizado."
}

function Reparar-Agente {
    Log "Deteniendo el agente si esta corriendo..."
    Stop-Process -Name ([IO.Path]::GetFileNameWithoutExtension($BaragentNombre)) -Force -ErrorAction SilentlyContinue
    $exe = $null
    if(Test-Path $BaragentExe){
        $exe = $BaragentExe
    } else {
        Log "Buscando el aplicativo en el equipo..."
        foreach($root in $env:ProgramFiles, ${env:ProgramFiles(x86)}){
            if($root -and (Test-Path $root)){
                $f = Get-ChildItem $root -Recurse -Filter $BaragentNombre -ErrorAction SilentlyContinue | Select-Object -First 1
                if($f){ $exe = $f.FullName; break }
            }
        }
    }
    if(-not $exe){
        [System.Windows.Forms.MessageBox]::Show(
            "EL APLICATIVO NO SE ENCUENTRA INSTALADO EN ESTE EQUIPO.`n`nPor favor comuniquese con el area de TI.",
            "Aplicativo no encontrado",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        Log "[!] Aplicativo no instalado. Avisar a TI."
        return
    }
    Start-Process $exe
    Log "[OK] Agente reiniciado: $exe"
}

function Obtener-Nircmd {
    Log "Descargando complemento de audio (nircmd)..."
    try{
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $zip = "$env:TEMP\nircmd.zip"
        Invoke-WebRequest -Uri "https://www.nirsoft.net/utils/nircmd.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $BaseDir -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    } catch { Log ("[ERROR] " + $_.Exception.Message) }
}

function Reparar-Diadema {
    if(-not (Test-Path $nircmd)){ Obtener-Nircmd }
    if(-not (Test-Path $nircmd)){
        Log "[X] No se pudo obtener el complemento de audio (posible antivirus)."
        return
    }
    Log "Quitando el silencio del sistema..."
    & $nircmd mutesysvolume 0
    Log "Subiendo el volumen a un nivel audible..."
    & $nircmd setsysvolume 45000
    if($DiademaNombre){
        Log "Fijando '$DiademaNombre' como dispositivo predeterminado..."
        & $nircmd setdefaultsounddevice "$DiademaNombre" 1
        & $nircmd setdefaultsounddevice "$DiademaNombre" 2
        Log "[OK] Diadema configurada."
    } else {
        Log "Abriendo el panel de sonido para seleccionar la diadema a mano..."
        Start-Process control "mmsys.cpl"
        Mostrar-GuiaDiadema
        Log "Se mostro la guia para seleccionar la diadema (USB Audio Device)."
    }
}

function LogArchivo($t){ try { Add-Content -Path $LogFile -Value $t -Encoding UTF8 } catch {} }

# ============================================================
#  CENTRALIZADOR (cliente) - reporte de uso y autoactualizacion
# ============================================================
function Firmar-Hmac($mensaje){
    $h = New-Object System.Security.Cryptography.HMACSHA256
    $h.Key = [Text.Encoding]::UTF8.GetBytes($HmacSecret)
    return [Convert]::ToBase64String($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($mensaje)))
}

function Enviar-Central($accion, $resultado, $detalle=""){
    if([string]::IsNullOrWhiteSpace($CentralUrl)){ return }
    $payload = @{
        device_id = $DeviceId; equipo = $env:COMPUTERNAME; usuario = $env:USERNAME
        alianza = $Alianza; version = $AgentVersion
        accion = $accion; resultado = $resultado; ts = (Get-Date).ToString("o")
    } | ConvertTo-Json -Compress
    $enviado = $false
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-RestMethod -Uri ($CentralUrl.TrimEnd('/') + "/checkin") -Method Post -Body $payload `
            -Headers @{ "x-api-key" = $ApiKey; "x-sign" = (Firmar-Hmac $payload); "content-type" = "application/json" } `
            -TimeoutSec 8 | Out-Null
        $enviado = $true
    } catch {}
    if(-not $enviado){ try { Add-Content -Path (Join-Path $BaseDir "pendientes.jsonl") -Value $payload -Encoding UTF8 } catch {} }
}

function Vaciar-Cola {
    if([string]::IsNullOrWhiteSpace($CentralUrl)){ return }
    $cola = Join-Path $BaseDir "pendientes.jsonl"
    if(-not (Test-Path $cola)){ return }
    $lineas = @(Get-Content $cola -ErrorAction SilentlyContinue)
    if($lineas.Count -eq 0){ return }
    $quedan = @()
    foreach($l in $lineas){
        if([string]::IsNullOrWhiteSpace($l)){ continue }
        try {
            Invoke-RestMethod -Uri ($CentralUrl.TrimEnd('/') + "/checkin") -Method Post -Body $l `
                -Headers @{ "x-api-key" = $ApiKey; "x-sign" = (Firmar-Hmac $l); "content-type" = "application/json" } -TimeoutSec 8 | Out-Null
        } catch { $quedan += $l }
    }
    try { if($quedan.Count){ Set-Content -Path $cola -Value $quedan -Encoding UTF8 } else { Remove-Item $cola -Force -ErrorAction SilentlyContinue } } catch {}
}

function Buscar-Actualizacion {
    if([string]::IsNullOrWhiteSpace($CentralUrl)){ return }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $r = Invoke-RestMethod -Uri ($CentralUrl.TrimEnd('/') + "/version") -Method Get -Headers @{ "x-api-key" = $ApiKey } -TimeoutSec 8
        if(-not $r.version -or [string]::IsNullOrWhiteSpace($r.url)){ return }
        if([version]$r.version -le [version]$AgentVersion){ return }   # solo si es mas nueva

        $tmp = Join-Path $env:TEMP ("agente_" + $r.version + ".ps1")
        Invoke-WebRequest -Uri $r.url -OutFile $tmp -UseBasicParsing -TimeoutSec 20
        $bytes = [IO.File]::ReadAllBytes($tmp)

        # 1) Huella SHA-256
        $sha = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
        $shaHex = -join ($sha | ForEach-Object { $_.ToString("x2") })
        if($shaHex -ne $r.sha256){ LogArchivo "[X] Update: huella no coincide."; Remove-Item $tmp -Force -ErrorAction SilentlyContinue; return }

        # 2) FIRMA DIGITAL con la llave publica (clave de seguridad)
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rsa.FromXmlString($PubKeyXml)
        if(-not $rsa.VerifyData($bytes, "SHA256", [Convert]::FromBase64String($r.signature))){
            LogArchivo "[X] Update: firma invalida, se ignora (posible manipulacion)."; Remove-Item $tmp -Force -ErrorAction SilentlyContinue; return
        }

        # 3) Reemplazar el cerebro (aplica en el proximo arranque)
        Copy-Item $tmp (Join-Path $env:AGENTE_DIR "diagnostico.ps1") -Force
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        LogArchivo ("[OK] Actualizado a la version " + $r.version)
        Enviar-Central "autoactualizacion" ("v" + $r.version)
    } catch { LogArchivo ("[X] Update: " + $_.Exception.Message) }
}

function Crear-AccesoDirecto($target){
    $icono = if(Test-Path $IcoPath){ "$IcoPath,0" } else { "imageres.dll,109" }
    $ws = $null
    try { $ws = New-Object -ComObject WScript.Shell } catch { LogArchivo "[X] No se pudo iniciar WScript.Shell."; return }

    # Reunir todas las rutas de escritorio posibles (usuario, OneDrive, publico)
    $cands = @()
    try { $cands += $ws.SpecialFolders("Desktop") } catch {}
    if($env:OneDrive)         { $cands += (Join-Path $env:OneDrive "Desktop") }
    if($env:OneDriveCommercial){ $cands += (Join-Path $env:OneDriveCommercial "Desktop") }
    $cands += (Join-Path $env:USERPROFILE "Desktop")
    $cands += (Join-Path $env:PUBLIC "Desktop")
    $cands = $cands | Where-Object { $_ } | Select-Object -Unique

    $creado = $false
    foreach($dk in $cands){
        try{
            if(Test-Path $dk){
                $dest = Join-Path $dk "Asistente TI.lnk"
                $lnk = $ws.CreateShortcut($dest)
                $lnk.TargetPath = $target
                $lnk.WorkingDirectory = (Split-Path $target)
                $lnk.IconLocation = $icono
                $lnk.Description = "Asistente TI - Mesa de Ayuda"
                $lnk.Save()
                LogArchivo ("[OK] Acceso directo creado en: " + $dest)
                $creado = $true
                break
            }
        } catch { LogArchivo ("[X] Fallo acceso directo en " + $dk + ": " + $_.Exception.Message) }
    }
    if(-not $creado){ LogArchivo "[X] No se pudo crear el acceso directo en ningun escritorio." }
    return $creado
}

function Limpiar-Previo {
    # Se ejecuta en la PRIMERA instalacion: borra restos de versiones anteriores.
    LogArchivo "== Limpieza de instalaciones previas =="

    # 1) Tareas programadas viejas (nombres actuales y anteriores)
    foreach($tn in @("AgenteDiagnostico-LimpiezaInicio","AgenteDiagnostico-Apagado21h","\Mantenimiento\Limpieza inicio","\Mantenimiento\Apagado 21h")){
        try { schtasks /Delete /TN $tn /F 2>$null | Out-Null } catch {}
    }

    # 2) Accesos directos viejos en TODOS los escritorios (nombres actuales y anteriores)
    $nombres = @("Asistente TI.lnk","Agente de Diagnostico.lnk","Agente de Diagnostico (unico).lnk","AgenteDiagnostico.lnk")
    $desks = @()
    try { $ws = New-Object -ComObject WScript.Shell; $desks += $ws.SpecialFolders("Desktop") } catch {}
    if($env:OneDrive)          { $desks += (Join-Path $env:OneDrive "Desktop") }
    if($env:OneDriveCommercial){ $desks += (Join-Path $env:OneDriveCommercial "Desktop") }
    $desks += (Join-Path $env:USERPROFILE "Desktop")
    $desks += (Join-Path $env:PUBLIC "Desktop")
    foreach($d in ($desks | Where-Object { $_ } | Select-Object -Unique)){
        foreach($n in $nombres){
            try { $p = Join-Path $d $n; if(Test-Path $p){ Remove-Item $p -Force -ErrorAction SilentlyContinue; LogArchivo ("  quitado acceso directo: " + $p) } } catch {}
        }
    }

    # 3) Carpetas de instalacion anteriores (deja intacta la actual $BaseDir)
    $viejas = @(
        (Join-Path $env:ProgramData "AgenteDiagnostico"),
        (Join-Path $env:LOCALAPPDATA "AgenteDiagnostico"),
        (Join-Path $env:ProgramData "Agente de Diagnostico")
    )
    foreach($ruta in $viejas){
        try {
            if((Test-Path $ruta) -and ($ruta -ne $BaseDir)){ Remove-Item $ruta -Recurse -Force -ErrorAction SilentlyContinue; LogArchivo ("  quitada carpeta: " + $ruta) }
        } catch {}
    }
}

function Mostrar-GuiaDiadema {
    $g = New-Object System.Windows.Forms.Form
    $g.Text = "Configurar la diadema"
    $g.Size = New-Object System.Drawing.Size(490,360)
    $g.StartPosition = "CenterScreen"
    $g.FormBorderStyle = "FixedDialog"
    $g.MaximizeBox = $false; $g.MinimizeBox = $false
    $g.TopMost = $true
    $g.BackColor = $blanco

    $t = New-Object System.Windows.Forms.Label
    $t.Text = "Se abrio la ventana de Sonido de Windows. Siga estos pasos:`r`n`r`n1. En la pestana 'Reproduccion', haga clic en 'USB Audio Device' (su diadema).`r`n2. Haga clic en el boton 'Predeterminar'.`r`n3. Haga clic en 'Aceptar' para cerrar la ventana de Sonido."
    $t.Font = New-Object System.Drawing.Font("Segoe UI",10)
    $t.Location = New-Object System.Drawing.Point(20,15)
    $t.Size = New-Object System.Drawing.Size(450,175)
    $g.Controls.Add($t)

    $b = New-Object System.Windows.Forms.Label
    $b.Text = "IMPORTANTE: revise el boton de silencio (MUTE) que va en el CABLE de la diadema. A veces esta activado sin darse cuenta."
    $b.Font = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
    $b.ForeColor = [System.Drawing.Color]::FromArgb(200,60,0)
    $b.Location = New-Object System.Drawing.Point(20,195)
    $b.Size = New-Object System.Drawing.Size(450,75)
    $g.Controls.Add($b)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "Entendido"
    $ok.Font = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
    $ok.ForeColor = $blanco
    $ok.BackColor = $naranja
    $ok.FlatStyle = "Flat"
    $ok.FlatAppearance.BorderSize = 0
    $ok.Location = New-Object System.Drawing.Point(185,280)
    $ok.Size = New-Object System.Drawing.Size(120,36)
    $ok.Add_Click({ $g.Close() })
    $g.Controls.Add($ok)
    Redondear $ok 12

    [void]$g.ShowDialog()
}

function Abrir-URL {
    Log "Abriendo la pagina correcta de acceso..."
    Start-Process $UrlAccess
    Log "[OK] $UrlAccess"
    Log "Si tambien sale 'pagina no encontrada', suele ser la IP publica"
    Log "del modem (debe ser FIJA). Eso lo resuelve el proveedor."
}

function Reparar-Red {
    Log "Reparando la red local (esto NO reinicia el modem fisico)..."
    $wifi = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' -and $_.Name -match 'Wi-?Fi|Wireless|inalamb' }
    if($wifi){ Log "[AVISO] Estas por Wi-Fi. Se recomienda cable de red." }
    else     { Log "Conexion por cable detectada (recomendado)." }
    cmd /c "ipconfig /release"  | Out-Null
    cmd /c "ipconfig /renew"    | Out-Null
    cmd /c "ipconfig /flushdns" | Out-Null
    cmd /c "netsh winsock reset" | Out-Null
    Log "[OK] Red local reparada. Si sigue fallando, reinicia el modem a mano."
}

function Probar-Conexion {
    Log "=== Diagnostico de red (solo mide, no cambia nada) ==="

    # 1) Puerto (prueba rapida con limite de 3 segundos)
    Log ""
    Log ("Probando el puerto {0} en {1} (max 3 seg) ..." -f $PuertoTest, $PuertoHost)
    try{
        $cliente = New-Object System.Net.Sockets.TcpClient
        $iar = $cliente.BeginConnect($PuertoHost, $PuertoTest, $null, $null)
        $ok  = $iar.AsyncWaitHandle.WaitOne(3000, $false)
        if($ok -and $cliente.Connected){
            $cliente.EndConnect($iar)
            Log ("[OK] El puerto {0} esta ABIERTO / habilitado." -f $PuertoTest)
        } else {
            Log ("[X] El puerto {0} esta CERRADO o no responde (timeout 3s)." -f $PuertoTest)
        }
        $cliente.Close()
    } catch { Log ("[X] No se pudo conectar al puerto {0}: " -f $PuertoTest) + $_.Exception.Message }

    # 2) Latencia (4 pings de 1 seg cada uno)
    Log ""
    Log ("Midiendo latencia hacia {0} ..." -f $PingHost)
    try{
        $ping = New-Object System.Net.NetworkInformation.Ping
        $enviados = 6
        $tiempos = @()
        for($k=0; $k -lt $enviados; $k++){
            try{
                $r = $ping.Send($PingHost, 1000)
                if($r.Status -eq 'Success'){ $tiempos += [int]$r.RoundtripTime }
            } catch {}
            [System.Windows.Forms.Application]::DoEvents()
        }
        $recibidos = $tiempos.Count
        $perdidos  = $enviados - $recibidos
        $pctPerd   = [math]::Round(($perdidos / $enviados) * 100, 0)
        if($recibidos -gt 0){
            $prom = [math]::Round(($tiempos | Measure-Object -Average).Average,0)
            $min  = ($tiempos | Measure-Object -Minimum).Minimum
            $max  = ($tiempos | Measure-Object -Maximum).Maximum
            Log ("[OK] Latencia -> promedio: {0} ms | minima: {1} ms | maxima: {2} ms" -f $prom, $min, $max)
            Log ("     Paquetes: {0} enviados, {1} recibidos, {2} perdidos ({3}%)" -f $enviados, $recibidos, $perdidos, $pctPerd)
            if($perdidos -gt 0){ Log "[X] Hay perdida de paquetes: la red esta inestable." }
            if($prom -lt 60){ Log "   -> Latencia excelente." }
            elseif($prom -lt 150){ Log "   -> Latencia aceptable." }
            else { Log "   -> Latencia alta: puede causar cortes en la voz." }
        } else {
            Log ("[X] Sin respuesta de {0}: {1} paquetes perdidos (100%)." -f $PingHost, $enviados)
        }
    } catch { Log ("[X] No se pudo medir la latencia.") }

    # 3) Velocidad de descarga (con timeout, leyendo por partes)
    Log ""
    Log "Midiendo velocidad de descarga (espera unos segundos)..."
    try{
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $req = [System.Net.HttpWebRequest]::Create("https://speed.cloudflare.com/__down?bytes=$SpeedBytes")
        $req.Timeout = 15000
        $req.ReadWriteTimeout = 15000
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = $req.GetResponse()
        $stream = $resp.GetResponseStream()
        $buffer = New-Object byte[] 65536
        $total = 0
        while(($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0){
            $total += $n
            [System.Windows.Forms.Application]::DoEvents()
        }
        $sw.Stop(); $stream.Close(); $resp.Close()
        $seg  = $sw.Elapsed.TotalSeconds
        $mb   = [math]::Round($total / 1MB, 1)
        $mbps = [math]::Round(($total * 8 / 1000000) / $seg, 1)
        Log ("[OK] {0} MB en {1} s" -f $mb, [math]::Round($seg,1))
        Log ("   -> Velocidad de bajada: {0} Mbps" -f $mbps)
    } catch { Log ("[X] No se pudo medir la velocidad: " + $_.Exception.Message) }

    Log ""
    Log "Nota: los valores pueden variar por el proxy o firewall de la empresa."
}

function Mantenimiento-Completo {
    Log "=== Mantenimiento completo ==="
    Reparar-Navegador
    cmd /c "ipconfig /flushdns" | Out-Null
    Log "[OK] Terminado."
}

function Instalar-Tareas($self){
    # Se ejecuta UNA sola vez (primer arranque del Agente).
    # Crea: 1) limpieza al iniciar sesion  2) apagado a las 21:00
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

    # 1) Limpieza al inicio -> llama a este mismo archivo en modo /limpieza
    try {
        $accLimp = New-ScheduledTaskAction -Execute "cmd.exe" -Argument ('/c "' + $self + '" /limpieza')
        # AtLogOn: se dispara en CADA inicio de sesion (arranque total o "resume" por Inicio rapido)
        $trgLimp = New-ScheduledTaskTrigger -AtLogOn
        Register-ScheduledTask -TaskName "AgenteDiagnostico-LimpiezaInicio" -Action $accLimp -Trigger $trgLimp -Principal $principal -Force -ErrorAction Stop | Out-Null
    } catch {}

    # 2) Apagado diario a las 21:00 (avisa 60s antes; cancelable con shutdown /a)
    try {
        $argApagar = '/s /t 60 /c "Apagado programado de las 21:00. Guarde su trabajo. Para cancelar ejecute: shutdown /a"'
        $accApag = New-ScheduledTaskAction -Execute "shutdown.exe" -Argument $argApagar
        $trgApag = New-ScheduledTaskTrigger -Daily -At "21:00"
        Register-ScheduledTask -TaskName "AgenteDiagnostico-Apagado21h" -Action $accApag -Trigger $trgApag -Principal $principal -Force -ErrorAction Stop | Out-Null
    } catch {}
}

# ============================================================
#  MODO SILENCIOSO: limpieza al iniciar Windows (sin ventana)
#  Lo dispara la tarea programada llamando al archivo con /limpieza
# ============================================================
if($env:MODO -eq 'LIMPIEZA'){
    Log "================================================================"
    Log ("Limpieza automatica al inicio - " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
    Log ("Equipo: $env:COMPUTERNAME")
    Mantenimiento-Completo
    Log "--- Fin limpieza automatica ---"
    exit
}

# ============================================================
#  PANTALLA INICIAL: seleccion de alianza
# ============================================================
$fSel = New-Object System.Windows.Forms.Form
$fSel.Text = "Seleccione su alianza"
$fSel.Size = New-Object System.Drawing.Size(400,240)
$fSel.StartPosition = "CenterScreen"
$fSel.FormBorderStyle = "FixedDialog"
$fSel.MaximizeBox = $false
$fSel.MinimizeBox = $false
$fSel.BackColor = $blanco

$lblSel = New-Object System.Windows.Forms.Label
$lblSel.Text = "Antes de comenzar, indique a que alianza pertenece:"
$lblSel.Font = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
$lblSel.Location = New-Object System.Drawing.Point(25,25)
$lblSel.Size = New-Object System.Drawing.Size(340,40)
$fSel.Controls.Add($lblSel)

$rbUni = New-Object System.Windows.Forms.RadioButton
$rbUni.Text = "Uniminuto"
$rbUni.Font = New-Object System.Drawing.Font("Segoe UI",11)
$rbUni.Location = New-Object System.Drawing.Point(45,75)
$rbUni.Size = New-Object System.Drawing.Size(300,28)
$rbUni.Checked = $true
$fSel.Controls.Add($rbUni)

$rbOpm = New-Object System.Windows.Forms.RadioButton
$rbOpm.Text = "OPM"
$rbOpm.Font = New-Object System.Drawing.Font("Segoe UI",11)
$rbOpm.Location = New-Object System.Drawing.Point(45,108)
$rbOpm.Size = New-Object System.Drawing.Size(300,28)
$fSel.Controls.Add($rbOpm)

$btnCont = New-Object System.Windows.Forms.Button
$btnCont.Text = "Continuar"
$btnCont.Font = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
$btnCont.ForeColor = $blanco
$btnCont.BackColor = $naranja
$btnCont.FlatStyle = "Flat"
$btnCont.FlatAppearance.BorderSize = 0
$btnCont.Location = New-Object System.Drawing.Point(130,155)
$btnCont.Size = New-Object System.Drawing.Size(130,38)
$btnCont.Add_Click({ $fSel.Tag = $(if($rbOpm.Checked){'OPM'}else{'Uniminuto'}); $fSel.Close() })
$fSel.Controls.Add($btnCont)
Redondear $btnCont 12

[void]$fSel.ShowDialog()

# ---- Aplicar la alianza elegida ----
if($fSel.Tag -eq 'OPM'){ $Alianza = 'OPM'; $PuertoHost = $IpOPM }
else { $Alianza = 'Uniminuto'; $PuertoHost = $IpUniminuto }

# ============================================================
#  VENTANA (interfaz grafica)
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text =  "Agente TI"
$form.Size = New-Object System.Drawing.Size(660,525)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = $blanco

# ---- Panel izquierdo (banner morado) ----
$panel = New-Object System.Windows.Forms.Panel
$panel.Size = New-Object System.Drawing.Size(190,525)
$panel.Location = New-Object System.Drawing.Point(0,0)
$panel.BackColor = $morado
$form.Controls.Add($panel)

$lblTitulo = New-Object System.Windows.Forms.Label
$lblTitulo.Text = "Agente`r`nTI"
$lblTitulo.ForeColor = $blanco
$lblTitulo.Font = New-Object System.Drawing.Font("Segoe UI",18,[System.Drawing.FontStyle]::Bold)
$lblTitulo.Location = New-Object System.Drawing.Point(15,30)
$lblTitulo.Size = New-Object System.Drawing.Size(165,80)
$panel.Controls.Add($lblTitulo)

$barra = New-Object System.Windows.Forms.Panel
$barra.Size = New-Object System.Drawing.Size(60,5)
$barra.Location = New-Object System.Drawing.Point(15,115)
$barra.BackColor = $naranja
$panel.Controls.Add($barra)

$lblPie = New-Object System.Windows.Forms.Label
$lblPie.Text = "Mesa de Ayuda`r`nScala Learning"
$lblPie.ForeColor = $blanco
$lblPie.Font = New-Object System.Drawing.Font("Segoe UI",9)
$lblPie.Location = New-Object System.Drawing.Point(15,400)
$lblPie.Size = New-Object System.Drawing.Size(165,40)
$panel.Controls.Add($lblPie)

# ---- Instruccion ----
$lblInstr = New-Object System.Windows.Forms.Label
$lblInstr.Text = "Seleccione el problema que tiene y pulse Ejecutar:"
$lblInstr.Font = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
$lblInstr.Location = New-Object System.Drawing.Point(210,25)
$lblInstr.Size = New-Object System.Drawing.Size(420,25)
$form.Controls.Add($lblInstr)

# ---- Opciones (radio buttons) ----
$opciones = @(
    "Pagina en blanco o lentitud",
    "El agente / aplicativo no abre",
    "No me escuchan o no escucho (diadema)",
    "Pagina no encontrada (abrir acceso)",
    "Internet lento o con fallos",
    "Probar conexion (latencia, velocidad, puerto $PuertoTest)",
    "Mantenimiento completo"
)
$radios = @()
$y = 55
foreach($o in $opciones){
    $r = New-Object System.Windows.Forms.RadioButton
    $r.Text = $o
    $r.Font = New-Object System.Drawing.Font("Segoe UI",10)
    $r.Location = New-Object System.Drawing.Point(215,$y)
    $r.Size = New-Object System.Drawing.Size(420,26)
    $form.Controls.Add($r)
    $radios += $r
    $y += 27
}
$radios[0].Checked = $true

# ---- Caja de resultados ----
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(245,245,245)
$txtLog.Font = New-Object System.Drawing.Font("Consolas",9)
$txtLog.Location = New-Object System.Drawing.Point(215,258)
$txtLog.Size = New-Object System.Drawing.Size(415,150)
$form.Controls.Add($txtLog)

# ---- Fila de botones (simetrica, bordes redondeados) ----
$btnY = 418
$btnW = 128
$btnH = 40

# Boton Ejecutar
$btnEjec = New-Object System.Windows.Forms.Button
$btnEjec.Text = "Ejecutar"
$btnEjec.Font = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
$btnEjec.ForeColor = $blanco
$btnEjec.BackColor = $naranja
$btnEjec.FlatStyle = "Flat"
$btnEjec.FlatAppearance.BorderSize = 0
$btnEjec.Location = New-Object System.Drawing.Point(215,$btnY)
$btnEjec.Size = New-Object System.Drawing.Size($btnW,$btnH)
$form.Controls.Add($btnEjec)
Redondear $btnEjec 12

# Boton Resultado
$btnResultado = New-Object System.Windows.Forms.Button
$btnResultado.Text = "Resultado"
$btnResultado.Font = New-Object System.Drawing.Font("Segoe UI",10)
$btnResultado.ForeColor = $morado
$btnResultado.BackColor = $grisclaro
$btnResultado.FlatStyle = "Flat"
$btnResultado.FlatAppearance.BorderSize = 0
$btnResultado.Location = New-Object System.Drawing.Point(358,$btnY)
$btnResultado.Size = New-Object System.Drawing.Size($btnW,$btnH)
$btnResultado.Add_Click({ if(Test-Path $LogFile){ Start-Process notepad.exe $LogFile } else { [System.Windows.Forms.MessageBox]::Show("Aun no hay resultado. Ejecuta una opcion primero.","Resultado") | Out-Null } })
$form.Controls.Add($btnResultado)
Redondear $btnResultado 12

# Boton Cerrar
$btnCerrar = New-Object System.Windows.Forms.Button
$btnCerrar.Text = "Cerrar"
$btnCerrar.Font = New-Object System.Drawing.Font("Segoe UI",10)
$btnCerrar.ForeColor = $morado
$btnCerrar.BackColor = $grisclaro
$btnCerrar.FlatStyle = "Flat"
$btnCerrar.FlatAppearance.BorderSize = 0
$btnCerrar.Location = New-Object System.Drawing.Point(501,$btnY)
$btnCerrar.Size = New-Object System.Drawing.Size($btnW,$btnH)
$btnCerrar.Add_Click({ $form.Close() })
$form.Controls.Add($btnCerrar)
Redondear $btnCerrar 12

# ---- Accion del boton Ejecutar ----
$btnEjec.Add_Click({
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $btnEjec.Enabled = $false
    $txtLog.Clear()
    $script:errores = 0
    try{
        $idx = 0
        for($i=0; $i -lt $radios.Count; $i++){ if($radios[$i].Checked){ $idx = $i; break } }
        $sel = $radios[$idx].Text

        # ---- Encabezado del registro ----
        Log "================================================================"
        Log ("Fecha:   " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
        Log ("Equipo:  $env:COMPUTERNAME     Usuario: $env:USERNAME")
        Log ("Alianza: $Alianza  (servidor $PuertoHost)")
        Log ("Sesion iniciada: " + $(if($sesion){$sesion.ToString('dd/MM/yyyy hh:mm tt')}else{'no disponible'}))
        Log ("Equipo encendido: " + $(if($boot){$boot.ToString('dd/MM/yyyy hh:mm tt')}else{'no disponible'}))
        Log ("Accion:  $sel")
        Log "----------------------------------------------------------------"

        switch($idx){
            0 { Reparar-Navegador }
            1 { Reparar-Agente }
            2 { Reparar-Diadema }
            3 { Abrir-URL }
            4 { Reparar-Red }
            5 { Probar-Conexion }
            6 { Mantenimiento-Completo }
        }
        Log ""
        Log "--- Proceso finalizado ---"
    } catch {
        Log ("[ERROR] " + $_.Exception.Message)
    } finally {
        # ---- Resumen final ----
        Log ""
        if($script:errores -gt 0){
            Log "****************************************************************"
            Log "  SE ENCONTRARON NOVEDADES / ERRORES DURANTE LA REVISION."
            Log "  Por favor comuniquese con el area de TI."
            Log "****************************************************************"
            [System.Windows.Forms.MessageBox]::Show(
                "Se encontraron novedades durante la revision.`n`nPor favor comuniquese con el area de TI.`n`nEl detalle quedo guardado en:`n$LogFile",
                "Resultado de la revision",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        } else {
            Log "Sin novedades: todo se ejecuto correctamente."
        }
        Log ("Registro guardado en: " + $LogFile)
        Log ""
        # Reportar al centralizador la accion ejecutada (no bloquea)
        try { $acc = if($sel){ $sel } else { "ejecucion" }; $det = if($txtLog.Text.Length -gt 3500){ $txtLog.Text.Substring(0,3500) } else { $txtLog.Text }; Enviar-Central $acc $(if($script:errores -gt 0){"novedad"}else{"ok"}) $det } catch {}
        $btnEjec.Enabled = $true
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# ---- Fecha/hora en que se encendio el equipo ----
try { $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } catch { $boot = $null }
# Inicio de sesion real = cuando cargo el escritorio (explorer). Fiable aunque haya Inicio rapido y sin clave.
try { $sesion = (Get-Process explorer -ErrorAction Stop | Sort-Object StartTime | Select-Object -First 1).StartTime } catch { $sesion = $null }
$txtBoot   = $(if($boot){ $boot.ToString("dd/MM/yyyy hh:mm tt") } else { "no disponible" })
$txtSesion = $(if($sesion){ $sesion.ToString("dd/MM/yyyy hh:mm tt") } else { "no disponible" })
$lblBoot = New-Object System.Windows.Forms.Label
$lblBoot.Text = "Sesion iniciada: $txtSesion     |     Encendido: $txtBoot"
$lblBoot.Font = New-Object System.Drawing.Font("Segoe UI",8)
$lblBoot.ForeColor = [System.Drawing.Color]::FromArgb(110,110,110)
$lblBoot.Location = New-Object System.Drawing.Point(215,466)
$lblBoot.Size = New-Object System.Drawing.Size(415,22)
$form.Controls.Add($lblBoot)

# ---- Primera vez: instalar mantenimiento automatico (apagado 9pm + limpieza) ----
# ---- Instalacion / mantenimiento (protegido: la ventana SIEMPRE debe abrir) ----
try {
$marker = Join-Path $BaseDir "instalado.flag"
$primeraVez = -not (Test-Path $marker)
if($primeraVez){ Limpiar-Previo }

# El programa se ejecuta EN SU SITIO (no se copia). Todo apunta a su ubicacion actual.
$InstallSelf = $env:AGENTE_SELF

# Acceso directo en el escritorio -> a la ubicacion actual del programa
Crear-AccesoDirecto $InstallSelf | Out-Null

# ---- SOLO la primera vez: tareas + Inicio rapido + aviso ----
if($primeraVez){
    # Desactivar el Inicio rapido (apagados totales, hora real, USB mas estable)
    try { Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue } catch {}

    # Tareas programadas (apagado 21:00 + limpieza al iniciar sesion)
    Instalar-Tareas $InstallSelf

    try { Set-Content -Path $marker -Value ("Instalado: " + (Get-Date)) -ErrorAction SilentlyContinue } catch {}

    [System.Windows.Forms.MessageBox]::Show(
        "Listo. Se configuro este equipo:`n`n - Acceso directo 'Asistente TI' en el escritorio.`n - Limpieza automatica en cada inicio de sesion.`n - Apagado programado a las 9:00 pm (avisa 60 seg antes).`n - Se desactivo el Inicio rapido (apagados completos).`n`nIMPORTANTE: deja esta carpeta donde esta (no la muevas ni la borres); el acceso directo apunta aqui:`n$env:AGENTE_DIR",
        "Configuracion completada",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}
} catch {
    try { [System.Windows.Forms.MessageBox]::Show("No se pudo completar la configuracion automatica:`n`n" + $_.Exception.Message + "`n`nEl programa funcionara igual. Si continua, avisa a TI.","Aviso",'OK','Warning') | Out-Null } catch {}
}

# ---- Centralizador: vaciar cola, buscar actualizacion y reportar inicio (no bloquea) ----
try { Vaciar-Cola } catch {}
try { Buscar-Actualizacion } catch {}
try { Enviar-Central "inicio" "ok" } catch {}

[void]$form.ShowDialog()
