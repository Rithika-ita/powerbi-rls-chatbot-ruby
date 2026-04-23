/**
 * Power BI RLS Chatbot — Frontend logic
 * Handles: user switching, report embedding, chat interaction
 */

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
let currentUser = null;       // { displayName, rlsUsername }
let chatHistory = [];         // {role, content}[]
let report = null;            // Power BI JS embed reference
let isLoading = false;

const API = {
    embedToken:   '/api/embed-token',
    generateDax:  '/api/chat/generate-dax',
    executeDax:   '/api/chat/execute-dax',
    summarize:    '/api/chat/summarize',
};

// ---------------------------------------------------------------------------
// DOM references
// ---------------------------------------------------------------------------
const userSelect       = document.getElementById('userSelect');
const reportContainer  = document.getElementById('reportContainer');
const chatMessages     = document.getElementById('chatMessages');
const chatInput        = document.getElementById('chatInput');
const sendBtn          = document.getElementById('sendBtn');
const rlsTag           = document.getElementById('rlsTag');
const rlsTagReport     = document.getElementById('rlsTagReport');

// ---------------------------------------------------------------------------
// Initialise
// ---------------------------------------------------------------------------
document.addEventListener('DOMContentLoaded', () => {
    userSelect.addEventListener('change', onUserChange);
    sendBtn.addEventListener('click', onSend);
    chatInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); onSend(); }
    });

    // Auto-select first user
    if (userSelect.options.length > 1) {
        userSelect.selectedIndex = 1;
        onUserChange();
    }
});

// ---------------------------------------------------------------------------
// User switching
// ---------------------------------------------------------------------------
async function onUserChange() {
    const option = userSelect.options[userSelect.selectedIndex];
    if (!option.value) return;

    currentUser = {
        displayName: option.text,
        rlsUsername: option.value,
    };

    rlsTag.textContent = `RLS: ${currentUser.rlsUsername}`;
    if (rlsTagReport) rlsTagReport.textContent = `RLS: ${currentUser.rlsUsername}`;

    // Reset chat
    chatHistory = [];
    chatMessages.innerHTML = '';
    addWelcomeCard();

    // Embed report
    await embedReport();
}

// ---------------------------------------------------------------------------
// Power BI Embedding
// ---------------------------------------------------------------------------
async function embedReport() {
    reportContainer.innerHTML = '<div class="placeholder-msg"><p>Loading report…</p></div>';

    try {
        const res = await fetch(API.embedToken, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ rls_username: currentUser.rlsUsername }),
        });

        if (!res.ok) throw new Error(`Embed token error: ${res.status}`);
        const data = await res.json();

        reportContainer.innerHTML = '';

        const models = window['powerbi-client'].models;
        const config = {
            type: 'report',
            tokenType: models.TokenType.Embed,
            accessToken: data.embedToken,
            embedUrl: data.embedUrl,
            id: data.reportId,
            permissions: models.Permissions.Read,
            settings: {
                panes: {
                    filters: { expanded: false, visible: false },
                    pageNavigation: { visible: true },
                },
                background: models.BackgroundType.Transparent,
            },
        };

        report = powerbi.embed(reportContainer, config);

        report.on('error', (event) => {
            console.error('PBI embed error:', event.detail);
        });
    } catch (err) {
        console.error(err);
        reportContainer.innerHTML = `
            <div class="placeholder-msg">
                <p><strong>Could not load report</strong></p>
                <p>${err.message}</p>
                <p style="margin-top:12px;font-size:12px;color:#94a3b8;">
                    Make sure your .env is configured and the Power BI service principal
                    has access to the workspace.
                </p>
            </div>`;
    }
}

// ---------------------------------------------------------------------------
// Chat
// ---------------------------------------------------------------------------
function addWelcomeCard() {
    const div = document.createElement('div');
    div.className = 'welcome-card';
    div.innerHTML = `
        <h3>👋 Welcome, ${currentUser.displayName}!</h3>
        <p>I can answer questions about your data. Your view is filtered by
        Row-Level Security — you'll only see data you have access to.</p>
        <p><strong>Try asking:</strong></p>
        <ul>
            <li>"What were total sales last quarter?"</li>
            <li>"Show me top 5 products by revenue"</li>
            <li>"Compare this year vs last year"</li>
        </ul>
    `;
    chatMessages.appendChild(div);
}

