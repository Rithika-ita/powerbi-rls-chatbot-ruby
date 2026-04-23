# Embedded Fabric Reports + Chatbot NLQ — Architecture & Implementation Guide

> Authored: 2026-04-22  
> POC Goal: Customers view embedded Power BI/Fabric reports and ask natural-language questions,  
> with answers generated programmatically from the semantic model, RLS enforced per user.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                      Browser (Customer)                  │
│                                                          │
│   ┌──────────────────┐     ┌──────────────────────┐     │
│   │  Embedded Report │     │  Chat / NLQ UI       │     │
│   │  (powerbi-client)│     │  (your custom UI)    │     │
│   └────────┬─────────┘     └──────────┬───────────┘     │
│            │ embed token              │ user question    │
└────────────┼──────────────────────────┼─────────────────┘
             │                          │
             ▼                          ▼
┌─────────────────────────────────────────────────────────┐
│                   Your Backend API                       │
│                                                          │
│  Track 1: Embedding          Track 2: Chatbot NLQ       │
│  ┌──────────────────┐        ┌──────────────────────┐   │
│  │ Service Principal│        │ Service Account       │   │
│  │ (Entra app reg.) │        │ (Entra master user)  │   │
│  │                  │        │                       │   │
│  │ GenerateToken    │        │ 1. Get schema         │   │
│  │ + effectiveIdent.│        │ 2. NL → DAX (OpenAI) │   │
│  │ (RLS roles)      │        │ 3. executeQueries     │   │
│  └──────────────────┘        │    + impersonatedUser │   │
│                              └──────────────────────┘   │
└─────────────────────────────────────────────────────────┘
             │                          │
             ▼                          ▼
┌─────────────────────────────────────────────────────────┐
│              Microsoft Fabric / Power BI Service         │
│                                                          │
│         Semantic Model (RLS enforced)                    │
└─────────────────────────────────────────────────────────┘
```

---

## Why Two Auth Tracks

| | Track 1 — Service Principal | Track 2 — Service Account (Master User) |
|---|---|---|
| **Used for** | Generating embed tokens for the report iframe | Executing DAX queries (chatbot NLQ) |
| **Auth type** | Client credentials (app secret or certificate) | Username + password (ROPC flow) or delegated token |
| **RLS enforcement** | Via `effectiveIdentity` in the embed token — specify the end user's UPN or RLS role | Via `impersonatedUserName` in the executeQueries body |
| **Why not use SP for both** | Service principals **cannot** use `impersonatedUserName` in executeQueries on RLS-enabled datasets | — |
| **Why not use master user for embedding** | Service principals scale better, no MFA friction, no shared password rotation risk | — |

**The split is intentional and required.** Service principals are blocked from user impersonation in the executeQueries API when the dataset has RLS. A dedicated Entra service account (no MFA, licensed Power BI Pro or Fabric capacity-backed) is the only supported path for RLS-enforced programmatic DAX execution.

---

## Track 1: Report Embedding (Service Principal)

### Setup

1. Register an app in Microsoft Entra ID (no redirect URI needed for service principal flow)
2. Create a client secret or upload a certificate
3. Add the service principal to the Fabric workspace as **Member** (not Admin — principle of least privilege)
4. Enable the Power BI tenant setting: **"Service principals can use Power BI APIs"**
5. Optionally scope to a specific security group

### Backend: Generate Embed Token

```csharp
// .NET example using Microsoft.PowerBI.Api
var tokenCredentials = new TokenCredentials(await GetServicePrincipalToken(), "Bearer");
var client = new PowerBIClient(new Uri("https://api.powerbi.com"), tokenCredentials);

var generateTokenRequest = new GenerateTokenRequestV2
{
    Reports = new List<ReportTokenRequest>
    {
        new ReportTokenRequest(reportId: reportId, allowEdit: false)
    },
    Datasets = new List<DatasetTokenRequest>
    {
        new DatasetTokenRequest(datasetId: datasetId)
    },
    Identities = new List<EffectiveIdentity>
    {
        new EffectiveIdentity(
            username: currentUser.Email,    // end user's UPN
            roles: new List<string> { currentUser.RlsRole },  // e.g., "RegionViewer"
            datasets: new List<string> { datasetId }
        )
    },
    TargetWorkspaces = new List<WorkspaceInfo>
    {
        new WorkspaceInfo(workspaceId)
    }
};

