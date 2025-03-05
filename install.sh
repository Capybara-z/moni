#!/bin/bash
# Скрипт для установки и настройки мониторинга с nginx, веб‑страницей и Flask‑демоном
# Учитывает:
#  - Вопросы о домене, порте, пути вебхука.
#  - Удаление ведущих и конечных слэшей из вебхука.
#  - Отключение интерактивного окна при установке iperf3 (выбор No).

# Проверка, что скрипт запущен от root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт от root (или с sudo)."
  exit 1
fi

# Чтобы при установке iperf3 не было интерактивного окна:
export DEBIAN_FRONTEND=noninteractive
echo "iperf3 iperf3/daemon boolean false" | debconf-set-selections

echo "===== Шаг 1. Настройка параметров ====="
read -p "Введите доменное имя (например, example.com): " DOMAIN < /dev/tty

read -p "Введите порт для мониторинга (7443 или 8443): " MONITOR_PORT < /dev/tty
if [[ "$MONITOR_PORT" != "7443" && "$MONITOR_PORT" != "8443" ]]; then
  echo "Неверный порт. Будет использован порт 8443 по умолчанию."
  MONITOR_PORT=8443
fi

read -p "Введите путь вебхука бота (например fTCdrLBwRr): " WEBHOOK_PATH < /dev/tty
# Уберём все ведущие и конечные слэши
WEBHOOK_PATH="${WEBHOOK_PATH##/}"
WEBHOOK_PATH="${WEBHOOK_PATH%%/}"

echo "===== Шаг 2. Установка nginx и создание конфига ====="
apt update -y

# Если nginx не установлен – установить его
if ! command -v nginx >/dev/null 2>&1; then
  apt install nginx -y
fi

