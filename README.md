# Power BI RLS Chatbot — Foundry + Entra Enterprise SaaS

A **production-ready enterprise SaaS accelerator** that combines:
- **Embedded Power BI report** with Row-Level Security (RLS)
- **AI Foundry chatbot** for natural language data exploration
- **Azure Entra ID** for secure multi-tenant user authentication
- **OBO token exchange** for per-user query execution and RLS enforcement

Perfect for SaaS applications where **each tenant's users** see only **their own data** — both in the report and in chat responses.

```
┌──────────────────────────────────────────────────┐
│  Multi-Tenant SaaS Browser                      │
│  ┌─────────────────┐      ┌────────────────────┐ │
│  │ PBI Report      │      │ AI Data Chatbot    │ │
│  │ (RLS filtered)  │      │ "Sales this year?" │ │
│  │                 │      │ → Foundry engine   │ │
│  │ Tenant A user   │      │ → Fabric semantic  │ │
│  │ sees only their │      │ → RLS-filtered     │ │
│  │ data            │      │   natural language │ │
│  └─────────────────┘      └────────────────────┘ │
└───┬─────────────────────────────────────┬────────┘
    │                                     │
    │   [MSAL Sign-In]                    │   [OBO Token Exchange]
    │   User → Entra → MSAL Token         │   User Token → OBO → Foundry Token
    ▼                                     ▼
┌──────────────────┐          ┌─────────────────────────┐
│ Power BI Token   │          │ Foundry API             │
│ Generation       │          │ + RLS Context in Prompt │
└────────┬─────────┘          └──────────┬──────────────┘
         │                               │
         ▼                               ▼
┌────────────────────────────────────────────────────┐
│  Fabric (F64 Capacity)                            │
│  Semantic Model with Row-Level Security           │
│  ├─ Identity Table: Users[UPN]                    │
│  ├─ Filter Table: Sales[Region]                   │
│  └─ RLS: Users see only rows matching their UPN   │
└────────────────────────────────────────────────────┘
```

---

## Features

| Feature | Details |
|---------|---------|
| **Multi-Tenant Ready** | Azure Entra ID OAuth 2.0 with per-user identity scoping |
| **Embedded Report** | Power BI JS SDK, role-based RLS via embed tokens |
| **Row-Level Security** | OBO token + RLS filter applied on every DAX query; server-side enforcement |
| **AI Chatbot** | Azure AI Foundry orchestrates natural language → data queries |
| **Foundry Integration** | Direct connection to Fabric Data Agent or Power BI Direct Query |
| **Config-driven Setup** | `rls_config.json` maps your identity & filter tables — no code changes |
| **Auto-discovery** | `setup.rb` scans your schema and RLS model, generates config |
| **MSAL Authentication** | Browser sign-in via PKCE flow; OBO for backend delegation |
| **User Simulation** | Demo dropdown for testing different RLS identities |

---

## Architecture

**Authentication Flow:**
1. **Frontend (Browser):** User signs in with Entra ID via MSAL.js (PKCE)
2. **Backend:** Exchanges user token for Foundry-scoped token via OBO
3. **Foundry:** Receives OBO token, passes user identity to Fabric
4. **Fabric Semantic Model:** RLS filters applied per user's identity
5. **Response:** Natural language answer + filtered data rows returned

**Why Foundry + Entra?**
- ✅ **Enterprise-ready:** Entra ID handles user identity, tenant isolation, MFA
- ✅ **SaaS-friendly:** OBO token flow scales across unlimited users
- ✅ **RLS enforced:** Semantic model enforces row-level filtering per user
- ✅ **Zero data leakage:** Cross-tenant data isolation built in
- ✅ **Simplified:** No need for ROPC ("Master User") accounts

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| **Entra ID Tenant** | For OAuth 2.0 and user authentication |
| **Entra App Registration** | Multi-tenant app w/ SPA platform (MSAL.js) + Web platform (OBO) |
| **Power BI Premium / PPU** | Required for RLS and embedded reports |
| **Fabric Workspace (F64 Capacity)** | Semantic model with RLS roles defined |
| **Fabric Data Agent** | Published for programmatic API access |
| **Azure AI Foundry** | Project with connection to Fabric |
| **Ruby 3.2+** | Backend runtime |

---

## Quick Start

### 1. Clone & install

```bash
cd powerbi-rls-chatbot
bundle install
```

### 2. Configure environment

```bash
cp .env.example .env
```