var embedToken = await client.EmbedToken.GenerateTokenAsync(generateTokenRequest);
// Return embedToken.Token, embedToken.Expiration, plus reportId and embedUrl to the browser
```

### Frontend: Embed the Report

```typescript
import * as pbi from 'powerbi-client';
import { models } from 'powerbi-client';

const powerbi = new pbi.service.Service(
  pbi.factories.hpmFactory,
  pbi.factories.wpmpFactory,
  pbi.factories.routerFactory
);

const config: models.IReportEmbedConfiguration = {
  type: 'report',
  tokenType: models.TokenType.Embed,
  accessToken: embedToken,          // from your backend
  embedUrl: embedUrl,               // from your backend
  id: reportId,
  settings: {
    panes: { filters: { visible: false } }
  }
};

const report = powerbi.embed(document.getElementById('report-container'), config);
```

**RLS is enforced automatically** — the embed token carries the `effectiveIdentity` you set server-side. The end user cannot see data outside their RLS role.

### Token Refresh

Embed tokens expire (typically 1 hour). Handle expiration in the browser:

```typescript
report.on('tokenExpired', async () => {
  const newToken = await fetchFreshEmbedToken(); // call your backend
  await report.setAccessToken(newToken);
});
```

---

## Track 2: Chatbot NLQ — Natural Language → DAX → Results

This is the programmatic Q&A pipeline. All steps happen on your backend.

### The Pipeline

```
User question (NL)
    │
    ▼
1. Fetch semantic model schema (tables, columns, measures, relationships)
    │
    ▼
2. Build prompt: schema + user question → send to Azure OpenAI (GPT-4o)
    │
    ▼
3. Receive DAX query from OpenAI
    │
    ▼
4. Validate DAX (optional: check for dangerous patterns)
    │
    ▼
5. POST /datasets/{id}/executeQueries
   with impersonatedUserName = currentUser.Email
    │
    ▼
6. RLS enforced server-side for that user
    │
    ▼
7. Format tabular result → natural language answer (optional second OpenAI call)
    │
    ▼
8. Return to browser chat UI
```

---

### Step 1: Fetch Schema

Call the Power BI REST API with the service account token. Cache this — schema rarely changes.

```csharp
// GET /groups/{workspaceId}/datasets/{datasetId}/tables
var tables = await powerBIClient.Datasets.GetTablesInGroupAsync(workspaceId, datasetId);

// Build a schema string for the LLM prompt
var schemaBuilder = new StringBuilder();
foreach (var table in tables.Value)
{
    schemaBuilder.AppendLine($"Table: {table.Name}");
    foreach (var col in table.Columns)
        schemaBuilder.AppendLine($"  Column: {col.Name} ({col.DataType})");
    foreach (var measure in table.Measures)
        schemaBuilder.AppendLine($"  Measure: {measure.Name} = {measure.Expression}");
}
```

**Also fetch relationships** via `GET /groups/{workspaceId}/datasets/{datasetId}/relationships` to give the LLM join context.

---

### Step 2 & 3: NL → DAX via Azure OpenAI

```csharp
var systemPrompt = $"""
You are a DAX query generator for a Microsoft Power BI semantic model.
Generate only a single valid DAX EVALUATE expression. Do not explain. Do not include markdown.
Return only raw DAX that can be passed directly to the Power BI executeQueries API.

Semantic model schema:
{schemaString}

Rules:
- Use EVALUATE at the top level
- Use SUMMARIZECOLUMNS or FILTER for aggregations and filters
- Never use DEFINE MEASURE (measures already exist in the model — reference them directly)
- Keep queries focused and minimal
- If the question cannot be answered from this schema, return exactly: UNSUPPORTED
""";

var response = await openAiClient.GetChatCompletionsAsync(
    deploymentOrModelName: "gpt-4o",
    new ChatCompletionsOptions
    {
        Messages =
        {
            new ChatMessage(ChatRole.System, systemPrompt),
            new ChatMessage(ChatRole.User, userQuestion)
        },
        Temperature = 0,   // deterministic output for DAX
        MaxTokens = 500
    }
);

