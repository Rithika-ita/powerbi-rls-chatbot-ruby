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
    embedToken: '/api/embed-token',
    chat:       '/api/chat',
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
        html = renderMarkdown(content);
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
        const res = await fetch(API.chat, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                message: text,
                rls_username: currentUser.rlsUsername,
                history: chatHistory,
            }),
        });

        if (!res.ok) throw new Error(`Chat error: ${res.status}`);
        const data = await res.json();

        hideTyping();

        // Optionally show DAX
        let answer = data.answer || 'Sorry, I could not generate an answer.';
        if (data.dax) {
            answer += `\n\n<div class="dax-block">-- Generated DAX\n${escapeHtml(data.dax)}</div>`;
        }

        addMessage('bot', answer);
        chatHistory.push({ role: 'assistant', content: data.answer });
    } catch (err) {
        hideTyping();
        addMessage('bot', `⚠️ Error: ${err.message}`);
    } finally {
        isLoading = false;
        sendBtn.disabled = false;
        chatInput.focus();
    }
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

    // Code blocks
    html = html.replace(/```(\w*)\n([\s\S]*?)```/g, '<div class="dax-block">$2</div>');

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
