# kubernetes/applications/sample-api/Dockerfile
# Hardened Non-Root Container Image for Sample API
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=1.0.0

RUN groupadd -g 10001 appgroup && \
    useradd -u 10001 -g appgroup -s /sbin/nologin -M appuser

WORKDIR /app
COPY app.py /app/app.py
RUN chown -R 10001:10001 /app

USER 10001:10001
EXPOSE 8080

CMD ["python3", "/app/app.py"]

