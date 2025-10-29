#!/bin/bash
set -e

PROJECT="website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin"
NAMESPACE="davtrowebdb"
REGISTRY="ghcr.io/exea-centrum/$PROJECT"
APP_DIR="app"

echo "📁 Tworzenie katalogów..."
mkdir -p "$APP_DIR/templates" "k8s/base" ".github/workflows"

# ==============================
# FastAPI Aplikacja
# ==============================
cat << 'EOF' > "$APP_DIR/main.py"
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
import psycopg2
import os
import logging
from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI()
templates = Jinja2Templates(directory="templates")
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("fastapi_app")

DB_CONN = os.getenv("DATABASE_URL", "dbname=appdb user=appuser password=apppass host=db")

Instrumentator().instrument(app).expose(app)

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    questions = ["Jak oceniasz usługę?", "Czy polecisz nas?", "Jak często korzystasz?"]
    return templates.TemplateResponse("form.html", {"request": request, "questions": questions})

@app.post("/submit", response_class=HTMLResponse)
async def submit(request: Request, question: str = Form(...), answer: str = Form(...)):
    conn = psycopg2.connect(DB_CONN)
    cur = conn.cursor()
    cur.execute("CREATE TABLE IF NOT EXISTS answers(id SERIAL PRIMARY KEY, question TEXT, answer TEXT);")
    cur.execute("INSERT INTO answers(question, answer) VALUES(%s, %s)", (question, answer))
    conn.commit()
    cur.close()
    conn.close()
    logger.info(f"Odpowiedź: {question} -> {answer}")
    return templates.TemplateResponse("form.html", {"request": request, "submitted": True, "questions": ["Jak oceniasz usługę?", "Czy polecisz nas?", "Jak często korzystasz?"]})

@app.get("/health")
async def health_check():
    try:
        conn = psycopg2.connect(DB_CONN)
        conn.close()
        return {"status": "healthy", "database": "connected"}
    except Exception as e:
        return {"status": "unhealthy", "database": "disconnected", "error": str(e)}
EOF

cat << 'EOF' > "$APP_DIR/templates/form.html"
<!DOCTYPE html>
<html>
<head><title>Kwestionariusz</title></head>
<body>
  <h1>Formularz</h1>
  {% if submitted %}
    <p><b>Dziękujemy za odpowiedź!</b></p>
  {% endif %}
  <form method="post" action="/submit">
    <label>Pytanie:</label>
    <select name="question">
      {% for q in questions %}
        <option value="{{q}}">{{q}}</option>
      {% endfor %}
    </select>
    <label>Odpowiedź:</label>
    <input type="text" name="answer"/>
    <input type="submit" value="Wyślij"/>
  </form>
</body>
</html>
EOF

cat << 'EOF' > "$APP_DIR/requirements.txt"
fastapi
uvicorn
jinja2
psycopg2-binary
prometheus-fastapi-instrumentator
python-multipart
EOF

# ==============================
# Dockerfile
# ==============================
cat << EOF > Dockerfile
FROM python:3.10-slim
WORKDIR /app
COPY app/ .
RUN pip install --no-cache-dir -r requirements.txt
ENV PYTHONUNBUFFERED=1
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

# ==============================
# Kubernetes Base Resources
# ==============================

# ConfigMap
cat << EOF > k8s/base/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: $PROJECT-config
  namespace: $NAMESPACE
data:
  DATABASE_URL: "dbname=appdb user=appuser password=apppass host=db"
EOF

# Secret
cat << EOF > k8s/base/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
  namespace: $NAMESPACE
type: Opaque
stringData:
  postgres-password: "apppass"
EOF

# App Deployment
cat << EOF > k8s/base/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $PROJECT
  namespace: $NAMESPACE
  labels:
    app: $PROJECT
