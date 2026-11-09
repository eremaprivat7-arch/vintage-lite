FROM python:3.12-slim
WORKDIR /srv
RUN pip install --no-cache-dir 'Flask>=3.1,<4' 'gunicorn>=23,<27'
COPY app.py .
COPY templates templates
CMD ["gunicorn","--bind","0.0.0.0:8000","--workers","2","app:app"]
