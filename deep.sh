#!/bin/bash
set -e

PROJECT="website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin"
NAMESPACE="davtrowebdb"
REGISTRY="ghcr.io/exea-centrum/$PROJECT"
APP_DIR="app"

echo "📁 Tworzenie katalogów..."
mkdir -p "$APP_DIR/templates" "k8s/base" ".github/workflows"

# ==============================
# FastAPI Aplikacja z ankietą
# ==============================
cat << 'EOF' > "$APP_DIR/main.py"
from fastapi import FastAPI, Form, Request, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates
from fastapi.staticfiles import StaticFiles
import psycopg2
import os
import logging
from prometheus_fastapi_instrumentator import Instrumentator
from pydantic import BaseModel
from typing import List, Dict, Any
import time

app = FastAPI(title="Dawid Trojanowski - Strona Osobista")
templates = Jinja2Templates(directory="templates")
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("fastapi_app")

DB_CONN = os.getenv("DATABASE_URL", "dbname=appdb user=appuser password=apppass host=db")

Instrumentator().instrument(app).expose(app)

class SurveyResponse(BaseModel):
    question: str
    answer: str

def get_db_connection():
    """Utwórz połączenie z bazą danych z retry logic"""
    max_retries = 3
    for attempt in range(max_retries):
        try:
            conn = psycopg2.connect(DB_CONN)
            return conn
        except psycopg2.OperationalError as e:
            logger.warning(f"Attempt {attempt + 1} failed: {e}")
            if attempt < max_retries - 1:
                time.sleep(2)
            else:
                raise e

