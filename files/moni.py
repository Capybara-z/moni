import asyncio
import logging
import os
import socket
import re
from logging.handlers import TimedRotatingFileHandler

import aiohttp
import psutil
from aiohttp import web

BASE_URL = "https://__DOMAIN_BOT__"
WEBHOOK_PATH = "/__WEBHOOK_PATH__"
LOG_DIR = "logs"

MONITOR_SLEEP_INTERVAL = 30
FETCH_LIMITS_INTERVAL = 15

LIMITS = {}
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
logging.getLogger('aiohttp').setLevel(logging.ERROR)

app = web.Application()

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

async def collect_processes() -> tuple:
    cmd = ["top", "-b", "-n", "2"]
    process = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE
    )
    stdout, stderr = await process.communicate()
    if process.returncode != 0:
        logger.error(f"Ошибка выполнения top: {stderr.decode()}")
        return [], []

    output = stdout.decode()

    lines = output.strip().split("\n")
    second_snapshot_start = 0
    header_count = 0
    for i, line in enumerate(lines):
        if "PID" in line and "USER" in line:
            header_count += 1
            if header_count == 2:
                second_snapshot_start = i
                break

    if second_snapshot_start == 0:
        logger.error("Не удалось найти вторую проверку из top")
        return [], []

    second_snapshot = []
    for line in lines[second_snapshot_start:]:
        if not line.strip():
            break
        second_snapshot.append(line)

    processes = []
    for line in second_snapshot[1:]:
        if not line.strip():
            continue
        fields = line.split()
        if len(fields) >= 12:
            try:
                pid = fields[0]
                user = fields[1]
                pr = fields[2]
                ni = fields[3]
                virt = fields[4]
                res = fields[5]
                shr = fields[6]
                state = fields[7]
                cpu = float(fields[8])
                mem = float(fields[9])
                time = fields[10]
                command = " ".join(fields[11:])
                processes.append({
                    "name": command,
                    "cpu_percent": cpu,
                    "memory_percent": mem
                })
            except (ValueError, IndexError) as e:
                logger.error(f"Ошибка парсинга строки top: {line}, ошибка: {e}")
                continue

    top_cpu = sorted(processes, key=lambda x: x["cpu_percent"], reverse=True)[:5]
    top_ram = sorted(processes, key=lambda x: x["memory_percent"], reverse=True)[:5]

    return top_cpu, top_ram

async def get_system_info() -> dict:
    loop = asyncio.get_running_loop()

    cpu_usage = await loop.run_in_executor(None, psutil.cpu_percent, 1)
    memory = psutil.virtual_memory()
    disk = psutil.disk_usage('/')

    return {
        "cpu_usage": cpu_usage,
        "memory_usage": memory.percent,
        "disk_usage": disk.percent,
        "cpu_cores": psutil.cpu_count(),
        "max_memory_gb": memory.total / (1024 ** 3),
        "total_disk_gb": disk.total / (1024 ** 3),
    }

async def monitor_load():
    while True:
        if not LIMITS:
            await asyncio.sleep(FETCH_LIMITS_INTERVAL)
            continue

        data = await get_system_info()
        hostname = socket.gethostname()

        overload_detected = False
        if data["cpu_usage"] > LIMITS.get("CPU_THRESHOLD", float('inf')):
            logger.info("Обнаружена перегрузка CPU")
            overload_detected = True
            resource_type = "CPU"
        elif data["memory_usage"] > LIMITS.get("MEMORY_THRESHOLD", float('inf')):
            logger.info("Обнаружена перегрузка RAM")
            overload_detected = True
            resource_type = "RAM"
        elif data["disk_usage"] > LIMITS.get("DISK_THRESHOLD", float('inf')):
            logger.info("Обнаружена перегрузка Disk")
            overload_detected = True
            resource_type = "Disk"

        if overload_detected:
            top_cpu, top_ram = await collect_processes()
            data["top_cpu_processes"] = top_cpu
            data["top_memory_processes"] = top_ram
            await send_monitoring_alert(hostname, resource_type, data)

        await asyncio.sleep(MONITOR_SLEEP_INTERVAL)

async def send_monitoring_alert(server_name: str, resource_type: str, data: dict):
    payload = {
        "server_name": MY_IP,
        "resource_type": resource_type,
        "data": data
    }
    logger.info(f"Отправка уведомления о {resource_type} для {server_name} (IP: {MY_IP})")
    async with aiohttp.ClientSession() as session:
        try:
            await session.post(f"{BASE_URL}{WEBHOOK_PATH}/monitoring", json=payload)
        except Exception as e:
            logger.error(f"Ошибка отправки мониторинга: {e}")

async def fetch_limits_on_startup():
    global LIMITS
    while not LIMITS:
        logger.info("Запрос лимитов с бота")
        payload = {"ip": MY_IP}
        async with aiohttp.ClientSession() as session:
            try:
                await session.post(f"{BASE_URL}{WEBHOOK_PATH}/get_limits", json=payload)
                logger.info(f"Запрос лимитов отправлен для IP {MY_IP}")
            except Exception as e:
                logger.error(f"Ошибка запроса лимитов: {e}")
        await asyncio.sleep(FETCH_LIMITS_INTERVAL)