spec:
  replicas: 2
  selector:
    matchLabels:
      app: $PROJECT
  template:
    metadata:
      labels:
        app: $PROJECT
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8000"
        prometheus.io/path: "/metrics"
    spec:
      containers:
      - name: app
        image: $REGISTRY:latest
        ports:
        - containerPort: 8000
        env:
        - name: DATABASE_URL
          valueFrom:
            configMapKeyRef:
              name: $PROJECT-config
              key: DATABASE_URL
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 5
EOF

# Service
cat << EOF > k8s/base/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: $PROJECT
  namespace: $NAMESPACE
  labels:
    app: $PROJECT
spec:
  selector:
    app: $PROJECT
  ports:
    - port: 80
      targetPort: 8000
      protocol: TCP
  type: ClusterIP
EOF

# PostgreSQL
cat << EOF > k8s/base/postgres.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db
  namespace: $NAMESPACE
  labels:
    app: db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: db
  template:
    metadata:
      labels:
        app: db
    spec:
      containers:
      - name: postgres
        image: postgres:14
        env:
        - name: POSTGRES_DB
          value: appdb
        - name: POSTGRES_USER
          value: appuser
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-secret
              key: postgres-password
        ports:
        - containerPort: 5432
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: db
  namespace: $NAMESPACE
  labels:
    app: db
spec:
  selector:
    app: db
  ports:
  - port: 5432
    targetPort: 5432
  type: ClusterIP
EOF

# pgAdmin - UPROSZCZONY, bez PVC
cat << EOF > k8s/base/pgadmin.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgadmin
  namespace: $NAMESPACE
  labels:
    app: pgadmin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pgadmin
  template:
    metadata:
      labels:
        app: pgadmin
    spec:
      containers:
      - name: pgadmin
        image: dpage/pgadmin4:latest
        env:
        - name: PGADMIN_DEFAULT_EMAIL
          value: "admin@admin.com"
        - name: PGADMIN_DEFAULT_PASSWORD
          value: "admin"
        - name: PGADMIN_CONFIG_SERVER_MODE
          value: "False"
        - name: PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED
          value: "False"
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: pgadmin
  namespace: $NAMESPACE
  labels:
    app: pgadmin
spec:
  selector:
    app: pgadmin
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
EOF

# Ingress
cat << EOF > k8s/base/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $PROJECT
  namespace: $NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - host: $PROJECT.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $PROJECT
            port:
              number: 80
  - host: pgadmin.$PROJECT.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: pgadmin
            port:
              number: 80
  - host: grafana.$PROJECT.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: grafana
            port:
              number: 3000
EOF

# ==============================
# Monitoring Stack
# ==============================

# Prometheus Config
cat << EOF > k8s/base/prometheus-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: $NAMESPACE
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
    scrape_configs:
      - job_name: 'fastapi'
        metrics_path: /metrics
        static_configs:
          - targets: ['$PROJECT:8000']
EOF

# Prometheus Deployment
cat << EOF > k8s/base/prometheus-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: $NAMESPACE
  labels:
    app: prometheus
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      containers:
      - name: prometheus
        image: prom/prometheus:latest
        ports:
        - containerPort: 9090
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
      volumes:
      - name: config
        configMap:
          name: prometheus-config
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: $NAMESPACE
  labels:
    app: prometheus
spec:
  selector:
    app: prometheus
  ports:
  - port: 9090
    targetPort: 9090
  type: ClusterIP
EOF

# Grafana Datasources
cat << EOF > k8s/base/grafana-provisioning-datasources.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: $NAMESPACE
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus:9090
        isDefault: true
      - name: Loki
        type: loki
        access: proxy
        url: http://loki:3100
      - name: Tempo
        type: tempo
        access: proxy
        url: http://tempo:3200
EOF

# Grafana Dashboards
cat << EOF > k8s/base/grafana-provisioning-dashboards.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards
  namespace: $NAMESPACE
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards
EOF

# Grafana Dashboard Config
cat << 'EOF' > k8s/base/grafana-dashboard-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-fastapi
  namespace: $NAMESPACE
