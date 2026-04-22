require 'sinatra'
require 'sinatra/json'
require_relative 'config'
require_relative 'powerbi_service'
require_relative 'chat_engine'

set :public_folder, File.join(File.dirname(__FILE__), 'static')
set :static, true
set :views, File.join(File.dirname(__FILE__), 'templates')

# Sinatra doesn't have a direct equivalent to lifespan, but we can use before
configure do
  Settings.logger.info "Power BI RLS Chatbot starting …"
  schema_path = File.join(File.dirname(__FILE__), "sample_report", "schema.json")
  rls_path = File.join(File.dirname(__FILE__), "rls_config.json")
  if !File.exist?(schema_path) || !File.exist?(rls_path)
    Settings.logger.warn(
      "┌────────────────────────────────────────────────────┐\n" \
      "│  First run detected!  Run:  ruby setup.rb          │\n" \
      "│  to auto-discover schema and RLS configuration.    │\n" \
      "└────────────────────────────────────────────────────┘"
    )
  end
end

get '/' do
  erb :index, locals: { demo_users: Settings.demo_users }
end

post '/api/embed-token' do
  payload = JSON.parse(request.body.read)
  rls_username = payload['rls_username']
  
  begin
    data = PowerBIService.generate_embed_token(rls_username)
    json data
  rescue => e
    status 500
    json({ error: e.message })
  end
end

post '/api/chat/generate-dax' do
  payload = JSON.parse(request.body.read)
  message = payload['message']
  rls_username = payload['rls_username']
  history = payload['history'] || []

  begin
    result = ChatEngine.generate_dax(message, rls_username, history)
    json result
  rescue => e
    status 500
    json({ error: e.message })
  end
end

post '/api/chat/execute-dax' do
  payload = JSON.parse(request.body.read)
  dax = payload['dax']
  rls_username = payload['rls_username'].to_s

  begin
    rows = PowerBIService.execute_dax(dax, rls_username: rls_username)
    json({ results: rows })
  rescue => e
    status 500
    json({ error: e.message })
  end
end

post '/api/chat/summarize' do
  payload = JSON.parse(request.body.read)
  message = payload['message']
  dax = payload['dax']
  results = payload['results'] || []
  history = payload['history'] || []

  begin
    answer = ChatEngine.summarize(message, dax, results, history)
    json({ answer: answer })
  rescue => e
    status 500
    json({ error: e.message })
  end
end

# Backward-compatible single endpoint that orchestrates all three phases.
post '/api/chat' do
  payload = JSON.parse(request.body.read)
  message = payload['message']
  rls_username = payload['rls_username']
  history = payload['history'] || []

  begin
    phase1 = ChatEngine.generate_dax(message, rls_username, history)
    if phase1['mode'] == 'answer'
      json({ answer: phase1['answer'], data: [] })
    else
      rows = PowerBIService.execute_dax(phase1['dax'], rls_username: rls_username.to_s)
      answer = ChatEngine.summarize(message, phase1['dax'], rows, history)
      json({ answer: answer, data: rows, dax: phase1['dax'] })
    end
  rescue => e
    status 500
    json({ error: e.message })
  end
end

get '/health' do
  json({ status: 'ok' })
end