# Создаём конфигурационный файл для nginx
NGINX_CONFIG="/etc/nginx/sites-available/monitoring.conf"
cat > "$NGINX_CONFIG" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    # Перенаправление HTTP -> HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 127.0.0.1:${MONITOR_PORT} ssl http2 proxy_protocol;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_session_cache shared:SSL:1m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # Настройки Proxy Protocol
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;

    root /var/www/site;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # Обработка запросов для reverse proxy
    location /${WEBHOOK_PATH}/ {
        proxy_pass http://localhost:61016;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Активируем конфиг (если не активирован)
if [ ! -f "/etc/nginx/sites-enabled/monitoring.conf" ]; then
  ln -s "$NGINX_CONFIG" /etc/nginx/sites-enabled/
fi

# Тестируем конфигурацию и перезагружаем nginx
nginx -t && systemctl reload nginx

echo "===== Шаг 3. Создание веб-страницы ====="
mkdir -p /var/www/site
cat > /var/www/site/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
	<meta http-equiv="Content-Type" content="text/html; charset=UTF-8"/>
	<style type="text/css">
		* { 
			margin: 0;
			padding : 0;
			cursor: pointer;
		}
		body, html {
			height: 100%;
			overflow: hidden;
		}
		#instructionPrompt{
			position: relative;
			top: 40%;
			width: 100%;
			display: none;
			text-align: center;
			font-size: 5mm;
		}
	</style>
	<script type="text/javascript">
		/* Ваш HTML/JS код */
		var context, canvasWidth, canvasHeight;
		var mouseX = -1, mouseY = -1, mouseDown = false;
		var shape=[], numShapes = 0, colourAngle = 0, leadShape = null;
		var linkSize = 12, chainLength = 80, shrinkRate = .98;
		var colourOffset = { r : 0, g : 0 ,b : 0 };

		var shapeClass = function(){
			this.colour = { 'R' : 255, 'G' : 255, 'B' : 255 };
			this.position = { x : 0, y : 0 };
			this.numpoints = this.radius = 0;
			this.points = [];
			this.velocity = { x : 0, y : 0 };
			this.opacity = 1;
			this.sine = this.cosine = 0;
			this.parentShape = null;
			this.childShape = null;
		};

		shapeClass.prototype.getTrigVals = function(ang){
			this.sine = Math.sin(ang);
			this.cosine = Math.cos(ang);
		};

		shapeClass.prototype.move = function(){
			var n;
			if(this.parentShape == null){
				this.velocity.y++;
				this.position.x += this.velocity.x;
				this.position.y += this.velocity.y;
			}else{
				px = this.parentShape.position.x;
				py = this.parentShape.position.y;
				oldx = this.position.x;
				oldy = this.position.y;
				dx = px - oldx;
				dy = py - oldy;
				dist = Math.sqrt(dx * dx + dy * dy);
				dy *= linkSize / dist;
				dx *= linkSize / dist;
				this.position = {
					'x' : px - dx,
					'y' : py - dy
				};
				dx = this.position.x - oldx;
				dy = this.position.y - oldy;
				dx = dx > 5 ? 5 : (dx < -5 ? -5 : dx);
				dy = dy > 10 ? 10 : (dy < -10 ? -10 : dy) - 3;
				this.velocity = {
					x : dx,
					y : dy
				};
				
				for(n = 0; n < this.numpoints; n++){
					this.points[n].x *= shrinkRate;
					this.points[n].y *= shrinkRate;
				}
			}
			for(n = 0; n < this.numpoints; n++){
				var newx = this.cosine * this.points[n].x - this.sine * this.points[n].y;
				this.points[n].y = this.sine * this.points[n].x + this.cosine * this.points[n].y;
				this.points[n].x = newx;
			}
		};

		shapeClass.prototype.buildShape = function(x, y, radius, numpoints, colour){
			var n, ang, angi = Math.PI * 2 / numpoints, otherRadius;
			this.position={'x' : x, 'y' : y};
			this.numpoints = numpoints;
			this.radius = radius;
			this.ang = Math.random() * Math.PI * 2;
			this.angi = Math.random() * 0.2 + .01;
			this.points = [];
			this.colour = colour;
			otherRadius = radius * (1 + (!(this.numpoints % 2) && (this.numpoints > 8 || Math.random() < 0.5) ? 0.5 : 0));
			ang = this.ang;
			for(n = 0; n < this.numpoints; n++){
				if(n % 2){
					this.points[n] = {
						'x' : this.radius * Math.sin(ang),
						'y' : this.radius * Math.cos(ang)
					};
				}else{
					this.points[n] = {
						'x' : otherRadius * Math.sin(ang),
						'y' : otherRadius * Math.cos(ang)
					};
				}
				ang += this.angi;
			}
		};

		shapeClass.prototype.draw = function(){
			var n;
			context.save();
				context.beginPath();
				context.strokeStyle = 'rgba(' + (this.colour.R >> 1) + ', ' + (this.colour.G >> 1) + ', ' + (this.colour.B >> 1) + ', 1)';
				context.fillStyle = 'rgba(' + this.colour.R + ', ' + this.colour.G + ', ' + this.colour.B + ', ' + this.opacity + ')';
				context.lineWidth = 1;
				context.translate(this.position.x, this.position.y);
				context.moveTo(this.points[0].x, this.points[0].y);
				for(n = 1; n < this.numpoints; n++){
					context.lineTo(this.points[n].x, this.points[n].y);
				}
				context.closePath();
				context.stroke();
				context.fill();
			context.restore();
			if(mouseDown){
				document.body.style.backgroundColor = 'rgba(' + (511 - this.colour.R >> 1) + ', ' + (511 - this.colour.G >> 1) + ', ' + (511 - this.colour.B >> 1) + ', 1)';
			}else{
				document.body.style.backgroundColor = '#FFFFFF';
			}
		};

		shapeClass.prototype.scale = function(ratio){
			var n;
			for(n = 0; n < this.numpoints; n++){
				this.points[n].x *= ratio;
				this.points[n].y *= ratio;
			}
		};

		shapeClass.prototype.age = function(chainPos){
			chainPos = chainPos == undefined ? 0 : chainPos + 1;
			if(chainPos > chainLength){
				this.parentShape.childShape = null;
				this.parentShape = null;
				if(this.childShape != null){
					this.childShape.age(chainPos);
				}
			}else{
				if(this.childShape == null){
					if(this == leadShape){
						leadShape = null;
					}else{
						this.parentShape.childShape = null;
						this.parentShape = null;
					}
				}else{
					this.childShape.age(chainPos);
				}
			}
		};

		function buildCanvas(){
			var canvas = document.createElement("canvas");
			canvasWidth = canvas.width = document.body.clientWidth;
			canvasHeight = canvas.height = document.body.clientHeight;
			canvas.id = 'gameCanvas';
			document.body.appendChild(canvas);
			return canvas;
		}

		function fadeTo(element, target, callback){
			var opacity = parseFloat(element.style.opacity);
			var difference = target - opacity;
			var diff = Math.abs(difference);
			if(diff > .1){
				opacity += .1 * Math.sign(difference);
			}else{
				opacity = target;
				if(callback != undefined){
					callback();
				}
			}
			element.style.opacity = opacity;
			if(opacity != target){
				setTimeout(function(){fadeTo(element, target, callback);}, 50);
			}
		}

		function givePrompt(step){
			if(mouseX != -1 ||  mouseY != -1) return;
			var promptWin = document.getElementById('instructionPrompt');
			if(step == undefined){
				step = 0;
				promptWin.style.display = 'inline-block';
				promptWin.style.opacity = 0.1;
				setTimeout(function(){fadeTo(promptWin, 1);}, 50);
			}
			setTimeout(function(){
				fadeTo(promptWin, 0, function(){
					promptWin.style.display = 'none';
				});
			}, 3000);
		}

		function animate(){
			var n;
			context.clearRect(0, 0, canvasWidth, canvasHeight);
			for(n = 0; n < numShapes; n++){
				if(mouseDown){
					shape[n].scale(1.03);
				}
				shape[n].move();
				if(isNaN(shape[n].position.y) || shape[n].position.y > canvasHeight + shape[n].radius){
					shape.splice(n, 1);
					n--;
					numShapes--;
				}else{
					shape[n].opacity *= 0.98;
					shape[n].draw();
				}
			}
			if(leadShape != null){
				leadShape.age();
			}
		}

		window.onload = function(){
			var canvas = buildCanvas();
			context = canvas.getContext('2d');
			canvas.onmousemove = function(evt){				
				var x, y, colour;
				x = evt.clientX;
				y = evt.clientY;
				var dx = x - mouseX, dy = y - mouseY;
				colour = {
					'R' : Math.floor(128 + 100 * Math.sin(colourAngle + colourOffset.r)),
					'G' : Math.floor(128 + 100 * Math.cos(colourAngle + colourOffset.g)),
					'B' : Math.floor(128 - 100 * Math.sin(colourAngle + colourOffset.b))
				};
				if(dx * dx + dy * dy > 256){
					shape[numShapes] = new shapeClass();
					shape[numShapes].buildShape(x, y, 40, Math.floor(Math.random() * 10) + 3, colour);
					dx = dx > 5 ? 5 : (dx < -5 ? -5 : dx);
					dy = dy > 10 ? 10 : (dy < -10 ? -10 : dy) - 3;
					shape[numShapes].getTrigVals(dx / 30.0);
					mouseX = x;
					mouseY = y;
					if(!mouseDown){
						shape[numShapes].velocity = {x : dx, y : dy};
						if(leadShape != null){
							leadShape.parentShape = shape[numShapes];
						}
						shape[numShapes].childShape = leadShape;
						leadShape = shape[numShapes];
					}else{
						shape[numShapes].velocity = {x : 6 * dx - Math.random() * 12 * dx, y : dy - 12};
					}
					numShapes++;
					colourAngle += 0.05;
					if(colourAngle > 2 * Math.PI) colourAngle -= 2 * Math.PI;
				}
			};
			document.onmouseup = function(){
				mouseDown = false;
				colourOffset = {
					r : 2 * Math.random() - 1,
					g : 2 * Math.random() - 1,
					b : 2 * Math.random() - 1
				};
				if(leadShape != null){
					leadShape.age(10);
				}
			};
			document.onmousedown = function(){
				mouseDown = true;
			};
			setInterval(animate, 40);
			setTimeout(givePrompt, 3001);
		};
	</script>