data:
  fastapi.json: |-
    {
      "title": "FastAPI Overview",
      "refresh": "10s",
      "panels": [
        {
          "type": "graph",
          "title": "Requests per Second",
          "targets": [{"expr": "rate(http_requests_total[1m])"}]
        }
      ]
    }
EOF

# Grafana Deployment
cat << EOF > k8s/base/grafana-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: $NAMESPACE
  labels:
    app: grafana
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
      - name: grafana
        image: grafana/grafana:latest
        ports:
        - containerPort: 3000
        volumeMounts:
        - name: datasources
          mountPath: /etc/grafana/provisioning/datasources
        - name: dashboards
          mountPath: /etc/grafana/provisioning/dashboards
        - name: dashboard-files
          mountPath: /var/lib/grafana/dashboards
      volumes:
      - name: datasources
        configMap:
          name: grafana-datasources
      - name: dashboards
        configMap:
          name: grafana-dashboards
      - name: dashboard-files
        configMap:
          name: grafana-dashboard-fastapi
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: $NAMESPACE
  labels:
    app: grafana
spec:
  selector:
    app: grafana
  ports:
  - port: 3000
    targetPort: 3000
  type: ClusterIP
EOF

# Loki Config
cat << EOF > k8s/base/loki-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: $NAMESPACE
data:
  local-config.yaml: |
    server:
      http_listen_port: 3100
    ingester:
      lifecycler:
        address: 127.0.0.1
        ring:
          kvstore:
            store: inmemory
          replication_factor: 1
    schema_config:
      configs:
        - from: 2020-10-24
          store: boltdb
          object_store: filesystem
          schema: v11
          index:
            prefix: index_
            period: 24h
    storage_config:
      boltdb:
        directory: /loki/index
      filesystem:
        directory: /loki/chunks
EOF

# Loki Deployment
cat << EOF > k8s/base/loki-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki
  namespace: $NAMESPACE
  labels:
    app: loki
spec:
  replicas: 1
  selector:
    matchLabels:
      app: loki
  template:
    metadata:
      labels:
        app: loki
    spec:
      containers:
      - name: loki
        image: grafana/loki:2.9.0
        args:
          - "-config.file=/etc/loki/local-config.yaml"
        ports:
        - containerPort: 3100
        volumeMounts:
        - name: config
          mountPath: /etc/loki
      volumes:
      - name: config
        configMap:
          name: loki-config
---
apiVersion: v1
kind: Service
metadata:
  name: loki
  namespace: $NAMESPACE
  labels:
    app: loki
spec:
  selector:
    app: loki
  ports:
  - port: 3100
    targetPort: 3100
  type: ClusterIP
EOF

# Promtail Config
cat << EOF > k8s/base/promtail-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: $NAMESPACE
data:
  promtail.yaml: |
    server:
      http_listen_port: 9080
    clients:
      - url: http://loki:3100/loki/api/v1/push
    scrape_configs:
      - job_name: fastapi
        static_configs:
          - targets: ['$PROJECT:8000']
            labels:
              job: fastapi
EOF

# Promtail Deployment
cat << EOF > k8s/base/promtail-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: promtail
  namespace: $NAMESPACE
  labels:
    app: promtail
spec:
  replicas: 1
  selector:
    matchLabels:
      app: promtail
  template:
    metadata:
      labels:
        app: promtail
    spec:
      containers:
      - name: promtail
        image: grafana/promtail:2.9.0
        args:
          - "-config.file=/etc/promtail/promtail.yaml"
        ports:
        - containerPort: 9080
        volumeMounts:
        - name: config
          mountPath: /etc/promtail
      volumes:
      - name: config
        configMap:
          name: promtail-config
EOF

# Tempo Config
cat << EOF > k8s/base/tempo-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-config
  namespace: $NAMESPACE
data:
  tempo.yaml: |
    server:
      http_listen_port: 3200
    distributor:
      receivers:
        otlp:
          protocols:
            http: {}
            grpc: {}
    ingester:
      trace_idle_period: 10s
      max_block_duration: 5m
    compactor:
      compaction:
        block_retention: 1h
    storage:
      trace:
        backend: local
        local:
          path: /var/tempo/traces