Edit `.env` and fill in your values (organized by section):

| Section | Key Variables | Where to find them |
|---------|---------------|--------------------|
| **Entra ID (REQUIRED)** | `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` | Entra ID → App Registrations |
| **Power BI** | `PBI_WORKSPACE_ID`, `PBI_REPORT_ID`, `PBI_DATASET_ID`, `PBI_RLS_ROLE` | Power BI service URL or REST API |
| **Foundry (PRIMARY)** | `FOUNDRY_ENDPOINT` | Azure AI Foundry → Deployments |
| **MSAL (Frontend)** | `MSAL_API_SCOPE` | Entra App Registration → API Permissions |
| **DAX Auth** | `DAX_AUTH_MODE`, `DAX_USER_EMAIL`, `DAX_USER_PASSWORD` | Session-based or admin account |
| **App** | `APP_SECRET_KEY`, `DEMO_USERS` | Generate a random key; set demo user map |

### 3. Register your Entra AD app (one-time)

In **Azure Portal → Entra ID → App Registrations**:
1. **Create New Registration**
   - Name: "Power BI RLS Chatbot"
   - Supported account types: **Multitenant** (for SaaS)
2. **Add Platforms**
   - **Web:** Redirect URI = `https://localhost:4567/`
   - **Single-Page Application:** Redirect URI = `https://localhost:3000/`
3. **Configure API Permissions**
   - Microsoft Graph → `User.Read` (delegated)
   - Power BI Service → `Report.Read.All`, `Dataset.ReadWrite.All` (delegated)
   - Grant admin consent
4. **Create a Client Secret** → copy to `.env` as `AZURE_CLIENT_SECRET`
5. **Expose an API**
   - Application ID URI: `api://{YOUR_CLIENT_ID}`
   - Scope: `chat.read` (used for OBO token exchange)
6. **Grant workspace access:** Add this app as **Member** in your Power BI workspace

### 4. Publish your Fabric Data Agent

In **Fabric Portal**:
```
Your Workspace → Data Agents → Your Agent → Publish
```
This activates the agent for programmatic API access via Foundry.

### 5. Run first-time setup

`setup.rb` does **three things**:

1. **Discovers your dataset schema** — Runs `COLUMNSTATISTICS()` and
   `INFO.MEASURES()` DAX queries to enumerate all tables, columns, and
   measures. Hidden system tables (`DateTableTemplate_*`, `LocalDateTable_*`)
   are automatically filtered out.

2. **Detects your RLS model** — Fetches the semantic model definition via
   the Fabric `getDefinition` API (TMDL format). It parses:
   - **Role definitions** — finds the identity table + column (e.g.
     `Users[UPN]`) from filter expressions like `[UPN] == USERNAME()`
   - **Relationships** — walks the relationship graph (BFS) from the identity
     table to find the best filter target (the table/column RLS should filter
     on)
   - Falls back to **schema heuristics** if TMDL isn't available (e.g. non-
     Fabric workspaces)

3. **Writes config files**:
   - `sample_report/schema.json` — dataset schema for the LLM
   - `rls_config.json` — RLS identity + filter mapping

**Modes:**

| Flag | Behaviour |
|------|-----------|
| *(none)* | Interactive — auto-detects then asks you to confirm or adjust |
| `--auto` | Fully automatic — accepts best-guess defaults, no prompts |

```bash
# Interactive (recommended for first run)
ruby setup.rb

# Fully automatic
ruby setup.rb --auto
```

