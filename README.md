# Power BI RLS Chatbot

A full-stack demo that embeds a **Power BI report** side-by-side with an
**AI chatbot**, both enforcing **Row-Level Security (RLS)** via a service
principal and effective identity — designed for scenarios where end users are
**not authenticated against Entra ID** (e.g., Power BI Embedded "App Owns
Data").

```
┌─────────────────────────────────────────────────────────┐
│  Browser (your customer)                                │
│  ┌──────────────────────┐ ┌──────────────────────────┐  │
│  │  Embedded PBI Report │ │  AI Data Chatbot         │  │
│  │  (RLS-filtered)      │ │  "What were my sales?"   │  │
│  │                      │ │  → DAX + Effective ID    │  │
│  │                      │ │  → RLS-filtered answer   │  │
│  └──────────────────────┘ └──────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
         │                           │
         ▼                           ▼
   ┌───────────┐            ┌──────────────────┐
   │ Embed     │            │ Execute Queries  │
   │ Token API │            │ API + Effective  │
   │ + RLS     │            │ Identity         │
   └─────┬─────┘            └────────┬─────────┘
         │                           │
         ▼                           ▼
   ┌───────────────────────────────────────┐
   │        Power BI Service               │
   │   Service Principal + RLS roles       │
   └───────────────────────────────────────┘
```

---

## Features

| Feature | Details |
|---------|---------|
| **Embedded Report** | Power BI JavaScript SDK, "App Owns Data" pattern |
| **Row-Level Security** | Effective identity passed on every embed token and DAX query |
| **AI Chatbot** | Azure OpenAI generates DAX from natural language |
| **RLS in Chat** | Every DAX query is executed with the user's effective identity |
| **User Simulation** | Dropdown lets you switch between demo users to see different RLS views |
| **Schema Discovery** | Automatically reads dataset schema for LLM context |

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| **Azure AD App Registration** | With a client secret; added as a service principal to your Power BI workspace |
| **Power BI Premium / PPU / Fabric (F SKU)** capacity | Required for the Execute Queries REST API |
| **A published report with RLS** | See [Setting Up the Sample Report](#setting-up-the-sample-report) below |
| **Azure OpenAI resource** | With a GPT-4o (or similar) deployment |
| **Python 3.11+** | For the backend |

---

## Quick Start

### 1. Clone & install

```bash
cd powerbi-rls-chatbot
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

### 2. Configure

```bash
cp .env.example .env
# Edit .env with your values
```

### 3. Run

```bash
uvicorn app:app --reload --port 8000
```

Open **http://localhost:8000** — select a demo user from the dropdown.

---

## Setting Up the Sample Report

### Step 1: Create the dataset in Power BI Desktop

Create a new Power BI Desktop file with these tables (you can use **Enter Data**):

**Sales table:**

| Region | Product | Amount | Date |
|--------|---------|--------|------|
| West | Widget A | 1200 | 2025-01-15 |
| West | Widget B | 800 | 2025-01-20 |
| East | Widget A | 1500 | 2025-02-10 |
| East | Widget C | 2200 | 2025-02-15 |
| West | Widget C | 950 | 2025-03-01 |
| East | Widget B | 1800 | 2025-03-10 |
| West | Widget A | 1100 | 2025-04-05 |
| East | Widget A | 2000 | 2025-04-12 |

**UserAccess table** (this is your RLS mapping table):

| UserEmail | Region |
|-----------|--------|
| alice@contoso.com | West |
| bob@contoso.com | East |
| carlos@contoso.com | West |
| carlos@contoso.com | East |

### Step 2: Create a relationship

- Create a relationship: `UserAccess[Region]` → `Sales[Region]` (many-to-one)

### Step 3: Define the RLS role

1. Go to **Modeling → Manage Roles**
2. Create a role named **`ViewerRole`**
3. On the **UserAccess** table, add the DAX filter:

```dax
[UserEmail] = USERNAME()
```

4. Click **Save**

### Step 4: Test in Desktop

- **Modeling → View as → ViewerRole** with username `alice@contoso.com`
- You should only see West region data

### Step 5: Publish

1. Publish to a **Premium / PPU / Fabric workspace**
2. Note the **Workspace ID**, **Report ID**, and **Dataset ID** from the URL

### Step 6: Grant the service principal access

1. In the Power BI Admin portal, enable *"Allow service principals to use Power BI APIs"*
2. Add your Azure AD app (service principal) to the workspace as a **Member** or **Contributor**

### Step 7: Update `.env`

Fill in the IDs and credentials in your `.env` file.

---

## Project Structure

```
powerbi-rls-chatbot/
├── app.py                  # FastAPI application & routes
├── config.py               # Settings loaded from .env
├── powerbi_service.py      # PBI REST API: tokens, DAX, schema
├── chat_engine.py          # LLM orchestrator: NL → DAX → answer
├── requirements.txt        # Python dependencies
├── .env.example            # Template for configuration
├── templates/
│   └── index.html          # Main page (Jinja2 template)
├── static/
│   ├── css/styles.css      # UI styles
│   └── js/app.js           # Frontend logic
└── sample_report/
    └── SalesWithRLS.pbit   # (you create this in PBI Desktop)
```

---

## How It Works

### Report Embedding with RLS

```
User selects "Alice" → POST /api/embed-token { rls_username: "alice@contoso.com" }
  → Server calls PBI GenerateToken with EffectiveIdentity(username=alice, role=ViewerRole)
  → Embed token returned → PBI JS SDK renders report filtered to West region
```

### Chat with RLS

```
Alice asks "What were total sales?" → POST /api/chat
  → LLM receives dataset schema, generates DAX:
      EVALUATE SUMMARIZECOLUMNS(Sales[Region], "Total", SUM(Sales[Amount]))
  → Server calls PBI ExecuteQueries with EffectiveIdentity(username=alice)
  → Results: [{ Region: "West", Total: 4050 }]  ← only West, RLS applied!
  → LLM summarises: "Your total sales were $4,050, all in the West region."
```

---

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Main page with embedded report + chatbot |
| `POST` | `/api/embed-token` | Generate embed token with RLS effective identity |
| `POST` | `/api/chat` | Send a chat message, get RLS-filtered answer |
| `GET` | `/health` | Health check |

---

## Security Notes

- **Never expose service principal credentials to the browser.** All PBI API calls go through the server.
- **The LLM cannot bypass RLS.** Every DAX query is executed server-side with the user's effective identity — Power BI enforces the role filter.
- **Validate DAX** before execution in production. The current implementation trusts the LLM output — you may want to add an allowlist of tables/functions.
- **Map users securely.** In production, replace the demo user dropdown with your actual user-identity mapping (JWT from your auth system, session lookup, etc.).

---

## Production Considerations

| Area | Recommendation |
|------|----------------|
| **Authentication** | Replace demo dropdown with your app's auth (JWT, OAuth, session) |
| **Token caching** | Cache MSAL tokens (built-in) and embed tokens (TTL ~1hr) |
| **Rate limiting** | PBI Execute Queries has throttling; add server-side rate limits |
| **Schema caching** | Cache the dataset schema; refresh on deploy or schedule |
| **Streaming** | Use SSE/WebSocket for streaming LLM responses |
| **Monitoring** | Add Application Insights or equivalent |
| **DAX validation** | Sanitise LLM-generated DAX with an allowlist approach |

---

## License

MIT