var daxQuery = response.Value.Choices[0].Message.Content.Trim();
```

---

### Step 4: Validate DAX (Security Gate)

Before executing, reject queries that could be used to extract bulk data or probe the schema.

```csharp
private static bool IsSafeDax(string dax)
{
    // Block attempts to enumerate all data
    if (dax.Contains("UNSUPPORTED")) return false;

    var upper = dax.ToUpperInvariant();
    var blocked = new[] { "SELECTCOLUMNS(*", "ALL(", "ALLEXCEPT(", "DETAILROWS(" };
    if (blocked.Any(b => upper.Contains(b))) return false;

    // Must start with EVALUATE
    if (!upper.TrimStart().StartsWith("EVALUATE")) return false;

    return true;
}
```

---

### Step 5: Execute DAX with RLS (Service Account + impersonatedUserName)

```csharp
// Get service account access token (ROPC or client credentials against the service account)
var serviceAccountToken = await GetServiceAccountToken();
var client = new PowerBIClient(new Uri("https://api.powerbi.com"),
    new TokenCredentials(serviceAccountToken, "Bearer"));

var queryRequest = new DatasetExecuteQueriesRequest
{
    Queries = new List<DatasetExecuteQueriesQuery>
    {
        new DatasetExecuteQueriesQuery(daxQuery)
    },
    ImpersonatedUserName = currentUser.Email   // <-- this is what enforces RLS
};

var result = await client.Datasets.ExecuteQueriesInGroupAsync(
    workspaceId, datasetId, queryRequest);

var rows = result.Results[0].Tables[0].Rows;
```

**`impersonatedUserName` requirements:**
- Must be a valid UPN that exists in the tenant
- The service account must have **Build** permission on the dataset (or be a workspace member)
- The dataset must have RLS roles defined — if a user matches no role, they see no data
- Service principal cannot do this — only a licensed Entra user account can use `impersonatedUserName`

**API limits:** 100,000 rows | 1,000,000 values | 15MB response | 120 requests/min/user

---

### Step 6 (Optional): Result → Natural Language

```csharp
var resultJson = JsonSerializer.Serialize(rows.Take(20));  // cap rows sent to LLM

var nlResponse = await openAiClient.GetChatCompletionsAsync(
    deploymentOrModelName: "gpt-4o",
    new ChatCompletionsOptions
    {
        Messages =
        {
            new ChatMessage(ChatRole.System,
                "You are a business intelligence assistant. Convert the following JSON query result " +
                "into a concise, human-readable answer to the user's question. Use numbers as given. " +
                "Do not invent data not present in the result."),
            new ChatMessage(ChatRole.User,
                $"Question: {userQuestion}\n\nData: {resultJson}")
        },
        Temperature = 0.2f,
        MaxTokens = 300
    }
);
```

---

## Service Account Setup (Track 2 Auth)

1. Create a dedicated Entra ID user: e.g., `pbi-query-svc@yourtenant.com`
2. Assign a **Power BI Pro** license (or ensure the workspace is on Fabric/Premium capacity)
3. **Disable MFA** for this account via a Conditional Access policy scoped to this user (or use a named location exclusion)
4. Add to the Fabric workspace as **Viewer** minimum (Build permission on the dataset is also needed for executeQueries)
5. Rotate the password on a schedule; store in Azure Key Vault
6. Use OAuth2 ROPC flow to get tokens programmatically:

```csharp
// ROPC flow for service account (no interactive sign-in)
var app = PublicClientApplicationBuilder
    .Create(clientId)
    .WithAuthority($"https://login.microsoftonline.com/{tenantId}")
    .Build();

var result = await app.AcquireTokenByUsernamePassword(
    scopes: new[] { "https://analysis.windows.net/powerbi/api/.default" },
    username: serviceAccountUpn,
    password: new NetworkCredential("", serviceAccountPassword).SecurePassword
).ExecuteAsync();
```

> **Security note:** Store `serviceAccountPassword` in Azure Key Vault. Never hardcode or log it. Rotate quarterly.

---

## Token Caching Strategy

Both tokens are expensive to acquire. Cache them with a buffer before expiry.

```csharp
public class TokenCache
{
    private string _servicePrincipalToken;
    private string _serviceAccountToken;
    private DateTimeOffset _spExpiry;
    private DateTimeOffset _saExpiry;
    private static readonly TimeSpan Buffer = TimeSpan.FromMinutes(5);