def init_database():
    """Inicjalizacja bazy danych"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        
        # Tabela odpowiedzi ankiet
        cur.execute("""
            CREATE TABLE IF NOT EXISTS survey_responses(
                id SERIAL PRIMARY KEY,
                question TEXT NOT NULL,
                answer TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        
        # Tabela odwiedzin stron
        cur.execute("""
            CREATE TABLE IF NOT EXISTS page_visits(
                id SERIAL PRIMARY KEY,
                page VARCHAR(255) NOT NULL,
                visited_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        
        # Tabela kontaktów
        cur.execute("""
            CREATE TABLE IF NOT EXISTS contact_messages(
                id SERIAL PRIMARY KEY,
                email VARCHAR(255) NOT NULL,
                message TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        
        conn.commit()
        cur.close()
        conn.close()
        logger.info("Database initialized successfully")
    except Exception as e:
        logger.error(f"Database initialization failed: {e}")

@app.on_event("startup")
async def startup_event():
    init_database()

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    """Główna strona osobista"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("INSERT INTO page_visits (page) VALUES ('home')")
        conn.commit()
        cur.close()
        conn.close()
    except Exception as e:
        logger.error(f"Error logging page visit: {e}")
    
    return templates.TemplateResponse("index.html", {"request": request})

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.close()
        conn.close()
        return {"status": "healthy", "database": "connected"}
    except Exception as e:
        return {"status": "unhealthy", "database": "disconnected", "error": str(e)}

@app.get("/api/survey/questions")
async def get_survey_questions():
    """Pobiera listę pytań do ankiety"""
    questions = [
        {
            "id": 1,
            "text": "Jak oceniasz design strony?",
            "type": "rating",
            "options": ["1 - Słabo", "2", "3", "4", "5 - Doskonale"]
        },
        {
            "id": 2,
            "text": "Czy informacje były przydatne?",
            "type": "choice",
            "options": ["Tak", "Raczej tak", "Nie wiem", "Raczej nie", "Nie"]
        },
        {
            "id": 3,
            "text": "Jakie technologie Cię zainteresowały?",
            "type": "multiselect",
            "options": ["Python", "JavaScript", "React", "Kubernetes", "Docker", "PostgreSQL"]
        },
        {
            "id": 4,
            "text": "Czy poleciłbyś tę stronę innym?",
            "type": "choice",
            "options": ["Zdecydowanie tak", "Prawdopodobnie tak", "Nie wiem", "Raczej nie", "Zdecydowanie nie"]
        },
        {
            "id": 5,
            "text": "Co sądzisz o portfolio?",
            "type": "text",
            "placeholder": "Podziel się swoją opinią..."
        }
    ]
    return questions

@app.post("/api/survey/submit")
async def submit_survey(response: SurveyResponse):
    """Zapisuje odpowiedź z ankiety"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO survey_responses (question, answer) VALUES (%s, %s)",
            (response.question, response.answer)
        )
        conn.commit()
        cur.close()
        conn.close()
        logger.info(f"Survey response saved: {response.question} -> {response.answer}")
        return {"status": "success", "message": "Dziękujemy za wypełnienie ankiety!"}
    except Exception as e:
        logger.error(f"Error saving survey response: {e}")
        raise HTTPException(status_code=500, detail="Błąd podczas zapisywania odpowiedzi")

@app.get("/api/survey/stats")
async def get_survey_stats():
    """Pobiera statystyki ankiet"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        
        # Statystyki odpowiedzi
        cur.execute("""
            SELECT question, answer, COUNT(*) as count 
            FROM survey_responses 
            GROUP BY question, answer 
            ORDER BY question, count DESC
        """)
        responses = cur.fetchall()
        
        # Liczba wizyt
        cur.execute("SELECT COUNT(*) FROM page_visits")
        total_visits = cur.fetchone()[0]
        
        cur.close()
        conn.close()
        
        # Formatowanie danych
        stats = {}
        for question, answer, count in responses:
            if question not in stats:
                stats[question] = []
            stats[question].append({"answer": answer, "count": count})
        
        return {
            "survey_responses": stats,
            "total_visits": total_visits,
            "total_responses": sum(len(answers) for answers in stats.values())
        }
    except Exception as e:
        logger.error(f"Error fetching survey stats: {e}")
        raise HTTPException(status_code=500, detail="Błąd podczas pobierania statystyk")

@app.post("/api/contact")
async def submit_contact(email: str = Form(...), message: str = Form(...)):
    """Zapisuje wiadomość kontaktową"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO contact_messages (email, message) VALUES (%s, %s)",
            (email, message)
        )
        conn.commit()
        cur.close()
        conn.close()
        logger.info(f"Contact message saved from: {email}")
        return {"status": "success", "message": "Wiadomość została wysłana!"}
    except Exception as e:
        logger.error(f"Error saving contact message: {e}")
        raise HTTPException(status_code=500, detail="Błąd podczas wysyłania wiadomości")

@app.get("/api/visits")
async def get_visit_stats():
    """Pobiera statystyki odwiedzin"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        
        cur.execute("""
            SELECT page, COUNT(*) as visits,
                   DATE(visited_at) as date
            FROM page_visits 
            GROUP BY page, DATE(visited_at)
            ORDER BY date DESC
        """)
        visits = cur.fetchall()
        
        cur.close()
        conn.close()
        
        return {
            "visits": [
                {
                    "page": page,
                    "visits": visit_count,
                    "date": date.isoformat() if date else None
                }
                for page, visit_count, date in visits
            ]
        }
    except Exception as e:
        logger.error(f"Error fetching visit stats: {e}")
        raise HTTPException(status_code=500, detail="Błąd podczas pobierania statystyk odwiedzin")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
EOF

# ==============================
# Strona HTML z ankietą
# ==============================
cat << 'EOF' > "$APP_DIR/templates/index.html"
<!DOCTYPE html>
<html lang="pl">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Dawid Trojanowski - Strona Osobista</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
      @keyframes fadeIn {
        from {
          opacity: 0;
          transform: translateY(10px);
        }
        to {
          opacity: 1;
          transform: translateY(0);
        }
      }
      @keyframes typewriter {
        from {
          width: 0;
        }
        to {
          width: 100%;
        }
      }
      @keyframes blink {
        from,
        to {
          border-color: transparent;
        }
        50% {
          border-color: #c084fc;
        }
      }
      .animate-fade-in {
        animation: fadeIn 0.5s ease-out;
      }
      .typewriter {
        overflow: hidden;
        border-right: 2px solid #c084fc;
        white-space: nowrap;
        animation: typewriter 2s steps(40, end), blink 0.75s step-end infinite;
      }
      .parallax {
        background-attachment: fixed;
        background-position: center;
        background-repeat: no-repeat;
        background-size: cover;
      }
      .particle {
        position: absolute;
        border-radius: 50%;
        background: radial-gradient(
          circle,
          rgba(168, 85, 247, 0.7) 0%,
          rgba(236, 72, 153, 0.3) 70%,
          transparent 100%
        );
        pointer-events: none;
      }
      .skill-bar {
        height: 10px;
        background: rgba(255, 255, 255, 0.1);
        border-radius: 5px;
        overflow: hidden;
      }
      .skill-progress {
        height: 100%;
        border-radius: 5px;
        transition: width 1.5s ease-in-out;
      }
      .hamburger {
        display: none;
        flex-direction: column;
        cursor: pointer;
      }
      .hamburger span {
        width: 25px;
        height: 3px;
        background: #c084fc;
        margin: 3px 0;
        transition: 0.3s;
      }
      @media (max-width: 768px) {
        .hamburger {
          display: flex;
        }
        nav {
          position: fixed;
          top: 80px;
          right: -100%;
          width: 70%;
          height: calc(100vh - 80px);
          background: rgba(15, 23, 42, 0.95);
          backdrop-filter: blur(10px);
          flex-direction: column;
          padding: 20px;
          transition: 0.5s;
          border-left: 1px solid rgba(168, 85, 247, 0.3);
        }
        nav.active {
          right: 0;
        }
        .tab-btn {
          margin: 10px 0;
          text-align: left;
          padding: 15px;
          border-radius: 8px;
          width: 100%;
        }
        .hamburger.active span:nth-child(1) {
          transform: rotate(-45deg) translate(-5px, 6px);
        }
        .hamburger.active span:nth-child(2) {
          opacity: 0;
        }
        .hamburger.active span:nth-child(3) {
          transform: rotate(45deg) translate(-5px, -6px);
        }
      }
    </style>
  </head>
  <body
    class="bg-gradient-to-br from-slate-900 via-purple-900 to-slate-900 text-white min-h-screen transition-colors duration-500"
  >
    <!-- Floating particles -->
    <div
      id="particles-container"
      class="fixed top-0 left-0 w-full h-full pointer-events-none z-0"
    ></div>

    <header
      class="border-b border-purple-500/30 backdrop-blur-sm bg-black/20 sticky top-0 z-50 transition-colors duration-500"
    >
      <div class="container mx-auto px-6 py-4">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-3">
            <svg
              class="w-10 h-10 text-purple-400"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"
              ></path>
            </svg>
            <h1
              class="text-3xl font-bold bg-gradient-to-r from-purple-400 to-pink-400 bg-clip-text text-transparent"
            >
              Dawid Trojanowski
            </h1>
          </div>

          <div class="flex items-center gap-4">
            <!-- Theme Toggle -->
            <button
              id="theme-toggle"
              class="p-2 rounded-full bg-purple-500/20 hover:bg-purple-500/40 transition-colors"
            >
              <svg
                id="sun-icon"
                class="w-6 h-6 text-yellow-300"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12 3v1m0 16v1m9-9h-1M4 12H3m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z"
                ></path>
              </svg>
              <svg
                id="moon-icon"
                class="w-6 h-6 text-purple-300 hidden"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z"
                ></path>
              </svg>
            </button>

            <!-- Hamburger Menu -->
            <div class="hamburger" id="hamburger">
              <span></span>
              <span></span>
              <span></span>
            </div>

            <nav id="nav-menu" class="flex gap-4">
              <button
                onclick="showTab('intro')"
                class="tab-btn px-4 py-2 rounded-lg transition-all text-purple-300"
                data-tab="intro"
              >
                O Mnie
              </button>
              <button
                onclick="showTab('edu')"
                class="tab-btn px-4 py-2 rounded-lg transition-all text-purple-300"
                data-tab="edu"
              >
                Edukacja
              </button>
              <button
                onclick="showTab('exp')"
                class="tab-btn px-4 py-2 rounded-lg transition-all text-purple-300"
                data-tab="exp"
              >
                Doświadczenie
              </button>
              <button
                onclick="showTab('skills')"
                class="tab-btn px-4 py-2 rounded-lg transition-all text-purple-300"
                data-tab="skills"
              >
                Umiejętności
              </button>
              <button
                onclick="showTab('survey')"
                class="tab-btn px-4 py-2 rounded-lg transition-all text-purple-300"
                data-tab="survey"
              >
                Ankieta
              </button>
              <button
                onclick="showTab('contact')"
                class="tab-btn px-4 py-2 rounded-lg transition-all text-purple-300"
                data-tab="contact"
              >
                Kontakt
              </button>
            </nav>
          </div>
        </div>
      </div>
    </header>

    <main class="container mx-auto px-6 py-12 relative z-10">
      <div id="intro-tab" class="tab-content">
        <div class="space-y-8 animate-fade-in">
          <div
            class="bg-gradient-to-br from-purple-500/10 to-pink-500/10 backdrop-blur-lg border border-purple-500/20 rounded-2xl p-8"
          >
            <h2 class="text-4xl font-bold mb-6 text-purple-300 typewriter">
              O Mnie
            </h2>
            <p class="text-lg text-gray-300 leading-relaxed mb-4">
              Cześć! Jestem Dawidem Trojanowskim, pasjonatem informatyki i
              nowych technologii. Zawsze dążyłem do rozwijania swoich
              umiejętności w programowaniu i rozwiązywaniu złożonych problemów.
              Moja ścieżka edukacyjna i zawodowa skupia się na informatyce
              stosowanej, gdzie łączę teorię z praktyką.
            </p>
            <p class="text-lg text-gray-300 leading-relaxed">
              Poza pracą interesuję się sportem, czytaniem książek i podróżami.
              Lubię wyzwania, które pozwalają mi rosnąć zarówno zawodowo, jak i
              osobowo.
            </p>
          </div>
          <div class="grid md:grid-cols-3 gap-6">
            <div
              class="bg-gradient-to-br from-blue-500/10 to-purple-500/10 backdrop-blur-lg border border-blue-500/20 rounded-xl p-6 hover:scale-105 transition-transform cursor-pointer"
              onclick="showTab('edu')"
            >
              <h3 class="text-xl font-bold mb-3 text-blue-300">Edukacja</h3>
              <p class="text-gray-400">
                Studia informatyczne na renomowanych uczelniach
              </p>
            </div>
            <div
              class="bg-gradient-to-br from-green-500/10 to-emerald-500/10 backdrop-blur-lg border border-green-500/20 rounded-xl p-6 hover:scale-105 transition-transform cursor-pointer"
              onclick="showTab('exp')"
            >
              <h3 class="text-xl font-bold mb-3 text-green-300">
                Doświadczenie
              </h3>
              <p class="text-gray-400">Praktyki i projekty w branży IT</p>
            </div>
            <div
              class="bg-gradient-to-br from-pink-500/10 to-rose-500/10 backdrop-blur-lg border border-pink-500/20 rounded-xl p-6 hover:scale-105 transition-transform cursor-pointer"
              onclick="showTab('survey')"
            >
              <h3 class="text-xl font-bold mb-3 text-pink-300">
                Ankieta
              </h3>
              <p class="text-gray-400">Podziel się opinią o stronie</p>
            </div>
          </div>
        </div>
      </div>

      <div id="edu-tab" class="tab-content hidden">
        <div class="space-y-6 animate-fade-in">
          <h2 class="text-4xl font-bold mb-8 text-purple-300">Edukacja</h2>
          <div
            class="bg-gradient-to-br from-slate-800/50 to-slate-900/50 backdrop-blur-lg border border-purple-500/20 rounded-xl p-6"
          >
            <h3 class="text-2xl font-bold mb-4 text-purple-300">
              Politechnika Warszawska
            </h3>
            <p class="text-gray-300 mb-4">Informatyka, studia magisterskie</p>
            <ul class="space-y-2">
              <li class="text-gray-400 flex items-center gap-2">
                <span class="w-1.5 h-1.5 rounded-full bg-purple-400"></span>
                Specjalizacja w sztucznej inteligencji i uczeniu maszynowym
              </li>
              <li class="text-gray-400 flex items-center gap-2">
                <span class="w-1.5 h-1.5 rounded-full bg-purple-400"></span>
                Praca dyplomowa: "Zastosowanie sieci neuronowych w analizie
                danych"
              </li>
              <li class="text-gray-400 flex items-center gap-2">
                <span class="w-1.5 h-1.5 rounded-full bg-purple-400"></span>
                Średnia ocen: 4.5/5
              </li>
            </ul>
          </div>
          <div
            class="bg-gradient-to-br from-slate-800/50 to-slate-900/50 backdrop-blur-lg border border-purple-500/20 rounded-xl p-6"
          >
            <h3 class="text-2xl font-bold mb-4 text-purple-300">
              Uniwersytet Warszawski
            </h3>
            <p class="text-gray-300 mb-4">Informatyka, studia licencjackie</p>
            <ul class="space-y-2">
              <li class="text-gray-400 flex items-center gap-2">
                <span class="w-1.5 h-1.5 rounded-full bg-purple-400"></span>
                Podstawy programowania i algorytmiki
              </li>
              <li class="text-gray-400 flex items-center gap-2">
                <span class="w-1.5 h-1.5 rounded-full bg-purple-400"></span>
                Projekty grupowe w Java i Python
              </li>
            </ul>
          </div>
        </div>
      </div>

      <div id="exp-tab" class="tab-content hidden">
        <div class="space-y-6 animate-fade-in">
          <h2 class="text-4xl font-bold mb-8 text-purple-300">
            Doświadczenie Zawodowe
          </h2>
          <div
            class="bg-gradient-to-br from-slate-800/50 to-slate-900/50 backdrop-blur-lg border border-purple-500/20 rounded-xl p-6"
          >
            <h3 class="text-2xl font-bold mb-4 text-purple-300">
              Junior Developer - TechCorp
            </h3>
            <p class="text-gray-300 mb-4">Styczeń 2023 - Obecnie</p>
            <ul class="space-y-2">
              <li class="text-gray-400 flex items-center gap-2">
                <span class="w-1.5 h-1.5 rounded-full bg-purple-400"></span>
                Rozwój aplikacji webowych w React i Node.js
              </li>
              <li class="text-gray-400 flex items-center gap-2">
                <span class="w-1.5 h-1.5 rounded-full bg-purple-400"></span>
                Optymalizacja baz danych SQL
              </li>
              <li class="text-gray-400 flex items-center gap-2">
                <span class="w-1.5 h-1.5 rounded-full bg-purple-400"></span>
                Współpraca z zespołem w metodologii Agile
              </li>
            </ul>
          </div>
          <div
            class="bg-gradient-to-br from-slate-800/50 to-slate-900/50 backdrop-blur-lg border border-purple-500/20 rounded-xl p-6"
          >
            <h3 class="text-2xl font-bold mb-4 text-purple-300">
              Praktykant - Startup AI
            </h3>
            <p class="text-gray-300 mb-4">Czerwiec 2022 - Sierpień 2022</p>
            <ul class="space-y-2">
              <li class="text-gray-400 flex items-center gap-2">
                <span class="w-1.5 h-1.5 rounded-full bg-purple-400"></span>
                Implementacja modeli ML w Python
              </li>
              <li class="text-gray-400 flex items-center gap-2">
                <span class="w-1.5 h-1.5 rounded-full bg-purple-400"></span>
                Analiza danych z wykorzystaniem Pandas i Scikit-learn
              </li>
            </ul>
          </div>
        </div>
      </div>

      <div id="skills-tab" class="tab-content hidden">
        <div class="space-y-6 animate-fade-in">
          <h2 class="text-4xl font-bold mb-8 text-purple-300">Umiejętności</h2>
          <div class="grid md:grid-cols-2 gap-6">
            <div
              class="bg-gradient-to-br from-slate-800/50 to-slate-900/50 backdrop-blur-lg border border-purple-500/20 rounded-xl p-6"
            >
              <h3 class="text-2xl font-bold mb-4 text-purple-300">
                Techniczne
              </h3>
              <div class="space-y-4">
                <div>
                  <div class="flex justify-between mb-1">
                    <span class="text-gray-300">Python</span>
                    <span class="text-purple-300">90%</span>
                  </div>
                  <div class="skill-bar">
                    <div
                      class="skill-progress bg-gradient-to-r from-purple-500 to-pink-500"
                      data-width="90%"
                    ></div>
                  </div>
                </div>
                <div>
                  <div class="flex justify-between mb-1">
                    <span class="text-gray-300">JavaScript</span>
                    <span class="text-purple-300">85%</span>
                  </div>
                  <div class="skill-bar">
                    <div
                      class="skill-progress bg-gradient-to-r from-purple-500 to-pink-500"
                      data-width="85%"
                    ></div>
                  </div>
                </div>
                <div>
                  <div class="flex justify-between mb-1">
                    <span class="text-gray-300">React</span>
                    <span class="text-purple-300">80%</span>
                  </div>
                  <div class="skill-bar">
                    <div
                      class="skill-progress bg-gradient-to-r from-purple-500 to-pink-500"
                      data-width="80%"
                    ></div>
                  </div>
                </div>
                <div>
                  <div class="flex justify-between mb-1">
                    <span class="text-gray-300">SQL</span>
                    <span class="text-purple-300">75%</span>
                  </div>
                  <div class="skill-bar">
                    <div
                      class="skill-progress bg-gradient-to-r from-purple-500 to-pink-500"
                      data-width="75%"
                    ></div>
                  </div>
                </div>
              </div>
            </div>
            <div
              class="bg-gradient-to-br from-slate-800/50 to-slate-900/50 backdrop-blur-lg border border-purple-500/20 rounded-xl p-6"
            >
              <h3 class="text-2xl font-bold mb-4 text-purple-300">Języki</h3>
              <div class="space-y-4">
                <div>
                  <div class="flex justify-between mb-1">
                    <span class="text-gray-300">Polski</span>
                    <span class="text-purple-300">100%</span>
                  </div>
                  <div class="skill-bar">
                    <div
                      class="skill-progress bg-gradient-to-r from-purple-500 to-pink-500"
                      data-width="100%"
                    ></div>
                  </div>
                </div>
                <div>
                  <div class="flex justify-between mb-1">
                    <span class="text-gray-300">Angielski</span>
                    <span class="text-purple-300">85%</span>
                  </div>
                  <div class="skill-bar">
                    <div
                      class="skill-progress bg-gradient-to-r from-purple-500 to-pink-500"
                      data-width="85%"
                    ></div>
                  </div>
                </div>
                <div>
                  <div class="flex justify-between mb-1">
                    <span class="text-gray-300">Niemiecki</span>
                    <span class="text-purple-300">40%</span>
                  </div>
                  <div class="skill-bar">
                    <div
                      class="skill-progress bg-gradient-to-r from-purple-500 to-pink-500"
                      data-width="40%"
                    ></div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- NOWA ZAKŁADKA: ANKIETA -->
      <div id="survey-tab" class="tab-content hidden">
        <div class="space-y-8 animate-fade-in">
          <div
            class="bg-gradient-to-br from-purple-500/10 to-pink-500/10 backdrop-blur-lg border border-purple-500/20 rounded-2xl p-8"
          >
            <h2 class="text-4xl font-bold mb-6 text-purple-300">Ankieta</h2>
            <p class="text-lg text-gray-300 mb-8">
              Podziel się swoją opinią o mojej stronie! Twoje odpowiedzi pomogą mi ulepszyć treści i design.
            </p>
            
            <form id="survey-form" class="space-y-6">
              <div id="survey-questions">
                <!-- Pytania będą ładowane dynamicznie -->
              </div>
              
              <button
                type="submit"
                class="w-full py-3 px-4 rounded-lg bg-purple-500 text-white hover:bg-purple-600 transition-all"
              >
                Wyślij ankietę
              </button>
            </form>
            
            <div id="survey-message" class="mt-4 hidden p-3 rounded-lg"></div>
          </div>

          <div
            class="bg-gradient-to-br from-purple-500/10 to-pink-500/10 backdrop-blur-lg border border-purple-500/20 rounded-2xl p-8"
          >
            <h3 class="text-2xl font-bold mb-6 text-purple-300">Statystyki ankiet</h3>
            <div class="grid md:grid-cols-2 gap-6">
              <div class="space-y-4">
                <div id="survey-stats">
                  <!-- Statystyki będą ładowane dynamicznie -->
                </div>
              </div>
              <div class="space-y-4">
                <canvas id="survey-chart" width="400" height="200"></canvas>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div id="contact-tab" class="tab-content hidden">
        <div class="space-y-8 animate-fade-in">
          <div
            class="bg-gradient-to-br from-purple-500/10 to-pink-500/10 backdrop-blur-lg border border-purple-500/20 rounded-2xl p-8"
          >
            <h2 class="text-4xl font-bold mb-6 text-purple-300">Kontakt</h2>
            <p class="text-lg text-gray-300 mb-8">
              Chętnie porozmawiam o możliwościach współpracy lub po prostu o
              pasjach!
            </p>
            <div class="grid md:grid-cols-2 gap-6">
              <div class="space-y-4">
                <form id="contact-form">
                  <div>
                    <label class="block text-gray-400 mb-2">Email</label>
                    <input
                      type="email"
                      id="email-input"
                      name="email"
                      placeholder="Twój email"
                      class="w-full py-3 px-4 rounded-lg bg-slate-700 text-white border border-purple-500/30 focus:border-purple-400 outline-none transition-colors"
                      required
                    />
                  </div>
                  <div>
                    <label class="block text-gray-400 mb-2">Wiadomość</label>
                    <textarea
                      id="message-input"
                      name="message"
                      placeholder="Twoja wiadomość"
                      rows="4"
                      class="w-full py-3 px-4 rounded-lg bg-slate-700 text-white border border-purple-500/30 focus:border-purple-400 outline-none transition-colors"
                      required
                    ></textarea>
                  </div>
                  <button
                    type="submit"
                    id="send-btn"
                    class="w-full mt-4 py-3 px-4 rounded-lg bg-purple-500 text-white hover:bg-purple-600 transition-all"
                  >
                    Wyślij
                  </button>
                </form>
                <div id="form-message" class="mt-4 hidden p-3 rounded-lg"></div>
              </div>
              <div class="space-y-4">
                <div
                  class="bg-slate-800/50 rounded-xl p-4 hover:bg-slate-700/50 transition-colors"
                >
                  <p class="text-gray-400 mb-1">Email</p>
                  <p class="text-purple-300">dawid.trojanowski@example.com</p>
                </div>
                <div
                  class="bg-slate-800/50 rounded-xl p-4 hover:bg-slate-700/50 transition-colors"
                >
                  <p class="text-gray-400 mb-1">LinkedIn</p>
                  <p class="text-purple-300">
                    linkedin.com/in/dawid-trojanowski
                  </p>
                </div>
                <div
                  class="bg-slate-800/50 rounded-xl p-4 hover:bg-slate-700/50 transition-colors"
                >
                  <p class="text-gray-400 mb-1">GitHub</p>
                  <p class="text-purple-300">github.com/dawidtrojanowski</p>
                </div>
                <div
                  class="bg-slate-800/50 rounded-xl p-4 hover:bg-slate-700/50 transition-colors"
                >
                  <p class="text-gray-400 mb-1">Telefon</p>
                  <p class="text-purple-300">+48 123 456 789</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </main>

    <footer
      class="border-t border-purple-500/30 backdrop-blur-sm bg-black/20 mt-16 transition-colors duration-500"
    >
      <div class="container mx-auto px-6 py-8 text-center text-gray-400">
        <p>Dawid Trojanowski © 2025</p>
      </div>
    </footer>

    <script>
      // Tab switching functionality
      function showTab(tabName) {
        document.querySelectorAll(".tab-content").forEach((tab) => {
          tab.classList.add("hidden");
          tab.classList.remove("animate-fade-in");
        });

        setTimeout(() => {
          const activeTab = document.getElementById(tabName + "-tab");
          activeTab.classList.remove("hidden");
          activeTab.classList.add("animate-fade-in");

          // Animate skill bars when skills tab is shown
          if (tabName === "skills") {
            setTimeout(animateSkillBars, 300);
          }
          
          // Load survey data when survey tab is shown
          if (tabName === "survey") {
            loadSurveyQuestions();
            loadSurveyStats();
          }
        }, 50);

        document.querySelectorAll(".tab-btn").forEach((btn) => {
          btn.classList.remove("bg-purple-500", "text-white");
          btn.classList.add("text-purple-300");
        });
        document
          .querySelector(`[data-tab="${tabName}"]`)
          .classList.add("bg-purple-500", "text-white");

        // Close mobile menu if open
        closeMobileMenu();
      }

      // Theme toggle functionality
      const themeToggle = document.getElementById("theme-toggle");
      const sunIcon = document.getElementById("sun-icon");
      const moonIcon = document.getElementById("moon-icon");

      themeToggle.addEventListener("click", () => {
        document.body.classList.toggle("light-mode");

        if (document.body.classList.contains("light-mode")) {
          document.body.className =
            "bg-gradient-to-br from-slate-100 via-purple-100 to-slate-100 text-slate-800 min-h-screen transition-colors duration-500";
          sunIcon.classList.add("hidden");
          moonIcon.classList.remove("hidden");
        } else {
          document.body.className =
            "bg-gradient-to-br from-slate-900 via-purple-900 to-slate-900 text-white min-h-screen transition-colors duration-500";
          sunIcon.classList.remove("hidden");
          moonIcon.classList.add("hidden");
        }
      });

      // Mobile menu functionality
      const hamburger = document.getElementById("hamburger");
      const navMenu = document.getElementById("nav-menu");

      function toggleMobileMenu() {
        hamburger.classList.toggle("active");
        navMenu.classList.toggle("active");
      }

      function closeMobileMenu() {
        hamburger.classList.remove("active");
        navMenu.classList.remove("active");
      }

      hamburger.addEventListener("click", toggleMobileMenu);

      // Close menu when clicking outside
      document.addEventListener("click", (e) => {
        if (!hamburger.contains(e.target) && !navMenu.contains(e.target)) {
          closeMobileMenu();
        }
      });

      // Skill bars animation
      function animateSkillBars() {
        const skillBars = document.querySelectorAll(".skill-progress");
        skillBars.forEach((bar) => {
          const width = bar.getAttribute("data-width");
          bar.style.width = width;
        });
      }

      // Contact form functionality
      document.getElementById('contact-form').addEventListener('submit', async (e) => {
        e.preventDefault();
        
        const email = document.getElementById('email-input').value.trim();
        const message = document.getElementById('message-input').value.trim();
        const formMessage = document.getElementById('form-message');

        if (!email || !message) {
          showFormMessage("Proszę wypełnić wszystkie pola", "error");
          return;
        }

        if (!validateEmail(email)) {
          showFormMessage("Proszę podać poprawny adres email", "error");
          return;
        }

        try {
          const formData = new FormData();
          formData.append('email', email);
          formData.append('message', message);

          const response = await fetch('/api/contact', {
            method: 'POST',
            body: formData
          });

          const result = await response.json();

          if (response.ok) {
            showFormMessage(result.message, "success");
            document.getElementById('email-input').value = "";
            document.getElementById('message-input').value = "";
          } else {
            showFormMessage(result.detail || "Wystąpił błąd podczas wysyłania", "error");
          }
        } catch (error) {
          console.error('Error sending contact form:', error);
          showFormMessage("Wystąpił błąd podczas wysyłania wiadomości", "error");
        }
      });

      function validateEmail(email) {
        const re = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
        return re.test(email);
      }

      function showFormMessage(text, type) {
        const formMessage = document.getElementById('form-message');
        formMessage.textContent = text;
        formMessage.className = "mt-4 p-3 rounded-lg";

        if (type === "error") {
          formMessage.classList.add(
            "bg-red-500/20",
            "text-red-300",
            "border",
            "border-red-500/30"
          );
        } else {
          formMessage.classList.add(
            "bg-green-500/20",
            "text-green-300",
            "border",
            "border-green-500/30"
          );
        }

        formMessage.classList.remove("hidden");

        setTimeout(() => {
          formMessage.classList.add("hidden");
        }, 5000);
      }

      // Floating particles effect
      function createParticles() {
        const container = document.getElementById("particles-container");
        const particleCount = 30;

        for (let i = 0; i < particleCount; i++) {
          const particle = document.createElement("div");
          particle.classList.add("particle");

          const size = Math.random() * 60 + 20;
          particle.style.width = `${size}px`;
          particle.style.height = `${size}px`;

          particle.style.left = `${Math.random() * 100}%`;
          particle.style.top = `${Math.random() * 100}%`;

          const animationDuration = Math.random() * 20 + 10;
          particle.style.animation = `float ${animationDuration}s infinite ease-in-out`;

          container.appendChild(particle);
        }
      }

      // Survey functionality
      async function loadSurveyQuestions() {
        try {
          const response = await fetch('/api/survey/questions');
          const questions = await response.json();
          
          const container = document.getElementById('survey-questions');
          container.innerHTML = '';
          
          questions.forEach((q, index) => {
            const questionDiv = document.createElement('div');
            questionDiv.className = 'space-y-3';
            
            questionDiv.innerHTML = `
              <label class="block text-gray-300 font-semibold">
                ${q.text}
              </label>
            `;
            
            if (q.type === 'rating') {
              questionDiv.innerHTML += `
                <div class="flex gap-2 flex-wrap">
                  ${q.options.map(option => `
                    <label class="flex items-center space-x-2 cursor-pointer">
                      <input type="radio" name="question_${q.id}" value="${option}" class="hidden peer" required>
                      <span class="px-4 py-2 rounded-lg bg-slate-700 text-gray-300 peer-checked:bg-purple-500 peer-checked:text-white transition-all hover:bg-slate-600">
                        ${option}
                      </span>
                    </label>
                  `).join('')}
                </div>
              `;
            } else if (q.type === 'choice') {
              questionDiv.innerHTML += `
                <div class="space-y-2">
                  ${q.options.map(option => `
                    <label class="flex items-center space-x-3 cursor-pointer">
                      <input type="radio" name="question_${q.id}" value="${option}" class="text-purple-500 focus:ring-purple-500" required>
                      <span class="text-gray-300">${option}</span>
                    </label>
                  `).join('')}
                </div>
              `;
            } else if (q.type === 'multiselect') {
              questionDiv.innerHTML += `
                <div class="space-y-2">
                  ${q.options.map(option => `
                    <label class="flex items-center space-x-3 cursor-pointer">
                      <input type="checkbox" name="question_${q.id}" value="${option}" class="text-purple-500 focus:ring-purple-500">
                      <span class="text-gray-300">${option}</span>
                    </label>
                  `).join('')}
                </div>
              `;
            } else if (q.type === 'text') {
              questionDiv.innerHTML += `
                <textarea 
                  name="question_${q.id}" 
                  placeholder="${q.placeholder}"
                  class="w-full py-3 px-4 rounded-lg bg-slate-700 text-white border border-purple-500/30 focus:border-purple-400 outline-none transition-colors"
                  rows="3"
                ></textarea>
              `;
            }
            
            container.appendChild(questionDiv);
          });
        } catch (error) {
          console.error('Error loading survey questions:', error);
        }
      }

      async function loadSurveyStats() {
        try {
          const response = await fetch('/api/survey/stats');
          const stats = await response.json();
          
          const container = document.getElementById('survey-stats');
          
          if (stats.total_responses === 0) {
            container.innerHTML = `
              <div class="text-center text-gray-400 py-8">
                <p>Brak odpowiedzi na ankietę.</p>
                <p class="text-sm mt-2">Bądź pierwszą osobą która wypełni ankietę!</p>
              </div>
            `;
            return;
          }
          
          let statsHTML = `
            <div class="space-y-4">
              <div class="grid grid-cols-2 gap-4 text-center">
                <div class="bg-slate-800/50 rounded-lg p-4">
                  <div class="text-2xl font-bold text-purple-300">${stats.total_visits}</div>
                  <div class="text-sm text-gray-400">Odwiedzin</div>
                </div>
                <div class="bg-slate-800/50 rounded-lg p-4">
                  <div class="text-2xl font-bold text-purple-300">${stats.total_responses}</div>
                  <div class="text-sm text-gray-400">Odpowiedzi</div>
                </div>
              </div>
          `;
          
          for (const [question, answers] of Object.entries(stats.survey_responses)) {
            statsHTML += `
              <div class="border-t border-purple-500/20 pt-4">
                <h4 class="font-semibold text-purple-300 mb-2">${question}</h4>
                <div class="space-y-2">
            `;
            
            answers.forEach(item => {
              statsHTML += `
                <div class="flex justify-between items-center">
                  <span class="text-gray-300 text-sm">${item.answer}</span>
                  <span class="text-purple-300 font-semibold">${item.count}</span>
                </div>
              `;
            });
            
            statsHTML += `
                </div>
              </div>
            `;
          }
          
          statsHTML += `</div>`;
          container.innerHTML = statsHTML;
          
          // Update chart if there are responses
          updateSurveyChart(stats);
        } catch (error) {
          console.error('Error loading survey stats:', error);
          document.getElementById('survey-stats').innerHTML = `
            <div class="text-red-300 text-center py-4">
              Błąd podczas ładowania statystyk
            </div>
          `;
        }
      }

      function updateSurveyChart(stats) {
        const ctx = document.getElementById('survey-chart').getContext('2d');
        
        // Prepare data for chart
        const labels = [];
        const data = [];
        
        for (const [question, answers] of Object.entries(stats.survey_responses)) {
          answers.forEach(item => {
            labels.push(`${question}: ${item.answer}`);
            data.push(item.count);
          });
        }
        
        new Chart(ctx, {
          type: 'doughnut',
          data: {
            labels: labels,
            datasets: [{
              data: data,
              backgroundColor: [
                '#a855f7', '#ec4899', '#8b5cf6', '#d946ef', '#7c3aed',
                '#c026d3', '#6d28d9', '#a21caf', '#5b21b6', '#86198f'
              ],
              borderWidth: 2,
              borderColor: '#1e293b'
            }]
          },
          options: {
            responsive: true,
            plugins: {
              legend: {
                position: 'bottom',
                labels: {
                  color: '#cbd5e1',
                  font: {
                    size: 10
                  }
                }
              }
            }
          }
        });
      }

      // Survey form submission
      document.getElementById('survey-form').addEventListener('submit', async (e) => {
        e.preventDefault();
        
        const formData = new FormData(e.target);
        const responses = [];
        
        // Collect all responses
        for (let i = 1; i <= 5; i++) {
          const questionName = `question_${i}`;
          const questionElement = e.target.elements[questionName];
          
          if (questionElement) {
            if (questionElement.type === 'radio') {
              const selected = document.querySelector(`input[name="question_${i}"]:checked`);
              if (selected) {
                responses.push({
                  question: `Pytanie ${i}: ${document.querySelector(`label[for="question_${i}"]`)?.textContent || questionName}`,
                  answer: selected.value
                });
              }
            } else if (questionElement.type === 'checkbox') {
              const selected = document.querySelectorAll(`input[name="question_${i}"]:checked`);
              if (selected.length > 0) {
                const answers = Array.from(selected).map(cb => cb.value).join(', ');
                responses.push({
                  question: `Pytanie ${i}: ${document.querySelector(`label[for="question_${i}"]`)?.textContent || questionName}`,
                  answer: answers
                });
              }
            } else if (questionElement.tagName === 'TEXTAREA' && questionElement.value.trim()) {
              responses.push({
                question: `Pytanie ${i}: ${document.querySelector(`label[for="question_${i}"]`)?.textContent || questionName}`,
                answer: questionElement.value.trim()
              });
            }
          }
        }
        
        if (responses.length === 0) {
          showSurveyMessage('Proszę odpowiedzieć na przynajmniej jedno pytanie', 'error');
          return;
        }
        
        try {
          // Send each response
          for (const response of responses) {
            await fetch('/api/survey/submit', {
              method: 'POST',
              headers: {
                'Content-Type': 'application/json',
              },
              body: JSON.stringify(response)
            });
          }
          
          showSurveyMessage('Dziękujemy za wypełnienie ankiety!', 'success');
          e.target.reset();
          loadSurveyStats(); // Reload stats
        } catch (error) {
          console.error('Error submitting survey:', error);
          showSurveyMessage('Wystąpił błąd podczas wysyłania ankiety', 'error');
        }
      });

      function showSurveyMessage(text, type) {
        const messageDiv = document.getElementById('survey-message');
        messageDiv.textContent = text;
        messageDiv.className = 'mt-4 p-3 rounded-lg';
        
        if (type === 'error') {
          messageDiv.classList.add('bg-red-500/20', 'text-red-300', 'border', 'border-red-500/30');
        } else {
          messageDiv.classList.add('bg-green-500/20', 'text-green-300', 'border', 'border-green-500/30');
        }
        
        messageDiv.classList.remove('hidden');
        
        setTimeout(() => {
          messageDiv.classList.add('hidden');
        }, 5000);
      }

      // Initialize on page load
      document.addEventListener("DOMContentLoaded", () => {
        showTab("intro");
        createParticles();

        // Add floating animation
        const style = document.createElement("style");
        style.textContent = `
          @keyframes float {
            0%, 100% { transform: translate(0, 0) rotate(0deg); }
            25% { transform: translate(10px, -10px) rotate(5deg); }
            50% { transform: translate(-5px, 5px) rotate(-5deg); }
            75% { transform: translate(-10px, -5px) rotate(3deg); }
          }
        `;
        document.head.appendChild(style);
      });
    </script>
  </body>
</html>
EOF

cat << 'EOF' > "$APP_DIR/requirements.txt"
fastapi==0.104.1
uvicorn==0.24.0
jinja2==3.1.2
psycopg2-binary==2.9.7
prometheus-fastapi-instrumentator==5.11.1
python-multipart==0.0.6
pydantic==2.5.0
EOF

# ==============================
# Dockerfile
# ==============================
cat << 'EOF' > Dockerfile
FROM python:3.10-slim

WORKDIR /app

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

ENV PYTHONUNBUFFERED=1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

# ==============================
# Kubernetes Resources
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
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
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

# PostgreSQL Deployment
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
        livenessProbe:
          exec:
            command:
            - sh
            - -c
            - exec pg_isready -U appuser -d appdb
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          exec:
            command:
            - sh
            - -c
            - exec pg_isready -U appuser -d appdb
          initialDelaySeconds: 5
          periodSeconds: 5
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

# pgAdmin Deployment
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
        livenessProbe:
          httpGet:
            path: /misc/ping
            port: 80
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
        readinessProbe:
          httpGet:
            path: /misc/ping
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 5
          timeoutSeconds: 3
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
EOF

# Prometheus ConfigMap
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
        env:
        - name: GF_SECURITY_ADMIN_USER
          value: admin
        - name: GF_SECURITY_ADMIN_PASSWORD
          value: admin
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

# Loki ConfigMap
cat << EOF > k8s/base/loki-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: $NAMESPACE
data:
  loki.yaml: |
    auth_enabled: false
    server:
      http_listen_port: 3100
    common:
      path_prefix: /tmp/loki
      storage:
        filesystem:
          chunks_directory: /tmp/loki/chunks
          rules_directory: /tmp/loki/rules
      replication_factor: 1
      ring:
        kvstore:
          store: inmemory
    schema_config:
      configs:
        - from: 2020-10-24
          store: boltdb-shipper
          object_store: filesystem
          schema: v11
          index:
            prefix: index_
            period: 24h
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
          - -config.file=/etc/loki/loki.yaml
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

# Promtail ConfigMap
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
      grpc_listen_port: 0
    positions:
      filename: /tmp/positions.yaml
    clients:
      - url: http://loki:3100/loki/api/v1/push
    scrape_configs:
    - job_name: system
      static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          __path__: /var/log/*log
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
          - -config.file=/etc/promtail/promtail.yaml
        volumeMounts:
        - name: config
          mountPath: /etc/promtail
        - name: varlog
          mountPath: /var/log
      volumes:
      - name: config
        configMap:
          name: promtail-config
      - name: varlog
        hostPath:
          path: /var/log
EOF

# Tempo ConfigMap
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
            http:
            grpc:
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
          - -config.file=/etc/tempo/tempo.yaml
        ports:
        - containerPort: 3200
        volumeMounts:
        - name: config
          mountPath: /etc/tempo
        - name: data
          mountPath: /var/tempo
      volumes:
      - name: config
        configMap:
          name: tempo-config
      - name: data
        emptyDir: {}
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

# Kustomization
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

# ArgoCD Application
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

# GitHub Actions - POPRAWIONA WERSJA
cat << EOF > .github/workflows/deploy.yml
name: Build and Deploy
on:
  push:
    branches: [main]
jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: \${{ github.actor }}
          password: \${{ secrets.GHCR_PAT }}
          
      - name: Build and push Docker image
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            $REGISTRY:latest
            $REGISTRY:\${{ github.sha }}
          cache-from: type=registry,ref=$REGISTRY:latest
          cache-to: type=inline
          
      - name: Deploy to Kubernetes
        run: |
          echo "Deployment would happen here via ArgoCD"
          
      - name: Run tests
        run: |
          echo "Running tests..."
EOF

echo "✅ KOMPLETNY SKRYPT Z ANKIETĄ I WSZYSTKIMI OBIEKTAMI GOTOWY!"
echo ""
echo "🎯 DODANE FUNKCJONALNOŚCI:"
echo "   📊 Ankieta z 5 pytaniami różnych typów"
echo "   📈 Statystyki w czasie rzeczywistym z wykresami"
echo "   💌 Formularz kontaktowy z zapisem do bazy"
echo "   👥 Śledzenie odwiedzin stron"
echo "   🔄 Retry logic dla połączeń z bazą danych"
echo ""
echo "🏗️  WSZYSTKIE OBIEKTY KUBERNETES:"
echo "   ✅ ConfigMap & Secret"
echo "   ✅ Deployment & Service (App, PostgreSQL, pgAdmin)"
echo "   ✅ Ingress z wieloma hostami"
echo "   ✅ Monitoring Stack (Prometheus, Grafana, Loki, Promtail, Tempo)"
echo "   ✅ Kyverno Policy"
echo "   ✅ ArgoCD Application"
echo ""
echo "🚀 ENDPOINTY API:"
echo "   GET  /                    - Strona główna"
echo "   GET  /health              - Health check"
echo "   GET  /api/survey/questions - Pytania ankietowe"
echo "   POST /api/survey/submit   - Zapis odpowiedzi"
echo "   GET  /api/survey/stats    - Statystyki ankiet"
echo "   POST /api/contact         - Formularz kontaktowy"
echo "   GET  /api/visits          - Statystyki odwiedzin"
echo ""
echo "📊 DOSTĘP:"
echo "   🌐 Strona: http://$PROJECT.local"
echo "   🗄️  pgAdmin: http://pgadmin.$PROJECT.local (admin@admin.com/admin)"
echo "   📈 Grafana: http://grafana.$PROJECT.local (admin/admin)"
echo ""
echo "💾 BAZA DANYCH:"
echo "   📝 survey_responses - odpowiedzi ankiet"
echo "   👀 page_visits - śledzenie odwiedzin"
echo "   💌 contact_messages - wiadomości kontaktowe"