function addMessage(role, content) {
    const div = document.createElement('div');
    div.className = `message ${role}`;

    // Simple Markdown rendering for bot messages
    let html = content;
    if (role === 'bot') {
        // Strip ALL HTML tags and any DAX code the model included.
        // 1. Remove every HTML tag (keeps inner text)
        // 2. Remove "-- Generated DAX" and everything after
        // 3. Remove any remaining EVALUATE block
        const clean = content
            .replace(/<\/?[a-z][^>]*>/gi, '')     // all HTML tags
            .replace(/--\s*Generated\s+DAX[\s\S]*$/i, '')  // DAX comment tail
            .replace(/\bEVALUATE\b[\s\S]*$/i, '')          // raw EVALUATE tail
            .replace(/```[\s\S]*?```/g, '')                // fenced code blocks
            .replace(/\n{3,}/g, '\n\n')
            .trim();
        html = renderMarkdown(clean);
    }

    const time = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    div.innerHTML = `${html}<span class="timestamp">${time}</span>`;
    chatMessages.appendChild(div);
    chatMessages.scrollTop = chatMessages.scrollHeight;
}

function showTyping() {
    const div = document.createElement('div');
    div.className = 'typing-indicator';
    div.id = 'typingIndicator';
    div.innerHTML = '<span></span><span></span><span></span>';
    chatMessages.appendChild(div);
    chatMessages.scrollTop = chatMessages.scrollHeight;
}

function hideTyping() {
    const el = document.getElementById('typingIndicator');
    if (el) el.remove();
}

async function onSend() {
    const text = chatInput.value.trim();
    if (!text || !currentUser || isLoading) return;

    chatInput.value = '';
    addMessage('user', text);
    chatHistory.push({ role: 'user', content: text });

    isLoading = true;
    sendBtn.disabled = true;
    showTyping();

    try {
        // Phase 1: Generate DAX or conversational answer
        const phase1Res = await fetch(API.generateDax, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                message: text,
                rls_username: currentUser.rlsUsername,
                history: chatHistory,
            }),
        });
        if (!phase1Res.ok) throw new Error(await extractApiError(phase1Res, 'Generate DAX'));
        const phase1 = await phase1Res.json();

        hideTyping();

        if (phase1.mode === 'answer') {
            const direct = phase1.answer || 'I can help with data questions from your model.';
            addMessage('bot', direct);
            chatHistory.push({ role: 'assistant', content: direct });
            return;
        }

        const dax = phase1.dax;
        if (!dax) throw new Error('No DAX returned from generator phase');

        // Phase 2: Execute DAX server-side
        const phase2Res = await fetch(API.executeDax, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                dax,
                rls_username: currentUser.rlsUsername,
            }),
        });
        if (!phase2Res.ok) throw new Error(await extractApiError(phase2Res, 'Execute DAX'));
        const phase2 = await phase2Res.json();
        const rows = Array.isArray(phase2.results) ? phase2.results : [];

        // Phase 3: Summarize
        const phase3Res = await fetch(API.summarize, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                message: text,
                dax,
                results: rows,
                history: chatHistory,
            }),
        });
        if (!phase3Res.ok) throw new Error(await extractApiError(phase3Res, 'Summarize'));
        const phase3 = await phase3Res.json();

        const answer = phase3.answer || 'Sorry, I could not summarize the results.';
        addMessage('bot', answer);
        if (rows.length > 0) {
            addResultPreview(rows);
        }
        chatHistory.push({ role: 'assistant', content: answer });
    } catch (err) {
        hideTyping();
        addMessage('bot', `⚠️ Error: ${err.message}`);
    } finally {
        isLoading = false;
        sendBtn.disabled = false;
        chatInput.focus();
    }
}