    public async Task<string> GetServicePrincipalTokenAsync()
    {
        if (_servicePrincipalToken == null || DateTimeOffset.UtcNow >= _spExpiry - Buffer)
        {
            var result = await AcquireServicePrincipalToken();
            _servicePrincipalToken = result.AccessToken;
            _spExpiry = result.ExpiresOn;
        }
        return _servicePrincipalToken;
    }
    // Same pattern for service account token
}
```

---

## RLS Validation Checklist

Before going to production, verify RLS is correctly enforced end-to-end:

- [ ] RLS roles are defined on the Fabric semantic model (not just in the .pbix — published to service)
- [ ] Every end-user UPN maps to exactly one RLS role (or zero = sees nothing)
- [ ] `effectiveIdentity` in embed token matches the user's UPN and correct role
- [ ] `impersonatedUserName` in executeQueries matches the same UPN
- [ ] Test with a user that has no RLS role — confirm empty results, not an error or unfiltered data
- [ ] Test cross-tenant UPNs if applicable
- [ ] Confirm service principal has no direct data access path that bypasses RLS

---

## Security Considerations

| Risk | Mitigation |
|---|---|
| LLM generates a query that returns bulk data | DAX safety validation gate (Step 4); row limit in Step 5 |
| Prompt injection via user question | Sanitize user input; use a separate system/user message boundary; never interpolate raw user text into the system prompt |
| Service account credentials exposed | Store in Azure Key Vault; inject at runtime via Managed Identity; never log tokens |
| User impersonates another UPN | Your app controls what UPN is passed to `impersonatedUserName` — always take it from the authenticated session, never from user input |
| DAX execution exposes data outside RLS | `impersonatedUserName` is enforced by Power BI service-side; verify with test accounts |
| Embed token forwarded to another user | Tokens are scoped to a single user's identity; a forwarded token shows the original user's RLS-filtered view, not the recipient's |

---

## Complete Request Flow (End-to-End)

```
1. Customer logs into your app (Entra ID, your own auth, whatever)
2. Your app knows: userUpn = "alice@customer.com", rlsRole = "RegionEast"

── Report View ──
3. Browser calls your backend: GET /api/embed-token
4. Backend (service principal) calls GenerateToken with effectiveIdentity(alice, RegionEast)
5. Returns { embedToken, embedUrl, reportId }
6. Browser embeds report — Alice sees only RegionEast data

── Chat Question ──
7. Alice types: "What were my top 5 products by revenue last quarter?"
8. Browser calls your backend: POST /api/chat { question: "...", userId: "alice" }
9. Backend fetches cached schema
10. Backend calls Azure OpenAI → receives DAX
11. Backend validates DAX (safety gate)
12. Backend calls executeQueries with impersonatedUserName="alice@customer.com"
13. Power BI enforces RegionEast RLS on the DAX result
14. Backend optionally calls OpenAI to format result as NL
15. Returns answer to Alice's chat UI
```

---

## Tech Stack Checklist

| Component | Recommendation |
|---|---|
| Backend | .NET 8 / Node.js |
| Power BI SDK | `Microsoft.PowerBI.Api` (NuGet) or `@azure/identity` + REST calls (Node) |
| Entra auth | `Microsoft.Identity.Client` (MSAL.NET) |
| Azure OpenAI | `Azure.AI.OpenAI` SDK |
| Secret storage | Azure Key Vault + Managed Identity |
| Schema cache | In-memory + Redis (invalidate on dataset refresh webhook) |
| Token cache | In-memory with expiry buffer (MSAL handles this natively) |
| Frontend embed | `powerbi-client` or `powerbi-client-react` |

---

## Key Microsoft Documentation

- [App owns data tutorial](https://learn.microsoft.com/en-us/power-bi/developer/embedded/embed-sample-for-customers)
- [GenerateToken API with effectiveIdentity](https://learn.microsoft.com/en-us/rest/api/power-bi/embed-token/generate-token)
- [Execute Queries REST API](https://learn.microsoft.com/en-us/rest/api/power-bi/datasets/execute-queries)
- [RLS in Power BI Embedded](https://learn.microsoft.com/en-us/power-bi/developer/embedded/embedded-row-level-security)
- [Service principal setup for embedding](https://learn.microsoft.com/en-us/power-bi/developer/embedded/embed-service-principal)
- [Tenant settings for service principals](https://learn.microsoft.com/en-us/power-bi/admin/service-admin-portal-developer)
- [powerbi-client JS SDK](https://learn.microsoft.com/en-us/javascript/api/overview/powerbi/embedded-analytics-client-api)
- [MSAL ROPC flow](https://learn.microsoft.com/en-us/azure/active-directory/develop/v2-oauth-ropc)