async def handle_reverse_mtr(request):
    data = await request.json()
    target_ip = data.get("target_ip")
    server_name = data.get("server_name")
    chat_id = data.get("chat_id")
    if not target_ip or not server_name or not chat_id:
        logger.error(f"Некорректные данные для reverse_mtr: target_ip={target_ip}, server_name={server_name}, chat_id={chat_id}")
        return web.json_response({"error": "Target IP, server name, and chat_id required"}, status=400)

    hostname = socket.gethostname()
    bot_ip = BASE_URL.split("://")[-1]
    packet_count = LIMITS.get("PACKET_COUNT_MTR")
    if packet_count is None:
        logger.error("Лимиты для PACKET_COUNT_MTR не загружены")
        return web.json_response({"error": "Limits not loaded"}, status=503)

    logger.info(f"Получен запрос на reverse_mtr для {hostname} к {bot_ip} с chat_id {chat_id}")
    cmd = ["mtr", "-r", "--no-dns", "-c", str(packet_count), bot_ip]
    logger.info(f"Запуск обратного MTR: {cmd}")
    try:
        process = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=60)
        if process.returncode == 0:
            payload = {
                "server_name": server_name,
                "reverse_mtr": stdout.decode(),
                "target_ip": target_ip,
                "chat_id": chat_id
            }
            logger.info(f"Отправка данных обратного MTR для {server_name} с chat_id {chat_id}")
            async with aiohttp.ClientSession() as session:
                await session.post(f"{BASE_URL}{WEBHOOK_PATH}/mtr", json=payload)
            return web.json_response({"status": "Reverse MTR sent"}, status=200)
        else:
            logger.error(f"Ошибка обратного MTR: {stderr.decode()}")
            return web.json_response({"error": stderr.decode()}, status=500)
    except asyncio.TimeoutError as e:
        logger.error(f"Таймаут обратного MTR к {bot_ip}: {e}")
        return web.json_response({"error": "MTR timeout"}, status=500)
    except Exception as e:
        logger.error(f"Неожиданная ошибка при выполнении reverse MTR к {bot_ip}: {e}")
        return web.json_response({"error": str(e)}, status=500)

async def handle_iperf3_test(request):
    data = await request.json()
    server = data.get("server")
    port = data.get("port")
    server_name = data.get("server_name", socket.gethostname())
    chat_id = data.get("chat_id")
    if not server or not port or not chat_id:
        logger.error(f"Некорректные данные для iperf3_test: server={server}, port={port}, chat_id={chat_id}")
        return web.json_response({"error": "Server, port, and chat_id required"}, status=400)

    logger.info(f"Получен запрос на iperf3_test для {server_name} с chat_id {chat_id}")
    cmd = ["iperf3", "-c", server, "-p", str(port), "-J"]
    try:
        logger.info(f"Запуск Speedtest для {server_name}")
        process = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await process.communicate()
        if process.returncode == 0:
            import json
            test_data = json.loads(stdout.decode())
            payload = {
                "server_name": server_name,
                "download_speed_mbps": test_data["end"]["sum_received"]["bits_per_second"] / 1e6,
                "upload_speed_mbps": test_data["end"]["sum_sent"]["bits_per_second"] / 1e6,
                "ping_ms": test_data["end"]["streams"][0]["sender"]["mean_rtt"] / 1000,
                "chat_id": chat_id
            }
            logger.info(f"Отправка данных Speedtest для {server_name} с chat_id {chat_id}")
            async with aiohttp.ClientSession() as session:
                await session.post(f"{BASE_URL}{WEBHOOK_PATH}/speedtest", json=payload)
            return web.json_response({"status": "Speedtest started"}, status=200)
        else:
            logger.error(f"Ошибка Speedtest: {stderr.decode()}")
            return web.json_response({"error": stderr.decode()}, status=500)
    except Exception as e:
        logger.error(f"Ошибка Speedtest для {server_name}: {e}")
        return web.json_response({"error": str(e)}, status=500)

async def handle_set_limits(request):
    data = await request.json()
    limits = data.get("limits")
    required_keys = ["CPU_THRESHOLD", "MEMORY_THRESHOLD", "DISK_THRESHOLD", "PACKET_COUNT_MTR"]
    if not limits or not all(k in limits for k in required_keys):
        logger.error("Некорректные данные для set_limits: отсутствуют необходимые лимиты")
        return web.json_response({"error": "Missing required limits"}, status=400)
    LIMITS.update(limits)
    logger.info(f"Лимиты обновлены: {LIMITS}")
    return web.json_response({"status": "Limits updated"}, status=200)

async def handle_system_info(request):
    data = await request.json()
    server_name = data.get("server_name")
    chat_id = data.get("chat_id")
    if not server_name or not chat_id:
        logger.error(f"Некорректные данные для system_info: server_name={server_name}, chat_id={chat_id}")
        return web.json_response({"error": "Server name and chat_id required"}, status=400)

    system_data = await get_system_info()

    top_cpu, top_ram = await collect_processes()
    system_data["top_cpu_processes"] = top_cpu
    system_data["top_memory_processes"] = top_ram

    payload = {
        "server_name": server_name,
        "ip": MY_IP,
        "data": system_data,
        "chat_id": chat_id
    }
    logger.info(f"Отправка данных system_info для {server_name} с chat_id {chat_id}")
    async with aiohttp.ClientSession() as session:
        await session.post(f"{BASE_URL}{WEBHOOK_PATH}/system_info_response", json=payload)
    return web.json_response({"status": "System info requested"}, status=200)

async def setup_routes():
    app.router.add_post(f"{WEBHOOK_PATH}/reverse_mtr", handle_reverse_mtr)
    app.router.add_post(f"{WEBHOOK_PATH}/iperf3_test", handle_iperf3_test)
    app.router.add_post(f"{WEBHOOK_PATH}/set_limits", handle_set_limits)
    app.router.add_post(f"{WEBHOOK_PATH}/system_info", handle_system_info)

async def main():
    init_globals()
    await setup_routes()
    asyncio.create_task(fetch_limits_on_startup())
    asyncio.create_task(monitor_load())
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", 61016)
    await site.start()
    logger.info("Сервер запущен на порту 61016")
    await asyncio.Event().wait()

if __name__ == "__main__":
    asyncio.run(main())
