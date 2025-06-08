Write-Host "🚀 Iniciando N8N con Túnel de Cloudflare..." -ForegroundColor Green

$initialDockerCompose = @"
volumes:
  n8n_storage:
services:
  n8n:
    image: n8nio/n8n:latest
    ports:
      - "5678:5678"
    container_name: n8n
    restart: unless-stopped
    environment:
      - N8N_HOST=localhost
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - NODE_ENV=production
      - N8N_DEFAULT_LOCALE=es
      - WEBHOOK_URL=http://localhost:5678/
      - NODE_FUNCTION_ALLOW_EXTERNAL=*
    volumes:
      - n8n_storage:/home/node/.n8n
      - ./n8n/backup:/backup
      - ./shared:/data/shared

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate --url http://n8n:5678
    depends_on:
      - n8n
"@

Write-Host "📁 Creando directorios necesarios..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path "./n8n/backup" | Out-Null
New-Item -ItemType Directory -Force -Path "./shared" | Out-Null

Write-Host "📝 Escribiendo docker-compose.yml inicial..." -ForegroundColor Yellow
$initialDockerCompose | Out-File -FilePath "docker-compose.yml" -Encoding UTF8

Write-Host "📦 Iniciando servicios..." -ForegroundColor Yellow
docker-compose up -d

Write-Host "⏳ Esperando que los servicios se inicialicen..." -ForegroundColor Yellow
Start-Sleep -Seconds 20

Write-Host "🔍 Extrayendo URL del túnel desde los logs..." -ForegroundColor Yellow

$tunnelUrl = ""
$maxAttempts = 60
for ($i = 1; $i -le $maxAttempts; $i++) {
    Write-Progress -Activity "Buscando URL del túnel" -Status "Intento $i de $maxAttempts" -PercentComplete (($i / $maxAttempts) * 100)

    $logs = docker logs cloudflared 2>&1

    echo $logs | Out-File -FilePath "cloudflared_logs.txt" -Encoding UTF8

    $urlPatterns = @(
        "https://[a-zA-Z0-9-]+\.trycloudflare\.com",
        "https://[a-zA-Z0-9-]+\.cloudflareaccess\.com",
        "Your quick Tunnel: (https://[a-zA-Z0-9-]+\.[a-zA-Z0-9.-]+)"
    )
    
    foreach ($pattern in $urlPatterns) {
        $urlMatch = $logs | Select-String $pattern | Select-Object -First 1
        
        if ($urlMatch) {
            if ($urlMatch.Line -match $pattern) {
                $tunnelUrl = $matches[1] ?? $matches[0]
                if ($tunnelUrl -match "^https://") {
                    break
                }
            }
        }
    }
    
    if ($tunnelUrl) {
        break
    }
    
    Start-Sleep -Seconds 3
}

Write-Progress -Activity "Buscando URL del túnel" -Completed

if (-not $tunnelUrl) {
    Write-Host "❌ Falló la extracción de URL del túnel después de $maxAttempts intentos" -ForegroundColor Red
    Write-Host ""
    Write-Host "📋 Logs recientes de Cloudflared:" -ForegroundColor Yellow
    Write-Host "$(docker logs --tail 50 cloudflared)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "🔍 Por favor busca un patrón de URL como 'https://algo.trycloudflare.com' en los logs anteriores" -ForegroundColor Yellow
    Write-Host "Si ves la URL, puedes actualizar manualmente el archivo docker-compose.yml" -ForegroundColor Yellow
    Write-Host ""
    $manualUrl = Read-Host "Ingresa la URL del túnel manualmente (o presiona Enter para salir)"
    
    if ([string]::IsNullOrWhiteSpace($manualUrl)) {
        Write-Host "Saliendo..." -ForegroundColor Red
        exit 1
    }
    
    $tunnelUrl = $manualUrl.Trim()
}

Write-Host "✅ URL del túnel encontrada: $tunnelUrl" -ForegroundColor Green