</head>
<body>
	<div id="instructionPrompt">
		Попробуйте использовать мышку)
	</div>
</body>
</html>
EOF

echo "===== Шаг 4. Создание папки /root/moni и файла moni.py ====="
mkdir -p /root/moni
cat > /root/moni/moni.py <<EOF
from flask import Flask, request, jsonify
import psutil
import requests
import threading
import time
import logging
import socket
import subprocess
import os
import json
from collections import deque
from logging.handlers import TimedRotatingFileHandler

BASE_URL = "https://monitiring.capybara-z.ru"
WEBHOOK_PATH = "/${WEBHOOK_PATH}"
LOG_DIR = "logs"

PROCESS_DATA_MAXLEN = 1 # Хранение в памяти результатов 
CHECK_INTERVAL_PROCESSES = 5 # Частота проверки процессов
MONITOR_SLEEP_INTERVAL = 30 # Частота проверки нагрузки цпу/озу/диск
FETCH_LIMITS_INTERVAL = 15 # Частота запроса лимитов.

LIMITS = {}
PROCESS_DATA = deque(maxlen=PROCESS_DATA_MAXLEN)
MY_IP = None

if not os.path.exists(LOG_DIR):
    os.makedirs(LOG_DIR)

file_handler = TimedRotatingFileHandler(
    filename=os.path.join(LOG_DIR, "moni.log"),
    when="H",
    interval=1,
    backupCount=72
)
formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
file_handler.setFormatter(formatter)

