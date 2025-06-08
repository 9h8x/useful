#!/bin/bash

echo -e "\e[32m🚀 Iniciando N8N con Túnel de Cloudflare...\e[0m"

INITIAL_DOCKER_COMPOSE=$(cat << 'EOF'
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
EOF
)

echo -e "\e[33m📁 Creando directorios necesarios...\e[0m"
mkdir -p ./n8n/backup
mkdir -p ./shared

echo -e "\e[33m📝 Escribiendo docker-compose.yml inicial...\e[0m"
echo "$INITIAL_DOCKER_COMPOSE" > docker-compose.yml

echo -e "\e[33m📦 Iniciando servicios...\e[0m"
docker compose up -d

echo -e "\e[33m⏳ Esperando que los servicios se inicialicen...\e[0m"
sleep 20

echo -e "\e[33m🔍 Extrayendo URL del túnel desde los logs...\e[0m"

TUNNEL_URL=""
MAX_ATTEMPTS=60

for ((i=1; i<=MAX_ATTEMPTS; i++)); do
    echo -ne "Buscando URL del túnel: Intento $i de $MAX_ATTEMPTS\r"
    
    LOGS=$(docker logs cloudflared 2>&1)
    echo "$LOGS" > cloudflared_logs.txt
    
    # Buscar patrones de URL en los logs
    URL_MATCH=$(echo "$LOGS" | grep -o -E 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | head -n 1)
    
    if [ -z "$URL_MATCH" ]; then
        URL_MATCH=$(echo "$LOGS" | grep -o -E 'https://[a-zA-Z0-9-]+\.cloudflareaccess\.com' | head -n 1)
    fi
    
    if [ -z "$URL_MATCH" ]; then
        URL_MATCH=$(echo "$LOGS" | grep -o -E 'Your quick Tunnel: (https://[a-zA-Z0-9-]+\.[a-zA-Z0-9.-]+)' | sed -E 's/.*Your quick Tunnel: (https:\/\/[a-zA-Z0-9-]+\.[a-zA-Z0-9.-]+).*/\1/' | head -n 1)
    fi
    
    if [ -n "$URL_MATCH" ]; then
        TUNNEL_URL="$URL_MATCH"
        break
    fi
    
    sleep 3
done

echo -e "\n"

if [ -z "$TUNNEL_URL" ]; then
    echo -e "\e[31m❌ Falló la extracción de URL del túnel después de $MAX_ATTEMPTS intentos\e[0m"
    echo ""
    echo -e "\e[33m📋 Logs recientes de Cloudflared:\e[0m"
    docker logs --tail 50 cloudflared
    echo ""
    echo -e "\e[33m🔍 Por favor busca un patrón de URL como 'https://algo.trycloudflare.com' en los logs anteriores\e[0m"
    echo -e "\e[33mSi ves la URL, puedes actualizar manualmente el archivo docker-compose.yml\e[0m"
    echo ""
    echo -n "Ingresa la URL del túnel manualmente (o presiona Enter para salir): "
    read MANUAL_URL
    
    if [ -z "$MANUAL_URL" ]; then
        echo -e "\e[31mSaliendo...\e[0m"
        exit 1
    fi
    
    TUNNEL_URL=$(echo "$MANUAL_URL" | xargs)
fi

echo -e "\e[32m✅ URL del túnel encontrada: $TUNNEL_URL\e[0m"

if ! echo "$TUNNEL_URL" | grep -qE '^https://[a-zA-Z0-9-]+\.[a-zA-Z0-9.-]+'; then
    echo -e "\e[33m⚠️ Advertencia: El formato de URL parece incorrecto. Por favor verifica: $TUNNEL_URL\e[0m"
    echo -n "¿Continuar de todos modos? (s/N): "
    read CONFIRM
    if [ "$CONFIRM" != "s" ] && [ "$CONFIRM" != "S" ]; then
        exit 1
    fi
fi

TUNNEL_HOST=$(echo "$TUNNEL_URL" | sed 's|https://||')

echo -e "\e[33m🔧 Actualizando configuración de N8N con URL del túnel...\e[0m"

UPDATED_DOCKER_COMPOSE=$(cat << EOF
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
      - N8N_HOST=$TUNNEL_HOST
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - N8N_DEFAULT_LOCALE=es
      - WEBHOOK_URL=$TUNNEL_URL/
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
EOF
)

cp docker-compose.yml docker-compose.yml.backup
echo "$UPDATED_DOCKER_COMPOSE" > docker-compose.yml

echo -e "\e[33m🔄 Reiniciando N8N con configuración actualizada...\e[0m"
docker compose up -d --force-recreate n8n

echo -e "\e[33m⏳ Esperando que N8N se reinicie...\e[0m"
sleep 20

echo -e "\e[33m🔍 Verificando que N8N sea accesible...\e[0m"
if command -v curl &> /dev/null; then
    if curl -s --head --request GET "$TUNNEL_URL" | grep "200 OK" > /dev/null; then
        echo -e "\e[32m✅ ¡N8N está respondiendo exitosamente!\e[0m"
    else
        echo -e "\e[33m⚠️ N8N respondió con un código de estado diferente a 200 OK\e[0m"
    fi
else
    echo -e "\e[33m⚠️ No se pudo verificar la accesibilidad de N8N: curl no está instalado\e[0m"
    echo -e "\e[90mEsto podría ser normal si N8N aún se está iniciando.\e[0m"
fi

echo ""
echo -e "\e[32m🎉 ¡Configuración completada!\e[0m"
echo ""
echo -e "\e[36m📊 Estado de los Servicios:\e[0m"
docker ps
echo ""

INFO_CONTENT=$(cat << EOF
Configuración de N8N con Túnel de Cloudflare
============================================
Fecha: $(date "+%Y-%m-%d %H:%M:%S")
URL del Túnel: $TUNNEL_URL
Host: $TUNNEL_HOST

Servicios:
- N8N: http://localhost:5678 (local) / $TUNNEL_URL (público)
- Cloudflared: Proxy del túnel

Comandos:
- Iniciar: docker compose up -d
- Detener: docker compose down
- Logs: docker logs [nombre_contenedor]
- Estado: docker compose ps
EOF
)

echo ""
echo -e "\e[36mConfiguración de N8N con Túnel de Cloudflare\e[0m"
echo -e "\e[36m============================================\e[0m"
echo -e "Fecha: $(date "+%Y-%m-%d %H:%M:%S")"
echo -e "URL del Túnel: $TUNNEL_URL"
echo ""
echo -e "\e[36mServicios:\e[0m"
echo -e "- N8N: http://localhost:5678 (local) / $TUNNEL_URL (público)"
echo -e "- Cloudflared: Proxy del túnel"
echo ""
echo -e "\e[36mComandos:\e[0m"
echo -e "- Iniciar: docker compose up -d"
echo -e "- Detener: docker compose down"
echo -e "- Logs: docker logs [nombre_contenedor]"
echo -e "- Estado: docker compose ps"
echo ""

echo -n "Presiona Enter para salir..."
read