if (-not ($tunnelUrl -match "^https://[a-zA-Z0-9-]+\.[a-zA-Z0-9.-]+")) {
    Write-Host "⚠️ Advertencia: El formato de URL parece incorrecto. Por favor verifica: $tunnelUrl" -ForegroundColor Yellow
    $confirm = Read-Host "¿Continuar de todos modos? (s/N)"
    if ($confirm -ne 's' -and $confirm -ne 'S') {
        exit 1
    }
}

$tunnelHost = $tunnelUrl -replace "https://", ""

Write-Host "🔧 Actualizando configuración de N8N con URL del túnel..." -ForegroundColor Yellow

$updatedDockerCompose = @"
volumes:
  n8n_storage:
services:
  n8n:
    image: n8nio/n8n:latest
    ports:
      - "5678:5678"
    container_name: n8n
    restart: unless-stopped
    environment:
      - N8N_HOST=$tunnelHost
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - N8N_DEFAULT_LOCALE=es
      - WEBHOOK_URL=$tunnelUrl/
      - NODE_FUNCTION_ALLOW_EXTERNAL=*
      - N8N_SECURE_COOKIE=false
      - N8N_METRICS=true
    volumes:
      - n8n_storage:/home/node/.n8n
      - ./n8n/backup:/backup
      - ./shared:/data/shared

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate --url http://n8n:5678
    depends_on:
      - n8n
"@

Copy-Item "docker-compose.yml" "docker-compose.yml.backup"
$updatedDockerCompose | Out-File -FilePath "docker-compose.yml" -Encoding UTF8

Write-Host "🔄 Reiniciando N8N con configuración actualizada..." -ForegroundColor Yellow
docker-compose up -d --force-recreate n8n

Write-Host "⏳ Esperando que N8N se reinicie..." -ForegroundColor Yellow
Start-Sleep -Seconds 20

Write-Host "🔍 Verificando que N8N sea accesible..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri $tunnelUrl -Method GET -TimeoutSec 30 -UseBasicParsing
    if ($response.StatusCode -eq 200) {
        Write-Host "✅ ¡N8N está respondiendo exitosamente!" -ForegroundColor Green
    } else {
        Write-Host "⚠️ N8N respondió con código de estado: $($response.StatusCode)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "⚠️ No se pudo verificar la accesibilidad de N8N: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Esto podría ser normal si N8N aún se está iniciando." -ForegroundColor Gray
}

Write-Host ""
Write-Host "🎉 ¡Configuración completada!" -ForegroundColor Green
Write-Host ""
Write-Host "📊 Estado de los Servicios:" -ForegroundColor Cyan
docker-compose ps
Write-Host ""

$infoContent = @"
Configuración de N8N con Túnel de Cloudflare
============================================
Fecha: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
URL del Túnel: $tunnelUrl
Host: $tunnelHost

Servicios:
- N8N: http://localhost:5678 (local) / $tunnelUrl (público)
- Cloudflared: Proxy del túnel

Comandos:
- Iniciar: docker-compose up -d
- Detener: docker-compose down
- Logs: docker logs [nombre_contenedor]
- Estado: docker-compose ps
"@

Write-Host ""
Write-Host "Configuración de N8N con Túnel de Cloudflare" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Fecha: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")" -ForegroundColor White
Write-Host "URL del Túnel: $tunnelUrl" -ForegroundColor White
Write-Host ""
Write-Host "Servicios:" -ForegroundColor Cyan
Write-Host "- N8N: http://localhost:5678 (local) / $tunnelUrl (público)" -ForegroundColor White
Write-Host "- Cloudflared: Proxy del túnel" -ForegroundColor White
Write-Host ""
Write-Host "Comandos:" -ForegroundColor Cyan
Write-Host "- Iniciar: docker-compose up -d" -ForegroundColor White
Write-Host "- Detener: docker-compose down" -ForegroundColor White
Write-Host "- Logs: docker logs [nombre_contenedor]" -ForegroundColor White
Write-Host "- Estado: docker-compose ps" -ForegroundColor White
Write-Host ""

Read-Host "Presiona Enter para salir..."