console_handler = logging.StreamHandler()
console_handler.setFormatter(formatter)

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
logger.addHandler(file_handler)
logger.addHandler(console_handler)
logging.getLogger('werkzeug').setLevel(logging.ERROR)

app = Flask(__name__)

def async_post(url: str, payload: dict, timeout: int = 10) -> None:
    def task():
        try:
            requests.post(url, json=payload, timeout=timeout)
        except Exception as e:
            logger.error(f"Ошибка при асинхронном POST на {url}: {e}")
    threading.Thread(target=task, daemon=True).start()

def get_my_ip() -> str:
    global MY_IP
    if MY_IP is None:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(("8.8.8.8", 80))
                MY_IP = s.getsockname()[0]
        except Exception as e:
            logger.error(f"Ошибка получения IP, используется 127.0.0.1: {e}")
            MY_IP = "127.0.0.1"
    return MY_IP

def init_globals() -> None:
    ip = get_my_ip()
    logger.info(f"Инициализирован IP: {ip}")

def get_system_info() -> dict:
    cpu_usage = psutil.cpu_percent(interval=1)
    memory = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    latest_process_info = PROCESS_DATA[-1] if PROCESS_DATA else {"top_cpu": [], "top_ram": []}
    
    return {
        "cpu_usage": cpu_usage,
        "memory_usage": memory.percent,
        "disk_usage": disk.percent,
        "cpu_cores": psutil.cpu_count(),
        "max_memory_gb": memory.total / (1024 ** 3),
        "total_disk_gb": disk.total / (1024 ** 3),
        "top_cpu_processes": latest_process_info.get("top_cpu", []),
        "top_memory_processes": latest_process_info.get("top_ram", [])
    }

def collect_process_data() -> None:
    while True:
        # Сбросим счётчики cpu_percent, чтобы при следующем запросе получить корректные данные
        for proc in psutil.process_iter(['name']):
            try:
                proc.cpu_percent(interval=None)
            except Exception:
                continue

        time.sleep(CHECK_INTERVAL_PROCESSES)

        cpu_list = []
        ram_list = []
        for proc in psutil.process_iter(['name']):
            try:
                cpu = proc.cpu_percent(interval=None)
                mem = proc.memory_percent()
                cpu_list.append({"name": proc.info["name"], "cpu_percent": cpu})
                ram_list.append({"name": proc.info["name"], "memory_percent": mem})
            except Exception:
                continue

        top_cpu = sorted(cpu_list, key=lambda x: x["cpu_percent"], reverse=True)[:5]
        top_ram = sorted(ram_list, key=lambda x: x["memory_percent"], reverse=True)[:5]
        PROCESS_DATA.append({"top_cpu": top_cpu, "top_ram": top_ram})

