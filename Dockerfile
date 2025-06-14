FROM python:3.11-slim

WORKDIR /app

# Install curl for healthcheck and other dependencies
RUN apt-get update && \
    apt-get install -y curl && \
    rm -rf /var/lib/apt/lists/*

# Copy requirements first for better caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app.py config.py fetcher.py models.py ./
#COPY config.yaml /app/config.yaml

# Expose port
EXPOSE 8000

# Set default environment variables
ENV CONFIG_PATH=/app/config.yaml
ENV LOG_LEVEL=INFO

# Healthcheck to ensure the application is running
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:8000/healthcheck || exit 1

# Command to run the application
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