async function extractApiError(response, phaseLabel) {
    let detail = '';

    try {
        const payload = await response.json();
        detail = (payload && payload.error) ? String(payload.error) : '';
    } catch (_e) {
        // Ignore JSON parse failures and fall back to status text.
    }

    const base = `${phaseLabel} error: ${response.status}`;
    return detail ? `${base} - ${detail}` : base;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function escapeHtml(str) {
    return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function renderMarkdown(text) {
    // Very basic Markdown → HTML (bold, italic, code, tables, line breaks)
    let html = escapeHtml(text);

    // Strip code blocks (DAX/SQL shown separately in result preview)
    html = html.replace(/```[\s\S]*?```/g, '');
    // Collapse multiple blank lines left after stripping code blocks
    html = html.replace(/\n{3,}/g, '\n\n');

    // Bold
    html = html.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');

    // Italic
    html = html.replace(/\*(.+?)\*/g, '<em>$1</em>');

    // Inline code
    html = html.replace(/`(.+?)`/g, '<code style="background:#e2e8f0;padding:1px 4px;border-radius:3px;font-size:12px;">$1</code>');

    // Markdown tables
    html = html.replace(/((?:\|.+\|\n?)+)/g, (match) => {
        const lines = match.trim().split('\n').filter(l => l.trim());
        if (lines.length < 2) return match;

        const parseRow = (line) => line.split('|').filter(c => c.trim()).map(c => c.trim());
        const headers = parseRow(lines[0]);

        // Check for separator row
        let dataStart = 1;
        if (lines[1] && /^[\s|:-]+$/.test(lines[1])) dataStart = 2;

        let table = '<table><thead><tr>' +
            headers.map(h => `<th>${h}</th>`).join('') +
            '</tr></thead><tbody>';

        for (let i = dataStart; i < lines.length; i++) {
            const cells = parseRow(lines[i]);
            table += '<tr>' + cells.map(c => `<td>${c}</td>`).join('') + '</tr>';
        }
        table += '</tbody></table>';
        return table;
    });

    // Line breaks
    html = html.replace(/\n/g, '<br>');

    return html;
}

function addResultPreview(rows) {
    const maxRows = 25;
    const previewRows = rows.slice(0, maxRows);
    const columns = Object.keys(previewRows[0] || {});

    if (columns.length === 0) return;

    const div = document.createElement('div');
    div.className = 'message bot result-preview';

    const tableHead = columns.map((col) => `<th>${escapeHtml(col)}</th>`).join('');
    const tableBody = previewRows.map((row) => {
        const cells = columns.map((col) => `<td>${formatCellValue(row[col])}</td>`).join('');
        return `<tr>${cells}</tr>`;
    }).join('');

    const footer = rows.length > maxRows
        ? `<div class="result-preview-note">Showing first ${maxRows.toLocaleString()} of ${rows.length.toLocaleString()} rows.</div>`
        : `<div class="result-preview-note">Showing ${rows.length.toLocaleString()} row${rows.length === 1 ? '' : 's'}.</div>`;

    div.innerHTML = `
        <div class="result-preview-meta">
            <span class="meta-pill">Rows: ${rows.length.toLocaleString()}</span>
            <span class="meta-pill">Columns: ${columns.length.toLocaleString()}</span>
        </div>
        <details open>
            <summary>Data preview</summary>
            <div class="result-preview-table-wrap">
                <table>
                    <thead><tr>${tableHead}</tr></thead>
                    <tbody>${tableBody}</tbody>
                </table>
            </div>
            ${footer}
        </details>
        <span class="timestamp">${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</span>
    `;

    chatMessages.appendChild(div);
    chatMessages.scrollTop = chatMessages.scrollHeight;
}

function formatCellValue(value) {
    if (value === null || value === undefined) return '<em>-</em>';
    if (typeof value === 'number') return Number.isFinite(value) ? value.toLocaleString() : escapeHtml(String(value));
    return escapeHtml(String(value));
}