def monitor_load() -> None:
    while True:
        if not LIMITS:
            time.sleep(FETCH_LIMITS_INTERVAL)
            continue

        data = get_system_info()
        hostname = socket.gethostname()

        if data["cpu_usage"] > LIMITS.get("CPU_THRESHOLD", float('inf')):
            send_monitoring_alert(hostname, "CPU", data)
        if data["memory_usage"] > LIMITS.get("MEMORY_THRESHOLD", float('inf')):
            send_monitoring_alert(hostname, "RAM", data)
        if data["disk_usage"] > LIMITS.get("DISK_THRESHOLD", float('inf')):
            send_monitoring_alert(hostname, "Disk", data)

        time.sleep(MONITOR_SLEEP_INTERVAL)

def send_monitoring_alert(server_name: str, resource_type: str, data: dict) -> None:
    payload = {
        "server_name": MY_IP,
        "resource_type": resource_type,
        "data": data
    }
    logger.info(f"Отправка уведомления о {resource_type} для {server_name} (IP: {MY_IP})")
    async_post(f"{BASE_URL}{WEBHOOK_PATH}/monitoring", payload)

def fetch_limits_on_startup() -> None:
    global LIMITS
    while not LIMITS:
        logger.info("Запрос лимитов с бота")
        payload = {"ip": MY_IP}
        async_post(f"{BASE_URL}{WEBHOOK_PATH}/get_limits", payload)
        logger.info(f"Запрос лимитов отправлен асинхронно для IP {MY_IP}")
        time.sleep(FETCH_LIMITS_INTERVAL)

@app.route(f'{WEBHOOK_PATH}/<string:path>', methods=['POST'])
def webhook(path: str):
    data = request.get_json()
    if not data:
        logger.error("Не получен корректный JSON payload")
        return jsonify({"error": "Invalid JSON payload"}), 400

    if path == "reverse_mtr":
        return handle_reverse_mtr(data)
    elif path == "iperf3_test":
        return handle_iperf3_test(data)
    elif path == "set_limits":
        return handle_set_limits(data)
    elif path == "system_info":
        return handle_system_info(data)
    else:
        logger.error(f"Неизвестный путь вебхука: {path}")
        return jsonify({"error": "Unknown path"}), 400

def handle_reverse_mtr(data: dict):
    target_ip = data.get("target_ip")
    server_name = data.get("server_name")
    if not target_ip or not server_name:
        logger.error(f"Некорректные данные для reverse_mtr: target_ip={target_ip}, server_name={server_name}")
        return jsonify({"error": "Target IP and server name required"}), 400

    hostname = socket.gethostname()
    bot_ip = BASE_URL.split("://")[-1]
    packet_count = LIMITS.get("PACKET_COUNT_MTR")
    if packet_count is None:
        logger.error("Лимиты для PACKET_COUNT_MTR не загружены")
        return jsonify({"error": "Limits not loaded"}), 503

    logger.info(f"Получен запрос на reverse_mtr для {hostname} к {bot_ip}")
    cmd = ["mtr", "-r", "--no-dns", "-c", str(packet_count), bot_ip]
    logger.info(f"Запуск обратного MTR: {cmd}")
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=60)
        payload = {
            "server_name": server_name,
            "reverse_mtr": result.stdout,
            "target_ip": target_ip
        }
        logger.info(f"Отправка данных обратного MTR для {server_name}")
        async_post(f"{BASE_URL}{WEBHOOK_PATH}/mtr", payload)
        return jsonify({"status": "Reverse MTR sent"}), 200
    except subprocess.TimeoutExpired as e:
        logger.error(f"Таймаут обратного MTR к {bot_ip}: {e}")
        return jsonify({"error": "MTR timeout"}), 500
    except subprocess.CalledProcessError as e:
        logger.error(f"Ошибка обратного MTR к {bot_ip}: {e}, stderr={e.stderr}")
        return jsonify({"error": str(e)}), 500
    except Exception as e:
        logger.error(f"Неожиданная ошибка при выполнении reverse MTR к {bot_ip}: {e}")
        return jsonify({"error": str(e)}), 500