> **Manual alternative:** You can create `rls_config.json` and
> `sample_report/schema.json` by hand — see [RLS Configuration](#rls-configuration)
> and [Schema File](#schema-file) below.

### 5. Run

```bash
ruby app.rb
```

Open **http://localhost:4567** — select a demo user from the dropdown.

---

## What `setup.rb` Does

```
ruby setup.rb
  │
  ├─ 1. Acquires tokens
  │     ├── Service Principal token (Power BI scope)
  │     ├── Service Principal token (Fabric scope)
  │     └── DAX token (az cli or ROPC)
  │
  ├─ 2. Discovers schema via DAX
  │     ├── EVALUATE COLUMNSTATISTICS()        → tables + columns
  │     ├── SELECT * FROM $SYSTEM.TMSCHEMA_MEASURES → measures  (DMV)
  │     ├── Filters hidden system tables
  │     └── Writes sample_report/schema.json
  │
  ├─ 3. Detects RLS configuration
  │     ├── Fetches TMDL via Fabric getDefinition API
  │     │     ├── Parses role files → identity table/column
  │     │     ├── Parses relationship files → builds graph
  │     │     └── BFS from identity table → filter target
  │     │
  │     ├── (fallback) Heuristic detection
  │     │     ├── Matches table/column names against known patterns
  │     │     └── Scores candidates (UPN, Email, UserName, etc.)
  │     │
  │     └── Writes rls_config.json
  │
  └─ Done! → "Run: ruby app.rb"
```

If you change your Power BI model (add tables, modify RLS), just re-run
`setup.rb` to regenerate the config files.

---

## RLS Configuration

The file **`rls_config.json`** tells the accelerator how to enforce RLS on
DAX chat queries. `setup.rb` generates this automatically, but you can also
create or edit it by hand.

A template is provided in **`rls_config.example.json`**.

```jsonc
{
  // Set to false to disable DAX-level RLS (embedded report still uses RLS)
  "enabled": true,

  // The table + column that stores user identities (e.g. UPN / email)
  "identity_table": "Users",
  "identity_column": "UPN",

  // The table + column to TREATAS-filter on (the RLS security boundary)
  "filter_table": "SalesTerritories",
  "filter_column": "SalesTerritoryRegion",

  // Optional: override the auto-generated lookup DAX.
  // Use {username} as a placeholder for the current user's UPN.
  "custom_lookup_dax": null,

  // Free-text description included in the LLM system prompt so it
  // understands your RLS model.
  "description": "Each user sees data only for their assigned regions."
}
```

### How it works

1. **User lookup** — When a chat request arrives for `alice@contoso.com`, the
   server runs a DAX query against your dataset:
   ```dax
   EVALUATE
   CALCULATETABLE(
       VALUES('SalesTerritories'[SalesTerritoryRegion]),
       'Users'[UPN] = "alice@contoso.com"
   )
   ```
   This returns the set of allowed values (e.g. `["West", "Central"]`).

2. **Query wrapping** — The LLM-generated DAX is wrapped with a
   `CALCULATETABLE + TREATAS` filter:
   ```dax
   EVALUATE
   CALCULATETABLE(
       <original query>,
       TREATAS({"West", "Central"}, 'SalesTerritories'[SalesTerritoryRegion])
   )
   ```

3. **Result** — The user only sees data filtered to their allowed values,
   matching what the embedded report shows via the embed token's effective
   identity.

### Common patterns

| RLS Model | identity_table | identity_column | filter_table | filter_column |
|-----------|---------------|-----------------|--------------|---------------|
| Region-based | Users | UPN | SalesTerritories | SalesTerritoryRegion |
| Department-based | Employees | Email | Departments | DepartmentName |
| Country-based | UserAccess | UserEmail | Geography | Country |
| Customer-based | UserCustomerMap | UserPrincipalName | Customers | CustomerKey |

### Custom lookup DAX

For complex models where the identity → filter chain isn't a simple
relationship, provide `custom_lookup_dax`:

```json
{
  "custom_lookup_dax": "EVALUATE SELECTCOLUMNS(FILTER(NATURALINNERJOIN('UserAccess', 'RegionMap'), 'UserAccess'[Email] = \"{username}\"), \"Region\", 'RegionMap'[Region])",
  "filter_table": "RegionMap",
  "filter_column": "Region"
}
```

### Disabling RLS on chat

Set `"enabled": false` (or delete `rls_config.json`). The embedded report will
still enforce RLS via the embed token, but chat queries will run unfiltered.

---

## Schema File

**`sample_report/schema.json`** is generated by `setup.rb`. It tells the LLM
what tables, columns, and measures exist so it can write correct DAX.

```json
{
  "tables": [
    {
      "name": "Sales",
      "columns": ["ProductKey", "SalesAmount", "OrderDate", "Region"],
      "measures": ["Total Sales", "YoY Growth %"]
    },
    {
      "name": "Products",
      "columns": ["ProductKey", "ProductName", "Category"],
      "measures": []
    }
  ]
}
```

`setup.rb` auto-discovers this via DAX queries (`COLUMNSTATISTICS()` and
`INFO.MEASURES()`) and filters out hidden system tables. You can also create
or edit it manually.

> **Tip:** Re-run `setup.rb` whenever your Power BI model changes (new tables,
> renamed columns, etc.) to keep the schema in sync.

---

## DAX Execution Auth — Why Not Service Principal?

The Power BI `executeQueries` REST API requires **`Dataset.ReadWrite.All`** —
a **delegated-only** permission (it requires a user context). This is a
universal limitation across all tenants.

| Auth Method | Token Type | `executeQueries` | Why |
|-------------|-----------|-------------------|-----|
| **Service Principal** | App-only (client credentials) | **401** | No `Dataset.ReadWrite.All` app role exists |
| **Managed Identity** | App-only (client credentials) | **401** | Same — no user context |
| **AzureCliCredential** | Delegated (your `az login`) | **200** | Has user context |
| **ROPC (Master User)** | Delegated (username/password) | **200** | Has user context |
| **On-Behalf-Of** | Delegated (exchanged user token) | **200** | Has user context |

### Supported auth modes (`DAX_AUTH_MODE` in `.env`)

| Mode | Setting | When to use |
|------|---------|-------------|
| `azcli` | `DAX_AUTH_MODE=azcli` (default) | Local development — requires `az login` as a Power BI admin |
| `ropc` | `DAX_AUTH_MODE=ropc` | Production / CI — set `DAX_USER_EMAIL` and `DAX_USER_PASSWORD` |

#### ROPC setup

1. Set `DAX_AUTH_MODE=ropc` in `.env`
2. Uncomment and fill in `DAX_USER_EMAIL` and `DAX_USER_PASSWORD`
3. The service account must **not** have MFA enabled
4. The app registration must allow public client flows:
   Portal → App Registration → Authentication → Advanced → Allow public client flows → **Yes**

#### On-Behalf-Of (recommended for production)

**OBO** is the most secure production option but requires replacing the demo
user dropdown with real Entra ID authentication. The `executeQueries` call
would use the real user's exchanged token, eliminating the need for a stored
password. (Not implemented in this accelerator — intended as a next step.)

---

##  Data Agent + Foundry Integration

This app uses Azure AI Foundry as the orchestration layer with Fabric Data Agent as the knowledge source.



### Environment Variables for Fabric Data Agent

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `USE_FABRIC_DATA_AGENT` | No | `false` | Set to `true` to enable Fabric Data Agent |
| `FABRIC_DATA_AGENT_URL` | Yes (if agent enabled) | — | Published endpoint of your Fabric Data Agent |

### Troubleshooting Fabric Data Agent

| Problem | Cause | Fix |
|---------|-------|-----|
| Data Agent returns 401 | Token doesn't have permission to access agent | Ensure `az login` session is authorized for the workspace |
| Data Agent returns 404 | Invalid agent URL or ID | Copy the exact URL from Fabric portal |
| Data Agent returns empty results | Agent not trained on schema or table names wrong | Re-configure the agent in Fabric to match your dataset |
| DAX execution fails | Agent-generated DAX has syntax errors | Check agent logs in Fabric and adjust agent configuration |

---

## Environment Variables Reference

All settings live in `.env` (copied from `.env.example`):

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `AZURE_TENANT_ID` | Yes | — | Entra ID tenant ID |
| `AZURE_CLIENT_ID` | Yes | — | App registration client ID |
| `AZURE_CLIENT_SECRET` | Yes | — | App registration client secret |
| `PBI_WORKSPACE_ID` | Yes | — | Power BI workspace GUID |
| `PBI_REPORT_ID` | Yes | — | Power BI report GUID |
| `PBI_DATASET_ID` | Yes | — | Power BI dataset (semantic model) GUID |
| `PBI_RLS_ROLE` | Yes | `ViewerRole` | RLS role name (case-sensitive) |
| `DAX_AUTH_MODE` | No | `azcli` | `azcli` or `ropc` |
| `DAX_USER_EMAIL` | ROPC only | — | Service account email |
| `DAX_USER_PASSWORD` | ROPC only | — | Service account password |
| `FOUNDRY_ENDPOINT` | Yes | — | Azure AI Foundry endpoint URL (with /openai/v1/chat/completions appended) |
| `MSAL_API_SCOPE` | Yes | `User.Read` | OAuth 2.0 scope for delegated token requests |
| `APP_SECRET_KEY` | Yes | — | Random string for session signing |
| `DEMO_USERS` | Yes | — | JSON map: `{"Display Name":"upn@domain.com"}` |

---

## Project Structure

```
powerbi-rls-chatbot/
├── app.rb                   # Sinatra routes (embed token, chat, health)
├── config.rb                # Settings from .env + rls_config.json loader
├── powerbi_service.rb       # PBI REST API: tokens, DAX execution, RLS wrapping
├── chat_engine.rb           # LLM orchestrator: NL → DAX → RLS → answer
├── setup.rb                 # First-time setup: auto-discover schema + RLS
├── rls_config.json          # RLS configuration (generated by setup.rb)
├── rls_config.example.json  # Template for rls_config.json
├── Gemfile                  # Ruby dependencies
├── .env                     # Secrets & IDs (git-ignored)
├── .env.example             # Documented template for .env
├── Dockerfile               # Container build
├── templates/
│   └── index.html           # ERB page template
├── static/
│   ├── css/styles.css       # UI styles
│   └── js/app.js            # Frontend logic (PBI embed + chat)
└── sample_report/
    └── schema.json          # Dataset schema (generated by setup.rb)
```

---

## How It Works

### Report Embedding with RLS

```
User selects "Alice" → POST /api/embed-token { rls_username: "alice@contoso.com" }
  → Server acquires SP token (client credentials)
  → Calls PBI GenerateToken with EffectiveIdentity(username=alice, role=ViewerRole)
  → Embed token returned → PBI JS SDK renders report filtered by RLS
```

### Chat with RLS

```
Alice asks "What were total sales by region?"
  → POST /api/chat { message, rls_username: "alice@contoso.com" }
  → Server loads schema.json + rls_config.json
  → LLM generates DAX: EVALUATE SUMMARIZECOLUMNS(...)
  → Server looks up Alice's allowed values: ["West"]
  → Server wraps DAX: CALCULATETABLE(<query>, TREATAS({"West"}, ...))
  → Calls executeQueries with delegated token
  → Results: [{ Region: "West", Total: 4050 }]  ← RLS applied!
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

## Adapting to Your Report — Checklist

1. **`.env`** — Fill in your Azure AD, Power BI, and OpenAI settings
   (copy from `.env.example`)
2. **`az login`** — Sign in as a Power BI admin (or configure ROPC)
3. **`ruby setup.rb`** — Auto-generates `schema.json` and `rls_config.json`
4. **Review** — Check the generated files; adjust if needed
5. **`DEMO_USERS`** — Set demo user map in `.env` to match your RLS identities
6. **Test** — Run `ruby app.rb`, switch between users,
   and verify each sees only their data

No Ruby code changes required.

---

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `setup.rb` — "401 Unauthorized" on schema discovery | DAX token doesn't have user context | Run `az login` (azcli) or configure ROPC credentials |
| `setup.rb` — "TMDL fetch failed" | Workspace isn't on Fabric (F SKU) | Expected — setup.rb falls back to heuristics automatically |
| `setup.rb` — identity column is empty | Filter expression uses non-standard DAX | Edit `rls_config.json` manually after setup |
| Chat returns unfiltered data | `rls_config.json` has `"enabled": false` or wrong table/column | Re-run `setup.rb` or edit the file |
| Embed token 403 | SP not added to workspace, or wrong workspace/report ID | Add SP as Member+ in PBI workspace settings |
| DAX 401 | Using SP/MI for `executeQueries` | Switch to `azcli` or `ropc` — see [DAX Execution Auth](#dax-execution-auth--why-not-service-principal) |

---

## Security Notes

- **Service principal credentials never reach the browser.** All PBI API calls
  are server-side.
- **The LLM cannot bypass RLS.** Every DAX query is wrapped server-side with
  CALCULATETABLE + TREATAS before execution.
- **Validate DAX** in production. Consider an allowlist of tables/functions.
- **Map users securely.** Replace the demo dropdown with your auth system
  (JWT, OAuth2, session) in production.

---

## Production Considerations

| Area | Recommendation |
|------|----------------|
| **Authentication** | Replace demo dropdown with Entra ID / your auth system |
| **DAX auth** | Use ROPC (Master User) or OBO for delegated tokens |
| **Token caching** | MSAL handles SP token caching; consider caching embed tokens (TTL ~1 hr) |
| **Rate limiting** | `executeQueries` is throttled; add server-side rate limits |
| **Schema refresh** | Re-run `setup.rb` when the Power BI model changes |
| **Streaming** | Add SSE/WebSocket for streaming LLM responses |
| **Monitoring** | Application Insights or equivalent |
| **DAX validation** | Sanitise LLM-generated DAX before execution |

---

## License

MIT
