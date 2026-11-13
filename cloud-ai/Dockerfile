FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt ./
COPY worker/requirements.txt worker/
RUN pip install --no-cache-dir -r requirements.txt
COPY api.py integrations.py pilot.py run_queue.py ./
COPY worker/ worker/
ENV BOOTH360_AI_DATA=/data PYTHONUNBUFFERED=1
CMD ["uvicorn", "api:production", "--factory", "--host", "0.0.0.0", "--port", "8080"]