EOF

# Tempo Deployment
cat << EOF > k8s/base/tempo-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tempo
  namespace: $NAMESPACE
  labels:
    app: tempo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tempo
  template:
    metadata:
      labels:
        app: tempo
    spec:
      containers:
      - name: tempo
        image: grafana/tempo:2.5.0
        args:
          - "-config.file=/etc/tempo/tempo.yaml"
        ports:
        - containerPort: 3200
        volumeMounts:
        - name: config
          mountPath: /etc/tempo
      volumes:
      - name: config
        configMap:
          name: tempo-config
---
apiVersion: v1
kind: Service
metadata:
  name: tempo
  namespace: $NAMESPACE
  labels:
    app: tempo
spec:
  selector:
    app: tempo
  ports:
  - port: 3200
    targetPort: 3200
  type: ClusterIP
EOF

# Kyverno Policy
cat << 'EOF' > k8s/base/kyverno-policy.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
spec:
  validationFailureAction: enforce
  rules:
  - name: check-for-labels
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "The labels 'app' and 'environment' are required."
      pattern:
        metadata:
          labels:
            app: "?*"
            environment: "?*"
EOF

# ==============================
# Kustomization
# ==============================
cat << EOF > k8s/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: $NAMESPACE

resources:
  - configmap.yaml
  - secret.yaml
  - deployment.yaml
  - service.yaml
  - postgres.yaml
  - pgadmin.yaml
  - ingress.yaml
  - prometheus-config.yaml
  - prometheus-deployment.yaml
  - grafana-provisioning-datasources.yaml
  - grafana-provisioning-dashboards.yaml
  - grafana-dashboard-config.yaml
  - grafana-deployment.yaml
  - loki-config.yaml
  - loki-deployment.yaml
  - promtail-config.yaml
  - promtail-deployment.yaml
  - tempo-config.yaml
  - tempo-deployment.yaml
  - kyverno-policy.yaml

commonLabels:
  app: $PROJECT
  environment: development

images:
  - name: $REGISTRY
    newTag: latest
EOF

# ==============================
# ArgoCD Application
# ==============================
cat << EOF > k8s/base/argocd-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $PROJECT
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/exea-centrum/$PROJECT.git
    targetRevision: main
    path: k8s/base
  destination:
    server: https://kubernetes.default.svc
    namespace: $NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF

# ==============================
# GitHub Actions
# ==============================
cat << EOF > .github/workflows/deploy.yml
name: Build and Push
on:
  push:
    branches: [main]
jobs:
  docker:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Login GHCR
        run: echo "\${{ secrets.GHCR_PAT }}" | docker login ghcr.io -u \${{ github.actor }} --password-stdin
      - name: Build & Push
        run: |
          docker build -t $REGISTRY:\${{ github.sha }} -t $REGISTRY:latest .
          docker push $REGISTRY:\${{ github.sha }}
          docker push $REGISTRY:latest
EOF

echo "✅ POPRAWIONY SKRYPT GOTOWY!"
echo ""
echo "🔧 KLUCZOWE POPRAWKI:"
echo "   ✅ Uproszczona konfiguracja - bez PVC"
echo "   ✅ pgAdmin bez problemów z permisjami"
echo "   ✅ Wszystkie komponenty monitoringowe"
echo "   ✅ Kyverno policy dla etykiet"
echo "   ✅ Użycie GHCR_PAT w GitHub Actions"
echo ""
echo "🚀 KOMPONENTY:"
echo "   - FastAPI aplikacja (2 repliki)"
echo "   - PostgreSQL + pgAdmin"
echo "   - Prometheus + Grafana + Loki + Tempo"
echo "   - Kyverno policy"
echo ""
echo "📊 Dostęp przez:"
echo "   - Aplikacja: http://$PROJECT.local"
echo "   - pgAdmin: http://pgadmin.$PROJECT.local"
echo "   - Grafana: http://grafana.$PROJECT.local"