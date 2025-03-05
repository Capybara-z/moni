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

BASE_URL = "https://__DOMAIN_BOT__"
WEBHOOK_PATH = "/__WEBHOOK_PATH__"
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
