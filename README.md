# website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin

website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin

# 🚀 Ankieta Aplikacja Kubernetes

Kompletny system ankietowy z pełnym stackiem monitoringowym, uruchamiany na Kubernetes.

## 📋 Funkcjonalności

### 📊 System Ankiet

- **5 pytań różnych typów** (tekst, jednokrotny wybór, wielokrotny wybór, skala)
- **Statystyki w czasie rzeczywistym** z wykresami
- **Zapis odpowiedzi** do bazy danych PostgreSQL

### 💌 Komunikacja

- **Formularz kontaktowy** z zapisem wiadomości
- **Śledzenie odwiedzin** stron
- **Retry logic** dla połączeń z bazą danych

## 🏗️ Architektura Kubernetes

### Podstawowe Komponenty

- **ConfigMap & Secret** - konfiguracja i dane uwierzytelniające
- **Deployment & Service** - aplikacja główna, PostgreSQL, pgAdmin
- **Ingress** - routing z wieloma hostami

### Monitoring Stack

- **Prometheus** - zbieranie metryk
- **Grafana** - wizualizacja danych
- **Loki** - log aggregation
- **Promtail** - log collection
- **Tempo** - distributed tracing

### Zabezpieczenia i DevOps

- **Kyverno Policy** - compliance i security
- **ArgoCD Application** - GitOps deployment

## 🌐 Endpointy API

### Ankieta

| Method | Endpoint                | Description                  |
| ------ | ----------------------- | ---------------------------- |
| `GET`  | `/`                     | Strona główna aplikacji      |
| `GET`  | `/health`               | Health check aplikacji       |
| `GET`  | `/api/survey/questions` | Pobieranie pytań ankietowych |
| `POST` | `/api/survey/submit`    | Zapis odpowiedzi ankietowych |
| `GET`  | `/api/survey/stats`     | Statystyki odpowiedzi ankiet |

### Dodatkowe Funkcje

| Method | Endpoint       | Description                |
| ------ | -------------- | -------------------------- |
| `POST` | `/api/contact` | Formularz kontaktowy       |
| `GET`  | `/api/visits`  | Statystyki odwiedzin stron |

## 📊 Dostęp do Usług

### Główne Adresy

- **🌐 Strona Główna**: `http://[PROJECT].local`
- **🗄️ pgAdmin**: `http://pgadmin.[PROJECT].local`
  - Login: `admin@admin.com`
  - Hasło: `admin`
- **📈 Grafana**: `http://grafana.[PROJECT].local`
  - Login: `admin`
  - Hasło: `admin`

## 💾 Struktura Bazy Danych

### Tabele

- **`survey_responses`** - przechowuje odpowiedzi z ankiet
- **`page_visits`** - śledzi statystyki odwiedzin stron
- **`contact_messages`** - przechowuje wiadomości z formularza kontaktowego

## 🛠️ Wymagania

- Kubernetes cluster
- Ingress controller
- Helm (dla komponentów monitoringowych)

## 🚀 Uruchomienie

```bash
# Zastąp [PROJECT] odpowiednią nazwą
kubectl apply -f wszystkie-manifesty/
```
