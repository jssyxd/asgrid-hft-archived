FROM python:3.11-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONMALLOC=malloc \
    PIP_NO_CACHE_DIR=1

RUN pip install --no-cache-dir numpy pandas requests urllib3

COPY gateway_okx_client.py /app/gateway_okx_client.py
COPY watchdog_trader_sentinel.py /app/watchdog_trader_sentinel.py
COPY cron_15m_inspector.py /app/cron_15m_inspector.py
COPY services /app/services

CMD ["python", "-u", "/app/watchdog_trader_sentinel.py"]