def handle_iperf3_test(data: dict):
    server = data.get("server")
    port = data.get("port")
    server_name = data.get("server_name", socket.gethostname())
    if not server or not port:
        logger.error("Некорректные данные для iperf3_test: отсутствует сервер или порт")
        return jsonify({"error": "Server and port required"}), 400

    logger.info(f"Получен запрос на iperf3_test для {server_name}")
    cmd = ["iperf3", "-c", server, "-p", str(port), "-J"]
    try:
        logger.info(f"Запуск Speedtest для {server_name}")
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        test_data = json.loads(result.stdout)
        payload = {
            "server_name": server_name,
            "download_speed_mbps": test_data["end"]["sum_received"]["bits_per_second"] / 1e6,
            "upload_speed_mbps": test_data["end"]["sum_sent"]["bits_per_second"] / 1e6,
            "ping_ms": test_data["end"]["streams"][0]["sender"]["mean_rtt"] / 1000
        }
        logger.info(f"Отправка данных Speedtest для {server_name}")
        async_post(f"{BASE_URL}{WEBHOOK_PATH}/speedtest", payload, timeout=15)
        return jsonify({"status": "Speedtest started"}), 200
    except Exception as e:
        logger.error(f"Ошибка Speedtest для {server_name}: {e}")
        return jsonify({"error": str(e)}), 500

def handle_set_limits(data: dict):
    limits = data.get("limits")
    required_keys = ["CPU_THRESHOLD", "MEMORY_THRESHOLD", "DISK_THRESHOLD", "PACKET_COUNT_MTR"]
    if not limits or not all(k in limits for k in required_keys):
        logger.error("Некорректные данные для set_limits: отсутствуют необходимые лимиты")
        return jsonify({"error": "Missing required limits"}), 400
    LIMITS.update(limits)
    logger.info(f"Лимиты обновлены: {LIMITS}")
    return jsonify({"status": "Limits updated"}), 200

def handle_system_info(data: dict):
    server_name = data.get("server_name")
    if not server_name:
        logger.error("Некорректные данные для system_info: отсутствует server_name")
        return jsonify({"error": "Server name required"}), 400

    system_data = get_system_info()
    payload = {
        "server_name": server_name,
        "ip": MY_IP,
        "data": system_data
    }
    logger.info(f"Отправка данных system_info для {server_name}")
    async_post(f"{BASE_URL}{WEBHOOK_PATH}/system_info_response", payload)
    return jsonify({"status": "System info requested"}), 200

if __name__ == "__main__":
    init_globals()
    threading.Thread(target=fetch_limits_on_startup, daemon=True, name="FetchLimitsThread").start()
    threading.Thread(target=collect_process_data, daemon=True, name="ProcessDataThread").start()
    threading.Thread(target=monitor_load, daemon=True, name="MonitorLoadThread").start()
    app.run(host="0.0.0.0", port=61016)
EOF

echo "===== Шаг 5. Установка необходимых пакетов ====="
apt remove python3-blinker -y || true
apt install python3-pip mtr -y

# iperf3 уже будет установлен без интерактива, т.к. мы задали debconf выше
apt install iperf3 -y

pip3 install Flask psutil requests --break-system-packages

echo "===== Шаг 6. Создание systemd-демона ====="
cat > /etc/systemd/system/moni.service <<EOF
[Unit]
Description=Flask Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /root/moni/moni.py
Restart=always
User=root
WorkingDirectory=/root/moni
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable moni.service
systemctl start moni.service

echo "===== Установка завершена ====="
echo "Проверьте статус демона командой:"
echo "sudo systemctl status moni.service"
