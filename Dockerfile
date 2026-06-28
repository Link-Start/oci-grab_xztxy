FROM python:3.12-slim

# 安装 oci-cli + web 框架
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash curl ca-certificates \
    && pip install --no-cache-dir oci-cli fastapi "uvicorn[standard]" \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY app.py /app/app.py
COPY grab.sh /app/grab.sh
COPY static /app/static
RUN chmod +x /app/grab.sh

ENV PYTHONUNBUFFERED=1

EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
